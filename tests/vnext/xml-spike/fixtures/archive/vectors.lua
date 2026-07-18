local M = {}

local function le16(value)
  return string.char(value & 0xFF, (value >> 8) & 0xFF)
end

local function le32(value)
  return string.char(
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF
  )
end

local function le64(value)
  local low = value & 0xFFFFFFFF
  local high = value >> 32
  return le32(low) .. le32(high)
end

local function zip64_extra(values)
  local body = table.concat(values)
  return le16(0x0001) .. le16(#body) .. body
end

local function descriptor(entry, compressed_size, uncompressed_size)
  if not entry.descriptor then return "" end
  local signature = entry.descriptor_signature == false and "" or le32(0x08074B50)
  local size_writer = entry.force_zip64 and le64 or le32
  return signature .. le32(entry.crc32 or 0) ..
    size_writer(entry.descriptor_compressed_size or compressed_size) ..
    size_writer(entry.descriptor_uncompressed_size or uncompressed_size)
end

function M.archive(entries, options)
  options = options or {}
  local local_parts = {}
  local records = {}
  local local_length = 0

  for index, source in ipairs(entries) do
    local entry = {}
    for key, value in pairs(source) do entry[key] = value end
    entry.name = assert(entry.name, "entry name is required")
    entry.local_name = entry.local_name or entry.name
    entry.data = entry.data or ""
    entry.compressed = entry.compressed or entry.data
    entry.method = entry.method or 0
    entry.flags = entry.flags or 0x0800
    if entry.descriptor then entry.flags = entry.flags | 0x0008 end
    entry.local_flags = entry.local_flags or entry.flags
    entry.declared_compressed_size =
      entry.declared_compressed_size or #entry.compressed
    entry.declared_uncompressed_size =
      entry.declared_uncompressed_size or #entry.data
    entry.local_compressed_size = entry.local_compressed_size
      or (entry.descriptor and 0 or entry.declared_compressed_size)
    entry.local_uncompressed_size = entry.local_uncompressed_size
      or (entry.descriptor and 0 or entry.declared_uncompressed_size)
    entry.local_crc32 = entry.local_crc32
      or (entry.descriptor and 0 or (entry.crc32 or 0))
    entry.local_extra = entry.local_extra or ""
    entry.central_extra = entry.central_extra or ""
    entry.comment = entry.comment or ""
    entry.local_offset = local_length

    if entry.force_zip64 and not entry.omit_local_zip64_extra then
      entry.local_extra = zip64_extra({
        le64(entry.declared_uncompressed_size),
        le64(entry.declared_compressed_size),
      }) .. entry.local_extra
    end
    if entry.force_zip64 and not entry.omit_central_zip64_extra then
      entry.central_extra = zip64_extra({
        le64(entry.declared_uncompressed_size),
        le64(entry.declared_compressed_size),
        le64(entry.local_offset),
      }) .. entry.central_extra
    end

    local local_header = table.concat({
      le32(0x04034B50),
      le16(entry.version_needed or (entry.force_zip64 and 45 or 20)),
      le16(entry.local_flags),
      le16(entry.local_method or entry.method),
      le16(entry.mod_time or 0),
      le16(entry.mod_date or 0),
      le32(entry.local_crc32),
      le32(entry.force_zip64 and 0xFFFFFFFF or entry.local_compressed_size),
      le32(entry.force_zip64 and 0xFFFFFFFF or entry.local_uncompressed_size),
      le16(#entry.local_name),
      le16(#entry.local_extra),
      entry.local_name,
      entry.local_extra,
    })
    local tail = entry.compressed .. descriptor(
      entry, entry.declared_compressed_size, entry.declared_uncompressed_size)
    local_parts[#local_parts + 1] = local_header .. tail
    local_length = local_length + #local_header + #tail
    records[index] = entry
  end

  local central_offset = local_length
  local central_parts = {}
  local central_length = 0
  for _, entry in ipairs(records) do
    local central_name = entry.central_name or entry.name
    local version_made = ((entry.made_by_os or 0) << 8) |
      (entry.made_by_version or 20)
    local header = table.concat({
      le32(0x02014B50),
      le16(version_made),
      le16(entry.version_needed or (entry.force_zip64 and 45 or 20)),
      le16(entry.flags),
      le16(entry.method),
      le16(entry.mod_time or 0),
      le16(entry.mod_date or 0),
      le32(entry.crc32 or 0),
      le32(entry.force_zip64 and 0xFFFFFFFF or entry.declared_compressed_size),
      le32(entry.force_zip64 and 0xFFFFFFFF or entry.declared_uncompressed_size),
      le16(#central_name),
      le16(#entry.central_extra),
      le16(#entry.comment),
      le16(entry.disk_start or 0),
      le16(entry.internal_attributes or 0),
      le32(entry.external_attributes or 0),
      le32(entry.force_zip64 and 0xFFFFFFFF or
        (entry.central_local_offset or entry.local_offset)),
      central_name,
      entry.central_extra,
      entry.comment,
    })
    central_parts[#central_parts + 1] = header
    central_length = central_length + #header
  end

  local comment = options.comment or ""
  local count = #records
  local zip64_eocd = ""
  local zip64_locator = ""
  local zip64_eocd_offset
  if options.zip64 then
    zip64_eocd_offset = central_offset + central_length
    zip64_eocd = table.concat({
      le32(0x06064B50),
      le64(44),
      le16(45),
      le16(45),
      le32(options.zip64_disk_number or 0),
      le32(options.zip64_central_disk or 0),
      le64(options.zip64_entries_on_disk or count),
      le64(options.zip64_total_entries or count),
      le64(options.zip64_central_size or central_length),
      le64(options.zip64_central_offset or central_offset),
    })
    zip64_locator = table.concat({
      le32(0x07064B50),
      le32(options.zip64_locator_disk or 0),
      le64(options.zip64_locator_offset or zip64_eocd_offset),
      le32(options.zip64_total_disks or 1),
    })
  end
  local eocd = table.concat({
    le32(0x06054B50),
    le16(options.disk_number or 0),
    le16(options.central_disk or 0),
    le16(options.entries_on_disk or (options.zip64 and 0xFFFF or count)),
    le16(options.total_entries or (options.zip64 and 0xFFFF or count)),
    le32(options.central_size or (options.zip64 and 0xFFFFFFFF or central_length)),
    le32(options.central_offset or (options.zip64 and 0xFFFFFFFF or central_offset)),
    le16(#comment),
    comment,
  })

  local bytes = table.concat(local_parts) .. table.concat(central_parts) ..
    zip64_eocd .. zip64_locator .. eocd
  return bytes, {
    records = records,
    central_offset = central_offset,
    central_size = central_length,
    zip64_eocd_offset = zip64_eocd_offset,
    zip64_locator_offset = zip64_eocd_offset and (zip64_eocd_offset + #zip64_eocd) or nil,
    eocd_offset = central_offset + central_length + #zip64_eocd + #zip64_locator,
  }
end

function M.patch(bytes, offset, replacement)
  return bytes:sub(1, offset) .. replacement .. bytes:sub(offset + #replacement + 1)
end

M.le16 = le16
M.le32 = le32
M.le64 = le64
M.zip64_extra = zip64_extra

return M
