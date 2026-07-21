-- LuaXML-specific semantic cross-check and byte-preserving overlay.
local common = require("candidates.common")
local diagnostic = require("lib.diagnostic")
local strictness = require("candidates.luaxml.strictness")

local M = {}

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

function M.luaxml_events(luaxml, xml)
  local events, stack = {}, {}
  local handler = {}

  function handler:starttag(qname)
    events[#events + 1] = {
      kind = "start",
      qname = qname,
    }
    stack[#stack + 1] = qname
  end

  function handler:endtag(qname)
    events[#events + 1] = {
      kind = "end",
      qname = qname,
    }
    stack[#stack] = nil
  end

  function handler:text(value)
    if #stack == 0 and value:find("[^%s]") == nil then return end
    events[#events + 1] = {
      kind = "text",
      value = value,
    }
  end

  function handler:comment(value)
    events[#events + 1] = {
      kind = "comment",
      value = value,
    }
  end

  function handler:cdata(value)
    events[#events + 1] = {
      kind = "cdata",
      value = value,
    }
  end

  function handler:pi(target, attributes)
    local value = attributes and attributes._text or ""
    value = value:gsub("^%s+", "")
    events[#events + 1] = {
      kind = "pi",
      target = target,
      value = value,
    }
  end

  function handler:decl()
    -- The strictness layer validates and retains the XML declaration.
  end

  local parser = luaxml.xmlParser(handler)
  parser.options.stripWS = nil
  parser.options.expandEntities = nil
  local ok, err = pcall(function()
    parser:parse(xml)
  end)
  if not ok then
    raise("xml.backend-rejected",
      "LuaXML rejected strictly validated XML", {
        detail = tostring(err),
      })
  end
  if #stack ~= 0 then
    raise("xml.backend-mismatch",
      "LuaXML event hierarchy remained open")
  end
  return events
end

local function assert_event_match(strict_event, backend_event, index)
  if not backend_event or strict_event.kind ~= backend_event.kind then
    raise("xml.backend-mismatch", "LuaXML event kind differs from overlay", {
      index = index,
      strict_kind = strict_event.kind,
      backend_kind = backend_event and backend_event.kind or nil,
    })
  end
  if strict_event.qname and strict_event.qname ~= backend_event.qname then
    raise("xml.backend-mismatch", "LuaXML qualified name differs from overlay", {
      index = index,
      strict_qname = strict_event.qname,
      backend_qname = backend_event.qname,
    })
  end
  if strict_event.kind == "pi" then
    if strict_event.target ~= backend_event.target or
        strict_event.value ~= backend_event.value then
      raise("xml.backend-mismatch",
        "LuaXML processing instruction differs from overlay", {
          index = index,
        })
    end
  elseif (strict_event.kind == "comment" or
      strict_event.kind == "cdata") and
      strict_event.value ~= backend_event.value then
    raise("xml.backend-mismatch",
      "LuaXML lexical token differs from overlay", {
        index = index,
      })
  end
end

function M.bind(source, strict_document, backend_events, version)
  if #strict_document.events ~= #backend_events then
    raise("xml.backend-mismatch", "LuaXML event count differs from overlay", {
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
    luaxml_version = version,
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
        name = strict_event.name,
        range = strict_event.range,
        attributes = {},
        direct_text = {},
        has_element_child = false,
        has_cdata = false,
      }
      for _, strict_attribute in ipairs(strict_event.attributes) do
        node.attributes[#node.attributes + 1] = {
          owner = node,
          name = strict_attribute.name,
          value = strict_attribute.value,
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
        value = strict_event.value,
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
