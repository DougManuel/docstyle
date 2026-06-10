-- field-code-utils.lua
-- Shared utilities for ADDIN DOCSTYLE field code generation
--
-- This module provides:
-- 1. Schema loading from inst/schema/docstyle-field-codes.json
-- 2. XML and JSON escaping functions
-- 3. Field code XML builders for all types (char, div, list, section)
--
-- All Lua filters should require this module instead of reimplementing
-- these functions locally.

local M = {}

-- Current schema version (must match R's DOCSTYLE_SCHEMA_VERSION)
-- v3: Anchor positioning - unified float/anchor model with content-aware assembly
M.SCHEMA_VERSION = 3

-- Debug logging (set DOCSTYLE_DEBUG=1 to enable)
local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function log_debug(msg)
  if DEBUG then
    io.stderr:write("[field-code-utils] " .. msg .. "\n")
  end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Schema Loading
-- ═══════════════════════════════════════════════════════════════════════════

-- Cached schema (loaded once per filter run)
local cached_schema = nil

-- Find the schema file path relative to the extension directory
local function find_schema_path()
  -- Try multiple locations:
  -- 1. Installed R package: system.file("schema/docstyle-field-codes.json", package = "docstyle")
  -- 2. Development: relative to _extensions/docstyle/
  -- 3. Quarto extension: QUARTO_PROJECT_DIR/_extensions/docstyle/../../inst/schema/

  local paths_to_try = {}

  -- Get the directory of this Lua file
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    local lua_dir = source:sub(2):match("(.*/)")
    if lua_dir then
      -- Development layout: _extensions/docstyle/ -> ../../inst/schema/
      table.insert(paths_to_try, lua_dir .. "../../inst/schema/docstyle-field-codes.json")
      -- Installed extension layout (schema copied to extension dir)
      table.insert(paths_to_try, lua_dir .. "docstyle-field-codes.json")
    end
  end

  -- Try QUARTO_PROJECT_DIR
  local project_dir = os.getenv("QUARTO_PROJECT_DIR")
  if project_dir then
    table.insert(paths_to_try, project_dir .. "/_extensions/docstyle/docstyle-field-codes.json")
    table.insert(paths_to_try, project_dir .. "/inst/schema/docstyle-field-codes.json")
  end

  for _, path in ipairs(paths_to_try) do
    local f = io.open(path, "r")
    if f then
      f:close()
      log_debug("Found schema at: " .. path)
      return path
    end
  end

  return nil
end

-- Simple JSON parser for our schema (handles objects, arrays, strings, numbers, booleans)
-- This avoids requiring external JSON libraries in Pandoc Lua filters
local function parse_json(str)
  local pos = 1
  local function skip_whitespace()
    pos = str:match("^%s*()", pos)
  end

  local function parse_value()
    skip_whitespace()
    local c = str:sub(pos, pos)

    if c == '"' then
      -- String
      local start = pos + 1
      pos = pos + 1
      while pos <= #str do
        local ch = str:sub(pos, pos)
        if ch == '"' then
          local result = str:sub(start, pos - 1)
          pos = pos + 1
          -- Unescape basic sequences
          result = result:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
          return result
        elseif ch == "\\" then
          pos = pos + 2
        else
          pos = pos + 1
        end
      end
    elseif c == "{" then
      -- Object
      pos = pos + 1
      local obj = {}
      skip_whitespace()
      if str:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip_whitespace()
        local key = parse_value()
        skip_whitespace()
        pos = pos + 1  -- skip ':'
        local value = parse_value()
        obj[key] = value
        skip_whitespace()
        local sep = str:sub(pos, pos)
        pos = pos + 1
        if sep == "}" then break end
      end
      return obj
    elseif c == "[" then
      -- Array
      pos = pos + 1
      local arr = {}
      skip_whitespace()
      if str:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        table.insert(arr, parse_value())
        skip_whitespace()
        local sep = str:sub(pos, pos)
        pos = pos + 1
        if sep == "]" then break end
      end
      return arr
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      -- Number
      local num_str = str:match("^-?%d+%.?%d*", pos)
      if num_str then
        pos = pos + #num_str
        return tonumber(num_str)
      end
    end
    error("JSON parse error at position " .. pos .. ": " .. str:sub(pos, pos + 20))
  end

  return parse_value()
end

-- Load and cache the schema
function M.load_schema()
  if cached_schema then
    return cached_schema
  end

  local schema_path = find_schema_path()
  if not schema_path then
    log_debug("Schema file not found, using built-in defaults")
    -- Return minimal built-in schema as fallback
    cached_schema = {
      schema_version = M.SCHEMA_VERSION,
      char_classes = {},
      div_types = {},
      list_classes = {}
    }
    return cached_schema
  end

  local f = io.open(schema_path, "r")
  if not f then
    log_debug("Could not open schema file: " .. schema_path)
    return nil
  end

  local content = f:read("*a")
  f:close()

  local ok, schema = pcall(parse_json, content)
  if not ok then
    log_debug("Failed to parse schema JSON: " .. tostring(schema))
    return nil
  end

  cached_schema = schema
  log_debug("Loaded schema version " .. (schema.schema_version or "unknown"))
  return cached_schema
end

-- Get char class definition from schema
function M.get_char_class(class)
  local schema = M.load_schema()
  if schema and schema.char_classes then
    return schema.char_classes[class]
  end
  return nil
end

-- Get div type definition from schema
function M.get_div_type(name)
  local schema = M.load_schema()
  if schema and schema.div_types then
    return schema.div_types[name]
  end
  return nil
end

-- Get list class definition from schema
function M.get_list_class(class)
  local schema = M.load_schema()
  if schema and schema.list_classes then
    return schema.list_classes[class]
  end
  return nil
end

-- Get table class definition from schema
function M.get_table_class(class)
  local schema = M.load_schema()
  if schema and schema.table_classes then
    return schema.table_classes[class]
  end
  return nil
end


-- ═══════════════════════════════════════════════════════════════════════════
-- Escaping Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- Escape XML special characters for use in OOXML content
function M.xml_escape(text)
  if not text then return "" end
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  text = text:gsub('"', "&quot;")
  text = text:gsub("'", "&apos;")
  return text
end

-- Escape a string for use inside a JSON string value
-- Handles backslash and double-quote
function M.json_escape(text)
  if not text then return "" end
  text = text:gsub('\\', '\\\\')
  text = text:gsub('"', '\\"')
  return text
end


-- ═══════════════════════════════════════════════════════════════════════════
-- Field Code Builders
-- ═══════════════════════════════════════════════════════════════════════════

-- Build JSON payload for field code instrText
-- @param payload_type: "char", "div", "list", or "section"
-- @param fields: table of additional fields to include
-- @return JSON string (not XML-escaped)
function M.build_payload_json(payload_type, fields)
  local parts = {}
  table.insert(parts, '"type":"' .. M.json_escape(payload_type) .. '"')
  table.insert(parts, '"version":' .. M.SCHEMA_VERSION)

  for key, value in pairs(fields) do
    if type(value) == "string" then
      table.insert(parts, '"' .. key .. '":"' .. M.json_escape(value) .. '"')
    elseif type(value) == "number" then
      table.insert(parts, '"' .. key .. '":' .. value)
    elseif type(value) == "boolean" then
      table.insert(parts, '"' .. key .. '":' .. (value and "true" or "false"))
    end
  end

  return "{" .. table.concat(parts, ",") .. "}"
end

-- Build the QMD source string for a char class
-- Uses source_template from schema if available, otherwise builds explicit form
function M.build_char_source(class, text)
  local class_def = M.get_char_class(class)
  if class_def and class_def.source_template then
    return class_def.source_template
  else
    return "[" .. text .. "]{." .. class .. "}"
  end
end

-- Build complete ADDIN DOCSTYLE field code XML for char type
-- @param style_id: Word style ID (e.g., "Date")
-- @param text: Display text
-- @param class: CSS class name (e.g., "date")
-- @return OOXML string
function M.build_char_field_code(style_id, text, class)
  local source = M.build_char_source(class, text)
  local json = M.build_payload_json("char", {
    class = class,
    source = source
  })
  local json_xml = M.xml_escape(json)

  local display_run = '<w:r>' ..
    '<w:rPr><w:rStyle w:val="' .. M.xml_escape(style_id) .. '"/></w:rPr>' ..
    '<w:t xml:space="preserve">' .. M.xml_escape(text) .. '</w:t>' ..
    '</w:r>'

  return '<w:r><w:fldChar w:fldCharType="begin"/></w:r>' ..
         '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ' .. json_xml .. ' </w:instrText></w:r>' ..
         '<w:r><w:fldChar w:fldCharType="separate"/></w:r>' ..
         display_run ..
         '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
end

-- Build field code start marker for block types (div, list, section)
-- @param payload_type: "div", "list", or "section"
-- @param fields: payload fields (e.g., {name = "toc"} or {class = "list-alpha"})
-- @return OOXML paragraph string
function M.build_block_field_start(payload_type, fields)
  local json = M.build_payload_json(payload_type, fields)
  local json_xml = M.xml_escape(json)

  return '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>' ..
         '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ' .. json_xml .. ' </w:instrText></w:r>' ..
         '<w:r><w:fldChar w:fldCharType="separate"/></w:r></w:p>'
end

-- Build field code end marker for block types
-- @return OOXML paragraph string
function M.build_block_field_end()
  return '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
end

-- Convenience: Build div field code start
function M.build_div_field_start(name)
  return M.build_block_field_start("div", {name = name})
end

-- Convenience: Build list field code start
function M.build_list_field_start(class, start_num)
  local fields = {class = class}
  if start_num and start_num > 1 then
    fields.start = start_num
  end
  return M.build_block_field_start("list", fields)
end

-- Convenience: Build table field code start
-- @param class: table class (e.g., "table-formal")
-- @param attrs: optional attributes table (widths, width, font-size, etc.)
function M.build_table_field_start(class, attrs)
  local fields = {class = class}
  if attrs then
    for k, v in pairs(attrs) do
      fields[k] = v
    end
  end
  return M.build_block_field_start("table", fields)
end

-- Convenience: Build figure field code start
-- @param id: QMD figure ID (e.g. "fig-consort-flow")
-- @param attrs: optional attributes table (docpr_id, width, align, wrap, original_path)
function M.build_figure_field_start(id, attrs)
  local fields = {id = id}
  if attrs then
    for k, v in pairs(attrs) do
      fields[k] = v
    end
  end
  return M.build_block_field_start("figure", fields)
end

-- Convenience: Build section field code start
function M.build_section_field_start(class, attrs)
  local fields = {class = class}
  if attrs then
    for k, v in pairs(attrs) do
      fields[k] = v
    end
  end
  return M.build_block_field_start("section", fields)
end

-- Build complete section field code in a SINGLE paragraph for R-First Assembly.
-- This prevents the 3-line gap by emitting BEGIN/instrText/SEPARATE/marker/END
-- all in one paragraph rather than three separate paragraphs.
-- @param class: section class (e.g., "section-body")
-- @param attrs: optional attributes table
-- @param marker_text: the DOCSTYLE_SECTION::... marker text
-- @return OOXML paragraph string
function M.build_section_marker_para(class, attrs, marker_text)
  local fields = {class = class}
  if attrs then
    for k, v in pairs(attrs) do
      fields[k] = v
    end
  end
  local json = M.build_payload_json("section", fields)
  local json_xml = M.xml_escape(json)
  local marker_xml = M.xml_escape(marker_text)

  return '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>' ..
         '<w:r><w:fldChar w:fldCharType="begin"/></w:r>' ..
         '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ' .. json_xml .. ' </w:instrText></w:r>' ..
         '<w:r><w:fldChar w:fldCharType="separate"/></w:r>' ..
         '<w:r><w:t>' .. marker_xml .. '</w:t></w:r>' ..
         '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
end


-- ═══════════════════════════════════════════════════════════════════════════
-- Helper Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- Convert inline content to plain text (recursively handles nested spans)
function M.inlines_to_text(inlines)
  local text = ""
  for _, inline in ipairs(inlines) do
    if inline.t == "Str" then
      text = text .. inline.text
    elseif inline.t == "Space" then
      text = text .. " "
    elseif inline.t == "SoftBreak" then
      text = text .. " "
    elseif inline.t == "Span" then
      text = text .. M.inlines_to_text(inline.content)
    end
  end
  return text
end


-- ═══════════════════════════════════════════════════════════════════════════
-- Page Config Loading (shared across filters)
-- ═══════════════════════════════════════════════════════════════════════════

-- Cached page config (loaded once, shared by all filters in same render)
local cached_page_config = nil

--- Load page-config.json from _docstyle/ directory.
-- Returns the parsed config table, or nil if not found.
-- Result is cached so multiple filters reading the same file pay I/O once.
function M.load_page_config()
  if cached_page_config then return cached_page_config end

  local config_paths = {
    "_docstyle/page-config.json",
    "./_docstyle/page-config.json"
  }

  for _, path in ipairs(config_paths) do
    local file = io.open(path, "r")
    if file then
      local content = file:read("*a")
      file:close()
      local ok, config = pcall(function()
        return pandoc.json.decode(content)
      end)
      if ok and config then
        log_debug("Loaded page config from " .. path)
        cached_page_config = config
        return config
      end
    end
  end

  log_debug("No page-config.json found")
  return nil
end


-- ═══════════════════════════════════════════════════════════════════════════
-- Inline Renderer: Pandoc AST → OOXML runs
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Converts Pandoc inline elements to OOXML run XML strings.
-- Handles the pre-conversion AST forms present when table-style.lua runs
-- (before char-style.lua and comment-inject.lua in the filter chain).
--
-- base_rPr_parts: array of XML fragments to include in every <w:rPr>
--   e.g., {"<w:b/>", '<w:sz w:val="18"/>', '<w:szCs w:val="18"/>'}

-- Build <w:rPr>...</w:rPr> from an array of parts, or "" if empty
local function build_rPr(parts)
  if #parts == 0 then return "" end
  return "<w:rPr>" .. table.concat(parts) .. "</w:rPr>"
end

-- Build a single <w:r> with given rPr parts and text
local function build_text_run(rPr_parts, text)
  return "<w:r>" .. build_rPr(rPr_parts) ..
         '<w:t xml:space="preserve">' .. M.xml_escape(text) .. "</w:t></w:r>"
end

-- Char-style class → Word style ID (via schema, with minimal fallback)
local char_style_fallback = {
  date = "Date", version = "Version", author = "Author",
  affiliation = "Affiliation", sc = "SmallCaps"
}
local function get_char_style_id(class)
  local def = M.get_char_class(class)
  if def and def.word_style then return def.word_style end
  return char_style_fallback[class]
end

-- Parse comment marker from HTML text
-- Returns id and type ("start", "end", "point"), or nil
-- Exported as M.parse_comment_marker for use by comment-inject.lua
local function parse_comment_marker(text)
  if not text then return nil, nil end
  local start_id = text:match('<!%-%-%s*comment:start%s+id="([^"]+)"%s*%-%->')
  if start_id then return start_id, "start" end
  local end_id = text:match('<!%-%-%s*comment:end%s+id="([^"]+)"%s*%-%->')
  if end_id then return end_id, "end" end
  local point_id = text:match('<!%-%-%s*comment%s+id="([^"]+)"%s*%-%->')
  if point_id then return point_id, "point" end
  return nil, nil
end

-- Recurse into inline content with an extra rPr fragment appended
-- Returns array of XML strings
local function recurse_with_rPr(content, rPr_parts, extra_rPr)
  local new_rPr = {}
  for _, p in ipairs(rPr_parts) do table.insert(new_rPr, p) end
  if type(extra_rPr) == "table" then
    for _, e in ipairs(extra_rPr) do table.insert(new_rPr, e) end
  else
    table.insert(new_rPr, extra_rPr)
  end
  local results = {}
  for _, child in ipairs(content) do
    for _, xml in ipairs(render_inline(child, new_rPr)) do
      table.insert(results, xml)
    end
  end
  return results
end

-- Render a single Pandoc inline element to OOXML run(s)
-- Returns array of XML strings
local function render_inline(inline, rPr_parts)
  local results = {}

  if inline.t == "Str" then
    table.insert(results, build_text_run(rPr_parts, inline.text))

  elseif inline.t == "Space" or inline.t == "SoftBreak" then
    table.insert(results, build_text_run(rPr_parts, " "))

  elseif inline.t == "Strong" then
    return recurse_with_rPr(inline.content, rPr_parts, "<w:b/>")

  elseif inline.t == "Emph" then
    return recurse_with_rPr(inline.content, rPr_parts, "<w:i/>")

  elseif inline.t == "Strikeout" then
    return recurse_with_rPr(inline.content, rPr_parts, "<w:strike/>")

  elseif inline.t == "Superscript" then
    return recurse_with_rPr(inline.content, rPr_parts, '<w:vertAlign w:val="superscript"/>')

  elseif inline.t == "Subscript" then
    return recurse_with_rPr(inline.content, rPr_parts, '<w:vertAlign w:val="subscript"/>')

  elseif inline.t == "Span" then
    -- Check for char-style class via schema lookup
    local matched_class = nil
    local matched_style_id = nil
    for _, class in ipairs(inline.classes) do
      local sid = get_char_style_id(class)
      if sid then
        matched_class = class
        matched_style_id = sid
        break
      end
    end

    if matched_class then
      -- Emit char field code (replicates char-style.lua)
      local text = M.inlines_to_text(inline.content)
      if text ~= "" then
        local field_xml = M.build_char_field_code(
          matched_style_id, text, matched_class)
        table.insert(results, field_xml)
      end
    else
      -- Unknown span class — recurse into children with current rPr
      for _, child in ipairs(inline.content) do
        for _, xml in ipairs(render_inline(child, rPr_parts)) do
          table.insert(results, xml)
        end
      end
    end

  elseif inline.t == "Link" then
    return recurse_with_rPr(inline.content, rPr_parts,
      {'<w:u w:val="single"/>', '<w:color w:val="0563C1"/>'})

  elseif inline.t == "RawInline" then
    if inline.format == "html" then
      -- Check for comment markers (replicates comment-inject.lua)
      local id, marker_type = parse_comment_marker(inline.text)
      if id then
        if marker_type == "start" then
          table.insert(results,
            '<w:commentRangeStart w:id="' .. M.xml_escape(id) .. '"/>')
        elseif marker_type == "end" then
          table.insert(results,
            '<w:commentRangeEnd w:id="' .. M.xml_escape(id) .. '"/>' ..
            '<w:r><w:rPr></w:rPr><w:commentReference w:id="' .. M.xml_escape(id) .. '"/></w:r>')
        elseif marker_type == "point" then
          table.insert(results,
            '<w:commentRangeStart w:id="' .. M.xml_escape(id) .. '"/>' ..
            '<w:commentRangeEnd w:id="' .. M.xml_escape(id) .. '"/>' ..
            '<w:r><w:rPr></w:rPr><w:commentReference w:id="' .. M.xml_escape(id) .. '"/></w:r>')
        end
      end
      -- Other HTML raw inlines are dropped (no meaningful OOXML equivalent)
    elseif inline.format == "openxml" then
      -- Already OOXML — pass through unchanged
      table.insert(results, inline.text)
    end

  elseif inline.t == "LineBreak" then
    -- Line break within a paragraph
    table.insert(results, "<w:r><w:br/></w:r>")

  elseif inline.t == "Code" then
    table.insert(results, build_text_run(rPr_parts, inline.text))

  -- Fallback: try to recurse into content, or stringify
  elseif inline.content then
    for _, child in ipairs(inline.content) do
      for _, xml in ipairs(render_inline(child, rPr_parts)) do
        table.insert(results, xml)
      end
    end
  else
    -- Leaf node we don't handle — stringify
    local text = pandoc.utils.stringify(pandoc.Inlines({inline}))
    if text ~= "" then
      table.insert(results, build_text_run(rPr_parts, text))
    end
  end

  return results
end

--- Render an array of Pandoc Inlines to OOXML run XML.
-- @param inlines Array of Pandoc inline elements
-- @param base_rPr_parts Array of base run property XML fragments
-- @return Concatenated OOXML string (runs only, no paragraph wrapper)
function M.render_inlines(inlines, base_rPr_parts)
  base_rPr_parts = base_rPr_parts or {}
  local all_runs = {}
  for _, inline in ipairs(inlines) do
    for _, xml in ipairs(render_inline(inline, base_rPr_parts)) do
      table.insert(all_runs, xml)
    end
  end
  return table.concat(all_runs)
end

-- Export parse_comment_marker for use by comment-inject.lua
M.parse_comment_marker = parse_comment_marker


return M
