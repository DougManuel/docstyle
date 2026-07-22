-- Candidate-local strictness layer. It does not import the oracle or SLAXML.
local common = require("candidates.common")
local diagnostic = require("lib.diagnostic")

local M = {}

local XML_NS = "http://www.w3.org/XML/1998/namespace"
local XMLNS_NS = "http://www.w3.org/2000/xmlns/"

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function is_xml_character(codepoint)
  return codepoint == 0x9 or codepoint == 0xa or codepoint == 0xd or
    (codepoint >= 0x20 and codepoint <= 0xd7ff) or
    (codepoint >= 0xe000 and codepoint <= 0xfffd) or
    (codepoint >= 0x10000 and codepoint <= 0x10ffff)
end

local function decode_utf8(bytes, first_byte)
  local records = {}
  local index = first_byte
  while index <= #bytes do
    local lead = bytes:byte(index)
    local width, codepoint, minimum
    if lead < 0x80 then
      width, codepoint, minimum = 1, lead, 0
    elseif lead >= 0xc2 and lead <= 0xdf then
      width, codepoint, minimum = 2, lead & 0x1f, 0x80
    elseif lead >= 0xe0 and lead <= 0xef then
      width, codepoint, minimum = 3, lead & 0x0f, 0x800
    elseif lead >= 0xf0 and lead <= 0xf4 then
      width, codepoint, minimum = 4, lead & 0x07, 0x10000
    else
      raise("xml.invalid-encoding", "invalid UTF-8 leading byte", {
        offset = index - 1,
      })
    end
    if index + width - 1 > #bytes then
      raise("xml.invalid-encoding", "truncated UTF-8 sequence", {
        offset = index - 1,
      })
    end
    for cursor = index + 1, index + width - 1 do
      local continuation = bytes:byte(cursor)
      if continuation < 0x80 or continuation > 0xbf then
        raise("xml.invalid-encoding", "invalid UTF-8 continuation byte", {
          offset = cursor - 1,
        })
      end
      codepoint = (codepoint << 6) | (continuation & 0x3f)
    end
    if codepoint < minimum or codepoint > 0x10ffff or
        (codepoint >= 0xd800 and codepoint <= 0xdfff) then
      raise("xml.invalid-encoding", "invalid UTF-8 scalar value", {
        offset = index - 1,
      })
    end
    if not is_xml_character(codepoint) then
      raise("xml.invalid-character", "character is forbidden by XML 1.0", {
        codepoint = codepoint,
        offset = index - 1,
      })
    end
    records[#records + 1] = {
      codepoint = codepoint,
      start = index - 1,
      finish = index + width - 1,
    }
    index = index + width
  end
  return records
end

local function u16(bytes, index, endian)
  local left, right = bytes:byte(index, index + 1)
  if not right then
    raise("xml.invalid-encoding", "truncated UTF-16 code unit", {
      offset = index - 1,
    })
  end
  if endian == "utf-16le" then return left | (right << 8) end
  return (left << 8) | right
end

local function decode_utf16(bytes, first_byte, endian)
  local records = {}
  local index = first_byte
  while index <= #bytes do
    local first = u16(bytes, index, endian)
    local codepoint, width
    if first >= 0xd800 and first <= 0xdbff then
      if index + 3 > #bytes then
        raise("xml.invalid-encoding", "UTF-16 high surrogate is unpaired", {
          offset = index - 1,
        })
      end
      local second = u16(bytes, index + 2, endian)
      if second < 0xdc00 or second > 0xdfff then
        raise("xml.invalid-encoding", "UTF-16 high surrogate is unpaired", {
          offset = index - 1,
        })
      end
      codepoint = 0x10000 + ((first - 0xd800) << 10) +
        (second - 0xdc00)
      width = 4
    elseif first >= 0xdc00 and first <= 0xdfff then
      raise("xml.invalid-encoding", "UTF-16 low surrogate is unpaired", {
        offset = index - 1,
      })
    else
      codepoint, width = first, 2
    end
    if not is_xml_character(codepoint) then
      raise("xml.invalid-character", "character is forbidden by XML 1.0", {
        codepoint = codepoint,
        offset = index - 1,
      })
    end
    records[#records + 1] = {
      codepoint = codepoint,
      start = index - 1,
      finish = index + width - 1,
    }
    index = index + width
  end
  return records
