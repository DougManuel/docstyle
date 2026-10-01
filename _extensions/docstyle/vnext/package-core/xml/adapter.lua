-- WP2 package core: LuaXML adapter for the bounded OPC XML seam.
local diagnostic = require("lib.diagnostic")
local strictness = require("xml.strictness")
local overlay = require("xml.token_overlay")
local luaxml = require("xml.vendor.luaxml-mod-xml")

local M = {}

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function assert_document(document)
  if type(document) ~= "table" or type(document.nodes) ~= "table" or
      type(document.source) ~= "string" then
    raise("xml.invalid-document", "LuaXML adapter document is invalid")
  end
end

local function assert_node(node)
  if type(node) ~= "table" or type(node.document) ~= "table" or
      type(node.name) ~= "table" then
    raise("xml.invalid-node", "LuaXML adapter node is invalid")
  end
  assert_document(node.document)
end

local function matching_attribute(node, namespace_uri, local_name)
  for _, attribute in ipairs(node.attributes) do
    if attribute.name.uri == namespace_uri and
        attribute.name.local_name == local_name then
      return attribute
    end
  end
  return nil
end

local function register_edit(document, target, range, replacement, value)
  document.edits = document.edits or {}
  for _, existing in ipairs(document.edits) do
    if existing.target == target then
      raise("xml.edit-target", "a token may be edited at most once")
    end
  end
  document.edits[#document.edits + 1] = {
    target = target,
    seq = #document.edits + 1,
    range = range,
    replacement = replacement,
    value = value,
  }
end

