# Lessons from Anthropic docx Skill

Key patterns and approaches from the Anthropic docx skill that inform docstyle development.

## Track changes handling

### Anthropic approach
- Track changes (`w:ins`, `w:del`) positioned at **paragraph level**, never nested inside `w:r`
- Required attributes: `w:id`, `w:author`, `w:date`, `w16du:dateUtc`
- RSIDs must be 8-digit hex (0-9, A-F)
- Nested changes: When modifying another author's tracked change, nest Claude's change inside their element (preserves original authorship)

### Applied to docstyle
- **Current:** We extract track changes during harvest but don't inject them back as proper OOXML
- **Improvement opportunity:** The `revisions-inject.lua` filter could generate proper OOXML structure following Anthropic's nesting pattern
- **Key insight:** Nesting changes rather than flattening preserves authorship chain

## Comments handling

### Anthropic approach
- Comments require updates to **5 XML files**: comments.xml, commentsExtended.xml, commentsIds.xml, commentsExtensible.xml, plus people.xml
- Comment replies use `parent_comment_id` for threading
- Infrastructure files auto-generated on first comment

### Applied to docstyle
- **Current:** We extract comments to JSON and inject via Lua filter
- **Gap:** We only handle comments.xml, not the extended metadata files
- **Improvement opportunity:** Add commentsExtended.xml support for richer comment metadata (resolved status, threading)

## Validation patterns

### Anthropic approach
- Reconstructs original document by reverting changes, then compares
- Validates both current and "clean" states
- Uses temporary directories for rollback capability

### Applied to docstyle
- **Current:** `validate_docx_structure()` checks basic XML validity
- **Improvement opportunity:** Add "round-trip validation" that harvests → renders → compares

## Namespace management

### Anthropic approach
- `_ensure_w16du_namespace()` conditionally adds namespaces
- Avoids duplication, maintains schema compliance

### Applied to docstyle
- **Current:** Lua filters emit raw XML strings
- **Improvement opportunity:** More robust namespace handling in OOXML injection

## Attribute auto-injection

### Anthropic approach
- `_inject_attributes_to_nodes()` automatically adds RSID, author, date
- Convention over configuration - reduces boilerplate

### Applied to docstyle
- **Current:** revisions.json stores metadata but it's not consistently used during injection
- **Improvement opportunity:** Auto-inject author/date from revisions.json during render

---

## Priority improvements for docstyle

1. **P1:** Fix track changes injection to generate valid OOXML (see plan-track-changes.md)
   - Includes: Attribute auto-injection from revisions.json (preserve original author/date)
2. **P2:** Add commentsExtended.xml support for comment threading
3. **P3:** Add round-trip validation test
4. **P3:** Improve namespace handling in Lua filters

## Parked for future consideration

- **DOM manipulation pattern:** Direct DOCX editing without QMD round-trip (see GitHub issue #13)
