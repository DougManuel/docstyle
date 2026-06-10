-- zotero-inject.lua
-- Pandoc Lua filter that emits text markers for Zotero citation field codes.
--
-- The R finisher (inject_zotero_citations) replaces these markers with real
-- Word field code XML after Pandoc has finished rendering to docx.
--
-- Markers:
--   DOCSTYLE_CITE::key1;key2   – citation (single or grouped)
--   DOCSTYLE_CITE_BIBL          – bibliography placeholder
--
-- Usage:
--   pandoc --lua-filter=zotero-inject.lua -M field-codes=path/to/field-codes.json ...

-- Debug logging (set DOCSTYLE_DEBUG=1 to enable)
local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write(msg)
  end
end

-- Citekey existence lookup (populated from field-codes.json citations section)
local known_citekeys = {}

-- Check if file exists
local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- Read field-codes.json at startup; populate known_citekeys
function Meta(meta)
  local field_codes_path = nil

  -- Get path from metadata (explicit override)
  if meta["field-codes"] then
    field_codes_path = pandoc.utils.stringify(meta["field-codes"])
  end

  -- Auto-detect common locations if not specified
  if not field_codes_path then
    debug("[zotero-inject] Looking for field-codes.json...\n")
    local search_paths = {
      "_docstyle/field-codes.json",
      "field-codes.json",
      "../_docstyle/field-codes.json"
    }
    for _, path in ipairs(search_paths) do
      debug("[zotero-inject] Checking: " .. path .. "\n")
      if file_exists(path) then
        field_codes_path = path
        debug("[zotero-inject] Found field-codes.json: " .. path .. "\n")
        break
      end
    end
  end

  if not field_codes_path then
    debug("[zotero-inject] No field-codes.json found; markers will not be emitted\n")
    return nil
  end

  -- Read and parse the JSON file
  local file = io.open(field_codes_path, "r")
  if not file then
    debug("[zotero-inject] Could not open: " .. field_codes_path .. "\n")
    return nil
  end

  local content = file:read("*all")
  file:close()

  local ok, parsed = pcall(function()
    return pandoc.json.decode(content)
  end)

  if not ok then
    debug("[zotero-inject] Failed to parse field-codes.json\n")
    return nil
  end

  -- Build citekey existence set from citations catalog
  local count = 0
  if parsed.citations then
    for citekey, _ in pairs(parsed.citations) do
      known_citekeys[citekey] = true
      count = count + 1
    end
  end
  debug("[zotero-inject] Loaded " .. count .. " citekey(s) from field-codes.json\n")

  return nil
end

-- Process Cite elements: emit text markers instead of raw OpenXML
function Cite(cite)
  local citekeys = {}
  for _, citation in ipairs(cite.citations) do
    table.insert(citekeys, citation.id)
  end

  if #citekeys == 0 then
    return nil
  end

  -- All citekeys must be known; otherwise fall back to Pandoc default rendering
  for _, citekey in ipairs(citekeys) do
    if not known_citekeys[citekey] then
      debug("[zotero-inject] Skipping (unknown citekey): " .. citekey .. "\n")
      return nil
    end
  end

  local marker = "DOCSTYLE_CITE::" .. table.concat(citekeys, ";")
  debug("[zotero-inject] Emitting marker: " .. marker .. "\n")
  return pandoc.Str(marker)
end

-- Process Div elements: emit bibliography marker for bibliography placeholder
function Div(div)
  if div.classes:includes("bibliography") then
    debug("[zotero-inject] Emitting bibliography marker from div\n")
    return pandoc.Para({ pandoc.Str("DOCSTYLE_CITE_BIBL") })
  end
  return nil
end

return {
  { Meta = Meta },
  { Cite = Cite },
  { Div = Div }
}
