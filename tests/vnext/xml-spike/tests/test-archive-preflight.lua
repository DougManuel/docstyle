local binary = require("lib.binary")
local diagnostic = require("lib.diagnostic")
local fixture = require("lib.fixture")
local preflight = require("archive.zip_preflight")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local vectors = dofile(pandoc.path.join({
  runner_here, "fixtures", "archive", "vectors.lua",
}))

local DEFAULT_LIMITS = {
  max_archive_bytes = 1024 * 1024,
  max_entries = 100,
  max_entry_uncompressed_bytes = 1024 * 1024,
  max_total_uncompressed_bytes = 2 * 1024 * 1024,
  max_compression_ratio = 100,
}

local function limits(overrides)
  local result = {}
  for key, value in pairs(DEFAULT_LIMITS) do result[key] = value end
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

local function with_archive(bytes, fn)
  return fixture.with_temp_dir("archive", function(dir)
    local path = pandoc.path.join({ dir, "fixture.docx" })
    fixture.write_bytes(path, bytes)
    return fn(path)
  end)
end

local function expect_code(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected diagnostic " .. code)
  assert(err.code == code,
    "expected diagnostic " .. code .. ", got " .. tostring(err.code))
  return err
end

local function with_open_override(open_fn, fn)
  local original = io.open
  io.open = open_fn
  local results = table.pack(pcall(fn))
  io.open = original
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

return {
  {
    name = "little-endian readers use zero-based offsets",
    gate = "archive",
    stage = "archive",
    fn = function()
      local bytes = "\xAA\x34\x12\x78\x56\x34\x12"
      assert(binary.u16le(bytes, 1) == 0x1234)
      assert(binary.u32le(bytes, 3) == 0x12345678)
    end,
  },
  {
    name = "64-bit reader preserves exact supported integers",
    gate = "archive",
    stage = "archive",
    fn = function()
      assert(binary.u64le("\xFF\xFF\xFF\xFF\x01\0\0\0", 0) == 0x1FFFFFFFF)
      assert(binary.u64le("\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x7F", 0) == math.maxinteger)
    end,
  },
  {
    name = "readers reject truncated fields with byte context",
    gate = "archive",
    stage = "archive",
    fn = function()
      local err = expect_code("zip.truncated", function()
        binary.u32le("\0\0\0", 0, { record = "EOCD" })
      end)
      assert(err.context.offset == 0)
      assert(err.context.needed == 4)
      assert(err.context.available == 3)
      assert(err.context.record == "EOCD")
    end,
  },
  {
    name = "64-bit reader rejects values outside Lua integer range",
    gate = "archive",
    stage = "archive",
    fn = function()
      local err = expect_code("zip.integer-overflow", function()
        binary.u64le("\0\0\0\0\0\0\0\x80", 0, { record = "ZIP64" })
      end)
      assert(err.context.offset == 0)
      assert(err.context.record == "ZIP64")
    end,
  },
  {
    name = "checked addition rejects integer overflow",
    gate = "archive",
    stage = "archive",
    fn = function()
      assert(binary.checked_add(10, 20, { record = "span" }) == 30)
      local err = expect_code("zip.integer-overflow", function()
        binary.checked_add(math.maxinteger, 1, { record = "span" })
      end)
      assert(err.context.record == "span")
    end,
  },
  {
    name = "valid stored package is fully preflighted before backend construction",
    gate = "archive",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "[Content_Types].xml", data = "<Types/>" },
        { name = "_rels/.rels", data = "<Relationships/>" },
        { name = "word/document.xml", data = "<w:document/>" },
      })
      with_archive(bytes, function(path)
        local calls = 0
        local result = preflight.open_path(path, limits(), {
          backend_factory = function(archive_bytes)
            calls = calls + 1
            assert(archive_bytes == bytes)
            return { marker = "backend" }
          end,
        })
        assert(calls == 1)
        assert(result.backend.marker == "backend")
        assert(#result.entries == 3)
        assert(result.entries[1].name == "[Content_Types].xml")
        assert(result.entries[2].name == "_rels/.rels")
        assert(result.entries[3].name == "word/document.xml")
        for _, entry in ipairs(result.entries) do
          assert(entry.local_span.start < entry.local_span.finish)
          assert(entry.local_span.finish <= result.central_directory.start)
        end
      end)
    end,
  },
  {
    name = "archive growth is detected through one bounded handle",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/document.xml",
        data = "x",
      } })
      local calls, closes, read_limit = 0, 0, nil
      local cursor = 0
      local handle = {}
      function handle:seek(whence, offset)
        if whence == "end" then
          cursor = #bytes
          return cursor
        end
        assert(whence == "set" and offset == 0,
          "archive reader must rewind the validated handle")
        cursor = 0
        return cursor
      end
      function handle:read(limit)
        assert(cursor == 0, "archive reader must rewind before reading")
        assert(type(limit) == "number", "archive read must be byte-bounded")
        read_limit = limit
        cursor = #bytes + 1
        return bytes .. "x"
      end
      function handle:close()
        closes = closes + 1
        return true
      end

      local err = with_open_override(function(path, mode)
        calls = calls + 1
        assert(calls == 1, "archive path must be opened exactly once")
        assert(path == "virtual.docx" and mode == "rb")
        return handle
      end, function()
        return expect_code("zip.file-changed", function()
          preflight.open_path("virtual.docx", limits())
        end)
      end)

      assert(err.context.before == #bytes)
      assert(err.context.after == #bytes + 1)
      assert(calls == 1 and closes == 1)
      assert(read_limit == #bytes + 1,
        "archive read must probe at most one byte beyond observed size")
    end,
  },
  {
    name = "empty archive reaches EOCD validation after bounded read",
    gate = "safety",
    stage = "archive",
    fn = function()
      with_archive("", function(path)
        expect_code("zip.eocd-not-found", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "compressed file-size limit is inclusive and checked before loading",
    gate = "archive",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/document.xml", data = "payload" },
      })
      with_archive(bytes, function(path)
        local calls = 0
        local opts = { backend_factory = function()
          calls = calls + 1
          return {}
        end }
        local result = preflight.open_path(path,
          limits({ max_archive_bytes = #bytes }), opts)
        assert(result.archive_size == #bytes)
        assert(calls == 1)

        local err = expect_code("zip.archive-size-limit", function()
          preflight.open_path(path,
            limits({ max_archive_bytes = #bytes - 1 }), opts)
        end)
        assert(err.context.actual == #bytes)
        assert(err.context.limit == #bytes - 1)
        assert(calls == 1)
      end)
    end,
  },
  {
    name = "EOCD search ignores signature bytes inside the archive comment",
    gate = "archive",
    stage = "archive",
    fn = function()
      local fake = vectors.le32(0x06054B50) .. "not-an-eocd"
      local bytes = vectors.archive({
        { name = "word/document.xml", data = "x" },
      }, { comment = fake })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, limits())
        assert(#result.entries == 1)
        assert(result.comment == fake)
      end)
    end,
  },
  {
    name = "multi-disk archives fail before backend construction",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/document.xml", data = "x" },
      }, { disk_number = 1, central_disk = 1 })
      with_archive(bytes, function(path)
        local calls = 0
        local err = expect_code("zip.multi-disk", function()
          preflight.open_path(path, limits(), {
            backend_factory = function() calls = calls + 1 end,
          })
        end)
        assert(err.context.disk_number == 1)
        assert(calls == 0)
      end)
    end,
  },
  {
    name = "declared count and size limits are inclusive",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/a.xml", data = "abc" },
        { name = "word/b.xml", data = "def" },
      })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, limits({
          max_entries = 2,
          max_entry_uncompressed_bytes = 3,
          max_total_uncompressed_bytes = 6,
        }))
        assert(#result.entries == 2)
        expect_code("zip.entry-count-limit", function()
          preflight.open_path(path, limits({ max_entries = 1 }))
        end)
        expect_code("zip.entry-size-limit", function()
          preflight.open_path(path,
            limits({ max_entry_uncompressed_bytes = 2 }))
        end)
        expect_code("zip.total-size-limit", function()
          preflight.open_path(path,
            limits({ max_total_uncompressed_bytes = 5 }))
        end)
      end)
    end,
  },
  {
    name = "declared compression-ratio limit is inclusive",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        {
          name = "word/document.xml",
          data = string.rep("a", 10),
          compressed = "x",
          method = 8,
        },
      })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path,
          limits({ max_compression_ratio = 10 }))
        assert(result.entries[1].compressed_size == 1)
        expect_code("zip.compression-ratio-limit", function()
          preflight.open_path(path, limits({ max_compression_ratio = 9 }))
        end)
      end)
    end,
  },
  {
    name = "invalid limit values fail before file access",
    gate = "safety",
    stage = "archive",
    fn = function()
      for _, value in ipairs({ -1, 1.5, "1" }) do
        local err = expect_code("zip.invalid-limits", function()
          preflight.open_path("does-not-exist.docx",
            limits({ max_entries = value }))
        end)
        assert(err.context.limit_name == "max_entries")
      end
      expect_code("zip.invalid-limits", function()
        preflight.open_path("does-not-exist.docx", {})
      end)
    end,
  },
  {
    name = "unsafe OPC and archive names fail closed",
    gate = "safety",
    stage = "archive",
    fn = function()
      local names = {
        "", "/word/document.xml", "C:/word/document.xml",
        "word\\document.xml", "word/../document.xml",
        "word/./document.xml", "word//document.xml",
        "word/document.xml/", "word/document.xml?x",
        "word/document.xml#x", "word/doc\0ument.xml",
      }
      for _, name in ipairs(names) do
        local bytes = vectors.archive({ { name = name, data = "x" } })
        with_archive(bytes, function(path)
          local err = expect_code("zip.invalid-name", function()
            preflight.open_path(path, limits())
          end)
          assert(err.context.entry == name or name == "")
        end)
      end
    end,
  },
  {
    name = "malformed and undeclared UTF-8 entry names are rejected",
    gate = "safety",
    stage = "archive",
    fn = function()
      local cases = {
        { name = "word/\xFF.xml", flags = 0x0800 },
        { name = "word/\xC3\xA9.xml", flags = 0 },
      }
      for _, entry in ipairs(cases) do
        local bytes = vectors.archive({ entry })
        with_archive(bytes, function(path)
          expect_code("zip.invalid-name-encoding", function()
            preflight.open_path(path, limits())
          end)
        end)
      end
    end,
  },
  {
    name = "duplicate exact and ASCII case-colliding names are rejected",
    gate = "safety",
    stage = "archive",
    fn = function()
      local duplicate = vectors.archive({
        { name = "word/a.xml" }, { name = "word/a.xml" },
      })
      with_archive(duplicate, function(path)
        expect_code("zip.duplicate-name", function()
          preflight.open_path(path, limits())
        end)
      end)

      local collision = vectors.archive({
        { name = "word/A.xml" }, { name = "word/a.xml" },
      })
      with_archive(collision, function(path)
        expect_code("zip.case-collision", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "encrypted symlink and unsupported-method entries are rejected",
    gate = "safety",
    stage = "archive",
    fn = function()
      local cases = {
        {
          entry = { name = "word/encrypted.xml", flags = 0x0801 },
          code = "zip.encrypted-entry",
        },
        {
          entry = {
            name = "word/link.xml",
            made_by_os = 3,
            external_attributes = 0xA000 << 16,
          },
          code = "zip.symlink-entry",
        },
        {
          entry = { name = "word/method.xml", method = 99 },
          code = "zip.unsupported-method",
        },
      }
      for _, case in ipairs(cases) do
        local bytes = vectors.archive({ case.entry })
        with_archive(bytes, function(path)
          expect_code(case.code, function()
            preflight.open_path(path, limits())
          end)
        end)
      end
    end,
  },
  {
    name = "symlink mode bits fail closed despite a spoofed creator host",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/spoofed-link.xml",
        made_by_os = 0,
        external_attributes = 0xA000 << 16,
      } })
      with_archive(bytes, function(path)
        expect_code("zip.symlink-entry", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "every central name must match its local header before backend construction",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/requested.xml", data = "a" },
        {
          name = "word/unrequested.xml",
          local_name = "word/different.xml",
          data = "b",
        },
      })
      with_archive(bytes, function(path)
        local calls = 0
        local err = expect_code("zip.local-name-mismatch", function()
          preflight.open_path(path, limits(), {
            backend_factory = function() calls = calls + 1 end,
          })
        end)
        assert(err.context.entry == "word/unrequested.xml")
        assert(calls == 0)
      end)
    end,
  },
  {
    name = "local sizes and methods must agree with the central directory",
    gate = "safety",
    stage = "archive",
    fn = function()
      local size_mismatch = vectors.archive({ {
        name = "word/document.xml",
        data = "abcd",
        local_compressed_size = 3,
      } })
      with_archive(size_mismatch, function(path)
        expect_code("zip.local-size-mismatch", function()
          preflight.open_path(path, limits())
        end)
      end)

      local method_mismatch = vectors.archive({ {
        name = "word/document.xml",
        data = "abcd",
        local_method = 8,
      } })
      with_archive(method_mismatch, function(path)
        expect_code("zip.local-header-mismatch", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "signed and unsigned data descriptors extend the complete local span",
    gate = "archive",
    stage = "archive",
    fn = function()
      for _, signed in ipairs({ true, false }) do
        local bytes = vectors.archive({ {
          name = "word/document.xml",
          data = "abcd",
          descriptor = true,
          descriptor_signature = signed,
        } })
        with_archive(bytes, function(path)
          local result = preflight.open_path(path, limits())
          local entry = result.entries[1]
          assert(entry.descriptor_length == (signed and 16 or 12))
          assert(entry.local_span.finish == result.central_directory.start)
        end)
      end
    end,
  },
  {
    name = "data descriptor disagreement fails closed",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/document.xml",
        data = "abcd",
        descriptor = true,
        descriptor_uncompressed_size = 3,
      } })
      with_archive(bytes, function(path)
        expect_code("zip.descriptor-mismatch", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "duplicate local-header offsets fail before local parsing",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/a.xml", data = "a" },
        { name = "word/b.xml", data = "b", central_local_offset = 0 },
      })
      with_archive(bytes, function(path)
        expect_code("zip.duplicate-local-offset", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "complete local-entry spans must be pairwise disjoint",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        {
          name = "word/a.xml",
          data = "a",
          method = 8,
          declared_compressed_size = 20,
          local_compressed_size = 20,
        },
        { name = "word/b.xml", data = "b" },
      })
      with_archive(bytes, function(path)
        expect_code("zip.local-span-overlap", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "local-entry spans must stop before archive metadata",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/document.xml",
        data = "a",
        method = 8,
        declared_compressed_size = 10,
        local_compressed_size = 10,
      } })
      with_archive(bytes, function(path)
        expect_code("zip.local-span-overlap-metadata", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "central-directory bounds and entry sizes are exact",
    gate = "safety",
    stage = "archive",
    fn = function()
      local _, info = vectors.archive({
        { name = "word/document.xml", data = "a" },
      })
      local bytes = vectors.archive({
        { name = "word/document.xml", data = "a" },
      }, { central_size = info.central_size - 1 })
      with_archive(bytes, function(path)
        expect_code("zip.central-bounds", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "span validation remains linearithmic for many entries",
    gate = "archive",
    stage = "archive",
    fn = function()
      local entries = {}
      for index = 1, 2000 do
        entries[index] = { name = ("word/p%04d.xml"):format(index) }
      end
      local bytes = vectors.archive(entries)
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, limits({
          max_archive_bytes = #bytes,
          max_entries = 2000,
        }))
        assert(#result.entries == 2000)
      end)
    end,
  },
  {
    name = "ZIP64 EOCD and entry extra fields supply authoritative values",
    gate = "archive",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/document.xml",
        data = "abcd",
        force_zip64 = true,
      } }, { zip64 = true })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, limits())
        assert(result.zip64 ~= nil)
        assert(result.entries[1].compressed_size == 4)
        assert(result.entries[1].uncompressed_size == 4)
        assert(result.entries[1].local_header_offset == 0)
        assert(result.central_directory.finish <= result.zip64.eocd.start)
        assert(result.zip64.eocd.finish <= result.zip64.locator.start)
        assert(result.zip64.locator.finish <= result.eocd.start)
      end)
    end,
  },
  {
    name = "ZIP64 multi-disk metadata fails closed",
    gate = "safety",
    stage = "archive",
    fn = function()
      local cases = {
        { zip64_disk_number = 1 },
        { zip64_central_disk = 1 },
        { zip64_locator_disk = 1 },
        { zip64_total_disks = 2 },
      }
      for _, options in ipairs(cases) do
        options.zip64 = true
        local bytes = vectors.archive({ {
          name = "word/document.xml",
          force_zip64 = true,
        } }, options)
        with_archive(bytes, function(path)
          expect_code("zip.multi-disk", function()
            preflight.open_path(path, limits())
          end)
        end)
      end
    end,
  },
  {
    name = "missing ZIP64 locator is rejected when EOCD fields are saturated",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/document.xml" },
      }, {
        entries_on_disk = 0xFFFF,
        total_entries = 0xFFFF,
        central_size = 0xFFFFFFFF,
        central_offset = 0xFFFFFFFF,
      })
      with_archive(bytes, function(path)
        expect_code("zip.zip64-locator-missing", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "ZIP64 integers outside Lua range fail with exact offset context",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes, info = vectors.archive({ {
        name = "word/document.xml",
        force_zip64 = true,
      } }, { zip64 = true })
      bytes = vectors.patch(bytes, info.zip64_eocd_offset + 32,
        "\0\0\0\0\0\0\0\x80")
      with_archive(bytes, function(path)
        local err = expect_code("zip.integer-overflow", function()
          preflight.open_path(path, limits())
        end)
        assert(err.context.record == "ZIP64-EOCD")
        assert(err.context.offset == info.zip64_eocd_offset + 32)
      end)
    end,
  },
  {
    name = "ZIP64 data descriptors use 64-bit sizes in complete spans",
    gate = "archive",
    stage = "archive",
    fn = function()
      for _, signed in ipairs({ true, false }) do
        local bytes = vectors.archive({ {
          name = "word/document.xml",
          data = "abcd",
          force_zip64 = true,
          descriptor = true,
          descriptor_signature = signed,
        } }, { zip64 = true })
        with_archive(bytes, function(path)
          local result = preflight.open_path(path, limits())
          assert(result.entries[1].descriptor_length == (signed and 24 or 20))
          assert(result.entries[1].local_span.finish ==
            result.central_directory.start)
        end)
      end
    end,
  },
  {
    name = "offset-only ZIP64 entries keep 32-bit descriptor sizes",
    gate = "archive",
    stage = "archive",
    fn = function()
      for _, signed in ipairs({ true, false }) do
        local bytes = vectors.archive({ {
          name = "word/document.xml",
          data = "abcd",
          zip64_offset = true,
          descriptor = true,
          descriptor_signature = signed,
        } })
        with_archive(bytes, function(path)
          local result = preflight.open_path(path, limits())
          local entry = result.entries[1]
          assert(entry.uses_zip64 == true)
          assert(entry.uses_zip64_sizes == false)
          assert(entry.descriptor_length == (signed and 16 or 12))
          assert(entry.local_span.finish == result.central_directory.start)
        end)
      end
    end,
  },
  {
    name = "ZIP64 locator must point to a complete adjacent EOCD record",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bad_offset = vectors.archive({ {
        name = "word/document.xml",
        force_zip64 = true,
      } }, { zip64 = true, zip64_locator_offset = 0 })
      with_archive(bad_offset, function(path)
        expect_code("zip.zip64-signature", function()
          preflight.open_path(path, limits())
        end)
      end)

      local short_record, info = vectors.archive({ {
        name = "word/document.xml",
        force_zip64 = true,
      } }, { zip64 = true })
      short_record = vectors.patch(short_record, info.zip64_eocd_offset + 4,
        vectors.le64(43))
      with_archive(short_record, function(path)
        expect_code("zip.zip64-record-size", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "stored entries require equal compressed and uncompressed sizes",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/document.xml",
        data = "abcd",
        compressed = "abc",
        method = 0,
      } })
      with_archive(bytes, function(path)
        expect_code("zip.stored-size-mismatch", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "OPC percent encodings and segment endings are validated without decoding",
    gate = "safety",
    stage = "archive",
    fn = function()
      local valid = vectors.archive({ {
        name = "word/My%20Image.xml",
        data = "x",
      } })
      with_archive(valid, function(path)
        local result = preflight.open_path(path, limits())
        assert(result.entries[1].name == "word/My%20Image.xml")
      end)

      local invalid = {
        "word/a%2.xml", "word/a%GG.xml", "word/a%2F.xml",
        "word/a%5c.xml", "word/a%00.xml", "word/a.", "word/...",
      }
      for _, name in ipairs(invalid) do
        local bytes = vectors.archive({ { name = name } })
        with_archive(bytes, function(path)
          expect_code("zip.invalid-name", function()
            preflight.open_path(path, limits())
          end)
        end)
      end
    end,
  },
  {
    name = "OPC part names reject percent-encoded unreserved characters",
    gate = "safety",
    stage = "archive",
    fn = function()
      local invalid = {
        "word/%2E.xml",
        "word/%2e%2e/outside.xml",
        "word/.%2e/outside.xml",
        "word/%41.xml",
        "word/%7E.xml",
      }
      for _, name in ipairs(invalid) do
        local bytes = vectors.archive({ { name = name } })
        with_archive(bytes, function(path)
          expect_code("zip.invalid-name", function()
            preflight.open_path(path, limits())
          end)
        end)
      end
    end,
  },
  {
    name = "maximum EOCD comment length is accepted exactly",
    gate = "archive",
    stage = "archive",
    fn = function()
      local comment = string.rep("c", 0xFFFF)
      local bytes = vectors.archive({
        { name = "word/document.xml" },
      }, { comment = comment })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, limits({
          max_archive_bytes = #bytes,
        }))
        assert(#result.comment == 0xFFFF)
      end)
    end,
  },
  {
    name = "required ZIP64 entry extra fields cannot be absent or truncated",
    gate = "safety",
    stage = "archive",
    fn = function()
      local missing = vectors.archive({ {
        name = "word/document.xml",
        force_zip64 = true,
        omit_central_zip64_extra = true,
      } }, { zip64 = true })
      with_archive(missing, function(path)
        expect_code("zip.zip64-extra-missing", function()
          preflight.open_path(path, limits())
        end)
      end)

      local truncated = vectors.archive({ {
        name = "word/document.xml",
        force_zip64 = true,
        omit_central_zip64_extra = true,
        central_extra = vectors.le16(0x0001) .. vectors.le16(4) ..
          vectors.le32(0),
      } }, { zip64 = true })
      with_archive(truncated, function(path)
        expect_code("zip.zip64-extra-truncated", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "backend construction remains after all metadata validation",
    gate = "safety",
    stage = "archive",
    fn = function()
      local cases = {
        {
          code = "zip.invalid-name",
          bytes = vectors.archive({ { name = "word/../x.xml" } }),
        },
        {
          code = "zip.encrypted-entry",
          bytes = vectors.archive({ {
            name = "word/x.xml", flags = 0x0801,
          } }),
        },
        {
          code = "zip.local-size-mismatch",
          bytes = vectors.archive({ {
            name = "word/x.xml", data = "xx", local_compressed_size = 1,
          } }),
        },
      }
      for _, case in ipairs(cases) do
        with_archive(case.bytes, function(path)
          local calls = 0
          expect_code(case.code, function()
            preflight.open_path(path, limits(), {
              backend_factory = function() calls = calls + 1 end,
            })
          end)
          assert(calls == 0)
        end)
      end
    end,
  },
  {
    name = "validated metadata rows are immutable",
    gate = "archive",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({
        { name = "word/document.xml", data = "x" },
      })
      with_archive(bytes, function(path)
        local result = preflight.open_path(path, limits())
        local ok, err = pcall(function()
          result.entries[1].name = "word/changed.xml"
        end)
        assert(not ok)
        assert(tostring(err):match("immutable ZIP metadata"))
        assert(result.entries[1].name == "word/document.xml")
      end)
    end,
  },
  {
    name = "local ZIP64 extra values are required when local fields are saturated",
    gate = "safety",
    stage = "archive",
    fn = function()
      local bytes = vectors.archive({ {
        name = "word/document.xml",
        force_zip64 = true,
        omit_local_zip64_extra = true,
      } }, { zip64 = true })
      with_archive(bytes, function(path)
        expect_code("zip.zip64-extra-missing", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
  {
    name = "non-saturated classic EOCD values must agree with ZIP64",
    gate = "safety",
    stage = "archive",
    fn = function()
      local entry = {
        name = "word/document.xml",
        force_zip64 = true,
      }
      local _, info = vectors.archive({ entry }, { zip64 = true })
      local bytes = vectors.archive({ entry }, {
        zip64 = true,
        entries_on_disk = 1,
        total_entries = 1,
        central_size = info.central_size,
        central_offset = info.central_offset,
        zip64_entries_on_disk = 2,
        zip64_total_entries = 2,
      })
      with_archive(bytes, function(path)
        expect_code("zip.zip64-classic-mismatch", function()
          preflight.open_path(path, limits())
        end)
      end)
    end,
  },
}
