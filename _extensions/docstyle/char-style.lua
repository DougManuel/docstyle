-- char-style.lua
-- Pandoc Lua filter that converts spans with style classes to Word character styles
--
-- Usage in QMD:
--   Date: [{{< meta version-summary.date >}}]{.date}  -- Shortcode with styling
--   Date: []{.date}                                    -- Auto-populated from metadata
--   Custom: [my text]{.date}                           -- Explicit content
--
-- All three syntaxes work. Empty spans auto-populate from version-summary metadata.
-- Shortcode syntax is preferred as it's explicit and works with any metadata field.
--
-- This applies w:rStyle to the run, creating a character-level style in Word.
-- The style must exist in reference.docx (generated from CSS via docstyle).
--
-- Round-trip support: Each styled span is wrapped in an ADDIN DOCSTYLE field code
-- that carries the original QMD source as JSON metadata. During harvest, the field
-- code's instrText is parsed to restore the exact QMD source (e.g., shortcodes).
-- See development/spec-round-trip-mechanism.md for the full specification.

-- Load shared field code utilities
local fcu = require("field-code-utils")

-- Debug logging (set DOCSTYLE_DEBUG=1 to enable)
local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write(msg)
  end
end

-- Metadata values for auto-population (set in Meta filter)
local meta_values = {
  date = nil,
  version = nil
}

-- Get style ID for a class from schema, with fallback
local function get_style_id(class)
  local class_def = fcu.get_char_class(class)
  if class_def and class_def.word_style then
    return class_def.word_style
  end
  -- Fallback for classes not in schema
  local fallback = {
    date = "Date",
    version = "Version",
    author = "Author",
    affiliation = "Affiliation"
  }
  return fallback[class]
end

-- List of supported style classes (for iteration)
local supported_classes = {"date", "version", "author", "affiliation"}

-- Process Span elements with character style classes
function Span(el)
  -- Only process for Word output
  if FORMAT ~= "docx" and FORMAT ~= "openxml" then
    return nil
  end

  -- Check if this span has any of our style classes
  local matched_class = nil
  local style_id = nil
  for _, class in ipairs(supported_classes) do
    if el.classes:includes(class) then
      matched_class = class
      style_id = get_style_id(class)
      break
    end
  end

  if not style_id then
    return nil
  end

  -- Get the text content
  local text = fcu.inlines_to_text(el.content)

  -- Auto-populate empty spans from metadata
  if text == "" or text == nil then
    if matched_class and meta_values[matched_class] then
      text = meta_values[matched_class]
      debug("[char-style] Auto-populated '" .. style_id .. "' from metadata: " .. text .. "\n")
    else
      debug("[char-style] Warning: Empty span with style '" .. style_id .. "' and no metadata value\n")
      return nil  -- Return nil to keep span as-is if we can't populate it
    end
  else
    debug("[char-style] Applying style '" .. style_id .. "' to: " .. text .. "\n")
  end

  -- Build field code XML using shared utility
  local field_xml = fcu.build_char_field_code(style_id, text, matched_class)
  debug("[char-style] Emitting field code for '" .. matched_class .. "'\n")

  return pandoc.RawInline('openxml', field_xml)
end

-- Process Div elements with .center class for paragraph alignment
function Div(el)
  -- Only process for Word output
  if FORMAT ~= "docx" and FORMAT ~= "openxml" then
    return nil
  end

  -- Check if this div has the center class
  if not el.classes:includes('center') then
    return nil
  end

  debug("[char-style] Applying center alignment to div\n")

  -- For each paragraph in the div, add custom-style="Centered" attribute
  -- This requires a "Centered" style in reference.docx with center alignment
  -- Alternatively, we can directly inject the alignment via RawBlock
  local result = {}
  for _, block in ipairs(el.content) do
    if block.t == "Para" then
      -- Convert paragraph content to runs, wrapped in a centered paragraph
      local runs = {}
      for _, inline in ipairs(block.content) do
        -- If it's already a RawInline openxml (from Span filter), keep it
        if inline.t == "RawInline" and inline.format == "openxml" then
          table.insert(runs, inline.text)
        elseif inline.t == "Str" then
          table.insert(runs, '<w:r><w:t xml:space="preserve">' .. fcu.xml_escape(inline.text) .. '</w:t></w:r>')
        elseif inline.t == "Space" then
          table.insert(runs, '<w:r><w:t xml:space="preserve"> </w:t></w:r>')
        end
      end

      local para_xml = '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>' .. table.concat(runs) .. '</w:p>'
      table.insert(result, pandoc.RawBlock('openxml', para_xml))
    else
      -- Keep other blocks as-is
      table.insert(result, block)
    end
  end

  return result
end

-- Extract metadata values for auto-population
function Meta(meta)
  if FORMAT == "docx" or FORMAT == "openxml" then
    debug("[char-style] Filter active for Word output\n")
  end

  -- Extract version-summary.date and version-summary.version
  if meta["version-summary"] then
    local vs = meta["version-summary"]
    if vs.date then
      meta_values.date = pandoc.utils.stringify(vs.date)
      debug("[char-style] Found version-summary.date: " .. meta_values.date .. "\n")
    end
    if vs.version then
      meta_values.version = pandoc.utils.stringify(vs.version)
      debug("[char-style] Found version-summary.version: " .. meta_values.version .. "\n")
    end
  end

  return nil
end

-- Filter order: Meta first (to extract values), then Span (character styles), then Div (centering)
return {
  { Meta = Meta },
  { Span = Span },
  { Div = Div }
}
