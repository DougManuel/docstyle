local fixture = require("lib.fixture")
local core = require("init")
local diagnostic = require("lib.diagnostic")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))

-- Same real Word-native fixture test-add-part.lua and test-inventory.lua use
-- (not the LibreOffice-produced one in fixtures/office/).
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

local CONTENT_TYPES = [[<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>]]
local ROOT_RELATIONSHIPS = [[<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>]]
local DOCUMENT = [[<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>]]
local CORE_PROPERTIES = [[<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>]]

local function write_minimal_package(dir, filename, document_relationships)
  local sources = {
    { name = "[Content_Types].xml", data = CONTENT_TYPES },
    { name = "_rels/.rels", data = ROOT_RELATIONSHIPS },
    { name = "word/document.xml", data = DOCUMENT },
    { name = "word/_rels/document.xml.rels", data = document_relationships },
    { name = "docProps/core.xml", data = CORE_PROPERTIES },
  }
  local entries = {}
  for index, source in ipairs(sources) do
    entries[index] = pandoc.zip.Entry(source.name, source.data, 946684800)
  end
  local path = pandoc.path.join({ dir, filename })
  fixture.write_bytes(path, pandoc.zip.Archive(entries):bytestring())
  return path
end

-- Synthetic package whose document rels part uses a namespace-prefixed
-- Relationships root (<r:Relationships xmlns:r="…">). Mirrors
-- build_prefixed_content_types_package in test-add-part.lua, but prefixes
-- the RELATIONSHIPS root instead of the content-types root. A non-self-
-- closing root is required: append_element raises xml.edit-target on a
-- self-closing element (no separate end tag to splice before).
local function build_prefixed_relationships_package(dir)
  local document_relationships = [[<?xml version="1.0" encoding="UTF-8"?>
<r:Relationships xmlns:r="http://schemas.openxmlformats.org/package/2006/relationships"></r:Relationships>]]
  return write_minimal_package(
    dir, "prefixed-relationships.docx", document_relationships)
end

-- Synthetic package whose document rels part is UTF-16 with a BOM, built the
-- same way the Task 4 UTF-16 fixture is built in test-multi-edit.lua
-- (pandoc.text.toencoding + explicit "\xFF\xFE" BOM prefix).
local function build_utf16_relationships_package(dir)
  local utf8_source =
    '<?xml version="1.0" encoding="UTF-16"?>' ..
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' ..
    '</Relationships>'
  local document_relationships = "\xFF\xFE" ..
    pandoc.text.toencoding(utf8_source, "UTF-16LE")
  return write_minimal_package(
    dir, "utf16-relationships.docx", document_relationships)
end

