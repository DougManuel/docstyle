local xml = require("xml")
local strictness = require("xml.strictness")
local diagnostic = require("lib.diagnostic")

-- Valid UTF-8 with no carriage return and no character XML forbids takes a
-- fast decode path; everything else takes the full path. The fast path marks
-- itself by an offset map computed on demand (a metatable), which these
-- tests use to prove each input took the path they claim.
local function took_fast_path(decoded)
  return getmetatable(decoded.boundaries) ~= nil
end

-- Offsets at every character boundary, including the end of the text.
local function boundaries_at_characters(text)
  local offsets = {}
  for position in utf8.codes(text) do offsets[#offsets + 1] = position - 1 end
  offsets[#offsets + 1] = #text
  return offsets
end

local ORDINARY = {
  ascii = '<?xml version="1.0"?><r a="1">text</r>',
  two_byte = "<r>caf\u{e9}</r>",
  three_byte = "<r>\u{20ac} \u{4e2d}\u{6587}</r>",
  four_byte = "<r>\u{1f600}</r>",
  bom = "\239\187\191<r>\u{e9}</r>",
  tab_and_line_feed = "<r>\ta\nb</r>",
  allowed_controls = "<r>\127\u{85}\u{9f}</r>",
  edges = "<r>\u{d7ff}\u{e000}\u{fffd}\u{10000}\u{10ffff}</r>",
}

local FALLBACK_VALID = {
  carriage_return = "<r>a\rb</r>",
  crlf = "<r>a\r\nb</r>",
  utf16le = "\255\254<\0r\0/\0>\0",
  utf16be = "\254\255\0<\0r\0/\0>",
}

local FALLBACK_INVALID = {
  nul = "<r>\0</r>",
  control = "<r>\1</r>",
  form_feed = "<r>\12</r>",
  fffe = "<r>\239\191\190</r>",
  ffff = "<r>\239\191\191</r>",
  overlong = "<r>\192\128</r>",
  surrogate = "<r>\237\160\128</r>",
  above_max = "<r>\244\144\128\128</r>",
  lone_continuation = "<r>\128</r>",
  truncated = "<r>\226\130",
}

return {
  {
    name = "ordinary UTF-8 takes the fast path and matches the full path",
    gate = "functional",
    stage = "xml",
    fn = function()
      for label, bytes in pairs(ORDINARY) do
        local fast = strictness._decode_document(bytes)
        local full = strictness._decode_document(bytes, true)
        assert(took_fast_path(fast), label .. " did not take the fast path")
        assert(not took_fast_path(full), label)
        assert(fast.text == full.text, label .. ": text differs")
        assert(fast.encoding == full.encoding and fast.bom == full.bom, label)
        for _, offset in ipairs(boundaries_at_characters(full.text)) do
          assert(fast.boundaries[offset] == full.boundaries[offset],
            ("%s: offset %d maps to %s, full path %s"):format(label, offset,
              tostring(fast.boundaries[offset]),
              tostring(full.boundaries[offset])))
        end
        assert(fast.boundaries[#fast.text + 1] == nil, label)
        assert(fast.boundaries[-1] == nil, label)
      end
    end,
  },
  {
    name = "other valid input takes the full path with the same result",
    gate = "functional",
    stage = "xml",
    fn = function()
      for label, bytes in pairs(FALLBACK_VALID) do
        local decoded = strictness._decode_document(bytes)
        local full = strictness._decode_document(bytes, true)
        assert(not took_fast_path(decoded), label .. " took the fast path")
        assert(decoded.text == full.text, label)
      end
      local crlf = strictness._decode_document(FALLBACK_VALID.crlf)
      assert(crlf.text == "<r>a\nb</r>", "line ends are still normalized")
    end,
  },
  {
    name = "invalid input reports the same diagnostic on both paths",
    gate = "safety",
    stage = "xml",
    fn = function()
      for label, bytes in pairs(FALLBACK_INVALID) do
        local ok, err = diagnostic.capture(function()
          return strictness._decode_document(bytes)
        end)
        local full_ok, full_err = diagnostic.capture(function()
          return strictness._decode_document(bytes, true)
        end)
        assert(not ok and not full_ok, label .. " was accepted")
        assert(err.code == full_err.code, label .. ": " .. tostring(err.code))
        assert(err.context.offset == full_err.context.offset, label)
        assert(err.context.codepoint == full_err.context.codepoint, label)
      end
    end,
  },
  {
    name = "an edit after multibyte text keeps every other byte",
    gate = "preservation",
    stage = "xml",
    fn = function()
      local part = "\239\187\191<r a=\"1\">\u{1f600} caf\u{e9}<b c=\"x\"/></r>"
      local doc = xml.parse(part)
      local child = xml.find_all(doc, "", "b")[1]
      xml.set_attribute(child, "", "c", "y")
      assert(xml.serialize(doc) == part:gsub('c="x"', 'c="y"'))
    end,
  },
  {
    name = "plain UTF-8 text decodes without per-character work",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- Before the fast path, 1 MiB of text took about 0.5 s on the
      -- reference Mac; with it, under 0.05 s. The limit leaves room for a
      -- slower CI runner, and the best of three runs is used so one noisy
      -- sample cannot fail the test.
      local part = "<r>" .. string.rep("x", 1024 * 1024 - 7) .. "</r>"
      local seconds = math.huge
      for _ = 1, 3 do
        collectgarbage("collect")
        local started = pandoc.system.cputime()
        xml.parse(part)
        seconds = math.min(seconds, (pandoc.system.cputime() - started) / 1e12)
      end
      assert(seconds < 0.25, ("1 MiB of text took %.2f s"):format(seconds))
    end,
  },
}
