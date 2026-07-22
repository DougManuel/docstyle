-- Spike-only bounded OPC package seam. Task 8 adds atomic publication.
local diagnostic = require("lib.diagnostic")
local entry_reader = require("archive.entry_reader")
local zip_preflight = require("archive.zip_preflight")
local xml_adapter = require("candidates.luaxml.adapter")

local M = {}

local REQUIRED_LIMITS = {
  "max_archive_bytes",
  "max_entries",
  "max_entry_uncompressed_bytes",
  "max_total_uncompressed_bytes",
  "max_compression_ratio",
  "max_materialized_bytes",
}

local Package = {}
Package.__index = Package

local CONTENT_TYPES_NS =
  "http://schemas.openxmlformats.org/package/2006/content-types"
local RELATIONSHIPS_NS =
  "http://schemas.openxmlformats.org/package/2006/relationships"
local OFFICE_DOCUMENT_TYPES = {
  ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"] = true,
  ["http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument"] = true,
}
local CORE_PROPERTIES_TYPE =
  "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function validate_limits(limits)
  if type(limits) ~= "table" then
    raise("opc.invalid-limits", "OPC limits object is required", {
      phase = "limits",
    })
  end
  for _, name in ipairs(REQUIRED_LIMITS) do
    local value = limits[name]
    if math.type(value) ~= "integer" or value < 0 then
      raise("opc.invalid-limits",
        "OPC limit must be a non-negative integer", {
          phase = "limits",
          limit_name = name,
          value = value,
        })
    end
  end
end

local function copy_limits(limits)
  local copied = {}
  for _, name in ipairs(REQUIRED_LIMITS) do copied[name] = limits[name] end
  return copied
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

local function is_ascii_pchar(octet)
  return is_ascii_unreserved(octet) or
    octet == 0x21 or octet == 0x24 or octet == 0x26 or octet == 0x27 or
    octet == 0x28 or octet == 0x29 or octet == 0x2A or octet == 0x2B or
    octet == 0x2C or octet == 0x3B or octet == 0x3D or octet == 0x3A or
    octet == 0x40
end

local function normalize_percent_hex(value)
  return (value:gsub("%%([0-9A-Fa-f][0-9A-Fa-f])", function(encoded)
    return "%" .. encoded:upper()
  end))
end

local function zip_name_for_part(part_name)
  if type(part_name) ~= "string" or part_name:sub(1, 1) ~= "/" or
      part_name:sub(2, 2) == "/" or #part_name < 2 then
    raise("opc.invalid-part-name",
      "OPC part name must have exactly one leading slash", {
        part_name = part_name,
      })
  end
  local zip_name = part_name:sub(2)
  if zip_name == "[Content_Types].xml" or
      zip_name:find("\\", 1, true) or zip_name:find("\0", 1, true) or
      zip_name:find("?", 1, true) or zip_name:find("#", 1, true) or
      utf8.len(zip_name) == nil then
    raise("opc.invalid-part-name", "invalid OPC part name", {
      part_name = part_name,
    })
  end
  for segment in (zip_name .. "/"):gmatch("(.-)/") do
    if segment == "" or segment == "." or segment == ".." or
        segment:sub(-1) == "." then
      raise("opc.invalid-part-name", "invalid OPC part-name segment", {
        part_name = part_name,
      })
    end
    local cursor = 1
    while cursor <= #segment do
      local octet = segment:byte(cursor)
      if octet == 0x25 then
        local encoded = segment:sub(cursor + 1, cursor + 2)
        if #encoded ~= 2 or
            not encoded:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
          raise("opc.invalid-part-name",
            "OPC part name has malformed percent encoding", {
              part_name = part_name,
            })
        end
        local decoded = tonumber(encoded, 16)
        if decoded == 0 or decoded == 0x2F or decoded == 0x5C or
            decoded < 0x20 or decoded == 0x7F or
            is_ascii_unreserved(decoded) then
          raise("opc.invalid-part-name",
            "OPC part name encodes a forbidden octet", {
              part_name = part_name,
            })
        end
        cursor = cursor + 3
      else
        if octet == 0 or octet < 0x20 or octet == 0x7F or
            (octet < 0x80 and not is_ascii_pchar(octet)) then
          raise("opc.invalid-part-name",
            "OPC part name contains a forbidden byte", {
              part_name = part_name,
            })
        end
        cursor = cursor + 1
      end
    end
  end
  return zip_name
end

local function require_entry(self, part_name)
  local zip_name = zip_name_for_part(part_name)
  local entry = self._entries_by_name[zip_name]
  if not entry then
    raise("opc.part-not-found", "OPC part was not found", {
      part_name = part_name,
      zip_name = zip_name,
    })
  end
  return zip_name, entry
end

