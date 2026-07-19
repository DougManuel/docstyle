local diagnostic = require("lib.diagnostic")
local fixture = require("lib.fixture")
local inflate = require("archive.inflate_limited")
local reader = require("archive.entry_reader")
local preflight = require("archive.zip_preflight")
local libdeflate = require("archive.vendor.libdeflate.LibDeflate")

local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local archive_vectors = dofile(pandoc.path.join({
  runner_here, "fixtures", "archive", "vectors.lua",
}))

local function from_hex(value)
  assert(#value % 2 == 0, "hexadecimal vector must contain complete octets")
  return (value:gsub("..", function(octet)
    return string.char(assert(tonumber(octet, 16)))
  end))
end

local VECTORS = {
  {
    name = "stored",
    compressed = from_hex(
      "011400ebff73746f72656420626c6f636b207061796c6f6164"),
    expected = "stored block payload",
    crc32 = 1527857339,
  },
  {
    name = "fixed",
    compressed = from_hex(
      "4bcbac484d51f0284d4bcb4dcc532848acccc94f4cb152484c4a363432a63f0900"),
    expected = "fixed Huffman payload: " .. string.rep("abc123", 20),
    crc32 = 1755841558,
  },
  {
    name = "dynamic",
    compressed = from_hex(
      "edc9c10d80201045c156b60e2bb08daf8092ec02897aa07bedc3779b64d26c8a" ..
      "badbfa94126a3634bd2b2d261fa76ccbb7ec50842c65ff9cc755bd379aa6699aa" ..
      "6699aa6699aa6699aa6699aa6ffd42f"),
    expected = "dynamic Huffman payload: " ..
      string.rep("alpha beta gamma delta epsilon ", 200),
    crc32 = 2309239847,
  },
}

local HIGH_RATIO_COMPRESSED = from_hex(
  "edc13101000000c2a06ceb5fcadb0e4001000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000000000000000000000000000000000000000" ..
  "0000000000000000000000000000bc01")

local function expect_code(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected diagnostic " .. code)
  assert(err.code == code,
    "expected diagnostic " .. code .. ", got " .. tostring(err.code))
  return err
end

local READ_LIMITS = {
  max_archive_bytes = 1024 * 1024,
  max_entries = 10,
  max_entry_uncompressed_bytes = 1024 * 1024,
  max_total_uncompressed_bytes = 2 * 1024 * 1024,
  max_compression_ratio = 1000,
}

local function with_preflight(bytes, fn)
  return fixture.with_temp_dir("inflate-read", function(dir)
    local path = pandoc.path.join({ dir, "fixture.docx" })
    fixture.write_bytes(path, bytes)
    local result = preflight.open_path(path, READ_LIMITS, {
      backend_factory = function(validated_bytes)
        return { bytes = validated_bytes }
      end,
    })
    return fn(result.backend.bytes, result.entries)
  end)
end

local cases = {}

local function add(name, gate, fn)
  cases[#cases + 1] = {
    name = name,
    gate = gate,
    stage = "archive",
    fn = fn,
  }
end

for _, vector in ipairs(VECTORS) do
  add(vector.name .. " block accepts its exact output limit", "archive", function()
    local output, produced = inflate.inflate_raw(
      vector.compressed, #vector.expected)
    assert(output == vector.expected)
    assert(produced == #vector.expected)
  end)

  add(vector.name .. " block accepts one byte of spare output budget",
    "archive", function()
      local output, produced = inflate.inflate_raw(
        vector.compressed, #vector.expected + 1)
      assert(output == vector.expected)
      assert(produced == #vector.expected)
    end)

  add(vector.name .. " block rejects a one-byte-short output limit",
    "safety", function()
      local emitted = 0
      local complete
      local err = expect_code("zip.output-limit", function()
        complete = inflate.inflate_raw(
          vector.compressed, #vector.expected - 1, function(chunk)
            emitted = emitted + #chunk
          end)
      end)
      assert(emitted <= #vector.expected - 1)
      assert(complete == nil)
      assert(err.context.limit == #vector.expected - 1)
      assert(err.context.produced == emitted)
    end)

  add(vector.name .. " block rejects a zero output limit", "safety", function()
    local emitted = 0
    local complete
    local err = expect_code("zip.output-limit", function()
      complete = inflate.inflate_raw(vector.compressed, 0, function(chunk)
        emitted = emitted + #chunk
      end)
    end)
    assert(emitted == 0)
    assert(complete == nil)
    assert(err.context.limit == 0)
    assert(err.context.produced == 0)
  end)
end

add("emitter receives only bounded chunks and exact produced count", "safety",
  function()
    local vector = VECTORS[3]
    local chunks = {}
    local output, produced = inflate.inflate_raw(
      vector.compressed, #vector.expected, function(chunk)
        assert(#chunk > 0 and #chunk <= 8192)
        chunks[#chunks + 1] = chunk
      end)
    assert(output == nil)
    assert(produced == #vector.expected)
    assert(table.concat(chunks) == vector.expected)
  end)

add("invalid block type has a stable diagnostic", "safety", function()
  expect_code("deflate.invalid-block-type", function()
    inflate.inflate_raw(from_hex("07"), 1024)
  end)
end)

add("malformed dynamic Huffman tree has a stable diagnostic", "safety",
  function()
    expect_code("deflate.invalid-huffman", function()
      inflate.inflate_raw(from_hex("05008000"), 1024)
    end)
  end)

add("impossible history distance has a stable diagnostic", "safety", function()
  expect_code("deflate.invalid-distance", function()
    inflate.inflate_raw(from_hex("0301"), 1024)
  end)
end)

add("truncated stream has a stable diagnostic", "safety", function()
  local fixed = VECTORS[2].compressed
  expect_code("deflate.truncated", function()
    inflate.inflate_raw(fixed:sub(1, -2), 1024)
  end)
end)

add("trailing bytes are rejected", "safety", function()
  expect_code("deflate.trailing-data", function()
    inflate.inflate_raw(VECTORS[1].compressed .. "\0", 1024)
  end)
end)

add("high-ratio stream stops before cap without retaining expanded output",
  "safety", function()
    local limit = 1024
    local emitted = 0
    collectgarbage("collect")
    local before_kib = collectgarbage("count")
    expect_code("zip.output-limit", function()
      inflate.inflate_raw(HIGH_RATIO_COMPRESSED, limit, function(chunk)
        emitted = emitted + #chunk
      end)
    end)
    collectgarbage("collect")
    local retained_bytes = math.max(0,
      (collectgarbage("count") - before_kib) * 1024)
    assert(emitted <= limit)
    assert(retained_bytes < limit + 2 * 1024 * 1024,
      "retained heap exceeds cap allowance: " .. tostring(retained_bytes))
  end)

add("circular history wraps beyond 32 KiB without collecting full output",
  "archive", function()
    local expected_length = 262144
    local observed = 0
    local output, produced = inflate.inflate_raw(
      HIGH_RATIO_COMPRESSED, expected_length, function(chunk)
        assert(#chunk <= 8192)
        assert(not chunk:find("[^A]"), "history output differs after ring wrap")
        observed = observed + #chunk
      end)
    assert(output == nil)
    assert(produced == expected_length)
    assert(observed == expected_length)
  end)

add("multi-block streams agree with the unmodified upstream compressor",
  "archive", function()
    local payload = string.rep(
      "multi-block payload 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\n", 2000)
    local configurations = {
      { level = 0 },
      { level = 6, strategy = "fixed" },
      { level = 6, strategy = "dynamic" },
    }
    for _, configuration in ipairs(configurations) do
      local compressed = libdeflate:CompressDeflate(payload, configuration)
      local cursor = 1
      local output, produced = inflate.inflate_raw(
        compressed, #payload, function(chunk)
          assert(chunk == payload:sub(cursor, cursor + #chunk - 1))
          cursor = cursor + #chunk
        end)
      assert(output == nil)
      assert(produced == #payload)
      assert(cursor == #payload + 1)
    end
  end)

add("pandoc zip contents materializes the full entry and exposes no byte cap",
  "archive", function()
    local vector = VECTORS[3]
    local bytes = archive_vectors.archive({
      {
        name = "word/document.xml",
        data = vector.expected,
        compressed = vector.compressed,
        method = 8,
        crc32 = vector.crc32,
      },
    })
    local archive = pandoc.zip.Archive(bytes)
    assert(#archive.entries == 1)
    local contents = archive.entries[1]:contents()
    assert(contents == vector.expected)
    local purportedly_capped = archive.entries[1]:contents(16)
    assert(#purportedly_capped == #vector.expected)
    assert(#purportedly_capped > 16)
    assert(purportedly_capped == vector.expected)
  end)

add("stored entry is sliced only after both output budgets permit it", "safety",
  function()
    local payload = "stored entry"
    local bytes = archive_vectors.archive({
      {
        name = "word/stored.xml",
        data = payload,
        crc32 = 2501814726,
      },
    })
    with_preflight(bytes, function(validated_bytes, entries)
      local output, evidence = reader.read_entry(
        validated_bytes, entries[1], #payload + 10, #payload)
      assert(output == payload)
      assert(evidence.produced == #payload)
      assert(evidence.crc32 == 2501814726)

      local err = expect_code("zip.output-limit", function()
        reader.read_entry(
          validated_bytes, entries[1], #payload, #payload - 1)
      end)
      assert(err.context.produced == 0)
      assert(err.context.limit == #payload - 1)
    end)
  end)

add("stored read reasserts size equality before slicing", "safety", function()
  expect_code("zip.stored-size-mismatch", function()
    reader.read_entry("x", {
      name = "word/stored.xml",
      method = 0,
      data_offset = 0,
      compressed_size = 1,
      uncompressed_size = 2,
      crc32 = 0,
    }, 2, 2)
  end)
end)

add("deflated entry uses validated offsets and verifies length and CRC", "safety",
  function()
    local vector = VECTORS[3]
    local bytes = archive_vectors.archive({
      {
        name = "word/document.xml",
        data = vector.expected,
        compressed = vector.compressed,
        method = 8,
        crc32 = vector.crc32,
      },
    })
    with_preflight(bytes, function(validated_bytes, entries)
      local chunks = {}
      local output, evidence = reader.read_entry(
        validated_bytes, entries[1], #vector.expected,
        #vector.expected + 100, function(chunk)
          chunks[#chunks + 1] = chunk
        end)
      assert(output == nil)
      assert(table.concat(chunks) == vector.expected)
      assert(evidence.produced == #vector.expected)
      assert(evidence.crc32 == vector.crc32)
      assert(evidence.compression_method == 8)
    end)
  end)

add("entry read rejects actual output length disagreement", "safety", function()
  local vector = VECTORS[2]
  local bytes = archive_vectors.archive({
    {
      name = "word/document.xml",
      data = vector.expected,
      compressed = vector.compressed,
      method = 8,
      crc32 = vector.crc32,
      declared_uncompressed_size = #vector.expected + 1,
    },
  })
  with_preflight(bytes, function(validated_bytes, entries)
    expect_code("zip.uncompressed-size-mismatch", function()
      reader.read_entry(validated_bytes, entries[1],
        #vector.expected + 1, #vector.expected + 1)
    end)
  end)
end)

add("entry read rejects CRC disagreement", "safety", function()
  local vector = VECTORS[2]
  local bytes = archive_vectors.archive({
    {
      name = "word/document.xml",
      data = vector.expected,
      compressed = vector.compressed,
      method = 8,
      crc32 = 0,
    },
  })
  with_preflight(bytes, function(validated_bytes, entries)
    expect_code("zip.crc32-mismatch", function()
      reader.read_entry(validated_bytes, entries[1],
        #vector.expected, #vector.expected)
    end)
  end)
end)

return cases
