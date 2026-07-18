local binary = require("lib.binary")
local diagnostic = require("lib.diagnostic")

local M = {}

local SIG_LOCAL = 0x04034B50
local SIG_CENTRAL = 0x02014B50
local SIG_DESCRIPTOR = 0x08074B50
local SIG_EOCD = 0x06054B50
local SIG_ZIP64_EOCD = 0x06064B50
local SIG_ZIP64_LOCATOR = 0x07064B50
local MAX_EOCD_COMMENT = 0xFFFF

local REQUIRED_LIMITS = {
  "max_archive_bytes",
  "max_entries",
  "max_entry_uncompressed_bytes",
  "max_total_uncompressed_bytes",
  "max_compression_ratio",
}

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function checked_end(offset, length, context)
  return binary.checked_add(offset, length, context)
end

local function immutable(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local proxy = {}
  local backing = {}
  seen[value] = proxy
  for key, child in pairs(value) do backing[key] = immutable(child, seen) end
  return setmetatable(proxy, {
    __index = backing,
    __len = function() return #backing end,
    __pairs = function() return next, backing, nil end,
    __newindex = function()
      error("immutable ZIP metadata cannot be changed", 2)
    end,
    __metatable = false,
  })
end

local function validate_limits(limits)
  if type(limits) ~= "table" then
    raise("zip.invalid-limits", "ZIP limits object is required", {})
  end
  for _, name in ipairs(REQUIRED_LIMITS) do
    local value = limits[name]
    if math.type(value) ~= "integer" or value < 0 then
      raise("zip.invalid-limits", "ZIP limit must be a non-negative integer", {
        limit_name = name,
        value = value,
      })
    end
  end
end

local function read_file_bounded(path, max_archive_bytes)
  local handle, err = io.open(path, "rb")
  if not handle then raise("zip.open-failed", tostring(err), { path = path }) end
  local size, seek_err = handle:seek("end")
  if not size then
    handle:close()
    raise("zip.open-failed", tostring(seek_err), { path = path })
  end
  if size > max_archive_bytes then
    handle:close()
    raise("zip.archive-size-limit", "compressed archive size limit exceeded", {
      path = path,
      actual = size,
      limit = max_archive_bytes,
    })
  end
  local position, rewind_err = handle:seek("set", 0)
  if not position then
    handle:close()
    raise("zip.open-failed", tostring(rewind_err), { path = path })
  end
  if size == math.maxinteger then
    handle:close()
    checked_end(size, 1, {
      path = path,
      record = "archive-read",
    })
  end
  local read_limit = checked_end(size, 1, {
    path = path,
    record = "archive-read",
  })
  local bytes, read_err = handle:read(read_limit)
  handle:close()
  if bytes == nil and read_err == nil then bytes = "" end
  if bytes == nil then
    raise("zip.open-failed", tostring(read_err), { path = path })
  end
  if #bytes ~= size then
    raise("zip.file-changed", "archive size changed during preflight", {
      path = path,
      before = size,
      after = #bytes,
    })
  end
  return bytes, size
end

local function find_eocd(bytes)
  if #bytes < 22 then
    raise("zip.eocd-not-found", "archive is too short for EOCD", {
      archive_size = #bytes,
    })
  end
  local first = math.max(0, #bytes - 22 - MAX_EOCD_COMMENT)
  for offset = #bytes - 22, first, -1 do
    if binary.u32le(bytes, offset) == SIG_EOCD then
      local comment_length = binary.u16le(bytes, offset + 20, { record = "EOCD" })
      if checked_end(offset + 22, comment_length, { record = "EOCD" }) == #bytes then
        return offset, comment_length
      end
    end
  end
  raise("zip.eocd-not-found", "valid EOCD record not found", {
    archive_size = #bytes,
  })
end

local function decode_name(name, flags, context)
  if name == "" then raise("zip.invalid-name", "empty ZIP entry name", context) end
  local valid_utf8 = utf8.len(name) ~= nil
  if (flags & 0x0800) ~= 0 then
    if not valid_utf8 then
      raise("zip.invalid-name-encoding", "UTF-8 ZIP entry name is malformed", context)
    end
  elseif not name:match("^[\001-\127]*$") then
    raise("zip.invalid-name-encoding",
      "non-UTF-8 ZIP entry names must be ASCII in the spike", context)
  end
  return name
end

local function ascii_lower(value)
  return (value:gsub("[A-Z]", function(char)
    return string.char(char:byte() + 32)
  end))
end

local function is_ascii_unreserved(octet)
  return (octet >= 0x41 and octet <= 0x5A) or
    (octet >= 0x61 and octet <= 0x7A) or
    (octet >= 0x30 and octet <= 0x39) or
    octet == 0x2D or octet == 0x2E or octet == 0x5F or octet == 0x7E
end

local function validate_entry_name(name, context)
  if name:find("\0", 1, true) or name:find("\\", 1, true) or
      name:sub(1, 1) == "/" or name:match("^[A-Za-z]:") then
    raise("zip.invalid-name", "unsafe ZIP entry name", context)
  end
  if name == "[Content_Types].xml" then return end
  if name:find("?", 1, true) or name:find("#", 1, true) then
    raise("zip.invalid-name", "OPC part name contains query or fragment", context)
  end
  local count = 0
  for segment in (name .. "/"):gmatch("(.-)/") do
    count = count + 1
    if segment == "" or segment == "." or segment == ".." or
        segment:sub(-1) == "." then
      raise("zip.invalid-name", "OPC part name contains an unsafe segment", context)
    end
    local cursor = 1
    while true do
      local percent = segment:find("%", cursor, true)
      if not percent then break end
      local encoded = segment:sub(percent + 1, percent + 2)
      if #encoded ~= 2 or not encoded:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
        raise("zip.invalid-name", "OPC part name has malformed percent encoding", context)
      end
      local octet = tonumber(encoded, 16)
      if octet == 0 or octet == 0x2F or octet == 0x5C or
          octet < 0x20 or octet == 0x7F or is_ascii_unreserved(octet) then
        raise("zip.invalid-name", "OPC part name encodes a forbidden octet", context)
      end
      cursor = percent + 3
    end
  end
  if count == 0 then raise("zip.invalid-name", "empty OPC part name", context) end
end

local function parse_eocd(bytes, offset, comment_length)
  local eocd = {
    start = offset,
    finish = offset + 22 + comment_length,
    disk_number = binary.u16le(bytes, offset + 4, { record = "EOCD" }),
    central_disk = binary.u16le(bytes, offset + 6, { record = "EOCD" }),
    entries_on_disk = binary.u16le(bytes, offset + 8, { record = "EOCD" }),
    total_entries = binary.u16le(bytes, offset + 10, { record = "EOCD" }),
    central_size = binary.u32le(bytes, offset + 12, { record = "EOCD" }),
    central_offset = binary.u32le(bytes, offset + 16, { record = "EOCD" }),
    comment = binary.slice(bytes, offset + 22, comment_length, { record = "EOCD" }),
  }
  if eocd.disk_number ~= 0 or eocd.central_disk ~= 0 or
      (eocd.entries_on_disk ~= 0xFFFF and eocd.total_entries ~= 0xFFFF and
        eocd.entries_on_disk ~= eocd.total_entries) then
    raise("zip.multi-disk", "multi-disk ZIP archives are unsupported", {
      disk_number = eocd.disk_number,
      central_disk = eocd.central_disk,
      entries_on_disk = eocd.entries_on_disk,
      total_entries = eocd.total_entries,
    })
  end
  eocd.requires_zip64 = eocd.entries_on_disk == 0xFFFF or
    eocd.total_entries == 0xFFFF or eocd.central_size == 0xFFFFFFFF or
    eocd.central_offset == 0xFFFFFFFF
  return eocd
end

local function agree_with_classic(name, classic, sentinel, zip64)
  if classic ~= sentinel and classic ~= zip64 then
    raise("zip.zip64-classic-mismatch", "ZIP64 and classic EOCD values disagree", {
      field = name,
      classic = classic,
      zip64 = zip64,
    })
  end
end

local function parse_zip64(bytes, eocd)
  local locator_start = eocd.start - 20
  if locator_start < 0 or binary.u32le(bytes, locator_start, {
      record = "ZIP64-locator",
    }) ~= SIG_ZIP64_LOCATOR then
    raise("zip.zip64-locator-missing",
      "ZIP64 EOCD locator must immediately precede EOCD", {
        eocd_start = eocd.start,
      })
  end
  local locator_context = { record = "ZIP64-locator", offset = locator_start }
  local locator_disk = binary.u32le(bytes, locator_start + 4, locator_context)
  local record_offset = binary.u64le(bytes, locator_start + 8, locator_context)
  local total_disks = binary.u32le(bytes, locator_start + 16, locator_context)
  if locator_disk ~= 0 or total_disks ~= 1 then
    raise("zip.multi-disk", "multi-disk ZIP64 archives are unsupported", {
      locator_disk = locator_disk,
      total_disks = total_disks,
    })
  end

  local record_context = { record = "ZIP64-EOCD", offset = record_offset }
  if binary.u32le(bytes, record_offset, record_context) ~= SIG_ZIP64_EOCD then
    raise("zip.zip64-signature", "invalid ZIP64 EOCD signature", record_context)
  end
  local record_size = binary.u64le(bytes, record_offset + 4, record_context)
  if record_size < 44 then
    raise("zip.zip64-record-size", "ZIP64 EOCD record is too short", {
      record = "ZIP64-EOCD",
      offset = record_offset,
      size = record_size,
    })
  end
  local total_record_size = checked_end(12, record_size, record_context)
  local record_finish = checked_end(record_offset, total_record_size, record_context)
  if record_finish ~= locator_start then
    raise("zip.zip64-record-bounds",
      "ZIP64 EOCD must finish at its adjacent locator", {
        record_start = record_offset,
        record_finish = record_finish,
        locator_start = locator_start,
      })
  end

  local disk_number = binary.u32le(bytes, record_offset + 16, record_context)
  local central_disk = binary.u32le(bytes, record_offset + 20, record_context)
  local entries_on_disk = binary.u64le(bytes, record_offset + 24, record_context)
  local total_entries = binary.u64le(bytes, record_offset + 32, record_context)
  local central_size = binary.u64le(bytes, record_offset + 40, record_context)
  local central_offset = binary.u64le(bytes, record_offset + 48, record_context)
  if disk_number ~= 0 or central_disk ~= 0 or entries_on_disk ~= total_entries then
    raise("zip.multi-disk", "multi-disk ZIP64 archives are unsupported", {
      disk_number = disk_number,
      central_disk = central_disk,
      entries_on_disk = entries_on_disk,
      total_entries = total_entries,
    })
  end

  agree_with_classic("entries_on_disk", eocd.entries_on_disk, 0xFFFF,
    entries_on_disk)
  agree_with_classic("total_entries", eocd.total_entries, 0xFFFF,
    total_entries)
  agree_with_classic("central_size", eocd.central_size, 0xFFFFFFFF,
    central_size)
  agree_with_classic("central_offset", eocd.central_offset, 0xFFFFFFFF,
    central_offset)

  eocd.entries_on_disk = entries_on_disk
  eocd.total_entries = total_entries
  eocd.central_size = central_size
  eocd.central_offset = central_offset
  eocd.metadata_start = record_offset
  return {
    eocd = { start = record_offset, finish = record_finish },
    locator = { start = locator_start, finish = eocd.start },
  }
end

local function zip64_values(bytes, extra_offset, extra_length, needs, context)
  local cursor = extra_offset
  local extra_finish = checked_end(extra_offset, extra_length, context)
  while cursor < extra_finish do
    if extra_finish - cursor < 4 then
      raise("zip.extra-truncated", "ZIP extra-field header is truncated", context)
    end
    local field_id = binary.u16le(bytes, cursor, context)
    local field_size = binary.u16le(bytes, cursor + 2, context)
    local field_start = cursor + 4
    local field_finish = checked_end(field_start, field_size, context)
    if field_finish > extra_finish then
      raise("zip.extra-truncated", "ZIP extra field exceeds its record", context)
    end
    if field_id == 0x0001 then
      local value_cursor = field_start
      local values = {}
      local function take_u64(name)
        if not needs[name] then return end
        if value_cursor + 8 > field_finish then
          raise("zip.zip64-extra-truncated", "ZIP64 extra field is incomplete", context)
        end
        values[name] = binary.u64le(bytes, value_cursor, {
          record = context.record,
          entry = context.entry,
          offset = value_cursor,
          field = name,
        })
        value_cursor = value_cursor + 8
      end
      take_u64("uncompressed_size")
      take_u64("compressed_size")
      take_u64("local_header_offset")
      if needs.disk_start then
        if value_cursor + 4 > field_finish then
          raise("zip.zip64-extra-truncated", "ZIP64 extra field is incomplete", context)
        end
        values.disk_start = binary.u32le(bytes, value_cursor, {
          record = context.record,
          entry = context.entry,
          offset = value_cursor,
          field = "disk_start",
        })
        value_cursor = value_cursor + 4
      end
      return values
    end
    cursor = field_finish
  end
  raise("zip.zip64-extra-missing", "required ZIP64 extra field is missing", context)
end

local function parse_central_entries(bytes, eocd, limits)
  if eocd.total_entries > limits.max_entries then
    raise("zip.entry-count-limit", "ZIP entry-count limit exceeded", {
      actual = eocd.total_entries,
      limit = limits.max_entries,
    })
  end
  local central_finish = checked_end(eocd.central_offset, eocd.central_size, {
    record = "central-directory",
  })
  local metadata_start = eocd.metadata_start or eocd.start
  if central_finish > metadata_start then
    raise("zip.central-bounds", "central directory overlaps archive metadata", {
      start = eocd.central_offset,
      finish = central_finish,
      metadata_start = metadata_start,
    })
  end

  local entries = {}
  local exact_names = {}
  local folded_names = {}
  local local_offsets = {}
  local total_uncompressed = 0
  local offset = eocd.central_offset
  for index = 1, eocd.total_entries do
    local context = { record = "central-directory", entry_index = index, offset = offset }
    if binary.u32le(bytes, offset, context) ~= SIG_CENTRAL then
      raise("zip.central-signature", "invalid central-directory signature", context)
    end
    local flags = binary.u16le(bytes, offset + 8, context)
    local method = binary.u16le(bytes, offset + 10, context)
    local name_length = binary.u16le(bytes, offset + 28, context)
    local extra_length = binary.u16le(bytes, offset + 30, context)
    local comment_length = binary.u16le(bytes, offset + 32, context)
    local record_length = 46 + name_length + extra_length + comment_length
    local record_finish = checked_end(offset, record_length, context)
    if record_finish > central_finish then
      raise("zip.central-bounds", "central entry exceeds directory bounds", context)
    end
    local raw_name = binary.slice(bytes, offset + 46, name_length, context)
    context.entry = raw_name
    local name = decode_name(raw_name, flags, context)
    validate_entry_name(name, context)

    if exact_names[name] then
      raise("zip.duplicate-name", "duplicate ZIP entry name", { entry = name })
    end
    local folded = ascii_lower(name)
    if folded_names[folded] then
      raise("zip.case-collision", "ASCII case-colliding OPC part names", {
        entry = name,
        other = folded_names[folded],
      })
    end
    exact_names[name] = true
    folded_names[folded] = name

    local compressed_size = binary.u32le(bytes, offset + 20, context)
    local uncompressed_size = binary.u32le(bytes, offset + 24, context)
    local disk_start = binary.u16le(bytes, offset + 34, context)
    local local_offset = binary.u32le(bytes, offset + 42, context)
    local zip64_needs = {
      uncompressed_size = uncompressed_size == 0xFFFFFFFF,
      compressed_size = compressed_size == 0xFFFFFFFF,
      local_header_offset = local_offset == 0xFFFFFFFF,
      disk_start = disk_start == 0xFFFF,
    }
    local uses_zip64 = zip64_needs.uncompressed_size or
      zip64_needs.compressed_size or zip64_needs.local_header_offset or
      zip64_needs.disk_start
    local uses_zip64_sizes = zip64_needs.uncompressed_size or
      zip64_needs.compressed_size
    if uses_zip64 then
      local values = zip64_values(bytes, offset + 46 + name_length,
        extra_length, zip64_needs, context)
      uncompressed_size = values.uncompressed_size or uncompressed_size
      compressed_size = values.compressed_size or compressed_size
      local_offset = values.local_header_offset or local_offset
      disk_start = values.disk_start or disk_start
    end
    if disk_start ~= 0 then
      raise("zip.multi-disk", "central entry starts on another disk", {
        entry = name,
        disk_start = disk_start,
      })
    end
    if local_offsets[local_offset] then
      raise("zip.duplicate-local-offset", "multiple entries share a local header", {
        entry = name,
        other = local_offsets[local_offset],
        offset = local_offset,
      })
    end
    local_offsets[local_offset] = name

    if method ~= 0 and method ~= 8 then
      raise("zip.unsupported-method", "unsupported ZIP compression method", {
        entry = name,
        method = method,
      })
    end
    if method == 0 and compressed_size ~= uncompressed_size then
      raise("zip.stored-size-mismatch",
        "stored ZIP entry sizes must be identical", {
          entry = name,
          compressed_size = compressed_size,
          uncompressed_size = uncompressed_size,
        })
    end
    if (flags & 0x0001) ~= 0 or (flags & 0x0040) ~= 0 or
        (flags & 0x2000) ~= 0 then
      raise("zip.encrypted-entry", "encrypted ZIP entry is unsupported", {
        entry = name,
        flags = flags,
      })
    end
    local external_attributes = binary.u32le(bytes, offset + 38, context)
    local unix_mode = external_attributes >> 16
    if (unix_mode & 0xF000) == 0xA000 then
      raise("zip.symlink-entry", "symlink ZIP entry is unsupported", { entry = name })
    end
    if uncompressed_size > limits.max_entry_uncompressed_bytes then
      raise("zip.entry-size-limit", "ZIP entry size limit exceeded", {
        entry = name,
        actual = uncompressed_size,
        limit = limits.max_entry_uncompressed_bytes,
      })
    end
    total_uncompressed = binary.checked_add(total_uncompressed, uncompressed_size, {
      entry = name,
      record = "declared-total",
    })
    if total_uncompressed > limits.max_total_uncompressed_bytes then
      raise("zip.total-size-limit", "ZIP total size limit exceeded", {
        entry = name,
        actual = total_uncompressed,
        limit = limits.max_total_uncompressed_bytes,
      })
    end
    local ratio = uncompressed_size / math.max(1, compressed_size)
    if ratio > limits.max_compression_ratio then
      raise("zip.compression-ratio-limit", "ZIP compression-ratio limit exceeded", {
        entry = name,
        actual = ratio,
        limit = limits.max_compression_ratio,
      })
    end

    entries[index] = {
      name = name,
      flags = flags,
      method = method,
      crc32 = binary.u32le(bytes, offset + 16, context),
      compressed_size = compressed_size,
      uncompressed_size = uncompressed_size,
      local_header_offset = local_offset,
      modification_time = binary.u16le(bytes, offset + 12, context),
      modification_date = binary.u16le(bytes, offset + 14, context),
      external_attributes = external_attributes,
      uses_zip64 = uses_zip64,
      uses_zip64_sizes = uses_zip64_sizes,
      central_span = { start = offset, finish = record_finish },
    }
    offset = record_finish
  end
  if offset ~= central_finish then
    raise("zip.central-size-mismatch", "central-directory size is inconsistent", {
      parsed_finish = offset,
      declared_finish = central_finish,
    })
  end
  return entries, {
    start = eocd.central_offset,
    finish = central_finish,
    declared_total_uncompressed = total_uncompressed,
  }
end

local function parse_descriptor(bytes, entry, offset, central_start)
  local context = { record = "data-descriptor", entry = entry.name, offset = offset }
  local has_signature = binary.u32le(bytes, offset, context) == SIG_DESCRIPTOR
  local cursor = offset + (has_signature and 4 or 0)
  local crc32 = binary.u32le(bytes, cursor, context)
  local compressed_size, uncompressed_size, finish
  if entry.uses_zip64_sizes then
    compressed_size = binary.u64le(bytes, cursor + 4, context)
    uncompressed_size = binary.u64le(bytes, cursor + 12, context)
    finish = cursor + 20
  else
    compressed_size = binary.u32le(bytes, cursor + 4, context)
    uncompressed_size = binary.u32le(bytes, cursor + 8, context)
    finish = cursor + 12
  end
  if finish > central_start then
    raise("zip.local-span-overlap-metadata", "data descriptor enters archive metadata", {
      entry = entry.name,
      finish = finish,
      central_start = central_start,
    })
  end
  if crc32 ~= entry.crc32 or compressed_size ~= entry.compressed_size or
      uncompressed_size ~= entry.uncompressed_size then
    raise("zip.descriptor-mismatch", "data descriptor disagrees with central directory", {
      entry = entry.name,
    })
  end
  return finish, finish - offset
end

local function parse_local_entries(bytes, entries, central_start)
  local spans = {}
  for _, entry in ipairs(entries) do
    local offset = entry.local_header_offset
    local context = { record = "local-header", entry = entry.name, offset = offset }
    if binary.u32le(bytes, offset, context) ~= SIG_LOCAL then
      raise("zip.local-signature", "invalid local-header signature", context)
    end
    local flags = binary.u16le(bytes, offset + 6, context)
    local method = binary.u16le(bytes, offset + 8, context)
    local crc32 = binary.u32le(bytes, offset + 14, context)
    local compressed_size = binary.u32le(bytes, offset + 18, context)
    local uncompressed_size = binary.u32le(bytes, offset + 22, context)
    local name_length = binary.u16le(bytes, offset + 26, context)
    local extra_length = binary.u16le(bytes, offset + 28, context)
    local name = binary.slice(bytes, offset + 30, name_length, context)
    if name ~= entry.name then
      raise("zip.local-name-mismatch", "central and local entry names disagree", {
        entry = entry.name,
        local_name = name,
        offset = offset,
      })
    end
    if flags ~= entry.flags or method ~= entry.method then
      raise("zip.local-header-mismatch", "central and local entry metadata disagree", {
        entry = entry.name,
      })
    end
    local has_descriptor = (flags & 0x0008) ~= 0
    if compressed_size == 0xFFFFFFFF or uncompressed_size == 0xFFFFFFFF then
      local values = zip64_values(bytes, offset + 30 + name_length,
        extra_length, {
          uncompressed_size = uncompressed_size == 0xFFFFFFFF,
          compressed_size = compressed_size == 0xFFFFFFFF,
        }, context)
      uncompressed_size = values.uncompressed_size or uncompressed_size
      compressed_size = values.compressed_size or compressed_size
    end
    if not has_descriptor and (crc32 ~= entry.crc32 or
        compressed_size ~= entry.compressed_size or
        uncompressed_size ~= entry.uncompressed_size) then
      raise("zip.local-size-mismatch", "local sizes disagree with central directory", {
        entry = entry.name,
      })
    end
    if has_descriptor and (crc32 ~= 0 or compressed_size ~= 0 or
        uncompressed_size ~= 0) and (crc32 ~= entry.crc32 or
        compressed_size ~= entry.compressed_size or
        uncompressed_size ~= entry.uncompressed_size) then
      raise("zip.local-size-mismatch", "local descriptor placeholders are inconsistent", {
        entry = entry.name,
      })
    end

    local data_offset = checked_end(offset, 30 + name_length + extra_length, context)
    local data_finish = checked_end(data_offset, entry.compressed_size, context)
    local finish = data_finish
    local descriptor_length = 0
    if has_descriptor then
      finish, descriptor_length = parse_descriptor(bytes, entry, data_finish, central_start)
    end
    if finish > central_start then
      raise("zip.local-span-overlap-metadata", "local entry enters archive metadata", {
        entry = entry.name,
        finish = finish,
        central_start = central_start,
      })
    end
    entry.data_offset = data_offset
    entry.descriptor_length = descriptor_length
    entry.local_span = { start = offset, finish = finish }
    spans[#spans + 1] = { start = offset, finish = finish, entry = entry.name }
  end

  table.sort(spans, function(left, right)
    if left.start == right.start then return left.finish < right.finish end
    return left.start < right.start
  end)
  for index = 2, #spans do
    local previous, current = spans[index - 1], spans[index]
    if current.start < previous.finish then
      raise("zip.local-span-overlap", "local entry spans overlap", {
        entry = current.entry,
        other = previous.entry,
        start = current.start,
        previous_finish = previous.finish,
      })
    end
  end
end

function M.open_path(path, limits, options)
  options = options or {}
  validate_limits(limits)
  local bytes, size = read_file_bounded(path, limits.max_archive_bytes)
  local eocd_offset, comment_length = find_eocd(bytes)
  local eocd = parse_eocd(bytes, eocd_offset, comment_length)
  local zip64
  local locator_start = eocd.start - 20
  local has_zip64_locator = locator_start >= 0 and
    binary.u32le(bytes, locator_start, {
      record = "ZIP64-locator",
      offset = locator_start,
    }) == SIG_ZIP64_LOCATOR
  if eocd.requires_zip64 or has_zip64_locator then
    zip64 = parse_zip64(bytes, eocd)
  end
  local entries, central = parse_central_entries(bytes, eocd, limits)
  parse_local_entries(bytes, entries, central.start)

  local result = {
    path = path,
    archive_size = size,
    entries = immutable(entries),
    central_directory = immutable(central),
    eocd = immutable({ start = eocd.start, finish = eocd.finish }),
    zip64 = immutable(zip64),
    comment = eocd.comment,
  }
  if options.backend_factory then
    result.backend = options.backend_factory(bytes, result)
  end
  return result
end

return M
