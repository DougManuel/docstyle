-- table-style.lua
-- Pandoc Lua filter that applies CSS-defined table styles to Word output
--
-- Usage in QMD:
--   ::: {.table-formal}
--   | Column 1 | Column 2 |
--   |----------|----------|
--   | Data     | Data     |
--   :::
--
-- Supported table classes:
--   .table-formal - Top/bottom borders, shaded header row
--   .table-grid   - Full grid borders on all cells
--
-- Table styles are loaded from page-config.json (CSS-derived) at runtime.
-- Built-in defaults are used as fallback when no CSS config is available.

-- Load field-code-utils for ADDIN DOCSTYLE field code emission
local fcu = require("field-code-utils")

-- Debug logging (set DOCSTYLE_DEBUG=1 to enable)
local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write(msg)
  end
end

local FORMAT = "openxml"

-- Built-in fallback table style definitions (used when CSS config not available)
local builtin_table_styles = {
  ["table-formal"] = {
    borders = {
      top = { val = "single", sz = "4", color = "7F7F7F" },
      bottom = { val = "single", sz = "4", color = "7F7F7F" },
      left = nil,
      right = nil,
      insideH = nil,
      insideV = nil
    },
    header_shading = "D9D9D9"
  },
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
  }
}

-- Active table styles (populated from CSS config or fallback)
local table_styles = nil

-- Load table styles from page-config.json (CSS-derived) via shared loader
local function load_table_styles()
  local config = fcu.load_page_config()
  if config and config.table_styles then
    debug("[table-style] Loaded CSS table styles from page-config.json\n")
    return config.table_styles
  end
  debug("[table-style] No CSS table config found, using built-in defaults\n")
  return nil
end

-- Initialise table_styles: CSS config with built-in fallback
local function init_table_styles()
  if table_styles then return end

  local css_styles = load_table_styles()
  if css_styles then
    -- Start with built-in defaults, then deep-merge CSS values
    table_styles = {}
    -- Deep-copy all built-in styles (avoids mutating builtin_table_styles
    -- when the CSS overlay loop writes into nested tables like borders)
    for name, style in pairs(builtin_table_styles) do
      table_styles[name] = {}
      for k, v in pairs(style) do
        if type(v) == "table" then
          table_styles[name][k] = {}
          for sub_k, sub_v in pairs(v) do
            table_styles[name][k][sub_k] = sub_v
          end
        else
          table_styles[name][k] = v
        end
      end
    end
    -- Overlay CSS-derived styles field-by-field (preserves built-in
    -- fields not covered by CSS, e.g. header_shading when CSS only
    -- defines borders). Deep-merges nested tables like borders.
    for name, css_style in pairs(css_styles) do
      if not table_styles[name] then
        table_styles[name] = {}
      end
      for k, v in pairs(css_style) do
        if type(v) == "table" and type(table_styles[name][k]) == "table" then
          -- Deep merge: overlay CSS sub-keys over built-in sub-keys
          for sub_k, sub_v in pairs(v) do
            table_styles[name][k][sub_k] = sub_v
          end
        else
          table_styles[name][k] = v
        end
      end
    end
  else
    table_styles = builtin_table_styles
  end
end

-- Build border XML element
local function build_border_xml(name, border)
  if not border then return "" end
  return string.format('<w:%s w:val="%s" w:sz="%s" w:space="0" w:color="%s"/>',
    name, border.val, border.sz, border.color)
end

-- Build table borders XML
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

-- Build cell shading XML
local function build_shading_xml(color)
  if not color then return "" end
  return string.format('<w:shd w:val="clear" w:color="auto" w:fill="%s"/>', color)
end


-- Parse widths attribute (e.g., "30,70" or "25,50,25")
-- Returns array of percentages or nil if not specified
local function parse_widths(widths_str)
  if not widths_str or widths_str == "" then
    return nil
  end

  local widths = {}
  for w in string.gmatch(widths_str, "([^,]+)") do
    local num = tonumber(w)
    if num then
      table.insert(widths, num)
    end
  end

  return #widths > 0 and widths or nil
end

