local xml = require("xml")
local diagnostic = require("lib.diagnostic")

return {
  {
    name = "the default XML-part input-byte limit is one MiB",
    gate = "safety",
    stage = "xml",
    fn = function()
      assert(xml.MAX_INPUT_BYTES == 1048576, tostring(xml.MAX_INPUT_BYTES))
    end,
  },
  {
    name = "an over-limit part is rejected before parsing",
    gate = "safety",
    stage = "xml",
    fn = function()
      local oversize = string.rep("x", 1048577)
      local ok, err = diagnostic.capture(function()
        xml.parse(oversize)
      end)
      assert(not ok, "over-limit input must be rejected")
      assert(err.code == "xml.input-too-large", tostring(err))
      assert(err.context.actual == 1048577, tostring(err.context.actual))
      assert(err.context.limit == 1048576, tostring(err.context.limit))
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
    name = "an explicit override permits a larger input",
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
      local big = '<?xml version="1.0"?><r>' ..
        string.rep("x", 1100000) .. '</r>'
      local doc = xml.parse(big, { max_input_bytes = 2 * 1048576 })
      assert(doc, "override must permit parsing above the default limit")
    end,
  },
}
