# vNext Legacy Characterization

This directory contains the migration-only harness for Docstyle vNext work
package 0. It freezes what release 0.19.0 produces; it does not define what
vNext ought to reproduce.

## Evidence model

Each fixture has an expectations.json record. Its statuses mean:

- observed: present in the frozen output and eligible for later acceptance
  testing
- known-bug: reproduced legacy behaviour that vNext must not adopt as its
  contract
- approximated: the legacy backends express similar intent without a shared
  property contract
- omitted: intentionally excluded from the compact fixture, with the reason
  recorded
- unsupported: absent from the legacy engine and assigned to a later work
  package

Normalized JSON inventories are semantic evidence. Selected 110-DPI PNG pages
are visual-review evidence. Binary DOCX and PDF hashes are not regression
assertions because ZIP metadata and render environments can change without a
semantic change.

## Requirements

Baseline capture uses R only as a legacy migration harness. It requires the
current Docstyle package, Quarto, Pandoc and Typst, plus the Poppler commands
pdfinfo, pdftotext and pdftoppm. Fixture sources use only local CSS, CSL,
bibliography and image assets.

## Regenerate release 0.19.0 baselines

From the repository root:

~~~bash
R CMD INSTALL .
quarto check
command -v pdfinfo
command -v pdftotext
command -v pdftoppm
Rscript dev/vnext/characterization/capture-baselines.R --repo-root=.
~~~

Then inspect every changed expectations.json, inventory, DOCX, PDF, JATS file
and selected page image. A changed baseline requires an explanatory
expectation update; never regenerate merely to make a test green. Review the
committed JSON for absolute paths, usernames and render timestamps.

## Visual review

The automated capture rasterizes the selected Typst/PDF pages declared by the
fixture catalogue. For a local Word comparison, open the frozen DOCX in the
target Word version, export it to PDF without accepting revisions, and run:

~~~bash
Rscript -e 'devtools::load_all(quiet = TRUE); source("dev/vnext/characterization/inspect-publication.R"); rasterize_pdf_pages("WORD-EXPORT.pdf", c(1L, 2L), "/tmp/docstyle-word-pages", "docstyle-docx")'
~~~

Review corresponding Word and Typst page images side by side. Do not commit
Word-exported images in work package 0: Word rendering varies by platform and
font installation. Work package 6 will define pinned environments, supported
property equivalence and quantitative visual tolerances.

## Update discipline

Keep each fixture below 5 MiB and the complete fixture tree below 15 MiB.
Change fixture source and its expectation record in the same commit. Preserve
known failures with their issue reference. The R harness remains isolated
under `dev/vnext/characterization/` and must not become a vNext runtime
dependency.