M.MAX_INPUT_BYTES = 8 * 1024 * 1024  -- XML-part input-byte limit (raised from 1 MiB by #53; WP2 design)

function M.parse(xml_bytes, options)
  if type(xml_bytes) ~= "string" then
    raise("xml.invalid-input", "XML input must be a byte string", {
      input_type = type(xml_bytes),
    })
  end
  options = options or {}
  local limit = options.max_input_bytes
  if limit == nil then
    limit = M.MAX_INPUT_BYTES
  elseif math.type(limit) ~= "integer" or limit < 0 then
    raise("xml.invalid-limit",
      "max_input_bytes must be a non-negative integer", {
        option = "max_input_bytes",
        value = limit,
      })
  end
  if #xml_bytes > limit then
    raise("xml.input-too-large",
      "XML part exceeds the input-byte limit; rejected before parsing", {
        actual = #xml_bytes,
        limit = limit,
      })
  end
  local strict_document = strictness.inspect(xml_bytes, options)
  local backend_events = overlay.luaxml_events(
    luaxml, strict_document.semantic_xml)
  return overlay.bind(
    xml_bytes, strict_document, backend_events, "dev@c919471")
end

function M.find_all(document, namespace_uri, local_name)
  assert_document(document)
  if type(namespace_uri) ~= "string" or type(local_name) ~= "string" or
      local_name == "" then
    raise("xml.invalid-selector", "expanded-name selector is invalid")
  end
  local matches = {}
  for _, node in ipairs(document.nodes) do
    if node.name.uri == namespace_uri and
        node.name.local_name == local_name then
      matches[#matches + 1] = node
    end
  end
  return matches
end

function M.get_attribute(node, namespace_uri, local_name)
  assert_node(node)
  if type(namespace_uri) ~= "string" or type(local_name) ~= "string" or
      local_name == "" then
    raise("xml.invalid-selector", "attribute selector is invalid")
  end
  local attribute = matching_attribute(node, namespace_uri, local_name)
  return attribute and attribute.value or nil
end

function M.set_attribute(node, namespace_uri, local_name, new_value)
  assert_node(node)
  if type(new_value) ~= "string" then
    raise("xml.invalid-input", "replacement attribute value must be a string")
  end
  local attribute = matching_attribute(node, namespace_uri, local_name)
  if not attribute then
    raise("xml.edit-target", "XML edit attribute was not found", {
      namespace_uri = namespace_uri,
      local_name = local_name,
    })
  end
  local replacement = overlay.attribute_replacement(
    attribute, new_value, node.document.encoding)
  register_edit(node.document, attribute, attribute.value_range,
    replacement, new_value)
  attribute.value = new_value
end

function M.replace_text(node, new_text)
  assert_node(node)
  if type(new_text) ~= "string" then
    raise("xml.invalid-input", "replacement text must be a string")
  end
  if node.has_element_child or node.has_cdata or #node.direct_text ~= 1 then
    raise("xml.edit-target", "element lacks one sole ordinary-text token", {
      text_tokens = #node.direct_text,
    })
  end
  local text = node.direct_text[1]
  local replacement = overlay.text_replacement(
    new_text, node.document.encoding)
  register_edit(node.document, text, text.range, replacement, new_text)
  text.value = new_text
end

function M.append_element(node, local_name, attributes)
  assert_node(node)
  local document = node.document
  -- Validate the local name against the XML Name production WITHOUT a
  -- colon (an NCName): the child's prefix comes from the parent, never the
  -- caller.
  if type(local_name) ~= "string" or
      not strictness.is_ncname(local_name) then
    raise("xml.invalid-input", "element name must be a valid NCName", {
      name = tostring(local_name),
    })
  end
  if not node.end_tag_range then
    raise("xml.edit-target",
      "append_element requires an element with a separate end tag", {})
  end
  -- Reuse the validated parent's namespace prefix, so the child lands in
  -- the parent's namespace whether the manifest root is prefixed
  -- (<ct:Types>) or default-namespaced (<Types xmlns="…">).
  -- An unprefixed element's prefix is the empty string, which is truthy in
  -- Lua: the check must be explicitly non-empty or the child name becomes
  -- ":Override".
  local prefix = node.name.prefix or ""
  local child_name = prefix ~= "" and
    (prefix .. ":" .. local_name) or local_name
  if attributes ~= nil and type(attributes) ~= "table" then
    raise("xml.invalid-input", "attributes must be a list", {})
  end
  local pieces = { "<", child_name }
  -- The child declares no namespaces, so its attributes resolve in the
  -- parent's scope. Reject anything the strict layer would refuse on
  -- reparse, and namespace declarations, which would move the child out of
  -- the parent's namespace.
  local bindings = node.namespace_bindings or {}
  local expanded = {}
  for _, attribute in ipairs(attributes or {}) do
    if type(attribute) ~= "table" then
      raise("xml.invalid-input", "each attribute must be a record", {})
    end
    if type(attribute.name) ~= "string" or
        not strictness.is_qname(attribute.name) then
      raise("xml.invalid-input",
        "attribute name must be a valid qualified name", {
          name = tostring(attribute.name),
        })
    end
    local attribute_prefix, attribute_local =
      attribute.name:match("^([^:]+):(.+)$")
    if attribute.name == "xmlns" or attribute_prefix == "xmlns" then
      raise("xml.invalid-input",
        "append_element cannot add namespace declarations", {
          name = attribute.name,
        })
    end
    local uri = ""
    if attribute_prefix then
      uri = bindings[attribute_prefix]
      if uri == nil then
        raise("xml.unbound-prefix",
          "attribute prefix is not bound at the parent", {
            name = attribute.name,
          })
      end
    end
    local key = uri .. "\0" .. (attribute_local or attribute.name)
    if expanded[key] then
      raise("xml.duplicate-attribute", "duplicate expanded-name attribute", {
        name = attribute.name,
      })
    end
    expanded[key] = true
    if type(attribute.value) ~= "string" then
      raise("xml.invalid-input", "attribute value must be a string", {
        name = attribute.name,
      })
    end
    pieces[#pieces + 1] = (' %s="%s"'):format(
      attribute.name, overlay.escape_attribute(attribute.value, '"'))
  end
  pieces[#pieces + 1] = "/>"
  -- Encode the complete insertion into the document's recorded encoding
  -- before registration -- exactly how attribute_replacement and
  -- text_replacement thread node.document.encoding. A raw UTF-8 splice
  -- corrupts UTF-16 parts.
  local replacement = overlay.encode_insertion(
    table.concat(pieces), document.encoding)
  local offset = node.end_tag_range.start
  register_edit(document, { insertion = true, at = offset },
    { start = offset, finish = offset }, replacement)
end

function M.serialize(document)
  assert_document(document)
  return overlay.serialize(document)
end

M.result = {
  candidate = "LuaXML",
  version = "dev@c919471",
  dependency_count = 1,
  vendored_lines = 570,
  docstyle_owned_lines = 1501,
  unsupported_constructs = {
    "DTD and custom entity expansion",
    "XInclude processing",
    "character encodings other than UTF-8 and UTF-16",
  },
  compensated_backend_limitations = {
    "attribute names are lowercased and attribute order is discarded",
    "namespace URIs are not reported",
    "numeric references above byte range are not expanded",
    "whole-tree serialization does not preserve lexical bytes",
  },
  hard_gate_status = "pass",
  hard_gate_failures = {},
  rejected_fixture_rows = {},
}

return M
