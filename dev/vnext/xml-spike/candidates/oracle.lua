local common = require("candidates.common")
local diagnostic = require("lib.diagnostic")

local M = {}

local XML_NS = "http://www.w3.org/XML/1998/namespace"
local XMLNS_NS = "http://www.w3.org/2000/xmlns/"

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function copy_map(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function is_xml_character(codepoint)
  return codepoint == 0x9 or codepoint == 0xa or codepoint == 0xd or
    (codepoint >= 0x20 and codepoint <= 0xd7ff) or
    (codepoint >= 0xe000 and codepoint <= 0xfffd) or
    (codepoint >= 0x10000 and codepoint <= 0x10ffff)
end

local function decode_utf8_codepoint(bytes, position)
  local first = bytes:byte(position)
  if not first then return nil end
  if first <= 0x7f then return first, position + 1 end

  local count
  local value
  local minimum
  if first >= 0xc2 and first <= 0xdf then
    count, value, minimum = 2, first & 0x1f, 0x80
  elseif first >= 0xe0 and first <= 0xef then
    count, value, minimum = 3, first & 0x0f, 0x800
  elseif first >= 0xf0 and first <= 0xf4 then
    count, value, minimum = 4, first & 0x07, 0x10000
  else
    raise("xml.invalid-encoding", "invalid UTF-8 leading byte", {
      offset = position - 1,
    })
  end

  if position + count - 1 > #bytes then
    raise("xml.invalid-encoding", "truncated UTF-8 sequence", {
      offset = position - 1,
    })
  end
  for index = 2, count do
    local byte = bytes:byte(position + index - 1)
    if byte < 0x80 or byte > 0xbf then
      raise("xml.invalid-encoding", "invalid UTF-8 continuation byte", {
        offset = position + index - 2,
      })
    end
    value = (value << 6) | (byte & 0x3f)
  end
  if value < minimum or value > 0x10ffff or
      (value >= 0xd800 and value <= 0xdfff) then
    raise("xml.invalid-encoding", "invalid UTF-8 scalar value", {
      offset = position - 1,
    })
  end
  return value, position + count
end

local function detect_encoding(bytes)
  if bytes:sub(1, 3) == "\239\187\191" then
    return "utf-8", 3, true
  end
  if bytes:sub(1, 2) == "\255\254" then
    return "utf-16le", 2, true
  end
  if bytes:sub(1, 2) == "\254\255" then
    return "utf-16be", 2, true
  end
  local first, second = bytes:byte(1, 2)
  if first == 0x3c and second == 0x00 then
    return "utf-16le", 0, false
  end
  if first == 0x00 and second == 0x3c then
    return "utf-16be", 0, false
  end
  return "utf-8", 0, false
end

local function append_mapped(parts, starts, finishes, codepoint,
    original_start, original_finish)
  local encoded = utf8.char(codepoint)
  parts[#parts + 1] = encoded
  for _ = 1, #encoded do
    starts[#starts + 1] = original_start
    finishes[#finishes + 1] = original_finish
  end
end

local function decoded_result(bytes, encoding, bom, skip, parts, starts, finishes)
  return {
    text = table.concat(parts),
    starts = starts,
    finishes = finishes,
    raw_length = #bytes,
    encoding = encoding,
    bom = bom,
    bom_bytes = skip,
  }
end

local function decode_utf8_document(bytes, skip, bom)
  local position = skip + 1
  local has_carriage_return = false
  while position <= #bytes do
    local codepoint, next_at = decode_utf8_codepoint(bytes, position)
    if not is_xml_character(codepoint) then
      raise("xml.invalid-character", "invalid XML character", {
        offset = position - 1,
        codepoint = codepoint,
      })
    end
    if codepoint == 0xd then has_carriage_return = true end
    position = next_at
  end
  if not has_carriage_return then
    return {
      text = bytes:sub(skip + 1),
      identity_offset = skip,
      raw_length = #bytes,
      encoding = "utf-8",
      bom = bom,
      bom_bytes = skip,
    }
  end

  local parts = {}
  local starts = {}
  local finishes = {}
  position = skip + 1
  while position <= #bytes do
    local start_at = position
    local codepoint, next_at = decode_utf8_codepoint(bytes, position)
    local finish_at = next_at - 1
    if codepoint == 0xd then
      codepoint = 0xa
      if next_at <= #bytes then
        local following, after_following = decode_utf8_codepoint(bytes, next_at)
        if following == 0xa then
          finish_at = after_following - 1
          next_at = after_following
        end
      end
    end
    append_mapped(parts, starts, finishes, codepoint,
      start_at - 1, finish_at)
    position = next_at
  end
  return decoded_result(
    bytes, "utf-8", bom, skip, parts, starts, finishes)
end

local function utf16_unit(bytes, encoding, position)
  local first, second = bytes:byte(position, position + 1)
  if encoding == "utf-16le" then return first | (second << 8) end
  return (first << 8) | second
end

local function decode_utf16_scalar(bytes, encoding, position)
  local start_at = position
  local first = utf16_unit(bytes, encoding, position)
  position = position + 2
  local codepoint = first
  if first >= 0xd800 and first <= 0xdbff then
    if position > #bytes then
      raise("xml.invalid-encoding", "truncated UTF-16 surrogate pair", {
        offset = start_at - 1,
      })
    end
    local second = utf16_unit(bytes, encoding, position)
    if second < 0xdc00 or second > 0xdfff then
      raise("xml.invalid-encoding", "invalid UTF-16 surrogate pair", {
        offset = start_at - 1,
      })
    end
    position = position + 2
    codepoint = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
  elseif first >= 0xdc00 and first <= 0xdfff then
    raise("xml.invalid-encoding", "unpaired UTF-16 low surrogate", {
      offset = start_at - 1,
    })
  end
  return codepoint, position, start_at - 1, position - 1
end

local function decode_utf16_document(bytes, encoding, skip, bom)
  if (#bytes - skip) % 2 ~= 0 then
    raise("xml.invalid-encoding", "truncated UTF-16 code unit", {
      offset = #bytes - 1,
    })
  end
  local parts = {}
  local starts = {}
  local finishes = {}
  local position = skip + 1
  while position <= #bytes do
    local codepoint, next_at, start_at, finish_at =
      decode_utf16_scalar(bytes, encoding, position)
    if not is_xml_character(codepoint) then
      raise("xml.invalid-character", "invalid XML character", {
        offset = start_at,
        codepoint = codepoint,
      })
    end
    if codepoint == 0xd then
      codepoint = 0xa
      if next_at <= #bytes then
        local following, after_following, _, following_finish =
          decode_utf16_scalar(bytes, encoding, next_at)
        if following == 0xa then
          finish_at = following_finish
          next_at = after_following
        end
      end
    end
    append_mapped(parts, starts, finishes, codepoint, start_at, finish_at)
    position = next_at
  end
  return decoded_result(
    bytes, encoding, bom, skip, parts, starts, finishes)
end

local function decode_document(bytes)
  local encoding, skip, bom = detect_encoding(bytes)
  if encoding == "utf-8" then
    return decode_utf8_document(bytes, skip, bom)
  end
  return decode_utf16_document(bytes, encoding, skip, bom)
end

local function original_boundary(decoded, position)
  if decoded.identity_offset ~= nil then
    return decoded.identity_offset + position - 1
  end
  if position <= #decoded.text then return decoded.starts[position] end
  return decoded.raw_length
end

local function original_range(decoded, start_at, finish_at)
  if finish_at < start_at then
    local boundary = original_boundary(decoded, start_at)
    return common.range(boundary, boundary)
  end
  if decoded.identity_offset ~= nil then
    return common.range(
      decoded.identity_offset + start_at - 1,
      decoded.identity_offset + finish_at)
  end
  return common.range(decoded.starts[start_at], decoded.finishes[finish_at])
end

local function is_space(character)
  return character == " " or character == "\t" or
    character == "\n" or character == "\r"
end

local function skip_space(text, position)
  while position <= #text and is_space(text:sub(position, position)) do
    position = position + 1
  end
  return position
end

local function in_range(value, first, last)
  return value >= first and value <= last
end

local function is_name_start(codepoint, allow_colon)
  return (allow_colon and codepoint == 0x3a) or codepoint == 0x5f or
    in_range(codepoint, 0x41, 0x5a) or in_range(codepoint, 0x61, 0x7a) or
    in_range(codepoint, 0xc0, 0xd6) or in_range(codepoint, 0xd8, 0xf6) or
    in_range(codepoint, 0xf8, 0x2ff) or in_range(codepoint, 0x370, 0x37d) or
    in_range(codepoint, 0x37f, 0x1fff) or
    in_range(codepoint, 0x200c, 0x200d) or
    in_range(codepoint, 0x2070, 0x218f) or
    in_range(codepoint, 0x2c00, 0x2fef) or
    in_range(codepoint, 0x3001, 0xd7ff) or
    in_range(codepoint, 0xf900, 0xfdcf) or
    in_range(codepoint, 0xfdf0, 0xfffd) or
    in_range(codepoint, 0x10000, 0xeffff)
end

local function is_name_character(codepoint, allow_colon)
  return is_name_start(codepoint, allow_colon) or codepoint == 0x2d or
    codepoint == 0x2e or in_range(codepoint, 0x30, 0x39) or
    codepoint == 0xb7 or in_range(codepoint, 0x300, 0x36f) or
    in_range(codepoint, 0x203f, 0x2040)
end

local function read_name(text, position)
  if math.type(position) ~= "integer" or position < 1 or position > #text then
    return nil, position
  end
  local first = utf8.codepoint(text, position)
  if not first or not is_name_start(first, true) then return nil, position end
  local next_at = utf8.offset(text, 2, position) or (#text + 1)
  while next_at <= #text do
    local codepoint = utf8.codepoint(text, next_at)
    if not is_name_character(codepoint, true) then break end
    next_at = utf8.offset(text, 2, next_at) or (#text + 1)
  end
  return text:sub(position, next_at - 1), next_at
end

local function split_qname(qname, context)
  local first = qname:find(":", 1, true)
  if not first then
    local codepoint = utf8.codepoint(qname, 1)
    if not codepoint or not is_name_start(codepoint, false) then
      raise("xml.invalid-name", "invalid XML qualified name", context)
    end
    return "", qname
  end
  if first == 1 or first == #qname or qname:find(":", first + 1, true) then
    raise("xml.invalid-name", "invalid XML qualified name", context)
  end
  local prefix = qname:sub(1, first - 1)
  local local_name = qname:sub(first + 1)
  for _, value in ipairs({ prefix, local_name }) do
    local at = 1
    local codepoint = utf8.codepoint(value, at)
    if not is_name_start(codepoint, false) then
      raise("xml.invalid-name", "invalid XML qualified name", context)
    end
    at = utf8.offset(value, 2, at) or (#value + 1)
    while at <= #value do
      codepoint = utf8.codepoint(value, at)
      if not is_name_character(codepoint, false) then
        raise("xml.invalid-name", "invalid XML qualified name", context)
      end
      at = utf8.offset(value, 2, at) or (#value + 1)
    end
  end
  return prefix, local_name
end

local function decode_references(value, context)
  local result = {}
  local position = 1
  while position <= #value do
    local amp = value:find("&", position, true)
    if not amp then
      result[#result + 1] = value:sub(position)
      break
    end
    result[#result + 1] = value:sub(position, amp - 1)
    local close = value:find(";", amp + 1, true)
    if not close then
      raise("xml.malformed-reference", "unterminated XML reference", context)
    end
    local name = value:sub(amp + 1, close - 1)
    local predefined = {
      amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'",
    }
    if predefined[name] then
      result[#result + 1] = predefined[name]
    else
      local digits
      local base
      if name:sub(1, 2) == "#x" then
        digits, base = name:sub(3), 16
        if digits == "" or not digits:match("^[0-9A-Fa-f]+$") then
          raise("xml.malformed-reference", "invalid hexadecimal reference", context)
        end
      elseif name:sub(1, 1) == "#" then
        digits, base = name:sub(2), 10
        if digits == "" or not digits:match("^[0-9]+$") then
          raise("xml.malformed-reference", "invalid decimal reference", context)
        end
      else
        raise("xml.malformed-reference", "unsupported XML entity", context)
      end
      local codepoint = tonumber(digits, base)
      if not codepoint or not is_xml_character(codepoint) then
        raise("xml.invalid-character", "invalid character reference", context)
      end
      result[#result + 1] = utf8.char(codepoint)
    end
    position = close + 1
  end
  return table.concat(result)
end

local function parse_declaration(text)
  if text:sub(1, 5) ~= "<?xml" then return nil, 1 end
  local following = text:sub(6, 6)
  if following ~= "?" and not is_space(following) then return nil, 1 end
  local close = text:find("?>", 6, true)
  if not close then
    raise("xml.malformed-declaration", "unclosed XML declaration")
  end
  local body = text:sub(6, close - 1)
  local position = 1

  local function read_attribute(expected)
    local before = position
    position = skip_space(body, position)
    if position == before then
      raise("xml.malformed-declaration", "declaration fields need whitespace")
    end
    local name, next_at = read_name(body, position)
    if name ~= expected then
      raise("xml.malformed-declaration", "unexpected XML declaration field")
    end
    position = skip_space(body, next_at)
    if body:sub(position, position) ~= "=" then
      raise("xml.malformed-declaration", "declaration field needs equals")
    end
    position = skip_space(body, position + 1)
    local quote = body:sub(position, position)
    if quote ~= "'" and quote ~= "\"" then
      raise("xml.malformed-declaration", "declaration value needs quotes")
    end
    local finish = body:find(quote, position + 1, true)
    if not finish then
      raise("xml.malformed-declaration", "unclosed declaration value")
    end
    local value = body:sub(position + 1, finish - 1)
    position = finish + 1
    return value
  end

  local version = read_attribute("version")
  if version ~= "1.0" then
    raise("xml.unsupported-version", "only XML 1.0 is supported", {
      version = version,
    })
  end

  local encoding
  local standalone
  local after_space = skip_space(body, position)
  local next_name = read_name(body, after_space)
  if next_name == "encoding" then
    encoding = read_attribute("encoding")
    if not encoding:match("^[A-Za-z][A-Za-z0-9._%-]*$") then
      raise("xml.malformed-declaration", "invalid encoding name")
    end
    after_space = skip_space(body, position)
    next_name = read_name(body, after_space)
  end
  if next_name == "standalone" then
    standalone = read_attribute("standalone")
    if standalone ~= "yes" and standalone ~= "no" then
      raise("xml.malformed-declaration", "invalid standalone value")
    end
  end
  if skip_space(body, position) <= #body then
    raise("xml.malformed-declaration", "unexpected declaration content")
  end
  return {
    version = version,
    encoding = encoding,
    standalone = standalone,
  }, close + 2
end

local function verify_declared_encoding(detected, declaration)
  if not declaration or not declaration.encoding then return end
  local declared = declaration.encoding:upper()
  local valid = (detected == "utf-8" and declared == "UTF-8") or
    (detected == "utf-16le" and
      (declared == "UTF-16" or declared == "UTF-16LE")) or
    (detected == "utf-16be" and
      (declared == "UTF-16" or declared == "UTF-16BE"))
  if not valid then
    raise("xml.encoding-mismatch", "XML declaration contradicts byte encoding", {
      detected = detected,
      declared = declaration.encoding,
    })
  end
end

local function resolve_name(qname, namespaces, attribute, context)
  local prefix, local_name = split_qname(qname, context)
  if prefix == "xmlns" then
    raise("xml.illegal-namespace", "the xmlns prefix is reserved", context)
  end
  local uri
  if prefix == "" then
    uri = attribute and "" or (namespaces[""] or "")
  else
    uri = namespaces[prefix]
    if not uri then
      raise("xml.unbound-prefix", "XML namespace prefix is unbound", {
        prefix = prefix,
        qname = qname,
      })
    end
  end
  return common.expanded_name(uri, local_name, prefix, qname)
end

local function validate_namespace(prefix, uri, context)
  if prefix == "xmlns" or uri == XMLNS_NS then
    raise("xml.illegal-namespace", "the xmlns namespace is reserved", context)
  end
  if prefix == "xml" and uri ~= XML_NS then
    raise("xml.illegal-namespace", "the xml prefix has a fixed namespace", context)
  end
  if prefix ~= "xml" and uri == XML_NS then
    raise("xml.illegal-namespace", "the XML namespace requires the xml prefix", context)
  end
  if prefix ~= "" and uri == "" then
    raise("xml.illegal-namespace", "a prefixed namespace cannot be empty", context)
  end
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

local function parse_start_tag(state)
  local text = state.decoded.text
  local token_start = state.position
  local position = token_start + 1
  local qname, next_at = read_name(text, position)
  if not qname then
    raise("xml.invalid-name", "start tag has an invalid name", {
      offset = original_boundary(state.decoded, position),
    })
  end
  split_qname(qname, { offset = original_boundary(state.decoded, position) })
  position = next_at

  local raw_attributes = {}
  local declarations = {}
  local declaration_names = {}
  local ordinary_count = 0
  local empty = false
  local token_finish
  while true do
    local before_space = position
    position = skip_space(text, position)
    local character = text:sub(position, position)
    if character == ">" then
      token_finish = position
      position = position + 1
      break
    elseif character == "/" and text:sub(position + 1, position + 1) == ">" then
      empty = true
      token_finish = position + 1
      position = position + 2
      break
    elseif position == before_space then
      raise("xml.malformed-token", "attributes must be whitespace-separated", {
        offset = original_boundary(state.decoded, position),
      })
    elseif position > #text then
      raise("xml.malformed-token", "unclosed start tag")
    end

    local attribute_qname
    attribute_qname, next_at = read_name(text, position)
    if not attribute_qname then
      raise("xml.invalid-name", "attribute has an invalid name", {
        offset = original_boundary(state.decoded, position),
      })
    end
    split_qname(attribute_qname, {
      offset = original_boundary(state.decoded, position),
    })
    position = skip_space(text, next_at)
    if text:sub(position, position) ~= "=" then
      raise("xml.malformed-token", "attribute requires equals", {
        attribute = attribute_qname,
      })
    end
    position = skip_space(text, position + 1)
    local quote = text:sub(position, position)
    if quote ~= "'" and quote ~= "\"" then
      raise("xml.malformed-token", "attribute value requires quotes", {
        attribute = attribute_qname,
      })
    end
    local value_start = position + 1
    local value_finish = text:find(quote, value_start, true)
    if not value_finish then
      raise("xml.malformed-token", "unclosed attribute value", {
        attribute = attribute_qname,
      })
    end
    local raw_value = text:sub(value_start, value_finish - 1)
    if raw_value:find("<", 1, true) then
      raise("xml.malformed-token", "attribute value contains less-than", {
        attribute = attribute_qname,
      })
    end
    local normalized = raw_value:gsub("[\t\n\r]", " ")
    local value = decode_references(normalized, { attribute = attribute_qname })
    local value_range = original_range(
      state.decoded, value_start, value_finish - 1)
    position = value_finish + 1

    local namespace_prefix
    if attribute_qname == "xmlns" then
      namespace_prefix = ""
    elseif attribute_qname:sub(1, 6) == "xmlns:" then
      namespace_prefix = attribute_qname:sub(7)
    end
    if namespace_prefix ~= nil then
      if declaration_names[attribute_qname] then
        raise("xml.duplicate-attribute", "duplicate namespace declaration", {
          attribute = attribute_qname,
        })
      end
      declaration_names[attribute_qname] = true
      if #declarations >= state.limits.max_namespaces then
        raise("xml.namespace-limit", "namespace-declarations limit exceeded", {
          limit = state.limits.max_namespaces,
          element = qname,
        })
      end
      declarations[#declarations + 1] = {
        prefix = namespace_prefix,
        uri = value,
        qname = attribute_qname,
        value_range = value_range,
        quote = quote,
      }
    else
      ordinary_count = ordinary_count + 1
      if ordinary_count > state.limits.max_attributes then
        raise("xml.attribute-limit", "attributes-per-element limit exceeded", {
          limit = state.limits.max_attributes,
          element = qname,
        })
      end
      raw_attributes[#raw_attributes + 1] = {
        qname = attribute_qname,
        value = value,
        value_range = value_range,
        quote = quote,
      }
    end
  end

  if #declarations > state.limits.max_namespaces then
    raise("xml.namespace-limit", "namespace-declarations limit exceeded", {
      limit = state.limits.max_namespaces,
      element = qname,
    })
  end
  local parent = state.stack[#state.stack]
  local namespaces = copy_map(parent and parent.namespaces or {
    xml = XML_NS,
  })
  for _, declaration in ipairs(declarations) do
    validate_namespace(declaration.prefix, declaration.uri, {
      attribute = declaration.qname,
    })
    namespaces[declaration.prefix] = declaration.uri
  end

  local name = resolve_name(qname, namespaces, false, {
    element = qname,
  })
  local attributes = {}
  local expanded_attributes = {}
  for _, attribute in ipairs(raw_attributes) do
    attribute.name = resolve_name(attribute.qname, namespaces, true, {
      attribute = attribute.qname,
      element = qname,
    })
    local key = attribute.name.uri .. "\0" .. attribute.name.local_name
    if expanded_attributes[key] then
      raise("xml.duplicate-attribute", "duplicate attribute expanded name", {
        element = qname,
        attribute = attribute.qname,
      })
    end
    expanded_attributes[key] = true
    attributes[#attributes + 1] = attribute
  end

  local depth = #state.stack + 1
  if depth > state.limits.max_depth then
    raise("xml.depth-limit", "XML element depth limit exceeded", {
      limit = state.limits.max_depth,
      element = qname,
    })
  end
  if #state.stack == 0 then
    if state.root then
      raise("xml.multiple-roots", "XML document has multiple roots", {
        element = qname,
      })
    end
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
    range = original_range(state.decoded, token_start, token_finish),
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
    if depth == 1 then state.root_closed = true end
  else
    state.stack[#state.stack + 1] = {
      qname = qname,
      name = name,
      namespaces = namespaces,
      event = event,
    }
  end
  state.position = position
end

local function parse_end_tag(state)
  local text = state.decoded.text
  local token_start = state.position
  local position = token_start + 2
  local qname, next_at = read_name(text, position)
  if not qname then
    raise("xml.invalid-name", "end tag has an invalid name")
  end
  split_qname(qname)
  position = skip_space(text, next_at)
  if text:sub(position, position) ~= ">" then
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
    name = current.name,
    range = original_range(state.decoded, token_start, position),
  })
  state.stack[#state.stack] = nil
  if #state.stack == 0 then state.root_closed = true end
  state.position = position + 1
end

local function parse_comment(state)
  local text = state.decoded.text
  local token_start = state.position
  local close = text:find("-->", token_start + 4, true)
  if not close then raise("xml.malformed-comment", "unclosed XML comment") end
  local value = text:sub(token_start + 4, close - 1)
  if value:find("--", 1, true) or value:sub(-1) == "-" then
    raise("xml.malformed-comment", "XML comment contains forbidden hyphens")
  end
  emit(state, {
    kind = "comment",
    parent_id = state.stack[#state.stack] and
      state.stack[#state.stack].event.id or nil,
    value = value,
    range = original_range(state.decoded, token_start, close + 2),
  })
  state.position = close + 3
end

local function parse_cdata(state)
  if #state.stack == 0 then
    raise("xml.cdata-outside-root", "CDATA is not allowed outside the root")
  end
  local text = state.decoded.text
  local token_start = state.position
  local close = text:find("]]>", token_start + 9, true)
  if not close then raise("xml.malformed-cdata", "unclosed CDATA section") end
  emit(state, {
    kind = "cdata",
    parent_id = state.stack[#state.stack].event.id,
    value = text:sub(token_start + 9, close - 1),
    range = original_range(state.decoded, token_start, close + 2),
  })
  state.position = close + 3
end

local function parse_pi(state)
  local text = state.decoded.text
  local token_start = state.position
  local close = text:find("?>", token_start + 2, true)
  if not close then raise("xml.malformed-pi", "unclosed processing instruction") end
  local position = token_start + 2
  local target, next_at = read_name(text, position)
  if not target then raise("xml.malformed-pi", "processing instruction needs a target") end
  if target:lower() == "xml" then
    if token_start ~= 1 and target == "xml" then
      raise("xml.misplaced-declaration", "XML declaration is misplaced")
    end
    raise("xml.reserved-pi-target", "processing-instruction target xml is reserved")
  end
  local data = ""
  if next_at < close then
    if not is_space(text:sub(next_at, next_at)) then
      raise("xml.malformed-pi", "processing-instruction data needs whitespace")
    end
    data = text:sub(skip_space(text, next_at), close - 1)
  end
  emit(state, {
    kind = "pi",
    parent_id = state.stack[#state.stack] and
      state.stack[#state.stack].event.id or nil,
    target = target,
    value = data,
    range = original_range(state.decoded, token_start, close + 1),
  })
  state.position = close + 2
end

local function parse_text(state)
  local text = state.decoded.text
  local token_start = state.position
  local next_markup = text:find("<", token_start, true) or (#text + 1)
  local raw_value = text:sub(token_start, next_markup - 1)
  if raw_value:find("]]>", 1, true) then
    raise("xml.malformed-token", "ordinary text contains CDATA close delimiter")
  end
  local value = decode_references(raw_value, {
    offset = original_boundary(state.decoded, token_start),
  })
  if #state.stack == 0 then
    if value:find("[^%s]") then
      raise("xml.text-outside-root", "non-whitespace text is outside the root")
    end
  elseif raw_value ~= "" then
    emit(state, {
      kind = "text",
      parent_id = state.stack[#state.stack].event.id,
      value = value,
      range = original_range(state.decoded, token_start, next_markup - 1),
    })
  end
  state.position = next_markup
end

function M.parse(bytes, options)
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
  verify_declared_encoding(decoded.encoding, declaration)

  local state = {
    decoded = decoded,
    declaration = declaration,
    position = position,
    events = {},
    stack = {},
    root = nil,
    root_closed = false,
    token_count = 0,
    next_id = 0,
    limits = limits,
  }
  local text = decoded.text
  while state.position <= #text do
    if text:sub(state.position, state.position + 3) == "<!--" then
      parse_comment(state)
    elseif text:sub(state.position, state.position + 8) == "<![CDATA[" then
      parse_cdata(state)
    elseif text:sub(state.position, state.position + 8):upper() == "<!DOCTYPE" then
      raise("xml.doctype-forbidden", "DOCTYPE is forbidden")
    elseif text:sub(state.position, state.position + 1) == "<?" then
      parse_pi(state)
    elseif text:sub(state.position, state.position + 1) == "</" then
      parse_end_tag(state)
    elseif text:sub(state.position, state.position) == "<" then
      if text:sub(state.position, state.position + 1) == "<!" then
        raise("xml.malformed-token", "unsupported XML declaration")
      end
      parse_start_tag(state)
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
  }
end

local function find_element(document, selector)
  local occurrence = selector.occurrence or 1
  local count = 0
  for _, event in ipairs(document.events) do
    if event.kind == "start" and event.name.uri == selector.uri and
        event.name.local_name == selector.local_name then
      count = count + 1
      if count == occurrence then return event end
    end
  end
  raise("xml.edit-target", "XML edit element was not found", {
    namespace_uri = selector.uri,
    local_name = selector.local_name,
    occurrence = occurrence,
  })
end

local function locate_change(document, change)
  local element = find_element(document, change.element)
  if change.operation == "attribute" then
    assert(type(change.attribute) == "table", "attribute selector is required")
    for _, attribute in ipairs(element.attributes) do
      if attribute.name.uri == change.attribute.uri and
          attribute.name.local_name == change.attribute.local_name then
        return attribute
      end
    end
    raise("xml.edit-target", "XML edit attribute was not found", {
      namespace_uri = change.attribute.uri,
      local_name = change.attribute.local_name,
    })
  elseif change.operation == "text" then
    local direct_text = {}
    local disallowed = false
    for _, event in ipairs(document.events) do
      if event.parent_id == element.id then
        if event.kind == "text" then
          direct_text[#direct_text + 1] = event
        elseif event.kind == "start" or event.kind == "cdata" then
          disallowed = true
        end
      end
    end
    if disallowed or #direct_text ~= 1 then
      raise("xml.edit-target", "element lacks one sole ordinary-text token", {
        text_tokens = #direct_text,
      })
    end
    return direct_text[1]
  end
  raise("xml.edit-target", "unsupported XML edit operation", {
    operation = change.operation,
  })
end

function M.find_edit_range(document, change)
  local target = locate_change(document, change)
  return target.value_range or target.range
end

local function semantic_signature(document)
  local events = {}
  for _, event in ipairs(document.events) do
    local row = {
      kind = event.kind,
      parent_id = event.parent_id,
      depth = event.depth,
    }
    if event.name then
      row.name = {
        uri = event.name.uri,
        local_name = event.name.local_name,
      }
    end
    if event.kind == "start" then
      row.namespace_bindings = copy_map(event.namespace_bindings)
      row.attributes = {}
      for _, attribute in ipairs(event.attributes) do
        row.attributes[#row.attributes + 1] = {
          name = {
            uri = attribute.name.uri,
            local_name = attribute.name.local_name,
          },
          value = attribute.value,
        }
      end
    elseif event.kind == "pi" then
      row.target = event.target
      row.value = event.value
    elseif event.value ~= nil then
      row.value = event.value
    end
    events[#events + 1] = row
  end
  return events
end

local function deep_equal(left, right, seen)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  seen = seen or {}
  if seen[left] == right then return true end
  seen[left] = right
  for key, value in pairs(left) do
    if not deep_equal(value, right[key], seen) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function verify_outside_bytes(original, edited, range)
  local suffix_length = #original - range.finish
  local edited_finish = #edited - suffix_length
  if edited_finish < range.start or
      original:sub(1, range.start) ~= edited:sub(1, range.start) or
      original:sub(range.finish + 1) ~= edited:sub(edited_finish + 1) then
    raise("xml.outside-bytes", "bytes outside the XML edit range changed", {
      start = range.start,
      finish = range.finish,
    })
  end
end

function M.verify_edit(original, edited, golden_range, expected_change)
  assert(type(original) == "string" and type(edited) == "string",
    "verify_edit requires byte strings")
  assert(type(golden_range) == "table", "golden edit range is required")
  assert(type(expected_change) == "table", "expected change is required")
  if not common.same_range(golden_range, expected_change.reported_range) then
    raise("xml.edit-range", "reported XML edit range differs from golden range", {
      golden_start = golden_range.start,
      golden_finish = golden_range.finish,
      reported_start = expected_change.reported_range and
        expected_change.reported_range.start or nil,
      reported_finish = expected_change.reported_range and
        expected_change.reported_range.finish or nil,
    })
  end
  verify_outside_bytes(original, edited, golden_range)

  local original_document = M.parse(original)
  local original_target = locate_change(original_document, expected_change)
  local actual_range = original_target.value_range or original_target.range
  if not common.same_range(actual_range, golden_range) then
    raise("xml.edit-range", "oracle source range differs from golden range", {
      golden_start = golden_range.start,
      golden_finish = golden_range.finish,
      oracle_start = actual_range.start,
      oracle_finish = actual_range.finish,
    })
  end

  local edited_document = M.parse(edited)
  local edited_target = locate_change(edited_document, expected_change)
  if edited_target.value ~= expected_change.value then
    raise("xml.semantic-change", "edited XML has the wrong requested value", {
      expected = expected_change.value,
      actual = edited_target.value,
    })
  end
  local replacement_value = edited_target.value
  edited_target.value = original_target.value
  local same = deep_equal(
    semantic_signature(original_document),
    semantic_signature(edited_document))
  edited_target.value = replacement_value
  if not same then
    raise("xml.semantic-change",
      "edited XML changed full-part semantics outside the requested value")
  end
  return {
    ok = true,
    original = original_document,
    edited = edited_document,
  }
end

return M
