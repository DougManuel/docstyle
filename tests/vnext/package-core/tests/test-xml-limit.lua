local xml = require("xml")
local diagnostic = require("lib.diagnostic")
local strictness = require("xml.strictness")
local overlay = require("xml.token_overlay")

-- A stand-in backend reporting the given element names, so the step that
-- maps backend aliases back to real names can be tested on its own (#55).
local function fake_backend(names)
  return {
    xmlParser = function(handler)
      return {
        options = {},
        parse = function()
          for _, name in ipairs(names) do handler:starttag(name) end
          for index = #names, 1, -1 do handler:endtag(names[index]) end
        end,
      }
    end,
  }
end

-- Approved in #53: 8 MiB keeps worst-case parse inside the programme's
-- five-second advisory CPU target while giving about 3x headroom over the
-- largest real part surveyed (2.7 MB).
local LIMIT = 8 * 1024 * 1024

-- Text-content padding, never one large attribute value (see #50).
local function text_part(total_bytes)
  local head, tail = '<?xml version="1.0"?><r>', '</r>'
  return head .. string.rep("x", total_bytes - #head - #tail) .. tail
end

return {
  {
    name = "the default XML-part input-byte limit is eight MiB",
    gate = "safety",
    stage = "xml",
    fn = function()
      assert(xml.MAX_INPUT_BYTES == LIMIT, tostring(xml.MAX_INPUT_BYTES))
    end,
  },
  {
    name = "a real-sized part above the former one-MiB limit parses by default",
    gate = "functional",
    stage = "xml",
    fn = function()
      -- The size of the largest document.xml seen in the local survey
      -- that the one-MiB limit rejected.
      local doc = xml.parse(text_part(1702258))
      assert(doc, "a 1.7 MB part must parse under the default limit")
    end,
  },
  {
    name = "an over-limit part is rejected before parsing",
    gate = "safety",
    stage = "xml",
    fn = function()
      local oversize = string.rep("x", LIMIT + 1)
      local ok, err = diagnostic.capture(function()
        xml.parse(oversize)
      end)
      assert(not ok, "over-limit input must be rejected")
      assert(err.code == "xml.input-too-large", tostring(err))
      assert(err.context.actual == LIMIT + 1, tostring(err.context.actual))
      assert(err.context.limit == LIMIT, tostring(err.context.limit))
    end,
  },
  {
    name = "a malformed limit override is rejected",
    gate = "safety",
    stage = "xml",
    fn = function()
      for _, bad in ipairs({ -1, 1.5, "1048576", true }) do
        local ok, err = diagnostic.capture(function()
          xml.parse("<r/>", { max_input_bytes = bad })
        end)
        assert(not ok, "malformed limit must be rejected: " .. tostring(bad))
        assert(err.code == "xml.invalid-limit", tostring(err))
      end
    end,
  },
  {
    name = "an explicit override replaces the default limit",
    gate = "functional",
    stage = "xml",
    fn = function()
      -- Padding lives in text content, not a single attribute value: the
      -- vendored LuaXML backend (xml/vendor/luaxml-mod-xml.lua, pinned
      -- immutable by provenance hash) has an O(n^2) blowup specific to one
      -- large attribute value (measured: ~71s at 80,000 bytes, scaling as
      -- size^2 -- a 1,100,000-byte single attribute would take on the order
      -- of hours). Realistic WordprocessingML parts never carry an
      -- attribute value anywhere near this large (the WP0 survey's largest
      -- attribute values are a few dozen bytes), so this substitution keeps
      -- the same byte size and the same override assertion while avoiding
      -- a pre-existing backend pathology that has nothing to do with the
      -- input-byte limit this test exists to exercise.
      -- Lowering the limit shows the override takes effect without
      -- parsing a >8 MiB part in the suite (about 4 s of CPU); the
      -- benchmark exercises overrides above the default.
      local part = text_part(1100000)
      assert(xml.parse(part), "the part parses under the default")
      local ok, err = diagnostic.capture(function()
        xml.parse(part, { max_input_bytes = 1048576 })
      end)
      assert(not ok, "a lower override must reject the same part")
      assert(err.code == "xml.input-too-large", tostring(err))
      assert(err.context.limit == 1048576, tostring(err.context.limit))
    end,
  },
  {
    name = "a long alphanumeric attribute value parses in linear time",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- #50: the vendored backend backtracks quadratically inside one long
      -- alphanumeric attribute value (recorded: 40,000 bytes took ~21 s).
      -- The backend only cross-checks structure, so it never sees values.
      local value = string.rep("a1", 20000)
      local part = '<r xmlns:w="urn:w" w:v="' .. value .. '"/>'
      local started = pandoc.system.cputime()
      local doc = xml.parse(part)
      local seconds = (pandoc.system.cputime() - started) / 1e12
      assert(seconds < 1, ("40,000-byte attribute took %.2f s"):format(seconds))
      assert(xml.get_attribute(doc.root, "urn:w", "v") == value,
        "the strict layer still reports the full value")
    end,
  },
  {
    name = "an edit beside a long attribute value preserves its bytes",
    gate = "preservation",
    stage = "xml",
    fn = function()
      local value = string.rep("Zz9", 100000)
      local part = '<r xmlns:w="urn:w" w:v="' .. value .. '" w:n="1"/>'
      local doc = xml.parse(part)
      xml.set_attribute(doc.root, "urn:w", "n", "2")
      local edited = xml.serialize(doc)
      assert(edited == part:gsub('w:n="1"', 'w:n="2"'),
        "only the edited attribute changes")
    end,
  },
  {
    name = "long names reach the backend only as short aliases",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- #55: the vendored backend is superlinear in name length, so its
      -- copy of the part carries a short alias for every name component.
      local long = string.rep("n", 5000)
      local part = '<?' .. long .. 'pi data?>' ..
        '<' .. long .. 'p:r xmlns:' .. long .. 'p="urn:p" ' ..
        long .. 'a="1"><' .. long .. 'e/></' .. long .. 'p:r>'
      local inspected = strictness.inspect(part)
      assert(not inspected.semantic_xml:find(long, 1, true),
        "a long name reached the backend")
      local doc = xml.parse(part)
      assert(doc.root.name.uri == "urn:p" and doc.root.name.local_name == "r",
        "the strict layer keeps the real names")
      assert(xml.get_attribute(doc.root, "", long .. "a") == "1")
    end,
  },
  {
    name = "the backend copy aliases names consistently by first appearance",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- Prefix structure survives, the reserved xml and xmlns prefixes stay
      -- as written, and attribute values stay empty (#50).
      local part = '<?xml version="1.0"?>' ..
        '<?mso-application progid="Word.Document"?>' ..
        '<w:document xmlns:w="urn:w" xml:space="preserve" w:val="1">' ..
        '<w:body/></w:document>'
      local backend = strictness.inspect(part).semantic_xml
      local expected = '<?xml version="1.0"?>' ..
        '<?n1 progid="Word.Document"?>' ..
        '<n2:n3 xmlns:n2="" xml:n4="" n2:n5="">' ..
        '<n2:n6/></n2:n3>'
      assert(backend == expected, backend)
    end,
  },
  {
    name = "long names parse in linear time",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- #55, recorded before the fix: one 20,000-byte element name took
      -- 7.6 s, and 10,000-byte attribute names, prefixes and processing-
      -- instruction targets took 1.0 to 2.9 s each.
      local long = string.rep("n", 20000)
      local shapes = {
        { "element", '<' .. long .. '/>' },
        { "attribute", '<r ' .. long .. '="1"/>' },
        { "prefix", '<' .. long .. ':r xmlns:' .. long .. '="urn:p"/>' },
        { "processing-instruction", '<?' .. long .. ' data?><r/>' },
      }
      for _, shape in ipairs(shapes) do
        local started = pandoc.system.cputime()
        xml.parse(shape[2])
        local seconds = (pandoc.system.cputime() - started) / 1e12
        assert(seconds < 1, ("20,000-byte %s name took %.2f s"):format(
          shape[1], seconds))
      end
    end,
  },
  {
    name = "backend names are compared after mapping aliases back",
    gate = "safety",
    stage = "xml",
    fn = function()
      local part = "<w:r xmlns:w='urn:w'/>"
      local inspected = strictness.inspect(part)
      local events = overlay.luaxml_events(fake_backend({ "n1:n2" }),
        inspected.semantic_xml, inspected.backend_names)
      assert(events[1].qname == "w:r", tostring(events[1].qname))
      overlay.bind(part, inspected, events, "test")
      -- With an alias map, any name outside it is refused, reporting the
      -- name the backend gave. That includes the real, unaliased name: a
      -- backend that saw the original text must not pass (found in
      -- review).
      for _, reported in ipairs({ "n9:n2", "w:r" }) do
        local ok, err = diagnostic.capture(function()
          overlay.luaxml_events(fake_backend({ reported }),
            inspected.semantic_xml, inspected.backend_names)
        end)
        assert(not ok and err.code == "xml.backend-mismatch",
          reported .. ": " .. tostring(err and err.code))
        assert(err.context.backend_qname == reported,
          tostring(err.context.backend_qname))
      end
      -- The same holds for processing-instruction targets.
      local pi_part = "<?mso-application progid='x'?><r/>"
      local pi_inspected = strictness.inspect(pi_part)
      local pi_backend = {
        xmlParser = function(handler)
          return {
            options = {},
            parse = function()
              handler:pi("mso-application", { _text = "progid='x'" })
              handler:starttag("n2")
              handler:endtag("n2")
            end,
          }
        end,
      }
      local ok, err = diagnostic.capture(function()
        overlay.luaxml_events(pi_backend, pi_inspected.semantic_xml,
          pi_inspected.backend_names)
      end)
      assert(not ok and err.code == "xml.backend-mismatch",
        tostring(err and err.code))
      assert(err.context.backend_qname == "mso-application",
        tostring(err.context.backend_qname))
      -- A caller that supplies no map gets names as the backend reports them.
      local plain = overlay.luaxml_events(fake_backend({ "w:r" }), part)
      assert(plain[1].qname == "w:r", tostring(plain[1].qname))
    end,
  },
  {
    name = "names keep their meaning where ASCII and other characters meet",
    gate = "functional",
    stage = "xml",
    fn = function()
      -- Plain-ASCII names take a fast path; any other name is read and
      -- validated character by character. These shapes sit on the boundary.
      local accepted = {
        { "<abc/>", "abc" },
        { "<abc\u{e9}/>", "abc\u{e9}" },
        { "<\u{e9}abc/>", "\u{e9}abc" },
        { "<a\u{b7}b/>", "a\u{b7}b" },
        { "<a-b.c_d9/>", "a-b.c_d9" },
      }
      for _, case in ipairs(accepted) do
        local doc = xml.parse(case[1])
        assert(doc.root.name.local_name == case[2], case[1])
      end
      local prefixed = xml.parse(
        "<w:\u{e9} xmlns:w='urn:w' w:a\u{b7}b='1'/>")
      assert(prefixed.root.name.uri == "urn:w" and
        prefixed.root.name.local_name == "\u{e9}")
      assert(xml.get_attribute(prefixed.root, "urn:w", "a\u{b7}b") == "1")
      local rejected = {
        { "<1a/>", "xml.invalid-name" },
        { "<-a/>", "xml.invalid-name" },
        { "<\u{b7}a/>", "xml.invalid-name" },
        { "<a:1b xmlns:a='urn:a'/>", "xml.invalid-name" },
        { "<r a:-b='1' xmlns:a='urn:a'/>", "xml.invalid-name" },
        -- A no-break space is neither a name character nor XML whitespace.
        { "<a\u{a0}b='1'/>", "xml.malformed-token" },
      }
      for _, case in ipairs(rejected) do
        local ok, err = diagnostic.capture(function() xml.parse(case[1]) end)
        assert(not ok and err.code == case[2],
          case[1] .. " gave " .. tostring(err and err.code))
      end
    end,
  },
  {
    name = "long ASCII names cost little more than text of the same size",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- Before the ASCII fast path, a part of 256-byte names took about
      -- twice as long as the same size of text, because every name
      -- character was decoded twice. A ratio travels between machines
      -- better than a time limit. Recorded ratios: 2.07 with neither fast
      -- path, 1.38 with only the validator's, 1.75 with only the reader's,
      -- 1.03 to 1.08 with both.
      local size = 1024 * 1024
      local plain = "<r>" .. string.rep("x", size - 7) .. "</r>"
      local pieces, length = { "<r>" }, 3
      local element = "<" .. string.rep("n", 256) .. "/>"
      while length + #element + 4 <= size do
        pieces[#pieces + 1] = element
        length = length + #element
      end
      pieces[#pieces + 1] = "</r>"
      local names = table.concat(pieces)
      local function cpu(part)
        collectgarbage("collect")
        local started = pandoc.system.cputime()
        xml.parse(part)
        return (pandoc.system.cputime() - started) / 1e12
      end
      local ratio = cpu(names) / cpu(plain)
      assert(ratio < 1.25,
        ("names took %.2f times as long as text"):format(ratio))
    end,
  },
  {
    name = "real names that look like aliases parse",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- abc takes the alias n1, so the real n1 must not reach the backend
      -- as written, or mapping the backend's names back would confuse them.
      local doc = xml.parse("<abc><n1/></abc>")
      assert(doc.root.name.local_name == "abc",
        tostring(doc.root.name.local_name))
      assert(#xml.find_all(doc, "", "n1") == 1)
    end,
  },
  {
    name = "both limit layers report an invalid limit with one context shape",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- #51: the adapter and the strict layer both report {option, value},
      -- with the value in its original type.
      local _, adapter_err = diagnostic.capture(function()
        xml.parse("<r/>", { max_input_bytes = 1.5 })
      end)
      assert(adapter_err.code == "xml.invalid-limit", tostring(adapter_err.code))
      assert(adapter_err.context.option == "max_input_bytes",
        tostring(adapter_err.context.option))
      assert(adapter_err.context.value == 1.5, tostring(adapter_err.context.value))
      local _, strict_err = diagnostic.capture(function()
        xml.parse("<r/>", { max_depth = 0 })
      end)
      assert(strict_err.code == "xml.invalid-limit", tostring(strict_err.code))
      assert(strict_err.context.option == "max_depth",
        tostring(strict_err.context.option))
      assert(strict_err.context.value == 0, tostring(strict_err.context.value))
    end,
  },
  {
    name = "a zero input-byte limit is valid in both layers",
    gate = "safety",
    stage = "xml",
    fn = function()
      -- #51: the design makes max_input_bytes a non-negative integer, so 0
      -- is a valid (if useless) limit; empty input then fails as XML, not
      -- as an invalid limit.
      local _, empty_err = diagnostic.capture(function()
        xml.parse("", { max_input_bytes = 0 })
      end)
      assert(empty_err.code ~= "xml.invalid-limit", tostring(empty_err.code))
      local _, err = diagnostic.capture(function()
        xml.parse("<r/>", { max_input_bytes = 0 })
      end)
      assert(err.code == "xml.input-too-large", tostring(err.code))
    end,
  },
  {
    name = "non-string input is a typed diagnostic, not a raw Lua error",
    gate = "safety",
    stage = "xml",
    fn = function()
      for _, bad in ipairs({ 42, {}, true }) do
        local ok, err = diagnostic.capture(function() xml.parse(bad) end)
        assert(not ok)
        assert(err.code == "xml.invalid-input", tostring(err.code))
      end
      local ok, err = diagnostic.capture(function() xml.parse(nil) end)
      assert(not ok and err.code == "xml.invalid-input", tostring(err and err.code))
    end,
  },
}
