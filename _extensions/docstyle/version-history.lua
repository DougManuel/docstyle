-- version-history.lua
-- Pandoc Lua filter that generates a version history table from YAML metadata
--
-- Usage in QMD:
--   ::: version-history
--   :::
--
-- Configuration in _quarto.yml (under docstyle.version-history):
--   title: "Version history"   # Heading text (or false to disable)
--   title-level: 1             # 1-6: uses Heading1-Heading6 style
--   widths: "15,70,15"         # Column width percentages (Version, Description, Date)
--   style: "table-grid"        # Table style: table-grid (all borders) or table-formal (top/bottom)
--
-- Version entries in QMD YAML front matter:
--   version-history:
--     - version: "1.0.0"
--       date: "2025-01-15"
--       description: "Final release"
--
-- This filter finds Div elements with class "version-history" and replaces them
-- with a Word table generated from the version-history metadata.

-- Load shared field code utilities
local fcu = require("field-code-utils")

local FORMAT = "openxml"

-- Built-in table style definitions (matching table-style.lua)
local table_styles = {
  ["table-grid"] = {
    borders = {
      top = { val = "single", sz = "4", color = "000000" },
      bottom = { val = "single", sz = "4", color = "000000" },
      left = { val = "single", sz = "4", color = "000000" },
      right = { val = "single", sz = "4", color = "000000" },
      insideH = { val = "single", sz = "4", color = "000000" },
      insideV = { val = "single", sz = "4", color = "000000" }
    },
    header_shading = nil,
    header_bold = true
  },
  ["table-formal"] = {
    borders = {
      top = { val = "single", sz = "4", color = "7F7F7F" },
      bottom = { val = "single", sz = "4", color = "7F7F7F" },
      left = nil,
      right = nil,
      insideH = nil,
      insideV = nil
    },
    header_shading = "D9D9D9",
    header_bold = true
  }
}

-- Store version history from metadata
local version_history = nil
local div_found = false
local config = {
  title = "Version history",
  title_level = 1,
  widths = {15, 70, 15},  -- Default: Version 15%, Description 70%, Date 15%
  style = "table-grid"    -- Default table style
}

-- Use shared xml_escape from field-code-utils
local xml_escape = fcu.xml_escape

-- Parse widths string "15,70,15" into table {15, 70, 15}
local function parse_widths(widths_str)
  local widths = {}
  for w in string.gmatch(widths_str, "([^,]+)") do
    local num = tonumber(w)
    if num then
      table.insert(widths, num)
    end
  end
  -- Ensure we have exactly 3 widths
  if #widths ~= 3 then
    return {15, 70, 15}  -- Default
  end
  return widths
end

