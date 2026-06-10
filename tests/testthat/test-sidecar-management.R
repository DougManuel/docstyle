# Tests for sidecar file management during harvest
# Regression tests for:
#   - https://github.com/DougManuel/docstyle/issues/27
#     (Harvest should write empty sidecars when source lacks content)
#   - https://github.com/DougManuel/docstyle/issues/51
#     (Harvest overwrites field-codes.json when no Zotero citations)


# --- Helpers ---

# Create a minimal valid DOCX with no Zotero, comments, or revisions
create_bare_docx <- function(path) {
  temp_dir <- tempfile("docx_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body><w:p><w:r><w:t>Hello world</w:t></w:r></w:p></w:body>',
    '</w:document>'
  ), file.path(temp_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Override PartName="/word/document.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" ',
    'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" ',
    'Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  old_wd <- setwd(temp_dir)
  on.exit({ setwd(old_wd); unlink(temp_dir, recursive = TRUE) }, add = TRUE)
  zip(path, files = c("[Content_Types].xml", "_rels/.rels", "word/document.xml"),
      flags = "-q")

  path
}

# Seed a field-codes.json with N test citations
seed_field_codes_json <- function(path, n_citations = 3) {
  citations <- list()
  groups <- list()
  for (i in seq_len(n_citations)) {
    key <- paste0("author", 2020 + i)
    citations[[key]] <- list(
      itemData = list(
        type = "article-journal",
        title = paste("Test Article", i),
        author = list(list(family = "Author", given = paste("Test", i))),
        issued = list(`date-parts` = list(list(2020 + i)))
      ),
      uris = list(paste0("http://zotero.org/users/local/test/items/ITEM", i))
    )
    gkey <- paste0("grp_", sprintf("cit%04d", i))
    groups[[gkey]] <- list(
      instrText = paste0("ADDIN ZOTERO_ITEM CSL_CITATION {\"citationID\":\"cit",
                         sprintf("%04d", i), "\"}"),
      properties = list(plainCitation = paste0("(Author, ", 2020 + i, ")"))
    )
  }
  obj <- list(
    docstyle_version = "0.8.0",
    source = "harvest",
    zotero_pref = list(style = list(styleID = "apa")),
    zotero_bibl = NULL,
    citations = citations,
    citationGroups = groups
  )
  writeLines(
    jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE),
    path
  )
}

# Seed a comments.json with N test comments
seed_comments_json <- function(path, n_comments = 3) {
  comments <- list()
  for (i in seq_len(n_comments)) {
    comments[[as.character(i)]] <- list(
      id = as.character(i),
      author = "Test Author",
      date = "2025-01-01T00:00:00Z",
      content = paste("Comment", i),
      done = FALSE
    )
  }
  writeLines(
    jsonlite::toJSON(comments, auto_unbox = TRUE, pretty = TRUE),
    path
  )
}

# Seed a revisions.json with N test revisions
seed_revisions_json <- function(path, n_revisions = 2) {
  revisions <- list()
  for (i in seq_len(n_revisions)) {
    key <- paste0("rev_", i)
    revisions[[key]] <- list(
      id = key,
      type = "insertion",
      author = "Test Author",
      date = "2025-01-01T00:00:00Z",
      content = paste("inserted text", i)
    )
  }
  writeLines(
    jsonlite::toJSON(revisions, auto_unbox = TRUE, pretty = TRUE),
    path
  )
}


# ===========================================================================
# Issue #27: Harvest should write empty sidecars when source lacks content
# ===========================================================================

test_that("#27: harvest writes empty comments.json when document has no comments", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  docx_path <- file.path(temp_dir, "no-comments.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  comments_path <- file.path(sidecar_dir, "comments.json")
  expect_true(file.exists(comments_path))

  comments <- jsonlite::fromJSON(comments_path, simplifyVector = FALSE)
  expect_equal(length(comments), 0)
})

test_that("#27: harvest writes empty revisions.json when document has no revisions", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  docx_path <- file.path(temp_dir, "no-revisions.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  revisions_path <- file.path(sidecar_dir, "revisions.json")
  expect_true(file.exists(revisions_path))

  revisions <- jsonlite::fromJSON(revisions_path, simplifyVector = FALSE)
  expect_equal(length(revisions), 0)
})

