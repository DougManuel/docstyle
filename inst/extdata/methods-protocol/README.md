# Methods protocol

Scaffolded by `docstyle::use_methods_protocol()`.

This directory contains a Quarto-based methods protocol configured for
both Word editing (with Zotero field codes) and medRxiv-ready preprint
output.

## Files

- `protocol.qmd` — main protocol document (PRISMA-ScR or PRISMA-P
  scaffolded sections — replace placeholder text with your content)
- `_quarto.yml` — format configuration (`docstyle-docx` for Word and
  `docstyle-typst` with `medrxiv: true` for preprint PDF)
- `references.bib` — bibliography (used by the Typst preprint path;
  the Word path uses Zotero field codes directly)
- `supplements/` — supplementary materials (search strategy, data
  charting/extraction fields, screening prompts)
- `_extensions/docstyle/` — bundled docstyle extension (do not edit
  directly; update via `docstyle::update_extension()`)

## Render

Both formats render from the same source:

```bash
quarto render protocol.qmd                    # renders both
quarto render protocol.qmd --to docstyle-docx # Word only
quarto render protocol.qmd --to docstyle-typst # PDF only
```

Output files land in `output/`.

## Submission checklist

Before submitting to medRxiv (or another preprint server):

- [ ] Replace all `{{TITLE}}` and `<placeholder>` text in `_quarto.yml`
      and `protocol.qmd`
- [ ] Complete the author block in `_quarto.yml` (real names, ORCIDs,
      affiliations, CRediT roles)
- [ ] Complete the abstract — make sure the structured sections
      (Background, Methods, etc.) match medRxiv's expected shape
- [ ] Register the protocol on PROSPERO (PRISMA-P) or OSF (PRISMA-ScR)
      and add the registration ID/URL to the Methods section
- [ ] Populate `supplements/search-strategy.json` with the actual
      search strategy
- [ ] Populate `supplements/data-charting-fields.csv` (or
      `data-extraction-fields.csv`) with the field list
- [ ] Add a PRISMA-ScR or PRISMA-P checklist as a supplementary file
- [ ] Add ICMJE author contribution forms (signed, kept locally)
- [ ] Render the PDF and verify with `pdfinfo` that `Tagged: yes`
- [ ] Cross-post to OSF Preprints

### Final pre-flight (run immediately before submission)

- [ ] No `{{TITLE}}`, `{{DATE}}`, or `<placeholder>` markers anywhere
      in the rendered PDF (search the extracted text)
- [ ] If you opted into PDF/UA-1 (`pdf-standard: ua-1`): run
      [veraPDF](https://verapdf.org/) on the output and confirm
      conformance (the docstyle default does NOT enable UA-1; it's
      opt-in because UA-1 is strict about list structure and image
      alt text)
- [ ] Word output (if used): confirm Zotero field codes still resolve
      cleanly when opened in Word
