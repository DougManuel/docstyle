# P1: Track changes OOXML injection

## Objective

Fix `revisions-inject.lua` to generate valid OOXML track changes that Word recognizes, including attribute auto-injection from `revisions.json`.

## Current state

- Harvest extracts track changes as Pandoc spans: `[text]{.ins id="rev_X"}` and `[~~text~~]{.del id="rev_X"}`
- Metadata stored in `_docstyle/revisions.json` with author, date, content
- `revisions-inject.lua` attempts to convert spans back to OOXML but:
  - Doesn't consistently use metadata from revisions.json
  - May generate invalid structure in some contexts
  - Loses original author attribution

## Requirements

1. **Valid OOXML structure** - Track changes must render correctly in Word
2. **Author preservation** - Original author/date from revisions.json, not hardcoded
3. **Proper nesting** - Follow Anthropic's pattern for nested changes (issue #10)

## Implementation plan

### Phase 1: Read revisions.json in Lua filter

**File:** `_extensions/docstyle/revisions-inject.lua`

```lua
-- At filter initialization
local revisions_data = {}

function Meta(meta)
  -- Read revisions.json from _docstyle/
  local revisions_path = "_docstyle/revisions.json"
  local f = io.open(revisions_path, "r")
  if f then
    local content = f:read("*all")
    f:close()
    revisions_data = pandoc.json.decode(content) or {}
  end
  return meta
end
```

### Phase 2: Auto-inject attributes from metadata

```lua
local function get_revision_metadata(rev_id)
  local rev = revisions_data[rev_id]
  if rev then
    return {
      author = rev.author or "Unknown",
      date = rev.date or os.date("!%Y-%m-%dT%H:%M:%SZ"),
      id = rev_id:gsub("rev_", "")
    }
  end
  -- Fallback for revisions not in JSON
  return {
    author = "Unknown",
    date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    id = rev_id:gsub("rev_", "") or "0"
  }
end
```

### Phase 3: Generate valid OOXML for insertions

```lua
function process_insertion(el)
  local rev_id = el.attributes.id
  local meta = get_revision_metadata(rev_id)
  local text = pandoc.utils.stringify(el.content)

  -- Escape XML entities
  text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

  -- Handle whitespace preservation
  local space_attr = ""
  if text:match("^%s") or text:match("%s$") then
    space_attr = ' xml:space="preserve"'
  end

  local xml = string.format(
    '<w:ins w:id="%s" w:author="%s" w:date="%s">' ..
    '<w:r><w:t%s>%s</w:t></w:r>' ..
    '</w:ins>',
    meta.id,
    meta.author:gsub('"', '&quot;'),
    meta.date,
    space_attr,
    text
  )

  return pandoc.RawInline('openxml', xml)
end
```

### Phase 4: Generate valid OOXML for deletions

```lua
function process_deletion(el)
  local rev_id = el.attributes.id
  local meta = get_revision_metadata(rev_id)

  -- Extract text from strikethrough content
  local text = pandoc.utils.stringify(el.content)
  text = text:gsub("^~~", ""):gsub("~~$", "")  -- Remove ~~ markers
  text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

  local space_attr = ""
  if text:match("^%s") or text:match("%s$") then
    space_attr = ' xml:space="preserve"'
  end

  -- Note: deletions use w:delText, not w:t
  local xml = string.format(
    '<w:del w:id="%s" w:author="%s" w:date="%s">' ..
    '<w:r><w:delText%s>%s</w:delText></w:r>' ..
    '</w:del>',
    meta.id,
    meta.author:gsub('"', '&quot;'),
    meta.date,
    space_attr,
    text
  )

  return pandoc.RawInline('openxml', xml)
end
```

### Phase 5: Handle nested track changes (issue #10)

When a deletion appears inside an insertion (or vice versa), preserve the nesting:

```lua
-- Detect if we're inside another track change
local track_change_stack = {}

function Span(el)
  if el.classes:includes('ins') then
    table.insert(track_change_stack, 'ins')
    local result = process_insertion(el)
    table.remove(track_change_stack)
    return result
  elseif el.classes:includes('del') then
    table.insert(track_change_stack, 'del')
    local result = process_deletion(el)
    table.remove(track_change_stack)
    return result
  end
  return nil
end
```

## Testing plan

1. **Unit test:** Create QMD with `.ins`/`.del` spans, render, verify OOXML structure
2. **Round-trip test:** Harvest → render → open in Word → verify track changes visible
3. **Author preservation test:** Verify original author appears in Word, not "Unknown"
4. **Nested changes test:** Create nested spans, verify Word shows correct authorship chain

## Files to modify

- `_extensions/docstyle/revisions-inject.lua` - Main implementation
- `tests/testthat/test-revisions-inject.R` - New test file
- `vignettes/comments-revisions.qmd` - Update documentation

## Success criteria

- [ ] Track changes visible in Word with correct formatting
- [ ] Original author/date preserved from revisions.json
- [ ] Deletions show as strikethrough with red markup
- [ ] Insertions show as underline with author colour
- [ ] Nested changes preserve authorship chain
