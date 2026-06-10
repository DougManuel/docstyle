# Supplementary materials

This directory holds machine-readable supplementary material that
travels with the protocol.

## Recommended structure

| File | Purpose |
|------|---------|
| `search-strategy.json` | Database-specific search strings (MeSH terms, free-text combinations, Boolean logic) in a structured form |
| `data-charting-fields.csv` (PRISMA-ScR) | List of fields the data-charting form will capture, with definitions |
| `data-extraction-fields.csv` (PRISMA-P) | List of fields the data-extraction form will capture, with definitions |
| `inclusion-criteria.csv` | PCC or PICO elements with operational definitions |
| `screening-prompts.json` (if AI-assisted screening) | Exact prompts used in any LLM-based screening, with model versions and decision thresholds |
| `prisma-checklist.pdf` | The completed PRISMA-ScR or PRISMA-P checklist |

Why machine-readable? Reviewers, systematic-review software, and
downstream meta-analyses can consume CSV/JSON directly. PDFs of these
artifacts work but lock the data away from automated tooling.
