local diagnostic = require("lib.diagnostic")
local strictness = require("candidates.slaxml.strictness")
local overlay = require("candidates.slaxml.token_overlay")
local slaxml = require("candidates.slaxml.vendor.slaxml")

local M = {}

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function assert_document(document)
  if type(document) ~= "table" or type(document.nodes) ~= "table" or
      type(document.source) ~= "string" then
    raise("xml.invalid-document", "SLAXML adapter document is invalid")
  end
end

local function assert_node(node)
  if type(node) ~= "table" or type(node.document) ~= "table" or
      type(node.name) ~= "table" then
    raise("xml.invalid-node", "SLAXML adapter node is invalid")
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
  if document.edit and document.edit.target ~= target then
    raise("xml.edit-target", "the spike adapter permits one owned edit")
  end
  document.edit = {
    target = target,
    range = range,
    replacement = replacement,
    value = value,
  }
end

function M.parse(xml_bytes, options)
  local strict_document = strictness.inspect(xml_bytes, options)
  local backend_events = overlay.slaxml_events(
    slaxml, strict_document.semantic_xml)
  return overlay.bind(
    xml_bytes, strict_document, backend_events, slaxml.VERSION)
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

function M.serialize(document)
  assert_document(document)
  return overlay.serialize(document)
end

M.result = {
  candidate = "SLAXML",
  version = "0.8",
  dependency_count = 1,
  vendored_lines = 259,
  docstyle_owned_lines = 1267,
  unsupported_constructs = {
    "DTD and custom entity expansion",
    "XInclude processing",
    "character encodings other than UTF-8 and UTF-16",
    "Unicode element and attribute names in the SLAXML semantic backend",
  },
  rejected_fixture_rows = {},
}

return M
