local xml = require("xml")
local oracle = require("lib.oracle")
local diagnostic = require("lib.diagnostic")

local SOURCE =
  '<?xml version="1.0" encoding="UTF-8"?>' ..
  '<w:p xmlns:w="urn:w" w:one="A" w:two="B"><w:t>hello</w:t></w:p>'

return {
  {
    name = "two attribute edits and a text edit all apply, oracle-verified",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      local t = xml.find_all(doc, "urn:w", "t")[1]
      xml.set_attribute(p, "urn:w", "one", "X")
      xml.set_attribute(p, "urn:w", "two", "Y")
      xml.replace_text(t, "world")
      local out, ranges = xml.serialize(doc)
      assert(#ranges == 3, "three edit ranges expected, got " .. #ranges)
      -- The returned ranges must BE the registered edits' original
      -- coordinates, in order — a serializer returning three wrong ranges
      -- must fail here, not slip past a length check.
      -- Sort by (range.start, seq) — the same tie-break the serializer
      -- uses — not by range.start alone, since same-offset edits are
      -- disambiguated by registration order (seq), not source position.
      local expected = {}
      for index, edit in ipairs(doc.edits) do expected[index] = edit end
      table.sort(expected, function(a, b)
        if a.range.start ~= b.range.start then
          return a.range.start < b.range.start
        end
        return a.seq < b.seq
      end)
      for index, range in ipairs(ranges) do
        assert(range.start == expected[index].range.start and
          range.finish == expected[index].range.finish,
          ("range %d mismatch: got [%d,%d), expected [%d,%d)"):format(
            index, range.start, range.finish,
            expected[index].range.start, expected[index].range.finish))
      end
      -- Independent multi-edit verification (Step 6 adds verify_edits to the
      -- test-lib oracle; the single-edit verify_edit signature takes one
      -- range plus an expected-change record and cannot verify this case).
      oracle.verify_edits(SOURCE, out, doc.edits)
      local reparsed = xml.parse(out)
      local p2 = xml.find_all(reparsed, "urn:w", "p")[1]
      assert(xml.get_attribute(p2, "urn:w", "one") == "X")
      assert(xml.get_attribute(p2, "urn:w", "two") == "Y")
    end,
  },
  {
    name = "editing the same token twice is rejected",
    gate = "safety",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      xml.set_attribute(p, "urn:w", "one", "X")
      local ok, err = diagnostic.capture(function()
        xml.set_attribute(p, "urn:w", "one", "Z")
      end)
      assert(not ok, "second edit of one token must be rejected")
      assert(err.code == "xml.edit-target", tostring(err))
    end,
  },
  {
    name = "overlapping edit ranges are rejected at serialize",
    gate = "safety",
    stage = "xml",
    fn = function()
      local overlay = require("xml.token_overlay")
      local document = {
        source = "0123456789",
        edits = {
          { target = {}, seq = 1, range = { start = 2, finish = 6 }, replacement = "AA" },
          { target = {}, seq = 2, range = { start = 4, finish = 8 }, replacement = "BB" },
        },
      }
      local ok, err = diagnostic.capture(function()
        overlay.serialize(document)
      end)
      assert(not ok, "overlapping ranges must be rejected")
      assert(err.code == "xml.overlapping-edits", tostring(err))
    end,
  },
  {
    name = "append_element reuses the parent prefix and escapes attribute values",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      -- local name in; the child reuses the parent's validated prefix
      xml.append_element(p, "extra", {
        { name = "w:val", value = 'a&b<c>"d' },
      })
      local out = xml.serialize(doc)
      -- The promoted escape_attribute escapes &, <, whitespace and the
      -- active quote; XML does not require escaping > in attribute values,
      -- so the literal > is expected.
      assert(out:find('<w:extra w:val="a&amp;b&lt;c>&quot;d"/></w:p>', 1, true),
        "prefixed, escaped insertion before the parent close tag: " .. out)
      xml.parse(out)  -- the result must still be strict-valid
    end,
  },
  {
    name = "append_element under a default-namespace parent stays unprefixed",
    gate = "functional",
    stage = "xml",
    fn = function()
      local doc = xml.parse(
        '<?xml version="1.0"?><Types xmlns="urn:ct"></Types>')
      local root = xml.find_all(doc, "urn:ct", "Types")[1]
      xml.append_element(root, "Override", {
        { name = "PartName", value = "/word/custom.xml" },
        { name = "ContentType", value = "application/xml" },
      })
      local out = xml.serialize(doc)
      local reparsed = xml.parse(out)
      assert(#xml.find_all(reparsed, "urn:ct", "Override") == 1,
        "unprefixed child must inherit the default namespace: " .. out)
    end,
  },
  {
    name = "append_element rejects invalid element and attribute names",
    gate = "safety",
    stage = "xml",
    fn = function()
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      for _, bad in ipairs({ "1abc", "a b", "", "a:b" }) do
        local ok, err = diagnostic.capture(function()
          xml.append_element(p, bad, {})
        end)
        assert(not ok, "invalid local name must be rejected: " .. bad)
        assert(err.code == "xml.invalid-input", tostring(err))
      end
      local ok, err = diagnostic.capture(function()
        xml.append_element(p, "extra", { { name = "1bad", value = "x" } })
      end)
      assert(not ok, "invalid attribute name must be rejected")
      assert(err.code == "xml.invalid-input", tostring(err))
    end,
  },
  {
    name = "two insertions at the same offset apply in registration order",
    gate = "functional",
    stage = "xml",
    fn = function()
      -- Two append_element calls on the SAME parent register two zero-width
      -- edits at the identical offset (the parent's end-tag start). The
      -- serializer must not treat these as overlapping, and must emit them
      -- in the order they were registered (seq), not source position.
      local doc = xml.parse(SOURCE)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      xml.append_element(p, "first", { { name = "w:val", value = "1" } })
      xml.append_element(p, "second", { { name = "w:val", value = "2" } })
      local out, ranges = xml.serialize(doc)
      assert(#ranges == 2, "two zero-width insertion ranges expected, got " ..
        #ranges)
      assert(out:find(
        '<w:first w:val="1"/><w:second w:val="2"/></w:p>', 1, true),
        "same-offset insertions must be contiguous and in call order: " ..
          out)
      xml.parse(out)  -- the result must still be strict-valid
    end,
  },
  {
    name = "append_element on a UTF-16 document preserves the encoding",
    gate = "preservation",
    stage = "xml",
    fn = function()
      -- Build the UTF-16LE source the same way the promoted adapter tests
      -- build their UTF-16 fixtures (pandoc.text.toencoding + BOM); read
      -- test-xml-adapter.lua for the exact helper and mirror it.
      local utf8_source =
        '<?xml version="1.0" encoding="UTF-16"?>' ..
        '<w:p xmlns:w="urn:w" w:one="A"></w:p>'
      local utf16_source = "\xFF\xFE" ..
        pandoc.text.toencoding(utf8_source, "UTF-16LE")
      local doc = xml.parse(utf16_source)
      local p = xml.find_all(doc, "urn:w", "p")[1]
      xml.append_element(p, "extra", { { name = "w:val", value = "v" } })
      local out = xml.serialize(doc)
      -- The output must still be UTF-16 (BOM intact) and must reparse with
      -- the inserted element visible; a raw UTF-8 splice fails both.
      assert(out:sub(1, 2) == "\xFF\xFE", "BOM must be preserved")
      local reparsed = xml.parse(out)
      assert(#xml.find_all(reparsed, "urn:w", "extra") == 1,
        "inserted element must survive the UTF-16 round trip")
    end,
  },
}
