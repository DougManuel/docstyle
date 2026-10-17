local fixture = require("lib.fixture")
local core = require("init")
local diagnostic = require("lib.diagnostic")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))

-- Same real Word-native fixture test-inventory.lua uses (not the
-- LibreOffice-produced one in fixtures/office/).
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

-- Minimal well-formed OPC package with caller-supplied content types, built
-- from scratch with pandoc.zip.Entry / pandoc.zip.Archive (mirrors
-- write_distinct_modtime_source in test-publication.lua, which proves a
-- pandoc.zip-built archive passes preflight): content-types, root
-- relationships, one document part and one core-properties part.
local build_package

-- Synthetic package whose [Content_Types].xml uses a namespace prefix
-- (<ct:Types xmlns:ct="…">).
local function build_prefixed_content_types_package(dir)
  return build_package(dir, "prefixed-content-types.docx", [[<?xml version="1.0" encoding="UTF-8"?>
<ct:Types xmlns:ct="http://schemas.openxmlformats.org/package/2006/content-types">
  <ct:Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <ct:Default Extension="xml" ContentType="application/xml"/>
  <ct:Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <ct:Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</ct:Types>]])
end

-- Content types declaring an Override for /word/<name>.xml although the
-- archive has no such part. OPC tolerates the orphan; parse_content_types
-- rejects a second Override for the same (case-folded) name.
local function orphan_override_content_types(name)
  return ([[<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/word/%s.xml" ContentType="application/vnd.example.orphan+xml"/>
</Types>]]):format(name)
end

build_package = function(dir, filename, content_types)
  local root_relationships = [[<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>]]
  local document = [[<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>]]
  local core_properties = [[<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>]]

  local sources = {
    { name = "[Content_Types].xml", data = content_types },
    { name = "_rels/.rels", data = root_relationships },
    { name = "word/document.xml", data = document },
    { name = "docProps/core.xml", data = core_properties },
  }
  local entries = {}
  for index, source in ipairs(sources) do
    entries[index] = pandoc.zip.Entry(source.name, source.data, 946684800)
  end
  local path = pandoc.path.join({ dir, filename })
  fixture.write_bytes(path, pandoc.zip.Archive(entries):bytestring())
  return path
end

