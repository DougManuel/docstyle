-- toc-field.lua
-- Pandoc Lua filter that injects Word TOC field codes
--
-- Usage in QMD:
--   ::: {.toc}
--   :::
--
-- Configuration in _quarto.yml (under docstyle.toc):
--   title: "Contents"        # Optional heading above TOC
--   title-level: 1           # Heading level for title (default: 1)
--   levels: "1-3"            # Which heading levels to include
--   page-numbers: true       # Show page numbers
--   hyperlinks: true         # Make entries clickable
--   tab-leader: "dot"        # dot, dash, underscore, none
--
-- This filter finds Div elements with class "toc" and replaces them with
-- Word TOC field codes, enabling dynamic table of contents in Word.

-- Load shared field code utilities
local fcu = require("field-code-utils")

local FORMAT = "openxml"

-- Default configuration
local toc_config = {
  title = nil,           -- No title by default
  title_level = 1,       -- # heading
  levels = "1-3",
  page_numbers = true,
  hyperlinks = true,
  tab_leader = "dot"
}

-- Read configuration from metadata
function Meta(meta)
  if meta.docstyle and meta.docstyle.toc then
    local toc = meta.docstyle.toc

    if toc.title then
      toc_config.title = pandoc.utils.stringify(toc.title)
    end

    if toc["title-level"] then
      toc_config.title_level = tonumber(pandoc.utils.stringify(toc["title-level"])) or 1
    end

    if toc.levels then
      toc_config.levels = pandoc.utils.stringify(toc.levels)
    end

    if toc["page-numbers"] ~= nil then
      local val = toc["page-numbers"]
      if type(val) == "boolean" then
        toc_config.page_numbers = val
      else
        toc_config.page_numbers = pandoc.utils.stringify(val) ~= "false"
      end
    end

    if toc.hyperlinks ~= nil then
      local val = toc.hyperlinks
      if type(val) == "boolean" then
        toc_config.hyperlinks = val
      else
        toc_config.hyperlinks = pandoc.utils.stringify(val) ~= "false"
      end
    end

    if toc["tab-leader"] then
      toc_config.tab_leader = pandoc.utils.stringify(toc["tab-leader"])
    end

    io.stderr:write("[toc-field] Config: levels=" .. toc_config.levels ..
                    ", page-numbers=" .. tostring(toc_config.page_numbers) ..
                    ", hyperlinks=" .. tostring(toc_config.hyperlinks) ..
                    ", tab-leader=" .. toc_config.tab_leader .. "\n")
  end

  return nil
end

-- Normalize levels to a range format (Word requires "1-3" not just "1")
local function normalize_levels(levels)
  -- If already a range (contains "-"), return as-is
  if string.find(levels, "-") then
    return levels
  end
  -- Single number: convert to range "n-n"
  return levels .. "-" .. levels
end

-- Build the TOC field instruction text
local function build_toc_instr()
  -- TOC field switches:
  -- \o "1-3"  - Include heading levels 1-3
  -- \h        - Hyperlink entries to headings
  -- \z        - Hide tab leader and page numbers in Web Layout view
  -- \u        - Use applied paragraph outline level
  -- \n        - Suppress page numbers (if page-numbers: false)

  local switches = {}

  -- Heading levels (normalize to range format)
  local levels_range = normalize_levels(toc_config.levels)
  table.insert(switches, '\\o "' .. levels_range .. '"')

  -- Hyperlinks
  if toc_config.hyperlinks then
    table.insert(switches, "\\h")
  end

  -- Hide formatting in web view
  table.insert(switches, "\\z")

  -- Use outline levels
  table.insert(switches, "\\u")

  -- Suppress page numbers if disabled
  if not toc_config.page_numbers then
    table.insert(switches, "\\n")
  end

  return "TOC " .. table.concat(switches, " ")
end

-- Build the OpenXML for a TOC field code
local function build_toc_field_xml()
  local instr = build_toc_instr()

  -- Pad instruction text (Word requires leading/trailing spaces)
  instr = " " .. instr .. " "

  -- Build the 5-part Word field code structure
  local xml = '<w:p>' ..
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>' ..
    '<w:r><w:instrText xml:space="preserve">' .. instr .. '</w:instrText></w:r>' ..
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>' ..
    '<w:r><w:t>[Update field to generate table of contents]</w:t></w:r>' ..
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>' ..
    '</w:p>'

  return xml
end

-- Build a heading element for the TOC title
-- Uses the configured title-level to determine the Word style
-- title-level: 1 -> Heading1, 2 -> Heading2, etc.
local function build_title_blocks()
  if not toc_config.title then
    return {}
  end

  -- Map title-level to Word heading style
  -- Default to Heading1 if title_level is 1 or not specified
  local style_id = "Heading" .. tostring(toc_config.title_level)

  -- Build OpenXML paragraph with the appropriate Heading style
  local title_xml = '<w:p>' ..
    '<w:pPr><w:pStyle w:val="' .. style_id .. '"/></w:pPr>' ..
    '<w:r><w:t>' .. toc_config.title .. '</w:t></w:r>' ..
    '</w:p>'

  return { pandoc.RawBlock("openxml", title_xml) }
end

-- Process Div elements looking for .toc class
function Div(div)
  -- Check if this div has the "toc" class
  if not div.classes:includes("toc") then
    return nil
  end

  -- Only process for docx output
  if not FORMAT or FORMAT ~= "openxml" then
    io.stderr:write("[toc-field] Skipping TOC injection (not docx output)\n")
    return nil
  end

  io.stderr:write("[toc-field] Found .toc div, injecting TOC field code\n")

  -- Build the result blocks
  local blocks = {}

  -- ADDIN DOCSTYLE field code begin (using shared utility)
  table.insert(blocks, pandoc.RawBlock("openxml", fcu.build_div_field_start("toc")))

  -- Add title heading if configured
  local title_blocks = build_title_blocks()
  for _, block in ipairs(title_blocks) do
    table.insert(blocks, block)
  end

  -- Add the TOC field code
  local toc_xml = build_toc_field_xml()
  table.insert(blocks, pandoc.RawBlock("openxml", toc_xml))

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

return {
  { Meta = Meta },
  { Div = Div }
}