end

local function normalize_line_ends(records)
  local normalized = {}
  local index = 1
  while index <= #records do
    local record = records[index]
    if record.codepoint == 0xd then
      local next_record = records[index + 1]
      normalized[#normalized + 1] = {
        codepoint = 0xa,
        start = record.start,
        finish = next_record and next_record.codepoint == 0xa and
          next_record.finish or record.finish,
      }
      index = index + (next_record and next_record.codepoint == 0xa and 2 or 1)
    else
      normalized[#normalized + 1] = record
      index = index + 1
    end
  end
  return normalized
end

local function materialize(records, source_start)
  local pieces = {}
  local boundaries = { [0] = source_start }
  local decoded_offset = 0
  for _, record in ipairs(records) do
    local character = utf8.char(record.codepoint)
    pieces[#pieces + 1] = character
    boundaries[decoded_offset] = record.start
    for inside = 1, #character - 1 do
      boundaries[decoded_offset + inside] = record.start
    end
    decoded_offset = decoded_offset + #character
    boundaries[decoded_offset] = record.finish
  end
  return table.concat(pieces), boundaries
end

local function decode_document(bytes)
  local encoding, first_byte, bom
  if bytes:sub(1, 3) == "\239\187\191" then
    encoding, first_byte, bom = "utf-8", 4, true
  elseif bytes:sub(1, 2) == "\255\254" then
    encoding, first_byte, bom = "utf-16le", 3, true
  elseif bytes:sub(1, 2) == "\254\255" then
    encoding, first_byte, bom = "utf-16be", 3, true
  elseif bytes:sub(1, 2) == "\0<" then
    encoding, first_byte, bom = "utf-16be", 1, false
  elseif bytes:sub(1, 2) == "<\0" then
    encoding, first_byte, bom = "utf-16le", 1, false
  else
    encoding, first_byte, bom = "utf-8", 1, false
  end
  local records
  if encoding == "utf-8" then
    records = decode_utf8(bytes, first_byte)
  else
    records = decode_utf16(bytes, first_byte, encoding)
  end
  records = normalize_line_ends(records)
  local text, boundaries = materialize(records, first_byte - 1)
  return {
    text = text,
    boundaries = boundaries,
    encoding = encoding,
    bom = bom,
  }
end

local function source_range(decoded, start_at, finish_at)
  local start_offset = decoded.boundaries[start_at - 1]
  local finish_offset = decoded.boundaries[finish_at - 1]
  assert(start_offset ~= nil and finish_offset ~= nil,
    "decoded boundary lacks an original byte offset")
  return common.range(start_offset, finish_offset)
end

local function is_space(character)
  return character == " " or character == "\t" or character == "\n" or
    character == "\r"
end

local function skip_space(text, position)
  while position <= #text and is_space(text:sub(position, position)) do
    position = position + 1
  end
  return position
end

local function is_name_start(codepoint)
  return codepoint == 0x3a or codepoint == 0x5f or
    (codepoint >= 0x41 and codepoint <= 0x5a) or
    (codepoint >= 0x61 and codepoint <= 0x7a) or
    (codepoint >= 0xc0 and codepoint <= 0xd6) or
    (codepoint >= 0xd8 and codepoint <= 0xf6) or
    (codepoint >= 0xf8 and codepoint <= 0x2ff) or
    (codepoint >= 0x370 and codepoint <= 0x37d) or
    (codepoint >= 0x37f and codepoint <= 0x1fff) or
    (codepoint >= 0x200c and codepoint <= 0x200d) or
    (codepoint >= 0x2070 and codepoint <= 0x218f) or
    (codepoint >= 0x2c00 and codepoint <= 0x2fef) or
    (codepoint >= 0x3001 and codepoint <= 0xd7ff) or
    (codepoint >= 0xf900 and codepoint <= 0xfdcf) or
    (codepoint >= 0xfdf0 and codepoint <= 0xfffd) or
    (codepoint >= 0x10000 and codepoint <= 0xeffff)
end

local function is_name_character(codepoint)
  return is_name_start(codepoint) or codepoint == 0x2d or
    codepoint == 0x2e or codepoint == 0xb7 or
    (codepoint >= 0x30 and codepoint <= 0x39) or
    (codepoint >= 0x300 and codepoint <= 0x36f) or
    (codepoint >= 0x203f and codepoint <= 0x2040)
end

local function is_ncname_start(codepoint)
  return codepoint ~= 0x3a and is_name_start(codepoint)
end

local function is_ncname_character(codepoint)
  return codepoint ~= 0x3a and is_name_character(codepoint)
end

local function next_utf8(text, position)
  local codepoint = utf8.codepoint(text, position)
  local next_at = utf8.offset(text, 2, position) or (#text + 1)
  return codepoint, next_at
end

local function read_name(text, position)
  if position > #text then return nil, position end
  local codepoint, next_at = next_utf8(text, position)
  if not is_name_start(codepoint) then return nil, position end
  local finish = next_at
  while finish <= #text do
    codepoint, next_at = next_utf8(text, finish)
    if not is_name_character(codepoint) then break end
    finish = next_at
  end
  return text:sub(position, finish - 1), finish
end

local function validate_ncname(name, context)
  local position = 1
  local codepoint, next_at = next_utf8(name, position)
  if not codepoint or not is_ncname_start(codepoint) then
    raise("xml.invalid-name", "qualified XML name is invalid", context)
  end
  position = next_at
  while position <= #name do
    codepoint, next_at = next_utf8(name, position)
    if not is_ncname_character(codepoint) then
      raise("xml.invalid-name", "qualified XML name is invalid", context)
    end
    position = next_at
  end
end

local function split_qname(qname, context)
  local colon = qname:find(":", 1, true)
  if not colon then
    validate_ncname(qname, context)
    return "", qname
  end
  if colon == 1 or colon == #qname or qname:find(":", colon + 1, true) then
    raise("xml.invalid-name", "qualified XML name is invalid", context)
  end
  local prefix = qname:sub(1, colon - 1)
  local local_name = qname:sub(colon + 1)
  validate_ncname(prefix, context)
  validate_ncname(local_name, context)
  return prefix, local_name
end

local entities = {
  amp = "&",
  apos = "'",
  gt = ">",
  lt = "<",
  quot = "\"",
}

local function numeric_reference(body)
  local base, digits
  if body:sub(1, 2) == "#x" then
    base, digits = 16, body:sub(3)
    if digits == "" or not digits:match("^[0-9A-Fa-f]+$") then return nil end
  elseif body:sub(1, 1) == "#" then
    base, digits = 10, body:sub(2)
    if digits == "" or not digits:match("^%d+$") then return nil end
  else
    return false
  end
  local significant = digits:gsub("^0+", "")
  if significant == "" then significant = "0" end
  if #significant > (base == 16 and 6 or 7) then
    return nil, "overflow"
  end
  local codepoint = tonumber(significant, base)
  if not codepoint or not is_xml_character(codepoint) then
    return nil, "character"
  end
  return utf8.char(codepoint)
end

local function decode_references(raw)
  local pieces = {}
  local position = 1
  while position <= #raw do
    local ampersand = raw:find("&", position, true)
    if not ampersand then
      pieces[#pieces + 1] = raw:sub(position)
      break
    end
    pieces[#pieces + 1] = raw:sub(position, ampersand - 1)
    local semicolon = raw:find(";", ampersand + 1, true)
    if not semicolon then
      raise("xml.malformed-reference", "XML reference lacks a semicolon")
    end
    local body = raw:sub(ampersand + 1, semicolon - 1)
    local replacement = entities[body]
    if not replacement then
      local numeric, reason = numeric_reference(body)
      if numeric == false then
        raise("xml.malformed-reference", "unknown XML entity", {
          entity = body,
        })
      elseif not numeric then
        if reason == "character" or reason == "overflow" then
          raise("xml.invalid-character", "numeric reference is not an XML character")
        end
        raise("xml.malformed-reference", "malformed numeric XML reference")
      end
      replacement = numeric
    end
    pieces[#pieces + 1] = replacement
    position = semicolon + 1
  end
  return table.concat(pieces)
end

local function parse_declaration(text)
  if text:sub(1, 5) ~= "<?xml" then return nil, 1 end
  local marker = text:sub(6, 6)
  if marker ~= "" and not is_space(marker) and marker ~= "?" then
    return nil, 1
  end
  local close = text:find("?>", 6, true)
  if not close then
    raise("xml.malformed-declaration", "unclosed XML declaration")
  end
  local cursor = 6
  local fields = {}
  while cursor < close do
    local spaced = skip_space(text, cursor)
    if spaced == cursor then
      raise("xml.malformed-declaration", "declaration fields need whitespace")
    end
    cursor = spaced
    if cursor >= close then break end
    local name, next_at = text:match("^([A-Za-z_:][A-Za-z0-9_.:-]*)()", cursor)
    if not name then
      raise("xml.malformed-declaration", "invalid declaration field")
    end
    cursor = skip_space(text, next_at)
    if text:sub(cursor, cursor) ~= "=" then
      raise("xml.malformed-declaration", "declaration field requires equals")
    end
    cursor = skip_space(text, cursor + 1)
    local quote = text:sub(cursor, cursor)
    if quote ~= "'" and quote ~= "\"" then
      raise("xml.malformed-declaration", "declaration value requires quotes")
    end
    local finish = text:find(quote, cursor + 1, true)
    if not finish or finish > close then
      raise("xml.malformed-declaration", "unclosed declaration value")
    end
    fields[#fields + 1] = {
      name = name,
      value = text:sub(cursor + 1, finish - 1),
    }
    cursor = finish + 1
  end
  if #fields < 1 or #fields > 3 or fields[1].name ~= "version" or
      (#fields >= 2 and fields[2].name ~= "encoding" and
        fields[2].name ~= "standalone") or
      (#fields == 3 and (fields[2].name ~= "encoding" or
        fields[3].name ~= "standalone")) then
    raise("xml.malformed-declaration", "XML declaration fields are invalid")
  end
  local declaration = { version = fields[1].value }
  for index = 2, #fields do
    declaration[fields[index].name] = fields[index].value
  end
  if declaration.version ~= "1.0" then
    if declaration.version == "1.1" then
      raise("xml.unsupported-version", "XML 1.1 is not supported")
    end
    raise("xml.malformed-declaration", "XML version is invalid")
  end
  if declaration.encoding and
      not declaration.encoding:match("^[A-Za-z][A-Za-z0-9._-]*$") then
    raise("xml.malformed-declaration", "XML encoding name is invalid")
  end
  if declaration.standalone and declaration.standalone ~= "yes" and
      declaration.standalone ~= "no" then
    raise("xml.malformed-declaration", "XML standalone value is invalid")
  end
  return declaration, close + 2
end

local function verify_encoding(decoded, declaration)
  local declared = declaration and declaration.encoding and
    declaration.encoding:lower() or nil
  if decoded.encoding ~= "utf-8" and not decoded.bom and not declared then
    raise("xml.encoding-mismatch",
      "non-UTF-8 XML requires a BOM or encoding declaration", {
        detected = decoded.encoding,
      })
  end
  if not declared then return end
  if not decoded.bom and declared == "utf-16" then
    raise("xml.encoding-mismatch", "generic UTF-16 requires a BOM", {
      declared = declaration.encoding,
      detected = decoded.encoding,
    })
  end
  local matches = declared == decoded.encoding or
    (declared == "utf-16" and decoded.encoding:sub(1, 6) == "utf-16")
  if not matches then
    raise("xml.encoding-mismatch", "declared XML encoding does not match bytes", {
      declared = declaration.encoding,
      detected = decoded.encoding,
    })
  end
end

local function copy_map(source)
  local result = {}
  for key, value in pairs(source or {}) do result[key] = value end
  return result
end

local function validate_namespace(prefix, uri, context)
  if prefix == "xmlns" or uri == XMLNS_NS then
    raise("xml.illegal-namespace", "the xmlns namespace is reserved", context)
  elseif prefix == "xml" and uri ~= XML_NS then
    raise("xml.illegal-namespace", "the xml prefix has a fixed namespace", context)
  elseif prefix ~= "xml" and uri == XML_NS then
    raise("xml.illegal-namespace", "the XML namespace requires the xml prefix", context)
  elseif prefix ~= "" and uri == "" then
    raise("xml.illegal-namespace", "a prefixed namespace cannot be empty", context)
  end
end

local function expanded_name(qname, namespaces, attribute, context)
  local prefix, local_name = split_qname(qname, context)
  if prefix == "xmlns" then
    raise("xml.illegal-namespace", "the xmlns prefix is reserved", context)
  end
  local uri = ""
  if prefix ~= "" then
    uri = namespaces[prefix]
    if uri == nil then
      raise("xml.unbound-prefix", "XML namespace prefix is unbound", {
        prefix = prefix,
        qname = qname,
      })
    end
  elseif not attribute then
    uri = namespaces[""] or ""
  end
  return common.expanded_name(uri, local_name, prefix, qname)
end

local function emit(state, event)
  if state.token_count >= state.limits.max_tokens then
    raise("xml.token-limit", "XML token limit exceeded", {
      limit = state.limits.max_tokens,
    })
  end
  state.token_count = state.token_count + 1
  state.events[#state.events + 1] = event
end

local function parse_start(state)
  local text = state.decoded.text
  local token_start = state.position
  local qname, cursor = read_name(text, token_start + 1)
  if not qname then
    raise("xml.invalid-name", "start tag has an invalid name")
  end
  split_qname(qname)
  local raw_attributes, declarations = {}, {}
  local lexical_names = {}
  local ordinary_count = 0
  local empty, token_finish
  while true do
    local before_space = cursor
    cursor = skip_space(text, cursor)
    local character = text:sub(cursor, cursor)
    if character == ">" then
      token_finish = cursor + 1
      cursor = cursor + 1
      break
    elseif character == "/" and text:sub(cursor + 1, cursor + 1) == ">" then
      empty = true
      token_finish = cursor + 2
      cursor = cursor + 2
      break
    elseif cursor > #text then
      raise("xml.malformed-token", "unclosed start tag")
    elseif cursor == before_space then
      raise("xml.malformed-token", "attributes must be whitespace-separated")
    end

    local attribute_qname, next_at = read_name(text, cursor)
    if not attribute_qname then
      raise("xml.invalid-name", "attribute has an invalid name")
    end
    split_qname(attribute_qname)
    if lexical_names[attribute_qname] then
      raise("xml.duplicate-attribute", "duplicate lexical attribute", {
        attribute = attribute_qname,
      })
    end
    lexical_names[attribute_qname] = true
    cursor = skip_space(text, next_at)
    if text:sub(cursor, cursor) ~= "=" then
      raise("xml.malformed-token", "attribute requires equals")
    end
    cursor = skip_space(text, cursor + 1)
    local quote = text:sub(cursor, cursor)
    if quote ~= "'" and quote ~= "\"" then
      raise("xml.malformed-token", "attribute value requires quotes")
    end
    local value_start = cursor + 1
    local value_finish = text:find(quote, value_start, true)
    if not value_finish then
      raise("xml.malformed-token", "unclosed attribute value")
    end
    local raw_value = text:sub(value_start, value_finish - 1)
    if raw_value:find("<", 1, true) then
      raise("xml.malformed-token", "attribute value contains less-than")
    end
    local value = decode_references(raw_value:gsub("[\t\n\r]", " "))
    local row = {
      qname = attribute_qname,
      value = value,
      quote = quote,
      value_range = source_range(state.decoded, value_start, value_finish),
      decoded_value_start = value_start,
      decoded_value_finish = value_finish,
    }
    state.attribute_spans[#state.attribute_spans + 1] = row
    cursor = value_finish + 1

    local namespace_prefix
    if attribute_qname == "xmlns" then
      namespace_prefix = ""
    elseif attribute_qname:sub(1, 6) == "xmlns:" then
      namespace_prefix = attribute_qname:sub(7)
    end
    if namespace_prefix ~= nil then
      if #declarations >= state.limits.max_namespaces then
        raise("xml.namespace-limit", "namespace-declarations limit exceeded", {
          limit = state.limits.max_namespaces,
          element = qname,
        })
      end
      row.prefix = namespace_prefix
      declarations[#declarations + 1] = row
    else
      ordinary_count = ordinary_count + 1
      if ordinary_count > state.limits.max_attributes then
        raise("xml.attribute-limit", "attributes-per-element limit exceeded", {
          limit = state.limits.max_attributes,
          element = qname,
        })
      end
      raw_attributes[#raw_attributes + 1] = row
    end
  end

  local parent = state.stack[#state.stack]
  local namespaces = copy_map(parent and parent.namespaces or {
    xml = XML_NS,
  })
  for _, declaration in ipairs(declarations) do
    validate_namespace(declaration.prefix, declaration.value, {
      attribute = declaration.qname,
    })
    namespaces[declaration.prefix] = declaration.value
  end
  local name = expanded_name(qname, namespaces, false, { element = qname })
  local attributes, expanded = {}, {}
  for _, attribute in ipairs(raw_attributes) do
    attribute.name = expanded_name(
      attribute.qname, namespaces, true, { attribute = attribute.qname })
    local key = attribute.name.uri .. "\0" .. attribute.name.local_name
    if expanded[key] then
      raise("xml.duplicate-attribute", "duplicate expanded-name attribute", {
        attribute = attribute.qname,
      })
    end
    expanded[key] = true
    attributes[#attributes + 1] = attribute
  end
  local depth = #state.stack + 1
  if depth > state.limits.max_depth then
    raise("xml.depth-limit", "XML element depth limit exceeded", {
      limit = state.limits.max_depth,
    })
  end
  if not parent and state.root then
    raise("xml.multiple-roots", "XML document has multiple roots")
  end
  state.next_id = state.next_id + 1
  local event = {
    kind = "start",
    id = state.next_id,
    parent_id = parent and parent.event.id or nil,
    depth = depth,
    qname = qname,
    name = name,
    attributes = attributes,
    namespace_declarations = declarations,
    namespace_bindings = copy_map(namespaces),
    range = source_range(state.decoded, token_start, token_finish),
  }
  if not state.root then state.root = event end
  emit(state, event)
  if empty then
    emit(state, {
      kind = "end",
      parent_id = event.parent_id,
      depth = depth,
      qname = qname,
      name = name,
      range = event.range,
      empty = true,
    })
  else
    state.stack[#state.stack + 1] = {
      event = event,
      qname = qname,
      namespaces = namespaces,
    }
  end
  state.position = cursor
end

local function parse_end(state)
  local text = state.decoded.text
  local token_start = state.position
  local qname, cursor = read_name(text, token_start + 2)
  if not qname then raise("xml.invalid-name", "end tag has an invalid name") end
  split_qname(qname)
  cursor = skip_space(text, cursor)
  if text:sub(cursor, cursor) ~= ">" then
    raise("xml.malformed-token", "unclosed end tag", { element = qname })
  end
  local current = state.stack[#state.stack]
  if not current or current.qname ~= qname then
    raise("xml.mismatched-element", "XML end tag does not match start tag", {
      expected = current and current.qname or nil,
      actual = qname,
    })
  end
  emit(state, {
    kind = "end",
    parent_id = current.event.parent_id,
    depth = #state.stack,
    qname = qname,
    name = current.event.name,
    range = source_range(state.decoded, token_start, cursor + 1),
  })
  state.stack[#state.stack] = nil
  state.position = cursor + 1
end

local function parse_comment(state)
  local start_at = state.position
  local close = state.decoded.text:find("-->", start_at + 4, true)
  if not close then raise("xml.malformed-comment", "unclosed XML comment") end
  local value = state.decoded.text:sub(start_at + 4, close - 1)
  if value:find("--", 1, true) or value:sub(-1) == "-" then
    raise("xml.malformed-comment", "XML comment contains forbidden hyphens")
  end
  emit(state, {
    kind = "comment",
    parent_id = state.stack[#state.stack] and
      state.stack[#state.stack].event.id or nil,
    value = value,
    range = source_range(state.decoded, start_at, close + 3),
  })
  state.position = close + 3
end

local function parse_cdata(state)
  if #state.stack == 0 then
    raise("xml.cdata-outside-root", "CDATA is not allowed outside the root")
  end
  local start_at = state.position
  local close = state.decoded.text:find("]]>", start_at + 9, true)
  if not close then raise("xml.malformed-cdata", "unclosed CDATA section") end
  emit(state, {
    kind = "cdata",
    parent_id = state.stack[#state.stack].event.id,
    value = state.decoded.text:sub(start_at + 9, close - 1),
    range = source_range(state.decoded, start_at, close + 3),
  })
  state.position = close + 3
end

local function parse_pi(state)
  local text = state.decoded.text
  local start_at = state.position
  local close = text:find("?>", start_at + 2, true)
  if not close then raise("xml.malformed-pi", "unclosed processing instruction") end
  local target, cursor = read_name(text, start_at + 2)
  if not target then raise("xml.malformed-pi", "processing instruction needs a target") end
  validate_ncname(target, { offset = start_at - 1 })
  if target:lower() == "xml" then
    if target == "xml" then
      raise("xml.misplaced-declaration", "XML declaration is misplaced")
    end
    raise("xml.reserved-pi-target", "processing-instruction target xml is reserved")
  end
  local value = ""
  if cursor < close then
    if not is_space(text:sub(cursor, cursor)) then
      raise("xml.malformed-pi", "processing-instruction data needs whitespace")
    end
    local data_start = skip_space(text, cursor)
    state.pi_separator_spans[#state.pi_separator_spans + 1] = {
      decoded_start = cursor,
      decoded_finish = data_start,
    }
    value = text:sub(data_start, close - 1)
  end
  emit(state, {
    kind = "pi",
    parent_id = state.stack[#state.stack] and
      state.stack[#state.stack].event.id or nil,
    target = target,
    value = value,
    range = source_range(state.decoded, start_at, close + 2),
  })
  state.position = close + 2
end

local function parse_text(state)
  local text = state.decoded.text
  local start_at = state.position
  local finish = text:find("<", start_at, true) or (#text + 1)
  local raw = text:sub(start_at, finish - 1)
  if raw:find("]]>", 1, true) then
    raise("xml.malformed-token", "ordinary text contains CDATA close delimiter")
  end
  local value = decode_references(raw)
  if #state.stack == 0 then
    if value:find("[^%s]") then
      raise("xml.text-outside-root", "non-whitespace text is outside the root")
    end
  elseif raw ~= "" then
    emit(state, {
      kind = "text",
      parent_id = state.stack[#state.stack].event.id,
      value = value,
      range = source_range(state.decoded, start_at, finish),
    })
  end
  state.position = finish
end

local function semantic_xml(state)
  local pieces = {}
  local cursor = 1
  local spans = {}
  for _, attribute in ipairs(state.attribute_spans) do
    spans[#spans + 1] = {
      decoded_start = attribute.decoded_value_start,
      decoded_finish = attribute.decoded_value_finish,
      normalize_attribute_space = true,
    }
  end
  for _, separator in ipairs(state.pi_separator_spans) do
    spans[#spans + 1] = separator
  end
  table.sort(spans, function(left, right)
    return left.decoded_start < right.decoded_start
  end)
  for _, span in ipairs(spans) do
    pieces[#pieces + 1] = state.decoded.text:sub(
      cursor, span.decoded_start - 1)
    if span.normalize_attribute_space then
      pieces[#pieces + 1] = state.decoded.text:sub(
        span.decoded_start, span.decoded_finish - 1):gsub("[\t\n\r]", " "):gsub(
          ">", "&gt;")
    else
      pieces[#pieces + 1] = " "
    end
    cursor = span.decoded_finish
  end
  pieces[#pieces + 1] = state.decoded.text:sub(cursor)
  return table.concat(pieces)
end

function M.inspect(bytes, options)
  if type(bytes) ~= "string" then
    raise("xml.invalid-input", "XML input must be a byte string")
  end
  local limits = common.limits(options)
  if #bytes > limits.max_input_bytes then
    raise("xml.input-limit", "XML input-byte limit exceeded", {
      size = #bytes,
      limit = limits.max_input_bytes,
    })
  end
  local decoded = decode_document(bytes)
  local declaration, position = parse_declaration(decoded.text)
  verify_encoding(decoded, declaration)
  local state = {
    decoded = decoded,
    declaration = declaration,
    limits = limits,
    position = position,
    events = {},
    stack = {},
    root = nil,
    next_id = 0,
    token_count = 0,
    attribute_spans = {},
    pi_separator_spans = {},
  }
  while state.position <= #decoded.text do
    local prefix4 = decoded.text:sub(state.position, state.position + 3)
    local prefix9 = decoded.text:sub(state.position, state.position + 8)
    if prefix4 == "<!--" then
      parse_comment(state)
    elseif prefix9 == "<![CDATA[" then
      parse_cdata(state)
    elseif prefix9:upper() == "<!DOCTYPE" then
      raise("xml.doctype-forbidden", "DOCTYPE is forbidden")
    elseif decoded.text:sub(state.position, state.position + 1) == "<?" then
      parse_pi(state)
    elseif decoded.text:sub(state.position, state.position + 1) == "</" then
      parse_end(state)
    elseif decoded.text:sub(state.position, state.position) == "<" then
      if decoded.text:sub(state.position, state.position + 1) == "<!" then
        raise("xml.malformed-token", "unsupported XML declaration")
      end
      parse_start(state)
    else
      parse_text(state)
    end
  end
  if #state.stack > 0 then
    raise("xml.unclosed-element", "XML element is not closed", {
      element = state.stack[#state.stack].qname,
    })
  end
  if not state.root then raise("xml.missing-root", "XML document has no root") end
  return {
    encoding = decoded.encoding,
    bom = decoded.bom,
    declaration = declaration,
    events = state.events,
    root = state.root,
    token_count = state.token_count,
    semantic_xml = semantic_xml(state),
  }
end

function M.encode(text, encoding)
  if type(text) ~= "string" then
    raise("xml.invalid-input", "replacement value must be a string")
  end
  local records = decode_utf8(text, 1)
  if encoding == "utf-8" then return text end
  local parts = {}
  for _, record in ipairs(records) do
    local codepoint = record.codepoint
    local function append(value)
      local high, low = (value >> 8) & 0xff, value & 0xff
      if encoding == "utf-16le" then
        parts[#parts + 1] = string.char(low, high)
      else
        parts[#parts + 1] = string.char(high, low)
      end
    end
    if codepoint <= 0xffff then
      append(codepoint)
    else
      local value = codepoint - 0x10000
      append(0xd800 + (value >> 10))
      append(0xdc00 + (value & 0x3ff))
    end
  end
  return table.concat(parts)
end

return M