local function attribute(node, name)
  return xml_adapter.get_attribute(node, "", name)
end

local function require_attribute(node, name, context)
  local value = attribute(node, name)
  if type(value) ~= "string" or value == "" then
    raise("opc.relationship-attribute",
      "relationship attribute is required", {
        relationship_part = context,
        attribute = name,
      })
  end
  return value
end

local function assert_root(document, namespace_uri, local_name, code, name)
  local root = document.root
  if not root or root.name.uri ~= namespace_uri or
      root.name.local_name ~= local_name then
    raise(code, name .. " has an invalid document element", {
      expected_namespace = namespace_uri,
      expected_local_name = local_name,
      actual_namespace = root and root.name.uri or nil,
      actual_local_name = root and root.name.local_name or nil,
    })
  end
end

function Package:_read_zip_entry(zip_name, missing_code)
  local entry = self._entries_by_name[zip_name]
  if not entry then
    raise(missing_code or "opc.part-not-found",
      "required package item was not found", {
        zip_name = zip_name,
      })
  end
  if self._cache[zip_name] ~= nil then
    return self._cache[zip_name]
  end
  local bytes, evidence = entry_reader.read_entry(
    self._archive_bytes,
    entry,
    self._limits.max_entry_uncompressed_bytes,
    self._materialization_remaining)
  self._cache[zip_name] = bytes
  self._materialization_remaining =
    self._materialization_remaining - evidence.produced
  evidence.cache_charge_count = 1
  evidence.zip_name = zip_name
  self._evidence[zip_name] = evidence
  return bytes
end

function Package:part(part_name)
  local zip_name = require_entry(self, part_name)
  if self._replacements[zip_name] ~= nil then
    return self._replacements[zip_name]
  end
  local bytes = self:_read_zip_entry(zip_name)
  local evidence = self._evidence[zip_name]
  evidence.part_name = part_name
  return bytes
end

function Package:part_evidence(part_name)
  local zip_name = zip_name_for_part(part_name)
  return self._evidence[zip_name]
end

function Package:remaining_materialization_bytes()
  return self._materialization_remaining
end

function Package:replace_part(part_name, bytes)
  local zip_name = require_entry(self, part_name)
  if type(bytes) ~= "string" then
    raise("opc.invalid-replacement", "replacement part must be byte string", {
      part_name = part_name,
    })
  end
  self._replacements[zip_name] = bytes
end

local function parse_content_types(self)
  local bytes = self:_read_zip_entry(
    "[Content_Types].xml", "opc.content-types-missing")
  local document = xml_adapter.parse(bytes)
  assert_root(document, CONTENT_TYPES_NS, "Types",
    "opc.content-types-root", "content-types stream")

  local defaults = {}
  for _, node in ipairs(xml_adapter.find_all(
      document, CONTENT_TYPES_NS, "Default")) do
    if node.parent_id ~= document.root.id then
      raise("opc.content-types-structure",
        "content-type declaration must be a child of Types", {})
    end
    local extension = attribute(node, "Extension")
    local content_type = attribute(node, "ContentType")
    if type(extension) ~= "string" or extension == "" or
        extension:find("/", 1, true) or extension:sub(1, 1) == "." or
        type(content_type) ~= "string" or content_type == "" then
      raise("opc.content-types-entry",
        "invalid default content-type declaration", {})
    end
    local key = ascii_lower(extension)
    if defaults[key] then
      raise("opc.content-types-duplicate",
        "duplicate default content-type declaration", {
          extension = extension,
        })
    end
    defaults[key] = content_type
  end

  local overrides = {}
  local folded_overrides = {}
  for _, node in ipairs(xml_adapter.find_all(
      document, CONTENT_TYPES_NS, "Override")) do
    if node.parent_id ~= document.root.id then
      raise("opc.content-types-structure",
        "content-type declaration must be a child of Types", {})
    end
    local part_name = attribute(node, "PartName")
    local content_type = attribute(node, "ContentType")
    if type(content_type) ~= "string" or content_type == "" then
      raise("opc.content-types-entry",
        "invalid override content-type declaration", {})
    end
    local zip_name = zip_name_for_part(part_name)
    local normalized_name = normalize_percent_hex(zip_name)
    local folded = ascii_lower(normalized_name)
    if overrides[normalized_name] or folded_overrides[folded] then
      raise("opc.content-types-duplicate",
        "duplicate override content-type declaration", {
          part_name = part_name,
        })
    end
    overrides[normalized_name] = content_type
    folded_overrides[folded] = true
  end
  self._content_type_defaults = defaults
  self._content_type_overrides = overrides
end

function Package:content_type(part_name)
  local zip_name = require_entry(self, part_name)
  local override = self._content_type_overrides[
    normalize_percent_hex(zip_name)]
  if override then return override end
  local extension = zip_name:match("%.([^./]+)$")
  if not extension then return nil end
  return self._content_type_defaults[ascii_lower(extension)]