return {
  {
    name = "an added internal relationship round-trips with a fresh id",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD, LIMITS)
        pkg:add_part("/word/custom.xml", '<?xml version="1.0"?><root/>',
          "application/xml")
        local rid = pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "custom.xml", "Internal")
        assert(rid:match("^rId%d+$"), tostring(rid))
        pkg:write_atomic(out)

        local reopened = core.open(out, LIMITS)
        local found
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          if record.id == rid then found = record end
        end
        assert(found, "added relationship survives")
        assert(found.resolved_part == "/word/custom.xml", tostring(found.resolved_part))
      end)
    end,
  },
  {
    name = "repeated additions mint distinct ids",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      pkg:add_part("/word/c1.xml", "<a/>", "application/xml")
      pkg:add_part("/word/c2.xml", "<b/>", "application/xml")
      local first = pkg:add_relationship("/word/document.xml",
        "http://schemas.example.org/custom", "c1.xml", "Internal")
      local second = pkg:add_relationship("/word/document.xml",
        "http://schemas.example.org/custom", "c2.xml", "Internal")
      assert(first ~= second, first .. " reused")
      local existing = {}
      for _, record in ipairs(pkg:relationships("/word/document.xml")) do
        assert(not existing[record.id], "duplicate id " .. record.id)
        existing[record.id] = true
      end
      assert(existing[first] and existing[second], "both additions present")
    end,
  },
  {
    name = "an external relationship stores TargetMode and is never resolved",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-ext", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD, LIMITS)
        local rid = pkg:add_relationship("/word/document.xml",
          "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
          "https://example.org/page?a=1&b=2", "External")
        pkg:write_atomic(out)
        local reopened = core.open(out, LIMITS)
        local found
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          if record.id == rid then found = record end
        end
        assert(found, "external relationship survives")
        assert(found.external == true and found.target_mode == "External")
        assert(found.target == "https://example.org/page?a=1&b=2",
          "raw target (with &) survives escaping and reparsing: " .. tostring(found.target))
        assert(found.resolved_part == nil, "external targets are never resolved")
      end)
    end,
  },
  {
    name = "an internal target that resolves to no part fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "missing.xml", "Internal")
      end)
      assert(not ok)
      assert(err.code == "opc.relationship-target-missing", tostring(err))
    end,
  },
  {
    name = "replace_part on a rels part is still rejected",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:replace_part("/word/_rels/document.xml.rels", "x")
      end)
      assert(not ok)
      assert(err.code == "opc.metadata-replacement", tostring(err))
    end,
  },
  {
    name = "root-relationship addition is deferred and rejected",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_relationship("/", "http://schemas.example.org/custom",
          "word/custom.xml", "Internal")
      end)
      assert(not ok)
      assert(err.code == "opc.metadata-replacement", tostring(err))
    end,
  },
  {
    name = "an added relationship survives a prefixed Relationships root at the package level",
    gate = "preservation",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-prefixed", function(dir)
        local source = build_prefixed_relationships_package(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(source, LIMITS)
        local rid = pkg:add_relationship("/word/document.xml",
          "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
          "https://example.org/prefixed", "External")
        pkg:write_atomic(out)
        local reopened = core.open(out, LIMITS)
        local found
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          if record.id == rid then found = record end
        end
        assert(found,
          "added relationship must survive a prefixed Relationships root")
        assert(found.target == "https://example.org/prefixed",
          tostring(found.target))
      end)
    end,
  },
  {
    name = "an added relationship survives a UTF-16 rels part with a BOM at the package level",
    gate = "preservation",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-utf16", function(dir)
        local source = build_utf16_relationships_package(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(source, LIMITS)
        local rid = pkg:add_relationship("/word/document.xml",
          "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
          "https://example.org/utf16", "External")
        pkg:write_atomic(out)
        local reopened = core.open(out, LIMITS)
        local found
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          if record.id == rid then found = record end
        end
        assert(found,
          "added relationship must survive a UTF-16 rels part with a BOM")
        assert(found.target == "https://example.org/utf16",
          tostring(found.target))
      end)
    end,
  },
  {
    name = "two added relationships from one source publish and reopen with distinct ids and resolved parts",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-multi", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD, LIMITS)
        pkg:add_part("/word/c1.xml", "<a/>",
          "application/vnd.docstyle-custom-1+xml")
        pkg:add_part("/word/c2.xml", "<b/>",
          "application/vnd.docstyle-custom-2+xml")
        local first = pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "c1.xml", "Internal")
        local second = pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "c2.xml", "Internal")
        assert(first ~= second, "ids must differ")
        pkg:write_atomic(out)

        local reopened = core.open(out, LIMITS)
        local found = {}
        for _, record in ipairs(reopened:relationships("/word/document.xml")) do
          found[record.id] = record
        end
        assert(found[first] and found[first].resolved_part == "/word/c1.xml",
          "first relationship must survive publish and resolve")
        assert(found[second] and found[second].resolved_part == "/word/c2.xml",
          "second relationship must survive publish and resolve")
        assert(reopened:content_type("/word/c1.xml") ==
          "application/vnd.docstyle-custom-1+xml",
          "first added part's content type survives publish")
        assert(reopened:content_type("/word/c2.xml") ==
          "application/vnd.docstyle-custom-2+xml",
          "second added part's content type survives publish")
      end)
    end,
  },
  {
    name = "add_relationship from a just-added part mints a fresh rels part that survives publish",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-fresh-added", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD, LIMITS)
        -- No _rels file exists yet for a just-added part: this exercises
        -- the fresh-Relationships-document branch of add_relationship
        -- (opc.lua's "else" branch when neither an addition nor an
        -- original entry exists at the relationship zip name).
        pkg:add_part("/word/catalogue.xml", "<c/>",
          "application/vnd.docstyle-catalogue+xml")
        local rid = pkg:add_relationship("/word/catalogue.xml",
          "http://schemas.example.org/points-at-document", "document.xml",
          "Internal")
        assert(rid:match("^rId%d+$"), tostring(rid))
        pkg:write_atomic(out)

        local reopened = core.open(out, LIMITS)
        local records = reopened:relationships("/word/catalogue.xml")
        assert(#records == 1 and records[1].id == rid and
          records[1].resolved_part == "/word/document.xml",
          "auto-created rels part must survive publish and resolve")
        local inv = reopened:inventory()
        local listed = false
        for _, name in ipairs(inv.metadata) do
          if name == "/word/_rels/catalogue.xml.rels" then listed = true end
        end
        assert(listed, "auto-created rels part must be classified as metadata")
      end)
    end,
  },
  {
    name = "add_relationship from an original part with no rels part mints a fresh rels part that survives publish",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-rel-fresh-original", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD, LIMITS)
        -- docProps/core.xml is an ORIGINAL part with no _rels file of its
        -- own (confirmed against the fixture's zip listing: only
        -- _rels/.rels, word/_rels/document.xml.rels and the three
        -- customXml/_rels/item*.xml.rels exist). This exercises the same
        -- fresh-rels branch as the case above, but for a part that was
        -- never add_part-ed -- not just a freshly-added one.
        local rid = pkg:add_relationship("/docProps/core.xml",
          "http://schemas.example.org/custom", "https://example.org/",
          "External")
        pkg:write_atomic(out)

        local reopened = core.open(out, LIMITS)
        local records = reopened:relationships("/docProps/core.xml")
        assert(#records == 1 and records[1].id == rid and
          records[1].target_mode == "External",
          "auto-created rels part for an original source must survive publish")
        local inv = reopened:inventory()
        local listed = false
        for _, name in ipairs(inv.metadata) do
          if name == "/docProps/_rels/core.xml.rels" then listed = true end
        end
        assert(listed, "auto-created rels part must be classified as metadata")
      end)
    end,
  },
  {
    name = "add_relationship rejects an empty type or target",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_relationship("/word/document.xml", "", "custom.xml",
          "Internal")
      end)
      assert(not ok)
      assert(err.code == "opc.invalid-relationship", tostring(err))

      local ok2, err2 = diagnostic.capture(function()
        pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "", "Internal")
      end)
      assert(not ok2)
      assert(err2.code == "opc.invalid-relationship", tostring(err2))
    end,
  },
  {
    name = "add_relationship rejects an invalid target mode",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_relationship("/word/document.xml",
          "http://schemas.example.org/custom", "custom.xml", "Bogus")
      end)
      assert(not ok)
      assert(err.code == "opc.invalid-target-mode", tostring(err))
    end,
  },
}