return {
  {
    name = "an added part round-trips through write_atomic",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-part", function(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(WORD, LIMITS)
        local original_document_type = pkg:content_type("/word/document.xml")
        -- Content type must NOT be resolvable via any Default extension
        -- rule (the fixture declares Default Extension="xml" ->
        -- application/xml) -- otherwise this test is vacuous: it would
        -- pass even if the Override were never written, because
        -- content_type() falls back to the extension Default. Only a
        -- non-default type proves the Override round-tripped.
        pkg:add_part("/word/custom.xml",
          '<?xml version="1.0"?><root/>', "application/vnd.docstyle-custom+xml")
        assert(pkg:part("/word/custom.xml") ==
          '<?xml version="1.0"?><root/>', "added part readable before publish")
        pkg:write_atomic(out)

        local reopened = core.open(out, LIMITS)
        assert(reopened:part("/word/custom.xml") ==
          '<?xml version="1.0"?><root/>', "added part bytes survive")
        assert(reopened:content_type("/word/custom.xml") ==
          "application/vnd.docstyle-custom+xml",
          "added content type survives")
        assert(reopened:part("/word/document.xml") ~= nil,
          "original parts untouched")
        assert(reopened:content_type("/word/document.xml") ==
          original_document_type,
          "an original part's content type is unchanged after add_part")
      end)
    end,
  },
  {
    name = "adding the same new part name twice fails closed on the second call",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      pkg:add_part("/word/custom.xml", "<root/>", "application/xml")
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/custom.xml", "<root/>", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-collision", tostring(err))
    end,
  },
  {
    name = "adding an existing part name fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/document.xml", "x", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-collision", tostring(err))
    end,
  },
  {
    name = "adding relationship metadata through add_part fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/_rels/newpart.xml.rels", "x", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.metadata-replacement", tostring(err))
    end,
  },
  {
    name = "adding a part with non-string bytes fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/custom.xml", 12345, "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.invalid-addition", tostring(err))
    end,
  },
  {
    name = "adding a part with a missing content type fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/custom.xml", "<root/>", "")
      end)
      assert(not ok)
      assert(err.code == "opc.invalid-addition", tostring(err))
    end,
  },
  {
    name = "a name differing only in ASCII case from an original fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/DOCUMENT.xml", "x", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-case-collision", tostring(err))
    end,
  },
  {
    name = "a name differing only in ASCII case from a prior addition fails closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      pkg:add_part("/word/custom.xml", "<root/>", "application/xml")
      local ok, err = diagnostic.capture(function()
        pkg:add_part("/word/CUSTOM.xml", "<root/>", "application/xml")
      end)
      assert(not ok)
      assert(err.code == "opc.add-part-case-collision", tostring(err))
    end,
  },
  {
    name = "a prefixed content-types root gets a prefixed Override in the same namespace",
    gate = "preservation",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("prefixed-ct", function(dir)
        local source = build_prefixed_content_types_package(dir)
        local out = dir .. "/out.docx"
        local pkg = core.open(source, LIMITS)
        -- Same non-Default-resolvable content type as the round-trip test,
        -- and for the same reason: the fixture declares
        -- Default Extension="xml" -> application/xml, so an
        -- application/xml Override would make this test pass even with a
        -- no-op _register_content_type_override.
        pkg:add_part("/word/custom.xml", "<root/>",
          "application/vnd.docstyle-custom+xml")
        pkg:write_atomic(out)
        local reopened = core.open(out, LIMITS)
        assert(reopened:content_type("/word/custom.xml") ==
          "application/vnd.docstyle-custom+xml",
          "Override must be valid in a prefixed content-types stream")
      end)
    end,
  },
  {
    name = "an added part is a first-class part before publication",
    gate = "functional",
    stage = "package",
    fn = function()
      local pkg = core.open(WORD, LIMITS)
      pkg:add_part("/word/custom.xml", "<root/>", "application/xml")
      -- inventory lists it (this exercises relationships()/content_type()
      -- routing through _require_effective; the naive version raises
      -- opc.part-not-found here)
      local inv = pkg:inventory()
      local listed = false
      for _, name in ipairs(inv.parts) do
        if name == "/word/custom.xml" then listed = true end
      end
      assert(listed, "added part must appear in inventory")
      assert(inv.content_types["/word/custom.xml"] == "application/xml")
      -- and it is replaceable like any other part
      pkg:replace_part("/word/custom.xml", "<root updated='1'/>")
      assert(pkg:part("/word/custom.xml") == "<root updated='1'/>",
        "replace_part must update an added part")
    end,
  },
  {
    name = "two publishes of the same additions are byte-identical",
    gate = "determinism",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-part-det", function(dir)
        local outputs = {}
        for run = 1, 2 do
          local out = dir .. "/out-" .. run .. ".docx"
          local pkg = core.open(WORD, LIMITS)
          pkg:add_part("/word/b.xml", "<b/>", "application/xml")
          pkg:add_part("/word/a.xml", "<a/>", "application/xml")
          pkg:write_atomic(out)
          outputs[run] = fixture.read_bytes(out)
        end
        assert(outputs[1] == outputs[2], "publication must be deterministic")
      end)
    end,
  },
  {
    name = "adding a part whose name already has an orphan Override fails closed at the call",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-part-orphan", function(dir)
        local source = build_package(dir, "orphan.docx",
          orphan_override_content_types("new"))
        local pkg = core.open(source, LIMITS)
        local ok, err = diagnostic.capture(function()
          pkg:add_part("/word/new.xml", "<x/>", "application/vnd.example+xml")
        end)
        assert(not ok, "add_part must reject the orphan-Override name")
        assert(err.code == "opc.add-part-content-type-collision",
          tostring(err.code))
        -- The rejected call left no partial state: the package still publishes.
        local out = dir .. "/out.docx"
        pkg:write_atomic(out)
        assert(fixture.exists(out), "package remains publishable")
      end)
    end,
  },
  {
    name = "an orphan Override differing only in ASCII case also fails closed at the call",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("add-part-orphan-case", function(dir)
        local source = build_package(dir, "orphan-case.docx",
          orphan_override_content_types("New"))
        local pkg = core.open(source, LIMITS)
        local ok, err = diagnostic.capture(function()
          pkg:add_part("/word/new.xml", "<x/>", "application/vnd.example+xml")
        end)
        assert(not ok, "add_part must reject the case-variant Override name")
        assert(err.code == "opc.add-part-content-type-collision",
          tostring(err.code))
      end)
    end,
  },
}