end

local function relationship_zip_name(source_part)
  if source_part == "/" then return "_rels/.rels" end
  local source_zip = zip_name_for_part(source_part)
  local directory, filename = source_zip:match("^(.-)([^/]+)$")
  return directory .. "_rels/" .. filename .. ".rels"
end

local function normalize_target_segment(segment, context)
  local parts = {}
  local cursor = 1
  local encoded_dot = false
  while cursor <= #segment do
    local octet = segment:byte(cursor)
    if octet == 0x25 then
      local encoded = segment:sub(cursor + 1, cursor + 2)
      if #encoded ~= 2 or not encoded:match("^[0-9A-Fa-f][0-9A-Fa-f]$") then
        raise("opc.malformed-percent-encoding",
          "relationship target has malformed percent encoding", context)
      end
      local decoded = tonumber(encoded, 16)
      if decoded == 0x2F or decoded == 0x5C then
        raise("opc.encoded-separator",
          "relationship target encodes a path separator", context)
      end
      if decoded == 0 or decoded < 0x20 or decoded == 0x7F then
        raise("opc.encoded-control",
          "relationship target encodes a control byte", context)
      end
      if is_ascii_unreserved(decoded) then
        parts[#parts + 1] = string.char(decoded)
        if decoded == 0x2E then encoded_dot = true end
      else
        parts[#parts + 1] = ("%%%02X"):format(decoded)
      end
      cursor = cursor + 3
    else
      if octet == 0 or octet < 0x20 or octet == 0x7F or octet == 0x5C or
          (octet < 0x80 and not is_ascii_pchar(octet)) then
        raise("opc.invalid-relationship-target",
          "relationship target contains a forbidden byte", context)
      end
      parts[#parts + 1] = string.char(octet)
      cursor = cursor + 1
    end
  end
  local normalized = table.concat(parts)
  if encoded_dot and (normalized == "." or normalized == "..") then
    raise("opc.encoded-dot-segment",
      "relationship target encodes a dot segment", context)
  end
  return normalized
end

local function resolve_literal_target(self, source_part, target, context)
  local path, fragment = target:match("^([^#]*)#(.*)$")
  if not path then path = target end
  if path == "" then
    if source_part == "/" or fragment == nil then
      raise("opc.invalid-relationship-target",
        "internal relationship target does not identify a part", context)
    end
    return source_part, fragment, ""
  end
  local first_segment = path:match("^([^/]*)")
  if path:sub(1, 1) == "/" or
      path:find("?", 1, true) or path:find("\\", 1, true) or
      path:match("^[A-Za-z][A-Za-z0-9+%.%-]*:") or
      path:sub(1, 2) == "//" or utf8.len(path) == nil or
      (first_segment ~= "." and first_segment ~= ".." and
        first_segment:find(":", 1, true)) then
    raise("opc.invalid-relationship-target",
      "internal relationship target is outside the spike subset", context)
  end
  local base = {}
  if source_part ~= "/" then
    local source_zip = zip_name_for_part(source_part)
    for segment in source_zip:gmatch("[^/]+") do base[#base + 1] = segment end
    base[#base] = nil
  end
  local normalized_segments = {}
  for segment in (path .. "/"):gmatch("(.-)/") do
    local normalized = normalize_target_segment(segment, context)
    normalized_segments[#normalized_segments + 1] = normalized
    if normalized == "" or normalized == "." then
      if normalized == "" then
        raise("opc.invalid-relationship-target",
          "relationship target contains an empty segment", context)
      end
    elseif normalized == ".." then
      if #base == 0 then
        raise("opc.relationship-target-escape",
          "relationship target escapes the package", context)
      end
      base[#base] = nil
    else
      base[#base + 1] = normalized
    end
  end
  if #base == 0 then
    raise("opc.invalid-relationship-target",
      "relationship target does not identify a part", context)
  end
  local resolved = "/" .. table.concat(base, "/")
  local zip_name = zip_name_for_part(resolved)
  local entry = self._entries_by_normalized_name[
    normalize_percent_hex(zip_name)]
  if not entry then
    raise("opc.relationship-target-missing",
      "internal relationship target was not found", {
        relationship_part = context.relationship_part,
        relationship_id = context.relationship_id,
        target = target,
        resolved_part = resolved,
      })
  end
  return "/" .. entry.name, fragment,
    table.concat(normalized_segments, "/")
end

function Package:relationships(source_part)
  if source_part ~= "/" then require_entry(self, source_part) end
  local relationship_zip = relationship_zip_name(source_part)
  if self._relationship_cache[relationship_zip] then
    return self._relationship_cache[relationship_zip]
  end
  local entry = self._entries_by_name[relationship_zip]
  if not entry then
    if source_part == "/" then
      raise("opc.relationships-missing",
        "package-root relationships are required", {
          zip_name = relationship_zip,
        })
    end
    self._relationship_cache[relationship_zip] = {}
    return self._relationship_cache[relationship_zip]
  end
  local document = xml_adapter.parse(self:_read_zip_entry(relationship_zip))
  assert_root(document, RELATIONSHIPS_NS, "Relationships",
    "opc.relationships-root", "relationships part")
  local records, ids = {}, {}
  for _, node in ipairs(xml_adapter.find_all(
      document, RELATIONSHIPS_NS, "Relationship")) do
    if node.parent_id ~= document.root.id then
      raise("opc.relationships-structure",
        "Relationship must be a child of Relationships", {
          relationship_part = relationship_zip,
        })
    end
    local id = require_attribute(node, "Id", relationship_zip)
    if ids[id] then
      raise("opc.duplicate-relationship-id",
        "relationship IDs must be unique within a part", {
          relationship_part = relationship_zip,
          relationship_id = id,
        })
    end
    ids[id] = true
    local relationship_type = require_attribute(node, "Type", relationship_zip)
    local target = require_attribute(node, "Target", relationship_zip)
    local mode = attribute(node, "TargetMode")
    if mode ~= nil and mode ~= "External" then
      raise("opc.invalid-target-mode",
        "TargetMode must be External when present", {
          relationship_part = relationship_zip,
          relationship_id = id,
          target_mode = mode,
        })
    end
    local record = {
      id = id,
      type = relationship_type,
      target = target,
      target_mode = mode or "Internal",
      external = mode == "External",
    }
    if not record.external then
      record.resolved_part, record.fragment, record.normalized_target =
        resolve_literal_target(
        self, source_part, target, {
          relationship_part = relationship_zip,
          relationship_id = id,
        })
    end
    records[#records + 1] = record
  end
  self._relationship_cache[relationship_zip] = records
  return records
end

local function initialize_package(self)
  parse_content_types(self)
  local relationships = self:relationships("/")
  local office
  for _, relationship in ipairs(relationships) do
    if OFFICE_DOCUMENT_TYPES[relationship.type] then
      if relationship.external then
        raise("opc.office-document-root",
          "office-document relationship must be internal", {
            relationship_id = relationship.id,
          })
      end
      if office then
        raise("opc.ambiguous-office-document",
          "package has more than one office-document root", {})
      end
      office = relationship.resolved_part
    elseif relationship.type == CORE_PROPERTIES_TYPE and
        not relationship.external then
      if self.core_properties_part then
        raise("opc.ambiguous-core-properties",
          "package has more than one core-properties root", {})
      end
      self.core_properties_part = relationship.resolved_part
    end
  end
  if not office then
    raise("opc.office-document-root",
      "package must have one internal office-document root", {})
  end
  self.office_document_part = office
  if not self:content_type(office) then
    raise("opc.content-type-missing",
      "office-document root has no declared content type", {
        part_name = office,
      })
  end
  if self.core_properties_part and
      not self:content_type(self.core_properties_part) then
    raise("opc.content-type-missing",
      "core-properties root has no declared content type", {
        part_name = self.core_properties_part,
      })
  end
end

function M.open_path(path, limits)
  validate_limits(limits)
  limits = copy_limits(limits)
  local archive_bytes
  local validated = zip_preflight.open_path(path, limits, {
    backend_factory = function(bytes)
      archive_bytes = bytes
      return { kind = "docstyle-bounded-entry-reader" }
    end,
  })
  local entries_by_name = {}
  local entries_by_normalized_name = {}
  for _, entry in ipairs(validated.entries) do
    if entry.name ~= "[Content_Types].xml" then
      zip_name_for_part("/" .. entry.name)
    end
    entries_by_name[entry.name] = entry
    local normalized_name = normalize_percent_hex(entry.name)
    if entries_by_normalized_name[normalized_name] then
      raise("opc.duplicate-normalized-part-name",
        "package entries collide after percent-hex normalization", {
          entry = entry.name,
          other = entries_by_normalized_name[normalized_name].name,
        })
    end
    entries_by_normalized_name[normalized_name] = entry
  end
  local package = setmetatable({
    path = path,
    entries = validated.entries,
    archive = validated,
    _archive_bytes = assert(archive_bytes),
    _entries_by_name = entries_by_name,
    _entries_by_normalized_name = entries_by_normalized_name,
    _limits = limits,
    _materialization_remaining = limits.max_materialized_bytes,
    _cache = {},
    _evidence = {},
    _replacements = {},
    _relationship_cache = {},
  }, Package)
  initialize_package(package)
  return package
end

return M
