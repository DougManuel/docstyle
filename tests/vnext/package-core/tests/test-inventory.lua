local core = require("init")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))

-- Real Word-native fixture (not the LibreOffice-produced one in
-- fixtures/office/): confirmed present at this path and already exercised by
-- test-office-preservation.lua's "Word native comments" matrix row.
local WORD = pandoc.path.join({
  root, "tests", "testthat", "fixtures", "word-native-comments.docx",
})

local LIMITS = {
  max_archive_bytes = 128 * 1024 * 1024,
  max_entries = 10000,
  max_entry_uncompressed_bytes = 128 * 1024 * 1024,
  max_total_uncompressed_bytes = 512 * 1024 * 1024,
  max_compression_ratio = 1000,
  max_materialized_bytes = 256 * 1024 * 1024,
}

return {
  {
    name = "inventory separates metadata from parts and includes root relationships",
    gate = "functional",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local inv = pkg:inventory()
      local part_set, metadata_set = {}, {}
      for _, name in ipairs(inv.parts) do part_set[name] = true end
      for _, name in ipairs(inv.metadata) do metadata_set[name] = true end
      assert(part_set["/word/document.xml"], "document.xml is a part")
      assert(metadata_set["/[Content_Types].xml"], "content-types stream is metadata")
      assert(metadata_set["/_rels/.rels"], "root rels is metadata")
      assert(not part_set["/[Content_Types].xml"], "metadata is not listed as a part")
      assert(inv.content_types["/word/document.xml"] ~= nil,
        "document.xml resolves a content type")
      assert(inv.relationships["/"], "package-root relationships are reported")
    end,
  },
  {
    name = "inventory relationship records are copies, not package state",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local inv = pkg:inventory()
      local source, record
      for src, records in pairs(inv.relationships) do
        source, record = src, records[1]
        break
      end
      assert(record, "expected at least one relationship record")
      local original_id = record.id
      record.id = "MUTATED"
      local again = pkg:inventory()
      assert(again.relationships[source][1].id == original_id,
        "mutating an inventory record must not change package state")
    end,
  },
}
