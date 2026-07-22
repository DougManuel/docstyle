local diagnostic = require("lib.diagnostic")
local fixture = require("lib.fixture")
local opc = require("archive.opc")
local libdeflate = require("archive.vendor.libdeflate.LibDeflate")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))
local vectors = dofile(pandoc.path.join({
  runner_here, "fixtures", "archive", "vectors.lua",
}))

local DEFAULT_LIMITS = {
  max_archive_bytes = 1024 * 1024,
  max_entries = 100,
  max_entry_uncompressed_bytes = 1024 * 1024,
  max_total_uncompressed_bytes = 2 * 1024 * 1024,
  max_compression_ratio = 100,
  max_materialized_bytes = 2 * 1024 * 1024,
}

local function limits(overrides)
  local result = {}
  for key, value in pairs(DEFAULT_LIMITS) do result[key] = value end
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

local function expect_code(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected diagnostic " .. code)
  assert(err.code == code,
    "expected diagnostic " .. code .. ", got " .. tostring(err.code))
  return err
end

local function with_archive(bytes, fn)
  return fixture.with_temp_dir("opc", function(dir)
    local path = pandoc.path.join({ dir, "fixture.docx" })
    fixture.write_bytes(path, bytes)
    return fn(path)
  end)
end

local DEFAULT_CONTENT_TYPES = [[<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
</Types>]]

local DEFAULT_ROOT_RELATIONSHIPS = [[<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>]]

local function package_bytes(options)
  options = options or {}
  local entries = {
    {
      name = "[Content_Types].xml",
      data = options.content_types or DEFAULT_CONTENT_TYPES,
    },
    {
      name = "_rels/.rels",
      data = options.root_relationships or DEFAULT_ROOT_RELATIONSHIPS,
    },
    {
      name = "word/document.xml",
      data = options.document or
        [[<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body/></w:document>]],
    },
    {
      name = "docProps/core.xml",
      data = options.core or
        [[<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"/>]],
    },
  }
  if options.omit_content_types then table.remove(entries, 1) end
  if options.omit_root_relationships then
    for index, entry in ipairs(entries) do
      if entry.name == "_rels/.rels" then table.remove(entries, index) break end
    end
  end
  for _, entry in ipairs(options.extra_entries or {}) do
    entries[#entries + 1] = entry
  end
  for _, entry in ipairs(entries) do
    if entry.crc32 == nil then entry.crc32 = vectors.crc32(entry.data or "") end
    if options.deflate then
      entry.compressed = assert(libdeflate:CompressDeflate(
        entry.data or "", { level = 6 }))
      entry.method = 8
    end
  end
  return vectors.archive(entries)
end

local function minimal_package(extra_entries)
  return package_bytes({ extra_entries = extra_entries })
end

local function document_relationships(rows)
  local parts = {
    [[<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">]],
  }
  for _, row in ipairs(rows) do
    local mode = row.mode and (' TargetMode="' .. row.mode .. '"') or ""
    parts[#parts + 1] = ('<Relationship Id="%s" Type="%s" Target="%s"%s/>')
      :format(row.id or "rId1", row.type or "urn:docstyle:test",
        row.target, mode)
  end
  parts[#parts + 1] = "</Relationships>"
  return table.concat(parts)
end

return {
  {
    name = "package limits fail before archive access",
    gate = "safety",
    stage = "package",
    fn = function()
      local invalid = {
        {},
        limits({ max_materialized_bytes = -1 }),
        limits({ max_materialized_bytes = 1.5 }),
        limits({ max_materialized_bytes = math.huge }),
        limits({ max_materialized_bytes = math.maxinteger + 1 }),
      }
      local nil_err = expect_code("opc.invalid-limits", function()
        opc.open_path("/path/that/must/not/be-opened.docx", nil)
      end)
      assert(nil_err.context.phase == "limits")
      for _, value in ipairs(invalid) do
        local err = expect_code("opc.invalid-limits", function()
          opc.open_path("/path/that/must/not/be-opened.docx", value)
        end)
        assert(err.context.phase == "limits")
      end
    end,
  },
  {
    name = "successful reads cache bytes and charge once",
    gate = "safety",
    stage = "package",
    fn = function()
      local payload = "opaque payload"
      local bytes = minimal_package({ {
        name = "custom/opaque.bin",
        data = payload,
      } })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        local before = pkg:remaining_materialization_bytes()
        assert(pkg:part("/custom/opaque.bin") == payload)
        local after_first = pkg:remaining_materialization_bytes()
        assert(before - after_first == #payload)
        assert(pkg:part("/custom/opaque.bin") == payload)
        assert(pkg:remaining_materialization_bytes() == after_first)
        local evidence = pkg:part_evidence("/custom/opaque.bin")
        assert(evidence.produced == #payload)
        assert(evidence.crc32 == vectors.crc32(payload))
        assert(evidence.cache_charge_count == 1)
      end)
    end,
  },
  {
    name = "deflated metadata preserves an integer cumulative budget",
    gate = "safety",
    stage = "package",
    fn = function()
      local bytes = package_bytes({ deflate = true })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        assert(math.type(pkg:remaining_materialization_bytes()) == "integer")
        assert(pkg:part(pkg.office_document_part):find(
          "w:document", 1, true))
        local evidence = pkg:part_evidence(pkg.office_document_part)
        assert(evidence.compression_method == 8)
        assert(math.type(evidence.produced) == "integer")
      end)
    end,
  },
  {
    name = "existing Word and Docstyle packages open through the bounded seam",
    gate = "functional",
    stage = "package",
    fn = function()
      local paths = {
        pandoc.path.join({
          root, "tests", "testthat", "fixtures",
          "word-native-comments.docx",
        }),
        pandoc.path.join({
          root, "tests", "vnext", "fixtures", "popcorn-protocol",
          "baseline", "legacy", "docstyle-docx.docx",
        }),
        pandoc.path.join({
          root, "tests", "vnext", "fixtures", "demport-protocol",
          "baseline", "legacy", "docstyle-docx.docx",
        }),
      }
      for _, path in ipairs(paths) do
        local pkg = opc.open_path(path, limits({
          max_archive_bytes = 128 * 1024 * 1024,
          max_entries = 10000,
          max_entry_uncompressed_bytes = 128 * 1024 * 1024,
          max_total_uncompressed_bytes = 512 * 1024 * 1024,
          max_compression_ratio = 1000,
          max_materialized_bytes = 128 * 1024 * 1024,
        }))
        assert(pkg:part(pkg.office_document_part):find(
          "document", 1, true))
        assert(math.type(pkg:remaining_materialization_bytes()) == "integer")
      end
    end,
  },
  {
    name = "failed reads do not populate cache or spend budget",
    gate = "safety",
    stage = "package",
    fn = function()
      local payload = "too large"
      local bytes = minimal_package({ {
        name = "custom/large.bin",
        data = payload,
      } })
      with_archive(bytes, function(path)
        local generous = limits()
        local probe = opc.open_path(path, generous)
        local metadata_charge = generous.max_materialized_bytes -
          probe:remaining_materialization_bytes()

        local pkg = opc.open_path(path, limits({
          max_materialized_bytes = metadata_charge + #payload - 1,
        }))
        local before = pkg:remaining_materialization_bytes()
        local err = expect_code("zip.output-limit", function()
          pkg:part("/custom/large.bin")
        end)
        assert(err.context.produced == 0)
        assert(pkg:remaining_materialization_bytes() == before)
        assert(pkg:part_evidence("/custom/large.bin") == nil)
      end)
    end,
  },
  {
    name = "content types and standards-defined roots are traversed",
    gate = "functional",
    stage = "package",
    fn = function()
      local unknown = "must remain in inventory"
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/opaque.bin", data = unknown },
        },
      })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        assert(pkg.office_document_part == "/word/document.xml")
        assert(pkg.core_properties_part == "/docProps/core.xml")
        assert(pkg:content_type("/word/document.xml") ==
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")
        assert(pkg:content_type("/custom/opaque.bin") == nil)
        local relationships = pkg:relationships("/")
        assert(#relationships == 2)
        assert(relationships[1].id == "rId1")
        assert(relationships[1].resolved_part == "/word/document.xml")
        assert(relationships[1].target_mode == "Internal")
        assert(relationships[1].external == false)
        assert(relationships[2].resolved_part == "/docProps/core.xml")
        assert(pkg:part(pkg.office_document_part):find("w:document", 1, true))
        assert(pkg:part(pkg.core_properties_part):find(
          "coreProperties", 1, true))

        local names = {}
        for _, entry in ipairs(pkg.entries) do names[entry.name] = true end
        assert(names["custom/opaque.bin"])
        assert(pkg:part_evidence("/custom/opaque.bin") == nil)
      end)
    end,
  },
  {
    name = "part names remain slash-prefixed byte-exact OPC names",
    gate = "safety",
    stage = "package",
    fn = function()
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/My%20File.xml", data = "encoded space" },
        },
      })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        assert(pkg:part("/custom/My%20File.xml") == "encoded space")
        expect_code("opc.invalid-part-name", function()
          pkg:part("/custom/My File.xml")
        end)
        expect_code("opc.part-not-found", function()
          pkg:part("/Word/document.xml")
        end)
        for _, name in ipairs({
          "word/document.xml",
          "//word/document.xml",
          "/[Content_Types].xml",
          "/word/../document.xml",
          "/word/document.xml?query",
          "/word/document.xml#fragment",
        }) do
          expect_code("opc.invalid-part-name", function() pkg:part(name) end)
        end
      end)
    end,
  },
  {
    name = "root relationships require unique IDs and one office root",
    gate = "safety",
    stage = "package",
    fn = function()
      local duplicate_id = [[
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="same" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="same" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>]]
      local duplicate_root = [[
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>]]
      local no_root = [[
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>]]
      local duplicate_core = [[
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>]]
      local missing_id = [[
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>]]
      local nested = [[
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Wrapper>
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  </Wrapper>
</Relationships>]]
      local wrong_root = [[
<NotRelationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>]]
      local rows = {
        { duplicate_id, "opc.duplicate-relationship-id" },
        { duplicate_root, "opc.ambiguous-office-document" },
        { no_root, "opc.office-document-root" },
        { duplicate_core, "opc.ambiguous-core-properties" },
        { missing_id, "opc.relationship-attribute" },
        { nested, "opc.relationships-structure" },
        { wrong_root, "opc.relationships-root" },
      }
      for _, row in ipairs(rows) do
        local bytes = package_bytes({ root_relationships = row[1] })
        with_archive(bytes, function(path)
          expect_code(row[2], function() opc.open_path(path, limits()) end)
        end)
      end
    end,
  },
  {
    name = "content-type metadata is required and structurally validated",
    gate = "safety",
    stage = "package",
    fn = function()
      local wrong_root = [[
<NotTypes xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>]]
      local duplicate_default = [[
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="XML" ContentType="application/other+xml"/>
</Types>]]
      local invalid_entry = [[
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Override PartName="/word/document.xml"/>
</Types>]]
      local nested = [[
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Wrapper>
    <Default Extension="xml" ContentType="application/xml"/>
  </Wrapper>
</Types>]]
      local root_without_content_type = [[
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
</Types>]]
      local rows = {
        { package_bytes({ omit_content_types = true }),
          "opc.content-types-missing" },
        { package_bytes({ content_types = wrong_root }),
          "opc.content-types-root" },
        { package_bytes({ content_types = duplicate_default }),
          "opc.content-types-duplicate" },
        { package_bytes({ content_types = invalid_entry }),
          "opc.content-types-entry" },
        { package_bytes({ content_types = nested }),
          "opc.content-types-structure" },
        { package_bytes({ content_types = root_without_content_type }),
          "opc.content-type-missing" },
        { package_bytes({ omit_root_relationships = true }),
          "opc.relationships-missing" },
      }
      for _, row in ipairs(rows) do
        with_archive(row[1], function(path)
          expect_code(row[2], function() opc.open_path(path, limits()) end)
        end)
      end
    end,
  },
  {
    name = "relationship targets follow the bounded RFC 3986 subset",
    gate = "functional",
    stage = "package",
    fn = function()
      local relationship_xml = document_relationships({
        { id = "space", target = "media/My%20Image.png" },
        { id = "tilde", target = "%7Eauthor.xml" },
        { id = "reserved", target = "media/My%2bImage.png" },
        { id = "stored-lower", target = "media/lower%2Bname.xml" },
        { id = "dot-name", target = "media/%2Ehidden.xml" },
        { id = "parent", target = "../custom/item.xml" },
        { id = "fragment", target = "comments.xml#mark?within-fragment" },
        { id = "self-fragment", target = "#same-part" },
        { id = "external-relative", target = "../outside.html",
          mode = "External" },
        { id = "external-uri", target = "https://example.test/resource",
          mode = "External" },
      })
      local bytes = package_bytes({
        extra_entries = {
          { name = "word/_rels/document.xml.rels", data = relationship_xml },
          { name = "word/media/My%20Image.png", data = "space" },
          { name = "word/~author.xml", data = "tilde" },
          { name = "word/media/My%2BImage.png", data = "reserved" },
          { name = "word/media/lower%2bname.xml", data = "lower hex" },
          { name = "word/media/.hidden.xml", data = "dot name" },
          { name = "custom/item.xml", data = "parent" },
          { name = "word/comments.xml", data = "fragment" },
        },
      })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        local relationships = pkg:relationships("/word/document.xml")
        local after_relationships = pkg:remaining_materialization_bytes()
        assert(pkg:relationships("/word/document.xml") == relationships)
        assert(pkg:remaining_materialization_bytes() == after_relationships)
        assert(#relationships == 10)
        local by_id = {}
        for _, relationship in ipairs(relationships) do
          by_id[relationship.id] = relationship
        end
        assert(by_id.space.resolved_part == "/word/media/My%20Image.png")
        assert(by_id.tilde.resolved_part == "/word/~author.xml")
        assert(by_id.reserved.resolved_part ==
          "/word/media/My%2BImage.png")
        assert(by_id["stored-lower"].resolved_part ==
          "/word/media/lower%2bname.xml")
        assert(pkg:part(by_id["stored-lower"].resolved_part) == "lower hex")
        expect_code("opc.part-not-found", function()
          pkg:part("/word/media/lower%2Bname.xml")
        end)
        assert(by_id["dot-name"].resolved_part ==
          "/word/media/.hidden.xml")
        assert(by_id.parent.resolved_part == "/custom/item.xml")
        assert(by_id.fragment.resolved_part == "/word/comments.xml")
        assert(by_id.fragment.fragment == "mark?within-fragment")
        assert(by_id["self-fragment"].resolved_part ==
          "/word/document.xml")
        assert(by_id["self-fragment"].fragment == "same-part")
        assert(by_id["external-relative"].external == true)
        assert(by_id["external-relative"].resolved_part == nil)
        assert(by_id["external-uri"].target ==
          "https://example.test/resource")
        assert(by_id["external-uri"].resolved_part == nil)
      end)
    end,
  },
  {
    name = "materialization limits are inclusive at the exact boundary",
    gate = "safety",
    stage = "package",
    fn = function()
      local payload = "boundary"
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/boundary.bin", data = payload },
        },
      })
      with_archive(bytes, function(path)
        local generous = limits()
        local probe = opc.open_path(path, generous)
        local metadata_charge = generous.max_materialized_bytes -
          probe:remaining_materialization_bytes()
        local exact = opc.open_path(path, limits({
          max_materialized_bytes = metadata_charge + #payload,
        }))
        assert(exact:part("/custom/boundary.bin") == payload)
        assert(exact:remaining_materialization_bytes() == 0)

        expect_code("zip.output-limit", function()
          local short = opc.open_path(path, limits({
            max_materialized_bytes = metadata_charge - 1,
          }))
          return short
        end)
      end)
    end,
  },
  {
    name = "unsafe internal relationship targets fail closed",
    gate = "safety",
    stage = "package",
    fn = function()
      local rows = {
        { "media/%2Fescape.xml", "opc.encoded-separator" },
        { "media/%5cescape.xml", "opc.encoded-separator" },
        { "%2E%2e/escape.xml", "opc.encoded-dot-segment" },
        { "media/bad%2.xml", "opc.malformed-percent-encoding" },
        { "media/bad%GG.xml", "opc.malformed-percent-encoding" },
        { "media/%00.xml", "opc.encoded-control" },
        { "media/%1f.xml", "opc.encoded-control" },
        { "media/%7F.xml", "opc.encoded-control" },
        { "https://example.test/x", "opc.invalid-relationship-target" },
        { "//example.test/x", "opc.invalid-relationship-target" },
        { "media/x.xml?query", "opc.invalid-relationship-target" },
        { "media/raw space.xml", "opc.invalid-relationship-target" },
        { "1bad:target.xml", "opc.invalid-relationship-target" },
        { "../../escape.xml", "opc.relationship-target-escape" },
        { "media/case.xml", "opc.relationship-target-missing",
          "word/media/Case.xml" },
      }
      for index, row in ipairs(rows) do
        local rels = document_relationships({ {
          id = "rId" .. index,
          target = row[1],
        } })
        local extra = {
          { name = "word/_rels/document.xml.rels", data = rels },
        }
        if row[3] then
          extra[#extra + 1] = { name = row[3], data = "case" }
        end
        local bytes = package_bytes({ extra_entries = extra })
        with_archive(bytes, function(path)
          local pkg = opc.open_path(path, limits())
          expect_code(row[2], function()
            pkg:relationships("/word/document.xml")
          end)
        end)
      end
    end,
  },
  {
    name = "TargetMode accepts only omitted internal or exact External",
    gate = "safety",
    stage = "package",
    fn = function()
      for _, mode in ipairs({ "Internal", "external", "EXTERNAL", "" }) do
        local rels = document_relationships({ {
          target = "media/x.xml",
          mode = mode,
        } })
        local bytes = package_bytes({
          extra_entries = {
            { name = "word/_rels/document.xml.rels", data = rels },
            { name = "word/media/x.xml", data = "x" },
          },
        })
        with_archive(bytes, function(path)
          local pkg = opc.open_path(path, limits())
          expect_code("opc.invalid-target-mode", function()
            pkg:relationships("/word/document.xml")
          end)
        end)
      end
    end,
  },
  {
    name = "cumulative budget charges each distinct materialization once",
    gate = "safety",
    stage = "package",
    fn = function()
      local first, second = "first", "second"
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/first.bin", data = first },
          { name = "custom/second.bin", data = second },
        },
      })
      with_archive(bytes, function(path)
        local generous = limits()
        local probe = opc.open_path(path, generous)
        local metadata_charge = generous.max_materialized_bytes -
          probe:remaining_materialization_bytes()
        local pkg = opc.open_path(path, limits({
          max_materialized_bytes = metadata_charge + #first + #second - 1,
        }))
        assert(pkg:part("/custom/first.bin") == first)
        local after_first = pkg:remaining_materialization_bytes()
        assert(pkg:part("/custom/first.bin") == first)
        assert(pkg:remaining_materialization_bytes() == after_first)
        local err = expect_code("zip.output-limit", function()
          pkg:part("/custom/second.bin")
        end)
        assert(err.context.produced == 0)
        assert(pkg:remaining_materialization_bytes() == after_first)
        assert(pkg:part_evidence("/custom/second.bin") == nil)
      end)
    end,
  },
  {
    name = "package content stays bound to preflight ranges and CRC evidence",
    gate = "safety",
    stage = "package",
    fn = function()
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/bad-crc.bin", data = "payload", crc32 = 0 },
        },
      })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        assert(pkg.archive.backend.kind ==
          "docstyle-bounded-entry-reader")
        local before = pkg:remaining_materialization_bytes()
        expect_code("zip.crc32-mismatch", function()
          pkg:part("/custom/bad-crc.bin")
        end)
        assert(pkg:remaining_materialization_bytes() == before)
        assert(pkg:part_evidence("/custom/bad-crc.bin") == nil)
      end)

      local source = fixture.read_bytes(pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "archive", "opc.lua",
      }))
      assert(not source:find("pandoc%.zip%.Archive%s*%("),
        "OPC seam must not use pandoc.zip for untrusted content")
      assert(source:find("entry_reader.read_entry", 1, true),
        "OPC seam must use the bounded entry reader")
    end,
  },
  {
    name = "replacement bytes shadow an existing part without budget charge",
    gate = "preservation",
    stage = "package",
    fn = function()
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/unknown.bin", data = "unknown" },
        },
      })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        local original = pkg:part("/word/document.xml")
        assert(original:find("w:document", 1, true))
        local before = pkg:remaining_materialization_bytes()
        pkg:replace_part("/word/document.xml", "replacement bytes")
        assert(pkg:part("/word/document.xml") == "replacement bytes")
        assert(pkg:remaining_materialization_bytes() == before)
        assert(pkg:part("/custom/unknown.bin") == "unknown")
        expect_code("opc.part-not-found", function()
          pkg:replace_part("/missing.xml", "x")
        end)
        expect_code("opc.invalid-replacement", function()
          pkg:replace_part("/word/document.xml", {})
        end)
      end)
    end,
  },
  {
    name = "replacement rejects package relationship metadata",
    gate = "preservation",
    stage = "package",
    fn = function()
      local bytes = package_bytes({
        extra_entries = {
          {
            name = "word/_rels/document.xml.rels",
            data = document_relationships({ {
              target = "../docProps/core.xml",
            } }),
          },
        },
      })
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        expect_code("opc.metadata-replacement", function()
          pkg:replace_part("/_rels/.rels", "replacement")
        end)
        expect_code("opc.metadata-replacement", function()
          pkg:replace_part(
            "/word/_rels/document.xml.rels", "replacement")
        end)
        expect_code("opc.invalid-part-name", function()
          pkg:replace_part("/[Content_Types].xml", "replacement")
        end)
      end)
    end,
  },
  {
    name = "package copies validated limits before exposing the handle",
    gate = "safety",
    stage = "package",
    fn = function()
      local bytes = minimal_package()
      with_archive(bytes, function(path)
        local supplied = limits()
        local pkg = opc.open_path(path, supplied)
        supplied.max_entry_uncompressed_bytes = 0
        supplied.max_materialized_bytes = 0
        assert(pkg:part("/word/document.xml"):find("w:document", 1, true))
      end)
    end,
  },
  {
    name = "public part lookup applies the OPC percent-encoding grammar",
    gate = "safety",
    stage = "package",
    fn = function()
      local bytes = minimal_package()
      with_archive(bytes, function(path)
        local pkg = opc.open_path(path, limits())
        for _, name in ipairs({
          "/word/bad%2.xml",
          "/word/bad%GG.xml",
          "/word/%2Fescape.xml",
          "/word/%5cescape.xml",
          "/word/%7Eencoded-unreserved.xml",
          "/word/raw space.xml",
          "/word/raw[bracket].xml",
          "/word/trailing.",
        }) do
          expect_code("opc.invalid-part-name", function() pkg:part(name) end)
        end
      end)
    end,
  },
  {
    name = "all stored entries pass OPC part-name grammar before exposure",
    gate = "safety",
    stage = "package",
    fn = function()
      local bytes = package_bytes({
        extra_entries = {
          { name = "custom/raw space.xml", data = "invalid URI" },
        },
      })
      with_archive(bytes, function(path)
        expect_code("opc.invalid-part-name", function()
          opc.open_path(path, limits())
        end)
      end)
    end,
  },
}
