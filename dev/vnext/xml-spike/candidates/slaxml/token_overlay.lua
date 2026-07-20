local common = require("candidates.common")
local diagnostic = require("lib.diagnostic")
local strictness = require("candidates.slaxml.strictness")

local M = {}

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function normalize_uri(uri)
  return uri or ""
end

local function is_namespace_declaration(name, prefix)
  return name == "xmlns" or prefix == "xmlns" or
    name:sub(1, 6) == "xmlns:"
end

function M.slaxml_events(slaxml, xml)
  local events, stack = {}, {}
  local callbacks = {}

  function callbacks.startElement(name, uri, prefix)
    local parent = stack[#stack]
    local event = {
      kind = "start",
      name = common.expanded_name(normalize_uri(uri), name, prefix),
      attributes = {},
      parent = parent,
    }
    events[#events + 1] = event
    stack[#stack + 1] = event
  end

  function callbacks.attribute(name, value, uri, prefix)
    if is_namespace_declaration(name, prefix) then return end
    local owner = assert(stack[#stack], "SLAXML attribute lacks an owner")
    owner.attributes[#owner.attributes + 1] = {
      name = common.expanded_name(normalize_uri(uri), name, prefix),
      value = value,
    }
  end

  function callbacks.text(value, cdata)
    local parent = stack[#stack]
    if not parent and value:find("[^%s]") == nil then return end
    events[#events + 1] = {
      kind = cdata and "cdata" or "text",
      value = value,
      parent = parent,
    }
  end

  function callbacks.comment(value)
    events[#events + 1] = {
      kind = "comment",
      value = value,
      parent = stack[#stack],
    }
  end

  function callbacks.pi(target, value)
    if target == "xml" and #stack == 0 then return end
    events[#events + 1] = {
      kind = "pi",
      target = target,
      value = value,
      parent = stack[#stack],
    }
  end

  function callbacks.closeElement()
    local current = assert(stack[#stack], "SLAXML close lacks an open element")
    events[#events + 1] = {
      kind = "end",
      name = current.name,
      parent = current.parent,
    }
    stack[#stack] = nil
  end

  local parser = slaxml:parser(callbacks)
  local ok, err = pcall(function()
    parser:parse(xml, { stripWhitespace = false })
  end)
  if not ok then
    raise("xml.backend-rejected", "SLAXML rejected strictly validated XML", {
      detail = tostring(err),
    })
  end
  if #stack ~= 0 then
    raise("xml.backend-mismatch", "SLAXML event hierarchy remained open")
  end
  return events
end

local function same_name(left, right)
  return left and right and left.uri == right.uri and
    left.local_name == right.local_name
end

local function assert_event_match(strict_event, backend_event, index)
  if not backend_event or strict_event.kind ~= backend_event.kind then
    raise("xml.backend-mismatch", "SLAXML event kind differs from overlay", {
      index = index,
      strict_kind = strict_event.kind,
      backend_kind = backend_event and backend_event.kind or nil,
    })
  end
  if strict_event.name and not same_name(strict_event.name, backend_event.name) then
    raise("xml.backend-mismatch", "SLAXML expanded name differs from overlay", {
      index = index,
    })
  end
  if strict_event.kind == "start" then
    if #strict_event.attributes ~= #backend_event.attributes then
      raise("xml.backend-mismatch", "SLAXML attribute count differs from overlay", {
        index = index,
      })
    end
    for attribute_index, strict_attribute in ipairs(strict_event.attributes) do
      local backend_attribute = backend_event.attributes[attribute_index]
      if not same_name(strict_attribute.name, backend_attribute.name) or
          strict_attribute.value ~= backend_attribute.value then
        raise("xml.backend-mismatch",
          "SLAXML attribute semantics differ from overlay", {
            index = index,
            attribute_index = attribute_index,
          })
      end
    end
  elseif strict_event.kind == "pi" then
    if strict_event.target ~= backend_event.target or
        strict_event.value ~= backend_event.value then
      raise("xml.backend-mismatch", "SLAXML processing instruction differs")
    end
  elseif strict_event.value ~= nil and
      strict_event.value ~= backend_event.value then
    raise("xml.backend-mismatch", "SLAXML text semantics differ from overlay", {
      index = index,
    })
  end
end

function M.bind(source, strict_document, backend_events, version)
  if #strict_document.events ~= #backend_events then
    raise("xml.backend-mismatch", "SLAXML event count differs from overlay", {
      strict_count = #strict_document.events,
      backend_count = #backend_events,
    })
  end
  local document = {
    source = source,
    encoding = strict_document.encoding,
    bom = strict_document.bom,
    declaration = strict_document.declaration,
    token_count = strict_document.token_count,
    slaxml_version = version,
    nodes = {},
    events = backend_events,
    edit = nil,
  }
  local nodes_by_id = {}
  for index, strict_event in ipairs(strict_document.events) do
    local backend_event = backend_events[index]
    assert_event_match(strict_event, backend_event, index)
    if strict_event.kind == "start" then
      local node = {
        document = document,
        id = strict_event.id,
        parent_id = strict_event.parent_id,
        name = backend_event.name,
        range = strict_event.range,
        attributes = {},
        direct_text = {},
        has_element_child = false,
        has_cdata = false,
      }
      for attribute_index, strict_attribute in
          ipairs(strict_event.attributes) do
        local backend_attribute = backend_event.attributes[attribute_index]
        node.attributes[#node.attributes + 1] = {
          owner = node,
          name = backend_attribute.name,
          value = backend_attribute.value,
          quote = strict_attribute.quote,
          value_range = strict_attribute.value_range,
        }
      end
      document.nodes[#document.nodes + 1] = node
      nodes_by_id[node.id] = node
      if node.parent_id then
        nodes_by_id[node.parent_id].has_element_child = true
      else
        document.root = node
      end
      backend_event.node = node
    elseif strict_event.kind == "text" then
      local parent = assert(nodes_by_id[strict_event.parent_id])
      parent.direct_text[#parent.direct_text + 1] = {
        owner = parent,
        value = backend_event.value,
        range = strict_event.range,
      }
    elseif strict_event.kind == "cdata" then
      nodes_by_id[strict_event.parent_id].has_cdata = true
    end
  end
  return document
end

local function replace_range(source, range, replacement)
  return source:sub(1, range.start) .. replacement ..
    source:sub(range.finish + 1)
end

local function escape_attribute(value, quote)
  local escaped = value:gsub("&", "&amp;"):gsub("<", "&lt;")
  escaped = escaped:gsub("\t", "&#x9;")
    :gsub("\n", "&#xA;")
    :gsub("\r", "&#xD;")
  if quote == "'" then
    return escaped:gsub("'", "&apos;")
  end
  return escaped:gsub("\"", "&quot;")
end

local function escape_text(value)
  local escaped = value:gsub("&", "&amp;"):gsub("<", "&lt;")
  escaped = escaped:gsub("\r", "&#xD;")
  return escaped:gsub("%]%]>", "]]&gt;")
end

function M.attribute_replacement(attribute, value, encoding)
  return strictness.encode(escape_attribute(value, attribute.quote), encoding)
end

function M.text_replacement(value, encoding)
  return strictness.encode(escape_text(value), encoding)
end

function M.serialize(document)
  if not document.edit then return document.source, {} end
  local edit = document.edit
  return replace_range(document.source, edit.range, edit.replacement), {
    common.range(edit.range.start, edit.range.finish),
  }
end

return M
