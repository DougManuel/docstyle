# OOXML Technical Notes

Key technical details from Anthropic's ooxml.md reference.

## Track changes structure

### Deletion (`w:del`)
```xml
<w:del w:id="1" w:author="Claude" w:date="2026-01-15T10:00:00Z">
  <w:r>
    <w:delText>deleted text</w:delText>
  </w:r>
</w:del>
```

### Insertion (`w:ins`)
```xml
<w:ins w:id="2" w:author="Claude" w:date="2026-01-15T10:00:00Z">
  <w:r>
    <w:t>inserted text</w:t>
  </w:r>
</w:ins>
```

### Critical rules
- **Never nest inside `w:r`** - creates invalid XML
- Deleted text uses `w:delText`, not `w:t`
- RSIDs: 8-digit hex only (0-9, A-F)
- Required attributes: `w:id`, `w:author`, `w:date`

## Nested changes pattern

When modifying another author's tracked change:

```xml
<!-- Original: Jane inserted "hello world" -->
<w:ins w:id="1" w:author="Jane Smith" w:date="...">
  <w:r><w:t>hello world</w:t></w:r>
</w:ins>

<!-- Claude changes "world" to "universe" -->
<w:ins w:id="1" w:author="Jane Smith" w:date="...">
  <w:r><w:t>hello </w:t></w:r>
  <w:del w:id="2" w:author="Claude" w:date="...">
    <w:r><w:delText>world</w:delText></w:r>
  </w:del>
  <w:ins w:id="3" w:author="Claude" w:date="...">
    <w:r><w:t>universe</w:t></w:r>
  </w:ins>
</w:ins>
```

This preserves authorship chain - Jane's original insertion contains Claude's modification.

## Unicode and entity handling

Both work interchangeably:
- Entity: `&#8220;` (curly quote)
- Unicode: `\u201c`

ASCII files use entities; UTF-8 preserves Unicode.

## Comment infrastructure files

Full comment support requires:
1. `word/comments.xml` - Comment content
2. `word/commentsExtended.xml` - Extended metadata
3. `word/commentsIds.xml` - ID mapping
4. `word/commentsExtensible.xml` - Future extensibility
5. `word/people.xml` - Author metadata
6. `word/_rels/document.xml.rels` - Relationship declarations

## Namespace declarations

Common namespaces:
```xml
xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
xmlns:w16du="http://schemas.microsoft.com/office/word/2023/wordml/word16du"
xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
```

Add conditionally to avoid duplication.
