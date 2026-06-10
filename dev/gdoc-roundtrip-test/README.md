# Google Docs Round-Trip Field Code Survival Test

Tests what survives a DOCX → Google Doc → DOCX round-trip, to determine if the DOCX-as-intermediate architecture is viable for Google Docs collaboration (issue #111).

## Test documents

| File | Features |
|------|----------|
| `minimal-example.docx` | 4 Zotero citations, 1 bibliography, 18 bookmarks, 71 styles, 3 sections |
| `comments-revisions-test-roundtrip.docx` | 8 comments, 5 insertions, 4 deletions, 4 bookmarks, 77 styles |

## Steps

### 1. Baselines (already generated)

```bash
python3 extract_inventory.py ../../inst/extdata/minimal-example/minimal-example.docx minimal-before.json
python3 extract_inventory.py ../../inst/extdata/minimal-example/comments-revisions-test-roundtrip.docx comments-before.json
```

### 2. Google Docs round-trip (manual, iPad-friendly)

For each test DOCX:

1. Open [drive.google.com](https://drive.google.com) on iPad
2. Tap **+ New** → **File upload** → select the DOCX from `inst/extdata/minimal-example/`
3. Once uploaded, tap the file → **Open with Google Docs**
4. In Google Docs: **File** → **Download** → **Microsoft Word (.docx)**
5. Place the downloaded file here as:
   - `minimal-after-gdoc.docx`
   - `comments-after-gdoc.docx`

### 3. Extract after-inventories

```bash
python3 extract_inventory.py minimal-after-gdoc.docx minimal-after.json
python3 extract_inventory.py comments-after-gdoc.docx comments-after.json
```

### 4. Compare

```bash
python3 compare_inventory.py minimal-before.json minimal-after.json minimal-report.json
python3 compare_inventory.py comments-before.json comments-after.json comments-report.json
```

## Interpreting results

Each category gets a verdict:
- **SURVIVED** — same count before and after
- **PARTIAL** — some items survived, some lost
- **LOST** — all items gone
- **N/A** — nothing to test (0 before, 0 after)

Critical categories for the DOCX-intermediate architecture:
- **Zotero field codes**: Must survive for citation round-trip
- **Comments**: Must survive for collaboration workflow
- **Tracked changes**: Nice-to-have (Google Docs uses "suggestions" instead)
- **Bookmarks**: Important for cross-references
- **Styles**: Important for harvest pipeline style resolution
