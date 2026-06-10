-- anchor.lua
-- Pandoc Lua filter that detects anchor-positioned divs and emits
-- DOCSTYLE_ANCHOR:: text markers wrapped in ADDIN DOCSTYLE field codes.
--
-- Anchor divs are identified by CSS class matching an anchor_styles entry
-- in page-config.json (written by pre-render from .column-margin,
-- .journal-sidebar, and other anchor class selectors in CSS).
--
-- Usage in QMD:
--   ::: {.column-margin}
--   | Table | Here |
--   :::
--
--   ::: {.column-margin adjacent="paragraph"}
--   | Table | Here |
--   :::
--
-- The filter emits opening and closing text markers that the R post-render
-- phase (finalize_docx.R) consumes to apply Word floating frame properties.
-- This follows the established R-first assembly pattern used by
-- page-section.lua for section breaks.
--
-- Typst: returns nil. Quarto Marginalia handles .column-margin natively.

local fcu = require("field-code-utils")

local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write("[anchor] " .. msg .. "\n")
  end
end

-- Cached anchor styles from page-config.json
local anchor_styles = nil

local function load_anchor_styles()
  if anchor_styles ~= nil then return anchor_styles end
  local config = fcu.load_page_config()
  if config and config.anchor_styles then
    anchor_styles = config.anchor_styles
  else
    debug("No anchor_styles in page-config.json; anchor divs will not be processed")
    anchor_styles = {}
  end
  return anchor_styles
end

-- Find first anchor-eligible class on a div
local function find_anchor_class(div)
  local styles = load_anchor_styles()
  for _, cls in ipairs(div.classes) do
    if styles[cls] then
      return cls, styles[cls]
    end
  end
  return nil, nil
end

-- Build an anchor marker paragraph with ADDIN DOCSTYLE field code wrapping.
-- Same structure as build_section_marker_para: BEGIN/instrText/SEPARATE/marker/END
-- all in one paragraph to avoid the 3-line gap problem.
local function build_anchor_marker_para(anchor_class, field_attrs, marker_text)
  local json = fcu.build_payload_json("anchor", field_attrs)
  if not json then
    io.stderr:write("[anchor] ERROR: build_payload_json returned nil for class " ..
                    anchor_class .. "\n")
    return nil
  end
  local json_xml = fcu.xml_escape(json)
  local marker_xml = fcu.xml_escape(marker_text)

  return '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>' ..
         '<w:r><w:fldChar w:fldCharType="begin"/></w:r>' ..
         '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ' .. json_xml .. ' </w:instrText></w:r>' ..
         '<w:r><w:fldChar w:fldCharType="separate"/></w:r>' ..
         '<w:r><w:t>' .. marker_xml .. '</w:t></w:r>' ..
         '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
end

-- Build anchor end marker paragraph (plain text, no field code)
local function build_anchor_end_marker_para(end_marker_text)
  return '<w:p><w:pPr><w:suppressLineNumbers/></w:pPr>' ..
         '<w:r><w:t>' .. fcu.xml_escape(end_marker_text) .. '</w:t></w:r></w:p>'
end

function Div(div)
  -- Skip non-docx formats (Typst gets .column-margin free via Quarto Marginalia)
  if not FORMAT:match("openxml") then return nil end

  local anchor_class, anchor_config = find_anchor_class(div)
  if not anchor_class then return nil end

  -- Extract optional adjacent attribute from div
  local adjacent = div.attributes["adjacent"]

  -- Build field code payload from CSS-derived config
  local field_attrs = {
    class = anchor_class,
    vertical_anchor = anchor_config.vertical_anchor or "text",
    horizontal_anchor = anchor_config.horizontal_anchor or "margin",
    position_y = anchor_config.position_y or "0",
    position_x = anchor_config.position_x or "0",
    wrap_style = anchor_config.wrap_style or "square",
    wrap_side = anchor_config.wrap_side or "both",
    wrap_distance = anchor_config.wrap_distance or "0 198dxa 0 198dxa"
  }
  if anchor_config.float_width then
    field_attrs.float_width = anchor_config.float_width
  end
  if adjacent then
    field_attrs.adjacent = adjacent
  end
  if anchor_config.content_mode then
    field_attrs.content_mode = anchor_config.content_mode
  end
  -- Also allow div attribute override
  local div_content_mode = div.attributes["content-mode"]
  if div_content_mode then
    field_attrs.content_mode = div_content_mode
  end

  -- Detect content hint from div content
  local content_hint = "text"
  for _, block in ipairs(div.content) do
    if block.t == "Table" then
      content_hint = "table"
      break
    elseif block.t == "Para" then
      for _, inline in ipairs(block.content) do
        if inline.t == "Image" then
          content_hint = "image"
          break
        end
      end
    end
  end
  field_attrs.content_hint = content_hint

  -- Marker texts
  local marker_text = "DOCSTYLE_ANCHOR::" .. anchor_class .. "::" .. (adjacent or "")
  local end_marker_text = "DOCSTYLE_ANCHOR_END::" .. anchor_class

  -- Build output: opening marker, inner content, closing marker
  local blocks = pandoc.List()

  local marker_xml = build_anchor_marker_para(anchor_class, field_attrs, marker_text)
  if not marker_xml then
    -- build_payload_json failed; return div unchanged to avoid unmatched end marker
    return nil
  end

  blocks:insert(pandoc.RawBlock("openxml", marker_xml))

  for _, block in ipairs(div.content) do
    blocks:insert(block)
  end

  blocks:insert(pandoc.RawBlock("openxml",
    build_anchor_end_marker_para(end_marker_text)))

  debug("Emitted anchor markers for ." .. anchor_class)
  return blocks
end
