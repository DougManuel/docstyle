local adapter = require("candidates.luaxml.adapter")
local fixture = require("lib.fixture")
local diagnostic = require("lib.diagnostic")
local opc = require("archive.opc")
local oracle = require("candidates.oracle")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))

local LIMITS = {
  max_archive_bytes = 128 * 1024 * 1024,
  max_entries = 10000,
  max_entry_uncompressed_bytes = 128 * 1024 * 1024,
  max_total_uncompressed_bytes = 512 * 1024 * 1024,
  max_compression_ratio = 1000,
  max_materialized_bytes = 256 * 1024 * 1024,
}

local SOURCE = pandoc.path.join({
  root, "tests", "vnext", "xml-spike", "fixtures", "office",
  "libreoffice-produced.docx",
})

local W_NS =
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

local function expect_code(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected diagnostic " .. code)
  assert(err.code == code,
    "expected diagnostic " .. code .. ", got " .. tostring(err.code))
  return err
end

local function assert_no_temporary_artifacts(dir)
  for _, name in ipairs(pandoc.system.list_directory(dir)) do
    assert(not name:match("^%.docstyle%-"),
      "temporary publication artifact survived: " .. name)
  end
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

return {
  {
    name = "publication preserves package inventory bytes and modification times",
    gate = "preservation",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("publication", function(dir)
        local output = pandoc.path.join({ dir, "published.docx" })
        fixture.write_bytes(output, "prior destination bytes")
        local pkg = opc.open_path(SOURCE, LIMITS)
        local document_name = pkg.office_document_part:sub(2)
        local unknown_name = "docProps/custom.xml"
        assert(pkg._cache[unknown_name] == nil,
          "unknown part was materialized before publication")
        local original_document = pkg:part(pkg.office_document_part)
        local edited_document = edit_first_text(
          original_document, "Docstyle Task 8 publication edit")
        pkg:replace_part(pkg.office_document_part, edited_document)
        pkg:write_atomic(output)

        local reopened = opc.open_path(output, LIMITS)
        assert(reopened.office_document_part == pkg.office_document_part)
        assert(#reopened.entries == #pkg.entries)
        for index, original_entry in ipairs(pkg.entries) do
          local output_entry = reopened.entries[index]
          assert(output_entry.name == original_entry.name,
            "entry order changed at index " .. index)
          local output_bytes = reopened:_read_zip_entry(output_entry.name)
          if original_entry.name == document_name then
            assert(output_bytes == edited_document)
            assert(output_bytes ~= original_document)
          else
            assert(output_bytes == pkg:_read_zip_entry(original_entry.name),
              "uncompressed bytes changed for " .. original_entry.name)
          end
        end
        assert(reopened:_read_zip_entry(unknown_name) ==
          pkg:_read_zip_entry(unknown_name))

        local original_archive = pandoc.zip.Archive(
          fixture.read_bytes(SOURCE))
        local output_archive = pandoc.zip.Archive(
          fixture.read_bytes(output))
        assert(#output_archive.entries == #original_archive.entries)
        for index, original_entry in ipairs(original_archive.entries) do
          local output_entry = output_archive.entries[index]
          assert(output_entry.path == original_entry.path)
          assert(original_entry.modtime ~= nil)
          assert(output_entry.modtime ~= nil)
          assert(tostring(output_entry.modtime) ==
            tostring(original_entry.modtime),
            "modification time changed for " .. original_entry.path)
        end
      end)
    end,
  },
  {
    name = "same-process publication is byte deterministic",
    gate = "determinism",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("publication-determinism", function(dir)
        local outputs = {
          pandoc.path.join({ dir, "first.docx" }),
          pandoc.path.join({ dir, "second.docx" }),
        }
        for _, output in ipairs(outputs) do
          local pkg = opc.open_path(SOURCE, LIMITS)
          local source = pkg:part(pkg.office_document_part)
          pkg:replace_part(pkg.office_document_part,
            edit_first_text(source,
              "Docstyle Task 8 deterministic publication edit"))
          pkg:write_atomic(output)
        end
        assert(fixture.read_bytes(outputs[1]) ==
          fixture.read_bytes(outputs[2]))
      end)
    end,
  },
  {
    name = "publication failures preserve destination and remove temporary data",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("publication-failure", function(dir)
        local output = pandoc.path.join({ dir, "published.docx" })
        local prior = "prior destination bytes"
        local points = {
          "after_archive",
          "after_close",
          "after_verification",
          "before_rename",
        }
        for _, point in ipairs(points) do
          fixture.write_bytes(output, prior)
          local pkg = opc.open_path(SOURCE, LIMITS)
          local err = expect_code("publication.injected-failure", function()
            pkg:write_atomic(output, { fail_at = point })
          end)
          assert(err.context.point == point)
          assert(fixture.read_bytes(output) == prior)
          assert_no_temporary_artifacts(dir)
        end
      end)
    end,
  },
  {
    name = "publication rejects unknown test options",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("publication-options", function(dir)
        local output = pandoc.path.join({ dir, "published.docx" })
        local pkg = opc.open_path(SOURCE, LIMITS)
        expect_code("publication.invalid-options", function()
          pkg:write_atomic(output, { fail_at = "not-a-checkpoint" })
        end)
        expect_code("publication.invalid-options", function()
          pkg:write_atomic(output, { unexpected = true })
        end)
        assert(not fixture.exists(output))
        assert_no_temporary_artifacts(dir)
      end)
    end,
  },
  {
    name = "temporary directory reservation retries a collision",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("publication-collision", function(dir)
        local output = pandoc.path.join({ dir, "published.docx" })
        local collision = pandoc.path.join({
          dir, ".docstyle-known-collision",
        })
        pandoc.system.make_directory(collision, false)
        local original_tmpname = os.tmpname
        local calls = 0
        os.tmpname = function()
          calls = calls + 1
          if calls == 1 then
            return pandoc.path.join({ dir, "known-collision" })
          end
          return original_tmpname()
        end
        local ok, err = pcall(function()
          local pkg = opc.open_path(SOURCE, LIMITS)
          pkg:write_atomic(output)
        end)
        os.tmpname = original_tmpname
        if not ok then error(err, 0) end

        assert(calls >= 2)
        assert(fixture.exists(output))
        pandoc.system.remove_directory(collision, true)
        assert_no_temporary_artifacts(dir)
      end)
    end,
  },
}
