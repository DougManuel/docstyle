# P2: commentsExtended.xml support

## Objective

Add support for Word's extended comment metadata files to enable comment threading, resolved status, and richer attribution.

## Current state

- Harvest extracts comments from `word/comments.xml` to `_docstyle/comments.json`
- `comments-inject.lua` injects comments back into `word/comments.xml`
- Missing: `commentsExtended.xml`, `commentsIds.xml`, `commentsExtensible.xml`, `people.xml`

## Why this matters

Word uses 5 files for full comment support:

| File | Purpose | Current support |
|------|---------|-----------------|
| `comments.xml` | Comment content | ✓ Read/write |
| `commentsExtended.xml` | Threading, resolved status | ✗ Not supported |
| `commentsIds.xml` | ID mapping for threading | ✗ Not supported |
| `commentsExtensible.xml` | Future extensibility | ✗ Not supported |
| `people.xml` | Author metadata | ✗ Not supported |

Without these, we lose:
- Comment replies (threading)
- "Resolved" status
- Consistent author attribution across sessions

## Implementation plan

### Phase 1: Extend comments.json schema

Update harvest to extract extended metadata:

```json
{
  "27": {
    "id": "27",
    "author": "Sarah Beach",
    "initials": "SB",
    "date": "2026-01-08T10:49:00Z",
    "content": "Should protocol be updated...",
    "parent_id": null,
    "resolved": false,
    "done": false
  },
  "28": {
    "id": "28",
    "author": "Doug Manuel",
    "initials": "DGM",
    "date": "2026-01-12T09:57:00Z",
    "content": "Yes. Karim has started that work.",
    "parent_id": "27",
    "resolved": false,
    "done": false
  }
}
```

### Phase 2: Update R extraction

**File:** `R/comments.R`

```r
extract_comments <- function(docx_path) {
  # ... existing extraction ...

  # Also read commentsExtended.xml if present
  extended_path <- file.path(temp_dir, "word", "commentsExtended.xml")
  if (file.exists(extended_path)) {
    extended_xml <- xml2::read_xml(extended_path)
    # Extract paraIdParent for threading
    # Extract done status
  }

  # Read people.xml for author metadata
  people_path <- file.path(temp_dir, "word", "people.xml")
  if (file.exists(people_path)) {
    # Extract author details
  }

  comments
}
```

### Phase 3: Generate extended files on render

**File:** `_extensions/docstyle/comments-inject.lua` (post-render hook)

After injecting comments.xml, also generate:

1. **commentsExtended.xml:**
```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w15:commentsEx xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">
  <w15:commentEx w15:paraId="..." w15:done="0"/>
</w15:commentsEx>
```

2. **commentsIds.xml:**
```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w16cid:commentsIds xmlns:w16cid="http://schemas.microsoft.com/office/word/2016/wordml/cid">
  <w16cid:commentId w16cid:paraId="..." w16cid:durableId="..."/>
</w16cid:commentsIds>
```

3. **people.xml:**
```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:people xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:person w:author="Sarah Beach">
    <w:presenceInfo w:providerId="None" w:userId="Sarah Beach"/>
  </w:person>
</w:people>
```

### Phase 4: Update relationships

Add entries to `word/_rels/document.xml.rels`:

```xml
<Relationship Id="rIdCommentsExtended"
  Type="http://schemas.microsoft.com/office/2011/relationships/commentsExtended"
  Target="commentsExtended.xml"/>
<Relationship Id="rIdPeople"
  Type="http://schemas.microsoft.com/office/2011/relationships/people"
  Target="people.xml"/>
```

### Phase 5: Handle comment threading

When rendering replies:
1. Assign unique `paraId` to each comment
2. Set `paraIdParent` for replies pointing to parent's `paraId`
3. Word will display as threaded conversation

## Testing plan

1. **Harvest test:** Extract document with threaded comments, verify parent_id captured
2. **Render test:** Create comments.json with threading, render, verify Word shows thread
3. **Resolved test:** Mark comment as resolved in JSON, verify Word shows resolved status

## Files to modify

- `R/comments.R` - Extract extended metadata
- `_extensions/docstyle/comments-inject.lua` - Generate extended files
- `R/inject_comments.R` - R-side injection support
- `tests/testthat/test-comments-extended.R` - New tests

## Success criteria

- [ ] Comment replies appear threaded in Word
- [ ] Resolved status persists through round-trip
- [ ] Author metadata consistent (name, initials)
- [ ] No warnings from Word about missing relationships
