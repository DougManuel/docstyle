# Anthropic docx Skill Reference

This directory contains reference material from Anthropic's official docx skill for Claude Code.

**Source:** https://github.com/anthropics/skills/tree/main/skills/docx
**License:** Source-available (not open source) - reference only
**Last fetched:** 2026-01-15

## Purpose

This reference material is used to:
1. Understand OOXML patterns for track changes and comments
2. Compare approaches with docstyle's implementation
3. Identify potential improvements to docstyle

## Relationship to docstyle

| Capability | Anthropic docx | docstyle |
|------------|---------------|----------|
| General docx creation | ✓ Primary focus | Via Quarto render |
| OOXML manipulation | ✓ Direct XML editing | Pandoc + Lua filters |
| Track changes | ✓ Full read/write | Read (harvest) + partial write |
| Comments | ✓ Full read/write | ✓ Full read/write |
| Zotero citations | ✗ Not supported | ✓ Primary feature |
| Round-trip (docx ↔ qmd) | ✗ One-way | ✓ Full round-trip |
| Academic workflows | ✗ General purpose | ✓ Designed for research |

## Key learnings applied to docstyle

See `LESSONS.md` for specific patterns adopted from this reference.
