-- figure.lua
-- Pandoc Lua filter that wraps .figure divs in ADDIN DOCSTYLE field codes
-- for round-trip harvest fidelity.
--
-- Usage in QMD:
--   ::: {#fig-consort-flow .figure width="80%" align="center"}
--   ![](images/flow.png)
--
--   **Figure 1.** Caption text with [@citation].
--   :::
--
-- The filter:
--   1. Detects divs with class "figure"
--   2. Emits opening ADDIN DOCSTYLE field code carrying id and attributes
--   3. Passes through all inner blocks (image + caption paragraph) unchanged
--   4. Emits closing field code
--
-- On re-harvest, detect_docstyle_field_codes() finds these markers,
-- handle_docstyle_figure() reconstructs the div_open with the original id,
-- and the harvest loop emits the figure div with the correct QMD id.

local fcu = require("field-code-utils")

-- Normalise FORMAT: Quarto passes "docx" at runtime; shadow and re-map to "openxml"
-- so all checks use the canonical name (same pattern as table-style.lua, list-style.lua).
local FORMAT = "openxml"

local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write("[figure] " .. msg .. "\n")
  end
end

-- Div attributes excluded from the field code payload (Pandoc-internal)
local skip_attr_keys = { ["data-pos"] = true }

-- Process Div elements with class "figure"
function Div(div)
  if FORMAT ~= "openxml" then
    return nil
  end

  -- Only handle divs with the "figure" class
  local is_figure = false
  for _, class in ipairs(div.classes) do
    if class == "figure" then
      is_figure = true
      break
    end
  end
  if not is_figure then
    return nil
  end

  -- Collect the QMD id (from div.identifier) and attributes
  local fig_id = div.identifier
  if not fig_id or fig_id == "" then
    fig_id = "fig-unknown"
  end

  local attrs = {}
  for key, val in pairs(div.attributes) do
    if val and val ~= "" and not skip_attr_keys[key] then
      attrs[key] = val
    end
  end

  -- Extract image path from the first Para containing an Image inside the div.
  -- This becomes original_path in the field code payload for re-harvest path restoration.
  local original_path = nil
  for _, block in ipairs(div.content) do
    if block.t == "Para" then
      for _, inline in ipairs(block.content) do
        if inline.t == "Image" then
          original_path = inline.src
          break
        end
      end
    end
    if original_path then break end
  end
  if original_path and original_path ~= "" then
    attrs["original_path"] = original_path
  end

  debug("Processing .figure div: id=" .. fig_id)

  local field_start = fcu.build_figure_field_start(fig_id, attrs)
  local field_end   = fcu.build_block_field_end()

  -- Wrap: field_start | inner blocks | field_end
  local result = pandoc.Blocks({ pandoc.RawBlock("openxml", field_start) })
  for _, block in ipairs(div.content) do
    result:insert(block)
  end
  result:insert(pandoc.RawBlock("openxml", field_end))

  return result
end

-- Normalise FORMAT at document level: Quarto passes "docx", canonicalise to "openxml".
function Pandoc(_)
  if FORMAT == "docx" or FORMAT == "openxml" then
    FORMAT = "openxml"
  end
  return nil
end
