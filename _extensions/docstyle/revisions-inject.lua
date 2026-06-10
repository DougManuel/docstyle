-- revisions-inject.lua
-- Pandoc Lua filter that converts revision spans to OpenXML track changes
--
-- Usage in QMD:
--   Insertions: [inserted text]{.ins id="rev_101"}
--   Deletions:  [~~deleted text~~]{.del id="rev_102"}
--
-- The filter reads revision metadata from a sidecar JSON file (revisions.json)
-- which contains author, date, and other metadata for each revision.
--
-- Metadata loading (in priority order):
--   1. -M revisions-file:path/to/revisions.json (explicit path)
--   2. Auto-detect _docstyle/revisions.json (convention-based)
--
-- Note: Deletions use strikethrough syntax with a .del class wrapper.
-- This is achieved via a Span around the Strikeout:
--   [~~deleted~~]{.del id="x"}

-- Debug logging (set DOCSTYLE_DEBUG=1 to enable)
local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write(msg)
  end
end

-- Metadata storage for revisions (loaded from revisions.json)
local revisions_meta = {}
local revisions_loaded = false

-- Helper function to escape XML special characters
local function xml_escape(text)
  if not text then return "" end
  text = text:gsub("&", "&amp;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  text = text:gsub('"', "&quot;")
  text = text:gsub("'", "&apos;")
  return text
end

-- Helper to generate xml:space attribute for whitespace preservation
-- Word requires xml:space="preserve" when text has leading/trailing whitespace
local function get_space_attr(text)
  if text and (text:match("^%s") or text:match("%s$") or text:match("%s%s")) then
    return ' xml:space="preserve"'
  end
  return ""
end

-- Helper to extract numeric ID from revision ID string (e.g., "rev_9" -> "9")
-- Word requires numeric w:id values
local function get_numeric_id(id)
  if not id then return "0" end
  local num = id:match("rev_(%d+)")
  if num then return num end
  -- If already numeric or doesn't match pattern, return as-is
  return id:match("^%d+$") and id or "0"
end

-- Helper to get revision metadata by ID
local function get_revision(id)
  if revisions_meta[id] then
    return revisions_meta[id]
  end
  -- Return defaults if not found
  return {
    author = "Unknown",
    date = "2025-01-01T00:00:00Z"
  }
end

-- Extract text and RawInlines from inline elements
-- Returns: { text = "plain text", raw_inlines = { {pos="before|after", el=RawInline}, ... } }
-- RawInlines (like comment markers) are preserved for output outside the deletion
local function extract_deletion_content(inlines)
  local text_parts = {}
  local raw_inlines_before = {}  -- RawInlines that appear before any text
  local raw_inlines_after = {}   -- RawInlines that appear after text starts
  local seen_text = false

  local function process_inlines(items)
    for _, inline in ipairs(items) do
      if inline.t == "Str" then
        table.insert(text_parts, inline.text)
        seen_text = true
      elseif inline.t == "Space" then
        table.insert(text_parts, " ")
        seen_text = true
      elseif inline.t == "SoftBreak" then
        table.insert(text_parts, " ")
        seen_text = true
      elseif inline.t == "LineBreak" then
        table.insert(text_parts, "\n")
        seen_text = true
      elseif inline.t == "RawInline" and inline.format == "openxml" then
        -- Preserve OpenXML RawInlines (e.g., comment markers from comment-inject.lua)
        if seen_text then
          table.insert(raw_inlines_after, inline)
        else
          table.insert(raw_inlines_before, inline)
        end
      elseif inline.t == "Strikeout" then
        -- Recursively process strikeout content
        process_inlines(inline.content)
      elseif inline.content then
        process_inlines(inline.content)
      end
    end
  end

  process_inlines(inlines)

  return {
    text = table.concat(text_parts),
    raw_before = raw_inlines_before,
    raw_after = raw_inlines_after
  }
end

-- Legacy function for backward compatibility (insertions still use this)
local function stringify_inlines(inlines)
  local result = extract_deletion_content(inlines)
  return result.text
end

-- Process Span elements with .ins class (insertions)
function Span(el)
  -- Only process for Word output
  if FORMAT ~= "docx" and FORMAT ~= "openxml" then
    return nil
  end

  -- Handle insertions (.ins class)
  if el.classes:includes('ins') then
    -- Pandoc parses {.ins id="x"} with "id" as the identifier, not an attribute
    local id = el.identifier
    if (not id or id == "") then
      id = el.attributes['id'] or "0"
    end
    local rev = get_revision(id)

    debug("[revisions-inject] Processing insertion id=" .. id .. "\n")

    -- Build w:ins wrapper (use numeric ID for Word compatibility)
    local numeric_id = get_numeric_id(id)
    local start_xml = string.format(
      '<w:ins w:id="%s" w:author="%s" w:date="%s">',
      xml_escape(numeric_id),
      xml_escape(rev.author),
      xml_escape(rev.date)
    )
    local end_xml = '</w:ins>'

    local result = { pandoc.RawInline('openxml', start_xml) }

    -- Add content
    for _, item in ipairs(el.content) do
      table.insert(result, item)
    end

    table.insert(result, pandoc.RawInline('openxml', end_xml))
    return result
  end

  -- Handle deletions (.del class wrapping strikethrough)
  -- Pattern: [~~deleted text~~]{.del id="x"}
  if el.classes:includes('del') then
    -- Pandoc parses {.del id="x"} with "id" as the identifier, not an attribute
    local id = el.identifier
    if (not id or id == "") then
      id = el.attributes['id'] or "0"
    end
    local rev = get_revision(id)

    debug("[revisions-inject] Processing deletion id=" .. id .. "\n")

    -- Extract text and any RawInlines (like comment markers) from content
    local content = extract_deletion_content(el.content)
    local del_text = content.text

    -- Remove any remaining strikethrough markers (~~ ) that may have leaked through
    del_text = del_text:gsub("~~", "")

    -- Build w:del with w:delText (use numeric ID for Word compatibility)
    -- Include xml:space="preserve" if text has significant whitespace
    local numeric_id = get_numeric_id(id)
    local space_attr = get_space_attr(del_text)
    local del_xml = string.format(
      '<w:del w:id="%s" w:author="%s" w:date="%s">' ..
      '<w:r><w:delText%s>%s</w:delText></w:r>' ..
      '</w:del>',
      xml_escape(numeric_id),
      xml_escape(rev.author),
      xml_escape(rev.date),
      space_attr,
      xml_escape(del_text)
    )

    -- Build result: RawInlines before + deletion + RawInlines after
    -- This preserves comment markers that were inside the deletion
    local result = {}

    -- Add any RawInlines that appeared before text (e.g., comment start markers)
    for _, raw in ipairs(content.raw_before) do
      table.insert(result, raw)
      debug("[revisions-inject] Preserving RawInline before deletion\n")
    end

    -- Add the deletion itself
    table.insert(result, pandoc.RawInline('openxml', del_xml))

    -- Add any RawInlines that appeared after text started (e.g., comment end markers)
    for _, raw in ipairs(content.raw_after) do
      table.insert(result, raw)
      debug("[revisions-inject] Preserving RawInline after deletion\n")
    end

    -- Return single element or list depending on whether we have RawInlines
    if #result == 1 then
      return result[1]
    else
      return result
    end
  end

  return nil
end

-- Parse JSON file content into revisions_meta table
-- Uses regex-based parsing that handles our flat JSON structure
local function parse_revisions_json(content, source_path)
  local count = 0

  -- Pattern matches revision entries with author and date fields
  -- Handles both orderings: author before date, or date before author
  for id, block in content:gmatch('"(rev_[^"]+)":%s*(%b{})') do
    local author = block:match('"author":%s*"([^"]*)"')
    local date = block:match('"date":%s*"([^"]*)"')
    local rev_type = block:match('"type":%s*"([^"]*)"')

    if author then
      revisions_meta[id] = {
        author = author,
        date = date or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        type = rev_type
      }
      count = count + 1
      debug("[revisions-inject] Loaded revision: " .. id .. " by " .. author .. "\n")
    end
  end

  if count > 0 then
    debug("[revisions-inject] Loaded " .. count .. " revisions from: " .. source_path .. "\n")
    revisions_loaded = true
  end

  return count
end

-- Try to load revisions from a file path
local function try_load_revisions(path)
  local file = io.open(path, "r")
  if file then
    local content = file:read("*all")
    file:close()
    return parse_revisions_json(content, path)
  end
  return 0
end

-- Load revision metadata from document metadata or auto-detect
-- Priority:
--   1. -M revisions-file:path (explicit)
--   2. _docstyle/revisions.json (convention)
function Meta(meta)
  -- Skip if already loaded
  if revisions_loaded then
    return nil
  end

  -- Priority 1: Explicit path via metadata
  if meta['revisions-file'] then
    local path = pandoc.utils.stringify(meta['revisions-file'])
    debug("[revisions-inject] Trying explicit path: " .. path .. "\n")
    if try_load_revisions(path) > 0 then
      return nil
    end
    debug("[revisions-inject] Warning: Could not open revisions file: " .. path .. "\n")
  end

  -- Priority 2: Auto-detect _docstyle/revisions.json
  local auto_path = "_docstyle/revisions.json"
  debug("[revisions-inject] Trying auto-detect: " .. auto_path .. "\n")
  if try_load_revisions(auto_path) > 0 then
    return nil
  end

  debug("[revisions-inject] No revisions.json found (checked _docstyle/revisions.json)\n")
  return nil
end

-- Check output format
function Pandoc(doc)
  if FORMAT == "docx" or FORMAT == "openxml" then
    debug("[revisions-inject] Filter active for Word output\n")
  end
  return nil
end

return {
  { Meta = Meta },
  { Pandoc = Pandoc },
  { Span = Span }
}