-- Read configuration from metadata
function Meta(meta)
  -- Get version history entries
  if meta["version-history"] then
    version_history = meta["version-history"]
    io.stderr:write("[version-history] Found " .. #version_history .. " version entries in metadata\n")
  end

  -- Get optional config from docstyle.version-history
  if meta.docstyle and meta.docstyle["version-history"] then
    local vh_config = meta.docstyle["version-history"]

    -- Title (string or false to disable)
    if vh_config.title ~= nil then
      local title_val = vh_config.title
      if type(title_val) == "boolean" and not title_val then
        config.title = nil  -- Disable title
      else
        config.title = pandoc.utils.stringify(title_val)
      end
    end

    -- Title level (1-6)
    if vh_config["title-level"] then
      config.title_level = tonumber(pandoc.utils.stringify(vh_config["title-level"])) or 1
    end

    -- Column widths
    if vh_config.widths then
      local widths_str = pandoc.utils.stringify(vh_config.widths)
      config.widths = parse_widths(widths_str)
      io.stderr:write("[version-history] Column widths: " .. table.concat(config.widths, ", ") .. "\n")
    end

    -- Table style
    if vh_config.style then
      local style_name = pandoc.utils.stringify(vh_config.style)
      if table_styles[style_name] then
        config.style = style_name
        io.stderr:write("[version-history] Table style: " .. style_name .. "\n")
      else
        io.stderr:write("[version-history] Unknown table style '" .. style_name .. "', using default\n")
      end
    end
  end

  return nil
end

-- Build border XML element
local function build_border_xml(name, border)
  if not border then return "" end
  return string.format('<w:%s w:val="%s" w:sz="%s" w:space="0" w:color="%s"/>',
    name, border.val, border.sz, border.color)
end

-- Build table borders XML from style definition
local function build_tblBorders_xml(borders)
  if not borders then return "" end

  local parts = { "<w:tblBorders>" }
  if borders.top then table.insert(parts, build_border_xml("top", borders.top)) end
  if borders.left then table.insert(parts, build_border_xml("left", borders.left)) end
  if borders.bottom then table.insert(parts, build_border_xml("bottom", borders.bottom)) end
  if borders.right then table.insert(parts, build_border_xml("right", borders.right)) end
  if borders.insideH then table.insert(parts, build_border_xml("insideH", borders.insideH)) end
  if borders.insideV then table.insert(parts, build_border_xml("insideV", borders.insideV)) end
  table.insert(parts, "</w:tblBorders>")

  return table.concat(parts)
end

-- Build a table cell XML with optional width and shading
local function build_cell(text, bold, width_pct, shading)
  local rPr = ""
  if bold then
    rPr = "<w:rPr><w:b/></w:rPr>"
  end

  -- Width in fiftieths of a percent (5000 = 100%)
  local tcPr_parts = { "<w:tcPr>" }
  if width_pct then
    local width_val = math.floor(width_pct * 50)  -- Convert % to fiftieths
    table.insert(tcPr_parts, '<w:tcW w:w="' .. width_val .. '" w:type="pct"/>')
  end
  if shading then
    table.insert(tcPr_parts, '<w:shd w:val="clear" w:color="auto" w:fill="' .. shading .. '"/>')
  end
  table.insert(tcPr_parts, "</w:tcPr>")

  return '<w:tc>' ..
    table.concat(tcPr_parts) ..
    '<w:p>' ..
    '<w:r>' .. rPr ..
    '<w:t>' .. xml_escape(text) .. '</w:t>' ..
    '</w:r>' ..
    '</w:p>' ..
    '</w:tc>'
end

-- Build the version history table XML
local function build_table_xml()
  if not version_history or #version_history == 0 then
    return nil
  end

  local w = config.widths
  local style = table_styles[config.style] or table_styles["table-grid"]

  -- Header row with column widths (bold header if style specifies, with optional shading)
  local header_bold = style.header_bold
  local header_shading = style.header_shading
  local header_row = '<w:tr>' ..
    build_cell("Version", header_bold, w[1], header_shading) ..
    build_cell("Description", header_bold, w[2], header_shading) ..
    build_cell("Date", header_bold, w[3], header_shading) ..
    '</w:tr>'

  -- Data rows
  local data_rows = {}
  for _, entry in ipairs(version_history) do
    local version = ""
    local description = ""
    local date = ""

    if entry.version then
      version = pandoc.utils.stringify(entry.version)
    end
    if entry.description then
      description = pandoc.utils.stringify(entry.description)
    end
    if entry.date then
      date = pandoc.utils.stringify(entry.date)
    end

    local row = '<w:tr>' ..
      build_cell(version, false, w[1], nil) ..
      build_cell(description, false, w[2], nil) ..
      build_cell(date, false, w[3], nil) ..
      '</w:tr>'
    table.insert(data_rows, row)
  end

  -- Build table borders from style
  local borders_xml = build_tblBorders_xml(style.borders)

  -- Complete table with style-defined borders
  local table_xml = '<w:tbl xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' ..
    '<w:tblPr>' ..
    '<w:tblW w:w="5000" w:type="pct"/>' ..  -- 100% width
    borders_xml ..
    '</w:tblPr>' ..
    header_row ..
    table.concat(data_rows) ..
    '</w:tbl>'

  return table_xml
end

-- Build heading for the title
local function build_title_xml()
  if not config.title then
    return nil
  end

  local style_id = "Heading" .. tostring(config.title_level)

  return '<w:p>' ..
    '<w:pPr><w:pStyle w:val="' .. style_id .. '"/></w:pPr>' ..
    '<w:r><w:t>' .. xml_escape(config.title) .. '</w:t></w:r>' ..
    '</w:p>'
end

-- Process Div elements looking for .version-history class
function Div(div)
  -- Check if this div has the "version-history" class
  if not div.classes:includes("version-history") then
    return nil
  end

  div_found = true

  -- Only process for docx output
  if FORMAT ~= "openxml" then
    io.stderr:write("[version-history] Skipping (not docx output)\n")
    return nil
  end

  if not version_history or #version_history == 0 then
    io.stderr:write("[version-history] No version-history metadata found\n")
    return {}  -- Remove the div entirely
  end

  io.stderr:write("[version-history] Generating table with " .. #version_history .. " entries\n")

  -- Build the result blocks
  local blocks = {}

  -- ADDIN DOCSTYLE field code begin (using shared utility)
  table.insert(blocks, pandoc.RawBlock("openxml", fcu.build_div_field_start("version-history")))

  -- Add title heading
  local title_xml = build_title_xml()
  if title_xml then
    table.insert(blocks, pandoc.RawBlock("openxml", title_xml))
  end

  -- Add the table
  local table_xml = build_table_xml()
  if table_xml then
    table.insert(blocks, pandoc.RawBlock("openxml", table_xml))
  end

  -- ADDIN DOCSTYLE field code end (using shared utility)
  table.insert(blocks, pandoc.RawBlock("openxml", fcu.build_block_field_end()))

  return blocks
end

-- Check output format
function Pandoc(doc)
  if FORMAT == "docx" or FORMAT == "openxml" then
    FORMAT = "openxml"
  end
  return nil
end

-- Warn if version-history metadata exists but no div was found
local function CheckUnused(doc)
  if version_history and #version_history > 0 and not div_found then
    io.stderr:write("[version-history] Warning: " .. #version_history ..
      " version-history entries in metadata but no ::: version-history ::: " ..
      "div in document. Add the div where you want the table to appear.\n")
  end
  return nil
end

return {
  { Meta = Meta, Pandoc = Pandoc },
  { Div = Div },
  { Pandoc = CheckUnused }
}
