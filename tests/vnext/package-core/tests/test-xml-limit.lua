local xml = require("xml")
local diagnostic = require("lib.diagnostic")

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
      -- that the one-MiB limit rejected (a CV).
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
}
