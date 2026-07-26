local adapter = require("candidates.luaxml.adapter")
local fixture = require("lib.fixture")
local opc = require("archive.opc")
local oracle = require("candidates.oracle")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))
local sha256 = dofile(pandoc.path.join({
  root, "tests", "vnext", "conformance", "lib", "sha256.lua",
}))

local W_NS =
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
local REL_FOOTER =
  "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"

local LIMITS = {
  max_archive_bytes = 128 * 1024 * 1024,
  max_entries = 10000,
  max_entry_uncompressed_bytes = 128 * 1024 * 1024,
  max_total_uncompressed_bytes = 512 * 1024 * 1024,
  max_compression_ratio = 1000,
  max_materialized_bytes = 256 * 1024 * 1024,
}

local OFFICE_DIR = pandoc.path.join({
  root, "tests", "vnext", "xml-spike", "fixtures", "office",
})

local function office_path(...)
  return pandoc.path.join({ OFFICE_DIR, ... })
end

local function edit_first_text(source, replacement)
  local document = adapter.parse(source)
  local target, occurrence
  for index, node in ipairs(adapter.find_all(document, W_NS, "t")) do
    if not node.has_element_child and not node.has_cdata and
        #node.direct_text == 1 then
      target = node
      occurrence = index
      break
    end
  end
  assert(target, "office document needs one editable text element")
  local change = {
    operation = "text",
    element = {
      uri = W_NS,
      local_name = "t",
      occurrence = occurrence,
    },
  }
  local golden = oracle.find_edit_range(oracle.parse(source), change)
  adapter.replace_text(target, replacement)
  local edited, ranges = adapter.serialize(document)
  assert(#ranges == 1)
  local verification = oracle.verify_edit(source, edited, golden, {
    reported_range = ranges[1],
    operation = change.operation,
    element = change.element,
    value = replacement,
  })
  assert(verification.ok == true)
  return edited
end

local cases = {
  {
    name = "LibreOffice fixture metadata pins source and output bytes",
    gate = "safety",
    stage = "package",
    fn = function()
      local metadata = pandoc.json.decode(fixture.read_bytes(
        office_path("metadata.json")), false)
      assert(metadata.licence == "CC0-1.0")
      assert(metadata.contains_personal_data == false)
      assert(sha256.hex(fixture.read_bytes(
        office_path(metadata.source.qmd))) ==
        metadata.source.qmd_sha256)
      assert(sha256.hex(fixture.read_bytes(
        office_path(metadata.source.project_config))) ==
        metadata.source.project_config_sha256)
      local output = fixture.read_bytes(
        office_path(metadata.output.docx))
      assert(sha256.hex(output) == metadata.output.sha256)
      assert(#output == metadata.output.size_bytes)
    end,
  },
  {
    name = "LibreOffice fixture retains the required office constructs",
    gate = "functional",
    stage = "package",
    fn = function()
      local pkg = opc.open_path(
        office_path("libreoffice-produced.docx"), LIMITS)
      local document = pkg:part(pkg.office_document_part)
      for _, literal in ipairs({
        "<w:tbl",
        "<w:numPr",
        "<w:hyperlink",
        "<w:sectPr",
        "<w:footerReference",
        'w:type w:val="nextPage"',
        "ADDIN DOCSTYLE",
        "ADDIN ZOTERO_PREF",
      }) do
        assert(document:find(literal, 1, true),
          "missing office construct " .. literal)
      end

      local saw_external, footer_count = false, 0
      for _, relationship in ipairs(
          pkg:relationships(pkg.office_document_part)) do
        if relationship.external and
            relationship.target == "https://example.org/" then
          saw_external = true
        elseif relationship.type == REL_FOOTER then
          footer_count = footer_count + 1
          assert(#pkg:part(relationship.resolved_part) > 0)
        end
      end
      assert(saw_external)
      assert(footer_count >= 1)
    end,
  },
}

local matrix = {
  {
    name = "Word native comments",
    path = pandoc.path.join({
      root, "tests", "testthat", "fixtures",
      "word-native-comments.docx",
    }),
    required_parts = {
      "word/comments.xml",
      "word/commentsExtended.xml",
      "customXml/item3.xml",
    },
    required_literals = {
      "<w:commentRangeStart",
      "<w:commentRangeEnd",
      "<w:commentReference",
      "<w:ins",
      "<w:del",
      "ADDIN ZOTERO_ITEM",
      "mc:Ignorable",
      "w14:paraId",
    },
  },
  {
    name = "Word page fields",
    path = pandoc.path.join({
      root, "tests", "testthat", "fixtures",
      "page-number-test.docx",
    }),
    required_parts = {
      "word/footer1.xml",
      "word/footer2.xml",
      "word/footer3.xml",
      "word/footer4.xml",
    },
    required_literals = {
      "<w:sectPr",
      "<w:footerReference",
      "PAGE",
      "mc:Ignorable",
    },
  },
  {
    name = "Docstyle POPCORN baseline",
    path = pandoc.path.join({
      root, "tests", "vnext", "fixtures", "popcorn-protocol",
      "baseline", "legacy", "docstyle-docx.docx",
    }),
    required_parts = {
      "word/comments.xml",
      "word/_rels/footnotes.xml.rels",
      "docProps/custom.xml",
    },
    required_literals = {
      "ADDIN DOCSTYLE",
      "ADDIN ZOTERO_PREF",
      "<w:ins",
      "<w:sectPr",
      "<w:footerReference",
    },
  },
  {
    name = "LibreOffice output",
    path = office_path("libreoffice-produced.docx"),
    required_parts = {
      "docProps/custom.xml",
      "word/footer1.xml",
      "word/footer2.xml",
      "word/footer3.xml",
    },
    required_literals = {
      "ADDIN DOCSTYLE",
      "ADDIN ZOTERO_PREF",
      "<w:ins",
      "<w:sectPr",
      "<w:footerReference",
      "mc:Ignorable",
    },
  },
}

for _, row in ipairs(matrix) do
  cases[#cases + 1] = {
    name = "publishes one independently verified edit in " .. row.name,
    gate = "preservation",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("office-preservation", function(dir)
        local input = pandoc.path.join({ dir, "input.docx" })
        local output = pandoc.path.join({ dir, "output.docx" })
        local input_bytes = fixture.read_bytes(row.path)
        fixture.write_bytes(input, input_bytes)

        local pkg = opc.open_path(input, LIMITS)
        local original_parts = {}
        for _, entry in ipairs(pkg.entries) do
          original_parts[entry.name] = pkg:_read_zip_entry(entry.name)
        end
        for _, part_name in ipairs(row.required_parts) do
          assert(original_parts[part_name],
            "fixture is missing required part " .. part_name)
        end
        for _, literal in ipairs(row.required_literals) do
          local found = false
          for _, bytes in pairs(original_parts) do
            if bytes:find(literal, 1, true) then
              found = true
              break
            end
          end
          assert(found, "fixture is missing construct " .. literal)
        end
        local source = pkg:part(pkg.office_document_part)
        local edited = edit_first_text(
          source, "Docstyle Task 8 preservation edit")
        pkg:replace_part(pkg.office_document_part, edited)
        pkg:write_atomic(output)

        assert(fixture.read_bytes(input) == input_bytes)
        local reopened = opc.open_path(output, LIMITS)
        assert(#reopened.entries == #pkg.entries)
        reopened:relationships(reopened.office_document_part)
        local document_name = pkg.office_document_part:sub(2)
        for index, original_entry in ipairs(pkg.entries) do
          local output_entry = reopened.entries[index]
          assert(output_entry.name == original_entry.name)
          local output_bytes =
            reopened:_read_zip_entry(output_entry.name)
          if output_entry.name == document_name then
            assert(output_bytes == edited)
          else
            assert(output_bytes ==
              original_parts[output_entry.name],
              "unmodified part changed: " .. output_entry.name)
          end
        end
      end)
    end,
  }
end

return cases
