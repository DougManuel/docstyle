-- comment-inject.lua
-- Pandoc Lua filter that converts comment markers to OpenXML comment markers
--
-- Supported formats (HTML comments only):
--   1. Range comment: <!-- comment:start id="1" -->text<!-- comment:end id="1" -->
--   2. Point comment: <!-- comment id="1" -->
--
-- The HTML comment format is robust because it can span complex structures
-- like tracked changes, multiple paragraphs, and nested formatting without
-- breaking Pandoc's parsing.
--
-- Fallback behavior:
--   - Start marker without end: Converts to point comment at document end
--   - End marker without start: Ignored (orphan end markers are harmless)
--
-- After rendering, R post-processing (inject_comments) adds the actual
-- comments.xml file to the DOCX container.

-- Debug logging (set DOCSTYLE_DEBUG=1 to enable)
local DEBUG = os.getenv("DOCSTYLE_DEBUG") == "1"
local function debug(msg)
  if DEBUG then
    io.stderr:write(msg)
  end
end

-- Load shared field code utilities
local fcu = require("field-code-utils")
local xml_escape = fcu.xml_escape
local parse_comment_marker = fcu.parse_comment_marker

-- Track comment states for fallback handling:
--   "started" = saw start marker, waiting for end
--   "completed" = saw both start and end (proper range comment)
--   "point" = point comment (no range, just a marker)
local comment_states = {}

-- Generate OpenXML for comment range start
local function comment_start_xml(id)
  return '<w:commentRangeStart w:id="' .. xml_escape(id) .. '"/>'
end

-- Generate OpenXML for comment range end (includes the clickable reference marker)
local function comment_end_xml(id)
  return '<w:commentRangeEnd w:id="' .. xml_escape(id) .. '"/>' ..
         '<w:r><w:rPr></w:rPr><w:commentReference w:id="' .. xml_escape(id) .. '"/></w:r>'
end

-- Generate OpenXML for point comment (start + end + reference together)
local function comment_point_xml(id)
  return '<w:commentRangeStart w:id="' .. xml_escape(id) .. '"/>' ..
         '<w:commentRangeEnd w:id="' .. xml_escape(id) .. '"/>' ..
         '<w:r><w:rPr></w:rPr><w:commentReference w:id="' .. xml_escape(id) .. '"/></w:r>'
end

-- Process RawInline elements for HTML comment markers
function RawInline(el)
  -- Only process for Word output
  if FORMAT ~= "docx" and FORMAT ~= "openxml" then
    return nil
  end

  -- Only process HTML raw content (where our markers live)
  if el.format ~= "html" then
    return nil
  end

  local id, marker_type = parse_comment_marker(el.text)
  if not id then
    return nil  -- Not a comment marker, leave as-is
  end

  if marker_type == "point" then
    -- Simple point comment - emit complete marker
    debug("[comment-inject] Found point comment id=" .. id .. "\n")
    comment_states[id] = "point"
    return pandoc.RawInline('openxml', comment_point_xml(id))

  elseif marker_type == "start" then
    debug("[comment-inject] Found comment start marker id=" .. id .. "\n")
    comment_states[id] = "started"
    -- Emit only the start marker; end will come later (or we'll close at doc end)
    return pandoc.RawInline('openxml', comment_start_xml(id))

  elseif marker_type == "end" then
    if comment_states[id] == "started" then
      -- Normal case: matching end for a start we saw
      debug("[comment-inject] Found comment end marker id=" .. id .. "\n")
      comment_states[id] = "completed"
      return pandoc.RawInline('openxml', comment_end_xml(id))
    elseif comment_states[id] == "completed" then
      -- Duplicate end marker - ignore
      debug("[comment-inject] Warning: duplicate end marker id=" .. id .. " (ignoring)\n")
      return pandoc.RawInline('openxml', '')  -- Empty, effectively removes it
    else
      -- Orphan end marker (no matching start) - ignore
      debug("[comment-inject] Warning: orphan end marker id=" .. id .. " (no matching start, ignoring)\n")
      return pandoc.RawInline('openxml', '')  -- Empty, effectively removes it
    end
  end

  return nil
end

-- Handle orphan start markers at document end
function Pandoc(doc)
  if FORMAT ~= "docx" and FORMAT ~= "openxml" then
    return nil
  end

  debug("[comment-inject] Filter active for Word output\n")

  -- Check for orphan start markers (started but never completed)
  -- These need to be closed at the end of the document
  local orphan_ids = {}
  for id, state in pairs(comment_states) do
    if state == "started" then
      table.insert(orphan_ids, id)
    end
  end

  if #orphan_ids == 0 then
    return nil  -- No orphans, document unchanged
  end

  -- We have orphan start markers - inject end markers at end of document
  debug("[comment-inject] Warning: " .. #orphan_ids .. " orphan start marker(s) found, closing at document end\n")
  for _, id in ipairs(orphan_ids) do
    debug("[comment-inject]   - Orphan comment id=" .. id .. "\n")
    comment_states[id] = "point"
  end

  -- Inject the end+reference markers at the very end of the document
  if #doc.blocks > 0 then
    local last_block = doc.blocks[#doc.blocks]

    -- Create the closing XML for all orphan comments
    local closing_inlines = {}
    for _, id in ipairs(orphan_ids) do
      table.insert(closing_inlines, pandoc.RawInline('openxml', comment_end_xml(id)))
    end

    -- Append to last block based on its type
    if last_block.t == "Para" or last_block.t == "Plain" then
      for _, inline in ipairs(closing_inlines) do
        table.insert(last_block.content, inline)
      end
    else
      -- For other block types, add a new Plain block with the closures
      table.insert(doc.blocks, pandoc.Plain(closing_inlines))
    end
  end

  return doc
end

return {
  -- First pass: process inline elements (populates comment_states)
  { RawInline = RawInline },
  -- Second pass: handle orphan comments at document level
  { Pandoc = Pandoc }
}