test_that("#27: stale comments.json is replaced by empty when document has no comments", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Seed stale sidecar with 3 comments
  comments_path <- file.path(sidecar_dir, "comments.json")
  seed_comments_json(comments_path, n_comments = 3)

  docx_path <- file.path(temp_dir, "no-comments.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  comments <- jsonlite::fromJSON(comments_path, simplifyVector = FALSE)
  expect_equal(length(comments), 0)
})

test_that("#27: stale revisions.json is replaced by empty when document has no revisions", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Seed stale sidecar with 2 revisions
  revisions_path <- file.path(sidecar_dir, "revisions.json")
  seed_revisions_json(revisions_path, n_revisions = 2)

  docx_path <- file.path(temp_dir, "no-revisions.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  revisions <- jsonlite::fromJSON(revisions_path, simplifyVector = FALSE)
  expect_equal(length(revisions), 0)
})


# ===========================================================================
# Issue #51: Harvest overwrites field-codes.json when no Zotero citations
# ===========================================================================

test_that("#51: harvest preserves existing field-codes.json when document has no citations", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Seed field-codes.json with 3 citations from a previous harvest
  fc_path <- file.path(sidecar_dir, "field-codes.json")
  seed_field_codes_json(fc_path, n_citations = 3)

  docx_path <- file.path(temp_dir, "no-zotero.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  # Existing citations must survive
  fc <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_equal(length(fc$citations), 3)
  expect_true("author2021" %in% names(fc$citations))
  expect_true("author2022" %in% names(fc$citations))
  expect_true("author2023" %in% names(fc$citations))
})

test_that("#51: harvest preserves zotero_pref from existing field-codes.json", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  fc_path <- file.path(sidecar_dir, "field-codes.json")
  seed_field_codes_json(fc_path, n_citations = 3)

  docx_path <- file.path(temp_dir, "no-zotero.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  fc <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_equal(fc$zotero_pref$style$styleID, "apa")
})

test_that("#51: harvest without existing field-codes.json does not create empty one", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # No existing field-codes.json
  fc_path <- file.path(sidecar_dir, "field-codes.json")

  docx_path <- file.path(temp_dir, "no-zotero.docx")
  create_bare_docx(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  # No citations in doc and no existing file — should not create one
  # (current behaviour: returns without writing when no pref and no citations)
  expect_false(file.exists(fc_path))
})


# --- Edge case: document with ZOTERO_PREF but no citations ---

# Create a DOCX that has ZOTERO_PREF embedded but no ZOTERO_ITEM citations.
# This is the scenario where merge=FALSE would have overwritten field-codes.json
# with an empty citations list (only preserving the pref).
create_docx_with_pref_only <- function(path) {
  temp_dir <- tempfile("docx_pref_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  # Document with a Zotero pref field code but no citation field codes
  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>',
    '<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText>ADDIN ZOTERO_PREF {"style":{"styleID":"apa"}}</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
    '<w:p><w:r><w:t>Body text with no citations.</w:t></w:r></w:p>',
    '</w:body></w:document>'
  )
  writeLines(doc_xml, file.path(temp_dir, "word", "document.xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
    '<Default Extension="xml" ContentType="application/xml"/>',
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
    '<Override PartName="/word/document.xml" ',
    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    '</Types>'
  ), file.path(temp_dir, "[Content_Types].xml"))

  writeLines(paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    '<Relationship Id="rId1" ',
    'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" ',
    'Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  old_wd <- setwd(temp_dir)
  on.exit({ setwd(old_wd); unlink(temp_dir, recursive = TRUE) }, add = TRUE)
  zip(path, files = c("[Content_Types].xml", "_rels/.rels", "word/document.xml"),
      flags = "-q")

  path
}

test_that("#51: document with ZOTERO_PREF but no citations preserves existing field-codes.json", {
  skip_on_cran()

  temp_dir <- tempfile("sidecar_")
  sidecar_dir <- file.path(temp_dir, "_docstyle")
  dir.create(sidecar_dir, recursive = TRUE)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  # Seed field-codes.json with 3 citations from a previous harvest
  fc_path <- file.path(sidecar_dir, "field-codes.json")
  seed_field_codes_json(fc_path, n_citations = 3)

  docx_path <- file.path(temp_dir, "pref-only.docx")
  create_docx_with_pref_only(docx_path)

  extract_sidecar_data(docx_path, sidecar_dir)

  # Existing citations must survive even though the document has ZOTERO_PREF
  fc <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)
  expect_equal(length(fc$citations), 3)
  expect_true("author2021" %in% names(fc$citations))
})
