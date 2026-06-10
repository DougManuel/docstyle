test_that("generate_base_key produces valid keys", {
  # Mock items
  item1 <- list(
    author = list(list(family = "Smith", given = "John")),
    issued = list(`date-parts` = list(list(2023))),
    title = "A Study"
  )

  item2 <- list(
    author = list(list(family = "Doe", given = "Jane")),
    # No date
    title = "Another Study"
  )

  item3 <- list(
    author = list(list(family = "O'Neil", given = "Tim")),
    issued = list(`date-parts` = list(list(2020, 5, 10))),
    title = "Complex Name"
  )

  expect_equal(generate_base_key(item1), "smith2023")
  expect_equal(generate_base_key(item2), "doe")
  expect_equal(generate_base_key(item3), "oneil2020")
})

test_that("resolve_cite_keys handles collisions", {
  item1 <- list(author = list(list(family = "Smith")), issued = list(`date-parts` = list(list(2023))))
  item2 <- list(author = list(list(family = "Smith")), issued = list(`date-parts` = list(list(2023))))

  all_items <- list(id1 = item1, id2 = item2)
  keys <- resolve_cite_keys(all_items)

  expect_equal(keys$id1, "smith2023")
  expect_equal(keys$id2, "smith2023a")
})

test_that("normalize_citation_text converts dashes and whitespace", {
  # en-dash -> hyphen
  expect_equal(normalize_citation_text("(17\u201324)"), "(17-24)")

  # em-dash -> hyphen
  expect_equal(normalize_citation_text("(17\u201424)"), "(17-24)")

  # Whitespace collapsing
  expect_equal(normalize_citation_text("(1,  2,  3)"), "(1, 2, 3)")

  # Leading/trailing whitespace trimmed
  expect_equal(normalize_citation_text("  (1-3)  "), "(1-3)")

  # Regular hyphen unchanged
  expect_equal(normalize_citation_text("(17-24)"), "(17-24)")
})

test_that("clean_rtf_escapes handles literal Unicode dashes", {
  # Literal en-dash in JSON string
  expect_equal(clean_rtf_escapes("(17\u201324)"), "(17-24)")

  # Literal em-dash
  expect_equal(clean_rtf_escapes("(17\u201424)"), "(17-24)")

  # RTF escape (existing behaviour)
  expect_equal(clean_rtf_escapes("\\u8211"), "-")
})

test_that("build_citation_instr produces valid single-item JSON", {
  citations <- list(
    cite1 = list(
      itemData = list(
        id = 12345,
        type = "article-journal",
        title = "Test Article",
        author = list(list(family = "Smith", given = "John")),
        issued = list(`date-parts` = list(list(2023)))
      ),
      uris = list("http://zotero.org/groups/123/items/ABC123")
    )
  )

  result <- build_citation_instr("cite1", citations)

  # Should start with ADDIN ZOTERO_ITEM CSL_CITATION
  expect_true(grepl("^ADDIN ZOTERO_ITEM CSL_CITATION ", result))

  # Extract and parse JSON
  json_str <- sub("^ADDIN ZOTERO_ITEM CSL_CITATION ", "", result)
  parsed <- jsonlite::fromJSON(json_str, simplifyVector = FALSE)

  # Should have exactly one citationItem
  expect_equal(length(parsed$citationItems), 1)

  # Display text should be placeholder
  expect_equal(parsed$properties$plainCitation, "(REF)")

  # Item data should be present
  expect_equal(parsed$citationItems[[1]]$itemData$title, "Test Article")

  # URI should be preserved
  expect_equal(parsed$citationItems[[1]]$uris[[1]],
               "http://zotero.org/groups/123/items/ABC123")
})


test_that("build_citation_instr produces multi-item JSON", {
  citations <- list(
    ref_a = list(
      itemData = list(id = 100, type = "article-journal", title = "Article A"),
      uris = list("http://z/items/A")
    ),
    ref_b = list(
      itemData = list(id = 200, type = "article-journal", title = "Article B"),
      uris = list("http://z/items/B")
    )
  )

  result <- build_citation_instr(c("ref_a", "ref_b"), citations)

  # Should start with ADDIN ZOTERO_ITEM CSL_CITATION
  expect_true(grepl("^ADDIN ZOTERO_ITEM CSL_CITATION ", result))

  # Parse JSON
  json_str <- sub("^ADDIN ZOTERO_ITEM CSL_CITATION ", "", result)
  parsed <- jsonlite::fromJSON(json_str, simplifyVector = FALSE)

  # Should have two citationItems
  expect_equal(length(parsed$citationItems), 2)
  expect_equal(parsed$citationItems[[1]]$itemData$title, "Article A")
  expect_equal(parsed$citationItems[[2]]$itemData$title, "Article B")
})


