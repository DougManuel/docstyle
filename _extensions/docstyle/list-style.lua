-- list-style.lua
-- Pandoc Lua filter for CSS-defined list styles in Word output
--
-- Approach: AST rewriting + ADDIN DOCSTYLE field code markers
-- 1. Converts BulletList → OrderedList with correct ListNumberStyle
--    (Pandoc's docx writer generates proper numbering.xml definitions)
-- 2. Wraps styled lists in ADDIN DOCSTYLE field codes
--    (harvest detects field codes to recover CSS class on round-trip)
--
-- Usage in QMD:
--   ::: {.list-alpha}
--   - First item (renders as a.)
--   - Second item (renders as b.)
--   :::
--
-- Supported list classes:
--   .list-bullet  - Bullet list (explicit)
--   .list-decimal - Numbered 1. 2. 3. at all levels
--   .list-alpha   - Lettered a. b. c. at all levels
--   .list-roman   - Roman i. ii. iii. at all levels
--   .list-formal  - Hierarchical: 1. / a. / i. per level

-- Load shared field code utilities
local fcu = require("field-code-utils")

local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write("[list-style] " .. msg .. "\n")
  end
end

local FORMAT = "openxml"

-- Map CSS class → Pandoc ListNumberStyle per indent level
-- Pandoc styles: DefaultStyle, Decimal, LowerAlpha, UpperAlpha, LowerRoman, UpperRoman
local list_styles = {
  ["list-bullet"] = nil,  -- keep as BulletList
  ["list-decimal"] = {
    [0] = "Decimal", [1] = "Decimal", [2] = "Decimal"
  },
  ["list-alpha"] = {
    [0] = "LowerAlpha", [1] = "LowerAlpha", [2] = "LowerAlpha"
  },
  ["list-roman"] = {
    [0] = "LowerRoman", [1] = "LowerRoman", [2] = "LowerRoman"
  },
  ["list-formal"] = {
    [0] = "Decimal", [1] = "LowerAlpha", [2] = "LowerRoman"
  }
}

-- Find list style class in div classes
local function find_list_style(classes)
  for _, class in ipairs(classes) do
    if list_styles[class] ~= nil then
      return class
    end
  end
  for _, class in ipairs(classes) do
    if class == "list-bullet" then
      return "list-bullet"
    end
  end
  return nil
end

-- Convert a BulletList or OrderedList to an OrderedList with the specified style
-- Handles nested lists recursively with level tracking
-- div_start: optional start value from div attribute (applied at level 0 only)
local function convert_list(block, style_name, level, div_start)
  level = level or 0
  local style_def = list_styles[style_name]

  -- list-bullet: keep as-is
  if not style_def then
    return block
  end

  local pandoc_style = style_def[level] or style_def[0]

  -- Process items, converting nested lists (nested lists don't inherit div_start)
  local new_items = {}
  for _, item in ipairs(block.content) do
    local new_blocks = {}
    for _, b in ipairs(item) do
      if b.t == "BulletList" or b.t == "OrderedList" then
        table.insert(new_blocks, convert_list(b, style_name, level + 1, nil))
      else
        table.insert(new_blocks, b)
      end
    end
    table.insert(new_items, new_blocks)
  end

  -- Determine start number: div_start at level 0, then block's own start, then 1
  local start_num = 1
  if div_start and level == 0 then
    start_num = div_start
  elseif block.t == "OrderedList" and block.listAttributes then
    start_num = block.listAttributes[1] or 1
  end

  return pandoc.OrderedList(new_items, pandoc.ListAttributes(start_num, pandoc_style, "Period"))
end

-- Process Div elements looking for list style classes
function Div(div)
  if FORMAT ~= "openxml" then
    return nil
  end

  local style_name = find_list_style(div.classes)
  if not style_name then
    return nil
  end

  -- Read optional start attribute for list continuation
  local div_start = tonumber(div.attributes.start) or nil

  debug("Found ." .. style_name .. " div" ..
    (div_start and (" start=" .. div_start) or ""))

  -- Convert all lists in the div
  local converted_blocks = {}
  local modified = false

  for _, block in ipairs(div.content) do
    if block.t == "BulletList" or block.t == "OrderedList" then
      table.insert(converted_blocks, convert_list(block, style_name, 0, div_start))
      modified = true
    else
      table.insert(converted_blocks, block)
    end
  end

  if not modified then
    debug("No lists found in ." .. style_name .. " div")
    return nil
  end

  -- Wrap with ADDIN DOCSTYLE field code markers using shared utility
  local result = {}
  table.insert(result, pandoc.RawBlock("openxml", fcu.build_list_field_start(style_name, div_start)))
  for _, block in ipairs(converted_blocks) do
    table.insert(result, block)
  end
  table.insert(result, pandoc.RawBlock("openxml", fcu.build_block_field_end()))

  debug("Converted lists in ." .. style_name .. " div (field code marker added)")

  return result
end

-- Check output format
function Pandoc(doc)
  if FORMAT == "docx" or FORMAT == "openxml" then
    FORMAT = "openxml"
  end
  return nil
end

return {
  { Pandoc = Pandoc },
  { Div = Div }
}