-- Convert Pandoc table to OpenXML with custom styling
-- widths_str: optional comma-separated percentages (e.g., "30,70")
-- width_pct: optional table width as percentage of page (e.g., "50" for half width)
-- font_size_pt: optional font size in points (e.g., 9)
-- overrides: optional table of per-table overrides (header_bold, header_shading)
local function styled_table_to_openxml(tbl, style_name, widths_str, width_pct, font_size_pt, overrides)
  local style = table_styles[style_name]
  if not style then
    debug("[table-style] Unknown table style: " .. style_name .. "\n")
    return nil
  end

  -- Apply per-table overrides from div attributes (header-bold, header-shading)
  overrides = overrides or {}
  local eff_header_bold = style.header_bold
  local eff_header_shading = style.header_shading
  if overrides.header_bold ~= nil then
    eff_header_bold = overrides.header_bold
  end
  if overrides.header_shading then
    eff_header_shading = overrides.header_shading
  end

  debug("[table-style] Applying style '" .. style_name .. "' to table\n")

  -- Get table dimensions
  local num_cols = 0
  local rows = {}

  -- Process table head
  if tbl.head and tbl.head.rows then
    for _, row in ipairs(tbl.head.rows) do
      local cells = {}
      for _, cell in ipairs(row.cells) do
        table.insert(cells, { content = cell, is_header = true })
        num_cols = math.max(num_cols, #row.cells)
      end
      table.insert(rows, { cells = cells, is_header_row = true })
    end
  end

  -- Process table body
  if tbl.bodies then
    for _, body in ipairs(tbl.bodies) do
      if body.body then
        for _, row in ipairs(body.body) do
          local cells = {}
          for _, cell in ipairs(row.cells) do
            table.insert(cells, { content = cell, is_header = false })
            num_cols = math.max(num_cols, #row.cells)
          end
          table.insert(rows, { cells = cells, is_header_row = false })
        end
      end
    end
  end

  -- Calculate table width (default 9000 twips = ~6.25 inches = full text width)
  local full_width = 9000
  local total_width = full_width

  -- Apply width percentage if specified (e.g., "50" for half width)
  if width_pct then
    local pct = tonumber(width_pct)
    if pct and pct > 0 and pct <= 100 then
      total_width = math.floor(full_width * pct / 100)
      debug("[table-style] Using table width: " .. pct .. "%\n")
    end
  end

  -- Calculate column widths
  local col_widths = {}
  local widths = parse_widths(widths_str)

  if widths and #widths == num_cols then
    -- Use specified percentages
    local total_pct = 0
    for _, w in ipairs(widths) do
      total_pct = total_pct + w
    end
    for i, w in ipairs(widths) do
      col_widths[i] = math.floor(total_width * w / total_pct)
    end
    debug("[table-style] Using custom column widths: " .. widths_str .. "\n")
  else
    -- Auto-compute widths from cell content.
    -- For each column: find the longest single word (minimum width to avoid
    -- mid-word breaks), then distribute remaining space by total text volume.

    -- Approximate characters that fit in the full table width
    -- ~11 chars/inch at 10pt Calibri, scale inversely with font size
    local base_font = font_size_pt or 10
    local chars_per_inch = 11 * (10 / base_font)
    local total_chars = math.floor(6.5 * chars_per_inch)

    -- Collect text per column (header + all body cells)
    local col_texts = {}
    for i = 1, num_cols do col_texts[i] = {} end
    for _, row in ipairs(rows) do
      for col_idx, cell in ipairs(row.cells) do
        if col_idx <= num_cols then
          local text = ""
          if cell.content then
            text = pandoc.utils.stringify(cell.content)
          end
          table.insert(col_texts[col_idx], text)
        end
      end
    end

    local min_chars = {}
    local volume = {}
    for i = 1, num_cols do
      -- Longest single word in this column (determines minimum width)
      local max_word = 1
      for _, text in ipairs(col_texts[i]) do
        for word in text:gmatch("%S+") do
          max_word = math.max(max_word, #word)
        end
      end
      min_chars[i] = max_word + 1  -- +1 char padding

      -- Total text volume (drives proportional allocation)
      local vol = 0
      for _, text in ipairs(col_texts[i]) do
        vol = vol + #text
      end
      volume[i] = math.max(vol, 1)
    end

    -- Convert minimum chars to percentage of page
    local min_pct = {}
    local sum_min = 0
    for i = 1, num_cols do
      min_pct[i] = min_chars[i] / total_chars * 100
      sum_min = sum_min + min_pct[i]
    end

    local auto_widths = {}
    if sum_min >= 100 then
      -- Minimums fill the page; scale proportionally
      for i = 1, num_cols do
        auto_widths[i] = min_pct[i] / sum_min * 100
      end
    else
      -- Allocate minimums, distribute remaining space by volume
      local remaining = 100 - sum_min
      local total_vol = 0
      for i = 1, num_cols do total_vol = total_vol + volume[i] end
      for i = 1, num_cols do
        auto_widths[i] = min_pct[i] + (volume[i] / total_vol * remaining)
      end
    end

    -- Convert percentages to twips, adjusting for rounding
    local sum_tw = 0
    for i = 1, num_cols do
      col_widths[i] = math.floor(total_width * auto_widths[i] / 100)
      sum_tw = sum_tw + col_widths[i]
    end
    -- Give rounding remainder to the widest column
    local widest = 1
    for i = 2, num_cols do
      if col_widths[i] > col_widths[widest] then widest = i end
    end
    col_widths[widest] = col_widths[widest] + (total_width - sum_tw)

    -- Log the computed widths
    local pcts = {}
    for i = 1, num_cols do
      table.insert(pcts, tostring(math.floor(auto_widths[i] + 0.5)))
    end
    debug("[table-style] Auto-computed column widths: " .. table.concat(pcts, ",") .. "\n")
  end

  -- Build table properties XML
  -- Add small bottom cell margin (~0.5 line = 120 twips) for breathing room
  local cell_margin_xml = '<w:tblCellMar><w:bottom w:w="120" w:type="dxa"/></w:tblCellMar>'

  local tblPr_parts = {
    "<w:tblPr>",
    '<w:tblW w:w="' .. total_width .. '" w:type="dxa"/>',
    build_tblBorders_xml(style.borders),
    '<w:tblLayout w:type="fixed"/>',
    cell_margin_xml,
    "</w:tblPr>"
  }

  -- Build grid columns
  local grid_parts = { "<w:tblGrid>" }
  for i = 1, num_cols do
    table.insert(grid_parts, '<w:gridCol w:w="' .. col_widths[i] .. '"/>')
  end
  table.insert(grid_parts, "</w:tblGrid>")

  -- Build rows
  -- Pre-compute font size string once (table-level constant)
  local half_pts = font_size_pt and tostring(font_size_pt * 2) or nil

  local row_parts = {}
  for _, row in ipairs(rows) do
    local row_xml = { "<w:tr>" }

    -- Build row-level run properties (same for all cells in this row)
    local rPr_parts = {}
    if row.is_header_row and eff_header_bold then
      table.insert(rPr_parts, "<w:b/>")
    end
    if half_pts then
      table.insert(rPr_parts, '<w:sz w:val="' .. half_pts .. '"/>')
      table.insert(rPr_parts, '<w:szCs w:val="' .. half_pts .. '"/>')
    end
    local rPr = ""
    if #rPr_parts > 0 then
      rPr = "<w:rPr>" .. table.concat(rPr_parts) .. "</w:rPr>"
    end

    -- Paragraph properties for single line spacing (no space after)
    local pPr = '<w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>'

    -- Helper: render a list of inlines to a Word paragraph
    local function build_rich_para(inlines)
      if #inlines == 0 then return nil end
      local runs_xml = fcu.render_inlines(inlines, rPr_parts)
      if runs_xml == "" then return nil end
      return "<w:p>" .. pPr .. runs_xml .. "</w:p>"
    end

    for col_idx, cell in ipairs(row.cells) do
      -- Cell properties
      local tcPr_parts = {
        "<w:tcPr>",
        '<w:tcW w:w="' .. col_widths[col_idx] .. '" w:type="dxa"/>'
      }

      -- Add header shading if this is a header row
      if row.is_header_row and eff_header_shading then
        table.insert(tcPr_parts, build_shading_xml(eff_header_shading))
      end

      table.insert(tcPr_parts, "</w:tcPr>")

      -- Build paragraphs for the cell using the inline renderer
      -- This preserves bold, italic, comments, char-style spans, etc.
      local paragraphs = {}

      -- Get the cell's content blocks
      local cell_blocks = {}
      if cell.content and cell.content.contents then
        cell_blocks = cell.content.contents
      elseif cell.content then
        cell_blocks = cell.content
      end

      -- Process each block in the cell
      for _, block in ipairs(cell_blocks) do
        if block.content then
          -- Split content on LineBreak elements to create separate Word paragraphs
          local current_line = {}

          for _, inline in ipairs(block.content) do
            if inline.t == "LineBreak" then
              local para = build_rich_para(current_line)
              if para then table.insert(paragraphs, para) end
              current_line = {}
            else
              table.insert(current_line, inline)
            end
          end

          -- Last line (after final LineBreak or if no LineBreak)
          if #current_line > 0 then
            local para = build_rich_para(current_line)
            if para then table.insert(paragraphs, para) end
          end
        else
          -- Block without inline content — stringify as fallback
          local text = pandoc.utils.stringify(block)
          if text ~= "" then
            table.insert(paragraphs,
              "<w:p>" .. pPr .. "<w:r>" .. rPr ..
              '<w:t xml:space="preserve">' .. fcu.xml_escape(text) .. "</w:t></w:r></w:p>")
          end
        end
      end

      -- If no paragraphs found (shouldn't happen), add empty paragraph
      if #paragraphs == 0 then
        table.insert(paragraphs, "<w:p>" .. pPr .. "<w:r>" .. rPr .. "<w:t></w:t></w:r></w:p>")
      end

      -- Build cell XML with all paragraphs
      local cell_xml = "<w:tc>" ..
        table.concat(tcPr_parts) ..
        table.concat(paragraphs) ..
        "</w:tc>"

      table.insert(row_xml, cell_xml)
    end

    table.insert(row_xml, "</w:tr>")
    table.insert(row_parts, table.concat(row_xml))
  end

  -- Assemble complete table XML
  local table_xml = "<w:tbl>" ..
    table.concat(tblPr_parts) ..
    table.concat(grid_parts) ..
    table.concat(row_parts) ..
    "</w:tbl>"

  return table_xml
end

-- Find table style class in div classes
local function find_table_style(classes)
  for _, class in ipairs(classes) do
    if table_styles and table_styles[class] then
      return class
    end
  end
  return nil
end

-- Keys to skip when collecting div attributes for field code payload
-- (Pandoc-internal keys that should not be serialised)
local skip_attr_keys = { id = true, ["data-pos"] = true }

-- Process Div elements looking for table style classes
function Div(div)
  -- Check if this div has a table style class
  local style_name = find_table_style(div.classes)
  if not style_name then
    return nil
  end

  -- Only process for docx output
  if FORMAT ~= "openxml" then
    return nil
  end

  -- Extract attributes if present
  -- Usage: ::: {.table-formal widths="30,70" width="50" font-size="9"}
  local widths_str = div.attributes["widths"]      -- column widths (e.g., "30,70")
  local width_pct = div.attributes["width"]        -- table width % (e.g., "50")
  local font_size_str = div.attributes["font-size"] -- font size in pt (e.g., "9")

  -- Find Table element inside the div (search recursively through nested Divs,
  -- since Quarto wraps R code chunk output in .cell > .cell-output-display divs)
  local function find_table(blocks)
    for _, block in ipairs(blocks) do
      if block.t == "Table" then
        return block
      elseif block.t == "Div" and block.content then
        local found = find_table(block.content)
        if found then return found end
      end
    end
    return nil
  end
  local tbl = find_table(div.content)

  if not tbl then
    debug("[table-style] No table found in ." .. style_name .. " div\n")
    return nil
  end

  -- Parse font size (points)
  local font_size_pt = nil
  if font_size_str then
    font_size_pt = tonumber(font_size_str)
    if font_size_pt then
      debug("[table-style] Using font size: " .. font_size_pt .. "pt\n")
    end
  end

  -- Also check for CSS-config font size if not specified as div attribute
  if not font_size_pt then
    local style = table_styles[style_name]
    if style and style.font_size_half_pts then
      font_size_pt = style.font_size_half_pts / 2
      debug("[table-style] Using CSS font size: " .. font_size_pt .. "pt\n")
    end
  end

  -- Parse per-table header overrides from div attributes
  local overrides = {}
  local hb = div.attributes["header-bold"]
  if hb then
    overrides.header_bold = (hb == "true" or hb == "1")
  end
  local hs = div.attributes["header-shading"]
  if hs and hs ~= "" then
    overrides.header_shading = hs:gsub("^#", "")  -- strip leading # if present
  end

  -- Convert to styled OpenXML
  local table_xml = styled_table_to_openxml(tbl, style_name, widths_str, width_pct, font_size_pt, overrides)
  if not table_xml then
    return nil
  end

  -- Build field code payload and wrap table with ADDIN DOCSTYLE markers
  -- Filter out Pandoc-internal keys before passing to field code builder
  local attrs = {}
  for key, val in pairs(div.attributes) do
    if val and val ~= "" and not skip_attr_keys[key] then
      attrs[key] = val
    end
  end
  local field_start = fcu.build_table_field_start(style_name, attrs)
  local field_end = fcu.build_block_field_end()

  return pandoc.Blocks({
    pandoc.RawBlock("openxml", field_start),
    pandoc.RawBlock("openxml", table_xml),
    pandoc.RawBlock("openxml", field_end)
  })
end

-- Initialise format and load table styles once
function Pandoc(doc)
  if FORMAT == "docx" or FORMAT == "openxml" then
    FORMAT = "openxml"
  end
  init_table_styles()
  return nil
end

return {
  { Pandoc = Pandoc },
  { Div = Div }
}