test_that("sanitize_instr_text_r cleans RTF artifacts", {
  # instrText with RTF artifact in formattedCitation
  instr <- paste0(
    'ADDIN ZOTERO_ITEM CSL_CITATION ',
    '{"citationID":"abc","properties":{"formattedCitation":"\\\\uldash{1}","plainCitation":"1","noteIndex":0},',
    '"citationItems":[],"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}'
  )

  result <- sanitize_instr_text_r(instr)

  # formattedCitation should now match plainCitation
  json_str <- sub("^ADDIN ZOTERO_ITEM CSL_CITATION ", "", result)
  parsed <- jsonlite::fromJSON(json_str, simplifyVector = FALSE)
  expect_equal(parsed$properties$formattedCitation, "1")

  # Clean instrText should pass through unchanged
  clean_instr <- paste0(
    'ADDIN ZOTERO_ITEM CSL_CITATION ',
    '{"citationID":"abc","properties":{"formattedCitation":"1","plainCitation":"1","noteIndex":0},',
    '"citationItems":[],"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}'
  )
  expect_equal(sanitize_instr_text_r(clean_instr), clean_instr)
})


test_that("replace_citations handles overlapping strings", {
  text <- "This is ref (1) and ref (10)."
  map <- list(
    "(1)" = "[@ref1]",
    "(10)" = "[@ref10]"
  )

  # Expectation: "(10)" should be replaced by "[@ref10]", not "[@ref1]0"
  res <- replace_citations(text, map)
  expect_equal(res, "This is ref [@ref1] and ref [@ref10].")
})


# Helper: minimal DOCX with a two-item Zotero citation where item2 has no itemData
create_multi_key_citation_docx <- function(path) {
  # Build instrText: item1 has full itemData, item2 has no itemData (web page)
  instr <- paste0(
    "ADDIN ZOTERO_ITEM CSL_CITATION ",
    jsonlite::toJSON(list(
      citationID = "cid1",
      properties = list(
        formattedCitation = "(Smith, 2020; Unknown, 2021)",
        plainCitation = "(Smith, 2020; Unknown, 2021)",
        noteIndex = 0L
      ),
      citationItems = list(
        list(
          id = "item1",
          uris = list("http://zotero.org/users/1/items/AAAA"),
          itemData = list(
            id = "item1",
            type = "article-journal",
            title = "A Study by Smith",
            author = list(list(family = "Smith", given = "John")),
            issued = list(`date-parts` = list(list(2020L)))
          )
        ),
        list(
          id = "item2",
          uris = list("http://zotero.org/users/1/items/BBBB")
          # No itemData — simulates a web page or item Zotero couldn't export
        )
      ),
      schema = "https://github.com/citation-style-language/schema/raw/master/csl-citation.json"
    ), auto_unbox = TRUE)
  )

  temp_dir <- tempfile("multi_cite_")
  dir.create(file.path(temp_dir, "word"), recursive = TRUE)
  dir.create(file.path(temp_dir, "_rels"), recursive = TRUE)

  # Build a paragraph with the Zotero field code
  doc_xml <- paste0(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:body>',
    '<w:p>',
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText>', escape_xml_text(instr), '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    '<w:r><w:t>(Smith, 2020; Unknown, 2021)</w:t></w:r>',
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>',
    '</w:p>',
    '<w:sectPr/>',
    '</w:body>',
    '</w:document>'
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
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/',
    'relationships/officeDocument" Target="word/document.xml"/>',
    '</Relationships>'
  ), file.path(temp_dir, "_rels", ".rels"))

  old_wd <- setwd(temp_dir)
  on.exit(setwd(old_wd), add = TRUE)
  zip(path, files = c("[Content_Types].xml", "_rels/.rels", "word/document.xml"),
      flags = "-q")
  unlink(temp_dir, recursive = TRUE)
  path
}


test_that("multi-key citation with missing itemData warns and omits NA key (#81)", {
  skip_on_cran()

  temp_dir <- tempfile("cite81_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  docx_path <- file.path(temp_dir, "multi-cite.docx")
  create_multi_key_citation_docx(docx_path)

  # Should warn about missing citekey for item2
  expect_warning(
    result <- extract_citations(docx_path, output_dir = temp_dir, verbose = FALSE),
    regexp = "missing itemData"
  )

  # The field-codes.json should exist and have one valid citation
  fc_path <- file.path(temp_dir, "field-codes.json")
  expect_true(file.exists(fc_path))
  fc <- jsonlite::fromJSON(fc_path, simplifyVector = FALSE)

  # Only item1 has itemData — should produce smith2020 key
  expect_true("smith2020" %in% names(fc$citations))
  expect_false("NA" %in% names(fc$citations))

  # The citation group should reference only smith2020 (item2 omitted)
  groups <- fc$citationGroups
  grp <- groups[[which(vapply(groups, function(g) g$citationID == "cid1", logical(1)))]]
  expect_false(is.null(grp))
  expect_equal(length(grp$citekeys), 1L)
  expect_equal(grp$citekeys[[1]], "smith2020")
})
