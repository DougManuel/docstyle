-- #54: archive entries that are not OPC parts. Word leaves `[trash]/NNNN.dat`
-- placeholders after some saves, and some tools write empty directory
-- entries (`word/`). Word ignores both. The package core opens such
-- packages, keeps the entries out of every part lookup, and drops them on
-- publication, reporting each dropped entry so the removal is never silent.
local fixture = require("lib.fixture")
local vectors = require("fixtures.archive.vectors")
local preflight = require("zip")
local core = require("init")
local diagnostic = require("lib.diagnostic")

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
</Types>]]
local ROOT_RELATIONSHIPS = [[<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>]]
local DOCUMENT = [[<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>]]
-- The shape observed in real Word output: an all-ones header, then zeros.
local TRASH_BYTES = "\255\255\255\255" .. string.rep("\0", 396)

local function write_package(dir, filename, extra_entries)
  local sources = {
    { name = "[Content_Types].xml", data = CONTENT_TYPES },
    { name = "_rels/.rels", data = ROOT_RELATIONSHIPS },
    { name = "word/", data = "" },
    { name = "word/document.xml", data = DOCUMENT },
  }
  for _, extra in ipairs(extra_entries or {}) do
    sources[#sources + 1] = extra
  end
  local entries = {}
  for index, source in ipairs(sources) do
    entries[index] = pandoc.zip.Entry(source.name, source.data, 946684800)
  end
  local path = pandoc.path.join({ dir, filename })
  fixture.write_bytes(path, pandoc.zip.Archive(entries):bytestring())
  return path
end

local function with_archive(bytes, fn)
  fixture.with_temp_dir("ignored-entries-zip", function(dir)
    local path = dir .. "/archive.zip"
    fixture.write_bytes(path, bytes)
    fn(path)
  end)
end

local function expect_code(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected " .. code)
  assert(err.code == code, "expected " .. code .. ", got " .. tostring(err.code))
  return err
end

local function names(list)
  local result = {}
  for index, item in ipairs(list) do result[index] = item.name end
  return table.concat(result, ",")
end

return {
  {
    name = "an empty directory entry passes preflight and is classified as ignored",
    gate = "archive",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/" },
        { name = "word/document.xml", data = "<x/>" },
      })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, LIMITS)
        assert(result.entries[1].ignored == "directory",
          tostring(result.entries[1].ignored))
        assert(result.entries[2].ignored == nil)
      end)
    end,
  },
  {
    name = "a directory entry carrying data fails closed",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ { name = "word/", data = "hidden" } })
      with_archive(bytes, function(path)
        expect_code("zip.invalid-name", function()
          preflight.open_path(path, LIMITS)
        end)
      end)
    end,
  },
  {
    name = "directory entry names are still validated",
    gate = "safety",
    stage = "archive",
    fn = function()
      for _, name in ipairs({ "/", "../", "word/../", "word//", "word/./" }) do
        local bytes = vectors.archive({ { name = name } })
        with_archive(bytes, function(path)
          expect_code("zip.invalid-name", function()
            preflight.open_path(path, LIMITS)
          end)
        end)
      end
    end,
  },
  {
    name = "a package with Office trash and directory entries opens without exposing them as parts",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("ignored-open", function(dir)
        local source = write_package(dir, "trash.docx", {
          { name = "[trash]/0000.dat", data = TRASH_BYTES },
        })
        local pkg = core.open(source, LIMITS)
        local inventory = pkg:inventory()
        for _, part in ipairs(inventory.parts) do
          assert(part ~= "/[trash]/0000.dat" and part ~= "/word/",
            "ignored entry listed as a part: " .. part)
        end
        assert(names(inventory.ignored) == "word/,[trash]/0000.dat",
          names(inventory.ignored))
        assert(inventory.ignored[2].kind == "office-trash")
        assert(inventory.ignored[1].kind == "directory")
        local ok = diagnostic.capture(function()
          pkg:part("/[trash]/0000.dat")
        end)
        assert(not ok, "trash is never readable as a part")
      end)
    end,
  },
  {
    name = "an Office trash entry is refused as a relationship target",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("ignored-target", function(dir)
        local source = write_package(dir, "trash-target.docx", {
          { name = "[trash]/0000.dat", data = TRASH_BYTES },
        })
        local pkg = core.open(source, LIMITS)
        local ok = diagnostic.capture(function()
          pkg:add_relationship("/word/document.xml",
            "http://schemas.example.org/custom", "../[trash]/0000.dat")
        end)
        assert(not ok, "trash must not resolve as a relationship target")
      end)
    end,
  },
  {
    name = "publication drops ignored entries and reports each one",
    gate = "preservation",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("ignored-publish", function(dir)
        local source = write_package(dir, "trash-publish.docx", {
          { name = "[trash]/0000.dat", data = TRASH_BYTES },
        })
        local pkg = core.open(source, LIMITS)
        local out = dir .. "/out.docx"
        local result = pkg:write_atomic(out)
        assert(names(result.dropped_entries) == "word/,[trash]/0000.dat",
          names(result.dropped_entries or {}))
        assert(result.dropped_entries[2].kind == "office-trash")
        local reopened = core.open(out, LIMITS)
        assert(#reopened:inventory().ignored == 0, "output carries no ignored entries")
        assert(reopened:part("/word/document.xml") == DOCUMENT,
          "parts survive byte-identically")
      end)
    end,
  },
  {
    name = "publication without ignored entries reports none",
    gate = "functional",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("ignored-none", function(dir)
        local source = write_package(dir, "plain.docx")
        local pkg = core.open(source, LIMITS)
        local first = pkg:write_atomic(dir .. "/first.docx")
        local again = core.open(dir .. "/first.docx", LIMITS)
        local second = again:write_atomic(dir .. "/second.docx")
        assert(#first.dropped_entries == 1, "the directory entry is dropped")
        assert(#second.dropped_entries == 0, tostring(#second.dropped_entries))
      end)
    end,
  },
  {
    name = "names that only resemble Office trash still fail closed",
    gate = "safety",
    stage = "package",
    fn = function()
      fixture.with_temp_dir("ignored-lookalike", function(dir)
        for index, name in ipairs({
          "[trash]/0000.xml", "[trash]/00000.dat", "[trash]/000.dat",
          "[Trash]/0000.dat", "[trash]/sub/0000.dat", "[trash]0000.dat",
          "word/[trash]/0000.dat",
        }) do
          local source = write_package(dir, "lookalike" .. index .. ".docx", {
            { name = name, data = TRASH_BYTES },
          })
          expect_code("opc.invalid-part-name", function()
            core.open(source, LIMITS)
          end)
        end
      end)
    end,
  },
}
