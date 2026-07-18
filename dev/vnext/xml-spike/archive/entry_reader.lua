local binary = require("lib.binary")
local diagnostic = require("lib.diagnostic")
local inflate = require("archive.inflate_limited")

local M = {}
local CHUNK_SIZE = 8192
local CRC32_MASK = 0xFFFFFFFF

local CRC32_TABLE = {}
for octet = 0, 255 do
  local value = octet
  for _ = 1, 8 do
    if (value & 1) == 1 then
      value = (value >> 1) ~ 0xEDB88320
    else
      value = value >> 1
    end
  end
  CRC32_TABLE[octet] = value & CRC32_MASK
end

local function crc32_update(crc, chunk)
  for index = 1, #chunk do
    local lookup = (crc ~ chunk:byte(index)) & 0xFF
    crc = ((crc >> 8) ~ CRC32_TABLE[lookup]) & CRC32_MASK
  end
  return crc
end

local function validate_remaining(name, value)
  if math.type(value) ~= "integer" or value < 0 then
    diagnostic.raise("zip.invalid-limits",
      "ZIP read budget must be a non-negative integer", {
        limit_name = name,
        value = value,
      })
  end
end

local function output_limit(entry, limit)
  diagnostic.raise("zip.output-limit",
    "declared entry output exceeds its remaining byte budget", {
      entry = entry.name,
      limit = limit,
      declared = entry.uncompressed_size,
      produced = 0,
    })
end

function M.read_entry(archive_bytes, entry, entry_remaining,
    package_remaining, emit)
  assert(type(archive_bytes) == "string", "validated archive bytes are required")
  assert(type(entry) == "table", "validated ZIP entry metadata is required")
  validate_remaining("entry_remaining", entry_remaining)
  validate_remaining("package_remaining", package_remaining)
  if emit ~= nil and type(emit) ~= "function" then
    diagnostic.raise("deflate.invalid-sink",
      "ZIP entry output sink must be a function", {})
  end
  if entry.method == 0 and
      entry.compressed_size ~= entry.uncompressed_size then
    diagnostic.raise("zip.stored-size-mismatch",
      "stored ZIP entry sizes must be identical at the read gate", {
        entry = entry.name,
        compressed_size = entry.compressed_size,
        uncompressed_size = entry.uncompressed_size,
      })
  end

  local limit = math.min(entry_remaining, package_remaining)
  if entry.uncompressed_size > limit then output_limit(entry, limit) end

  local compressed = binary.slice(archive_bytes, entry.data_offset,
    entry.compressed_size, {
      record = "entry-data",
      entry = entry.name,
    })
  local collected
  if not emit then collected = {} end
  local crc = CRC32_MASK
  local function sink(chunk)
    crc = crc32_update(crc, chunk)
    if emit then
      emit(chunk)
    else
      collected[#collected + 1] = chunk
    end
  end

  local produced = 0
  if entry.method == 0 then
    local offset = 0
    while offset < #compressed do
      local size = math.min(CHUNK_SIZE, #compressed - offset)
      local chunk = compressed:sub(offset + 1, offset + size)
      sink(chunk)
      produced = produced + size
      offset = offset + size
    end
  elseif entry.method == 8 then
    local _, inflated = inflate.inflate_raw(compressed, limit, sink)
    produced = inflated
  else
    diagnostic.raise("zip.unsupported-method",
      "unsupported ZIP compression method reached the read gate", {
        entry = entry.name,
        method = entry.method,
      })
  end

  if produced ~= entry.uncompressed_size then
    diagnostic.raise("zip.uncompressed-size-mismatch",
      "expanded entry length disagrees with the central directory", {
        entry = entry.name,
        declared = entry.uncompressed_size,
        actual = produced,
      })
  end
  local actual_crc32 = (~crc) & CRC32_MASK
  if actual_crc32 ~= entry.crc32 then
    diagnostic.raise("zip.crc32-mismatch",
      "expanded entry CRC-32 disagrees with the central directory", {
        entry = entry.name,
        declared = entry.crc32,
        actual = actual_crc32,
      })
  end

  local output = collected and table.concat(collected) or nil
  return output, {
    produced = produced,
    crc32 = actual_crc32,
    compression_method = entry.method,
    effective_limit = limit,
  }
end

return M
