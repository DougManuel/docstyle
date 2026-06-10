# Test field_codes.R - Unified field code parsing and handling
#
# Tests cover:
# - Core layer: Category detection, instruction parsing
# - Semantic registries: Char class and div registries
# - docstyle layer: Payload parsing, schema validation, type handlers

# ═══════════════════════════════════════════════════════════════════════════
# Semantic Registry Tests
# ═══════════════════════════════════════════════════════════════════════════

test_that("get_char_class_def returns registry entries", {
  # Classes with harvests_to
  date_def <- get_char_class_def("date")
  expect_equal(date_def$word_style, "Date")
  expect_equal(date_def$harvests_to, "version_summary.date")

  version_def <- get_char_class_def("version")
  expect_equal(version_def$word_style, "Version")
  expect_equal(version_def$harvests_to, "version_summary.version")

  # Pure styling class (no harvests_to)
  sc_def <- get_char_class_def("sc")
  expect_equal(sc_def$word_style, "SmallCaps")
  expect_null(sc_def$harvests_to)

  # Unknown class
  expect_null(get_char_class_def("unknown-class"))
})

test_that("get_div_def returns registry entries", {
  toc_def <- get_div_def("toc")
  expect_equal(toc_def$div_open, "::: toc")
  expect_equal(toc_def$div_close, ":::")

  vh_def <- get_div_def("version-history")
  expect_equal(vh_def$div_open, "::: version-history")
  expect_equal(vh_def$div_close, ":::")

  ap_def <- get_div_def("author-plate")
  expect_equal(ap_def$div_open, "::: author-plate")
  expect_equal(ap_def$div_close, ":::")

  # Unknown div
  expect_null(get_div_def("unknown-div"))
})

test_that("build_harvest_path creates nested structure", {
  # Single level
  result <- build_harvest_path("date", "2026-02-01")
  expect_equal(result, list(date = "2026-02-01"))

  # Two levels
  result <- build_harvest_path("version_summary.date", "2026-02-01")
  expect_equal(result, list(version_summary = list(date = "2026-02-01")))

  # Three levels
  result <- build_harvest_path("a.b.c", "value")
  expect_equal(result, list(a = list(b = list(c = "value"))))
})


# ═══════════════════════════════════════════════════════════════════════════
# Core Layer Tests: Category Detection
# ═══════════════════════════════════════════════════════════════════════════

test_that("is_zotero_field detects Zotero field codes", {
  expect_true(is_zotero_field("ADDIN ZOTERO_ITEM CSL_CITATION {}"))
  expect_true(is_zotero_field("ADDIN ZOTERO_BIBL"))
  expect_true(is_zotero_field(" ADDIN ZOTERO_PREF {}"))
  expect_false(is_zotero_field("ADDIN DOCSTYLE {}"))
  expect_false(is_zotero_field("TOC \\h"))
  expect_false(is_zotero_field(NULL))
  expect_false(is_zotero_field(NA))
})

test_that("is_docstyle_field detects docstyle field codes", {
  expect_true(is_docstyle_field("ADDIN DOCSTYLE {\"type\":\"char\"}"))
  expect_true(is_docstyle_field(" ADDIN DOCSTYLE {}"))
  expect_false(is_docstyle_field("ADDIN ZOTERO_ITEM {}"))
  expect_false(is_docstyle_field("PAGE \\* MERGEFORMAT"))
  expect_false(is_docstyle_field(NULL))
  expect_false(is_docstyle_field(NA))
})

test_that("is_word_native_field detects native Word field codes", {
  expect_true(is_word_native_field("TOC \\o \"1-3\""))
  expect_true(is_word_native_field("PAGE"))
  expect_true(is_word_native_field("NUMPAGES"))
  expect_true(is_word_native_field("SECTIONPAGES"))
  expect_true(is_word_native_field("REF _Ref123456"))
  expect_true(is_word_native_field("HYPERLINK \"https://example.com\""))
  expect_true(is_word_native_field("SEQ Figure"))
  expect_true(is_word_native_field("STYLEREF Heading1"))
  expect_true(is_word_native_field("  TOC \\h"))  # Leading whitespace
  expect_false(is_word_native_field("ADDIN ZOTERO_ITEM"))
  expect_false(is_word_native_field("ADDIN DOCSTYLE"))
  expect_false(is_word_native_field(NULL))
  expect_false(is_word_native_field(NA))
})


# ═══════════════════════════════════════════════════════════════════════════
# Core Layer Tests: Instruction Parsing
# ═══════════════════════════════════════════════════════════════════════════

test_that("parse_instr_text splits ADDIN instruction correctly", {
  result <- parse_instr_text("ADDIN DOCSTYLE {\"type\":\"char\"}")
  expect_equal(result$prefix, "ADDIN DOCSTYLE")
  expect_equal(result$content, "{\"type\":\"char\"}")
})

test_that("parse_instr_text handles Zotero instructions", {
  result <- parse_instr_text("ADDIN ZOTERO_ITEM CSL_CITATION {}")
  expect_equal(result$prefix, "ADDIN ZOTERO_ITEM")
  expect_equal(result$content, "CSL_CITATION {}")
})

test_that("parse_instr_text handles native Word fields", {
  result <- parse_instr_text("TOC \\o \"1-3\" \\h")
  expect_equal(result$prefix, "TOC")
  expect_equal(result$content, "\\o \"1-3\" \\h")

  result <- parse_instr_text("PAGE")
  expect_equal(result$prefix, "PAGE")
  expect_equal(result$content, "")
})

test_that("parse_instr_text handles edge cases", {
  result <- parse_instr_text(NULL)
  expect_null(result$prefix)
  expect_null(result$content)

  result <- parse_instr_text(NA)
  expect_null(result$prefix)
  expect_null(result$content)

  result <- parse_instr_text("  ADDIN DOCSTYLE  {}")
  expect_equal(result$prefix, "ADDIN DOCSTYLE")
  expect_equal(result$content, "{}")
})


# ═══════════════════════════════════════════════════════════════════════════
# docstyle Layer Tests: Payload Parsing
# ═══════════════════════════════════════════════════════════════════════════

test_that("parse_docstyle_payload extracts char type", {
  instr <- 'ADDIN DOCSTYLE {"type":"char","class":"date","source":"[2025]{.date}"}'
  result <- parse_docstyle_payload(instr)
  expect_equal(result$type, "char")
  expect_equal(result$class, "date")
  expect_equal(result$source, "[2025]{.date}")
})

test_that("parse_docstyle_payload handles XML entities", {
  # Simulate XML-encoded JSON (as it appears in Word XML)
  instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;char&quot;,&quot;class&quot;:&quot;sc&quot;,&quot;source&quot;:&quot;[{{&lt; meta foo &gt;}}]{.sc}&quot;}'
  result <- parse_docstyle_payload(instr)
  expect_equal(result$type, "char")
  expect_equal(result$class, "sc")
  expect_equal(result$source, "[{{< meta foo >}}]{.sc}")
})

test_that("parse_docstyle_payload returns NULL for non-docstyle", {
  expect_null(parse_docstyle_payload("ADDIN ZOTERO_ITEM {}"))
  expect_null(parse_docstyle_payload("TOC \\h"))
  expect_null(parse_docstyle_payload(NULL))
})

test_that("parse_docstyle_payload returns NULL for invalid JSON", {
  instr <- 'ADDIN DOCSTYLE {not valid json}'
  expect_null(parse_docstyle_payload(instr))
})

test_that("parse_docstyle_payload returns NULL for missing required fields", {
  # Missing 'source' for char type
  instr <- 'ADDIN DOCSTYLE {"type":"char","class":"date"}'
  expect_null(parse_docstyle_payload(instr))

  # Missing 'name' for div type
  instr <- 'ADDIN DOCSTYLE {"type":"div"}'
  expect_null(parse_docstyle_payload(instr))
})


# ═══════════════════════════════════════════════════════════════════════════
# docstyle Layer Tests: Schema Validation
# ═══════════════════════════════════════════════════════════════════════════

test_that("validate_docstyle_schema accepts valid char payload", {
  payload <- list(type = "char", class = "date", source = "[2025]{.date}")
  result <- validate_docstyle_schema(payload)
  expect_equal(result$type, "char")
  expect_equal(result$source, "[2025]{.date}")
})

test_that("validate_docstyle_schema accepts valid div payload", {
  payload <- list(type = "div", name = "toc")
  result <- validate_docstyle_schema(payload)
  expect_equal(result$type, "div")
  expect_equal(result$name, "toc")
})

test_that("validate_docstyle_schema accepts valid list payload", {
  payload <- list(type = "list", class = "list-alpha", start = 3)
  result <- validate_docstyle_schema(payload)
  expect_equal(result$type, "list")
  expect_equal(result$class, "list-alpha")
  expect_equal(result$start, 3)
})

test_that("validate_docstyle_schema accepts valid section payload", {
  payload <- list(
    type = "section",
    class = "section-break",
    `page-break` = TRUE,
    `line-numbers` = "continuous"
  )
  result <- validate_docstyle_schema(payload)
  expect_equal(result$type, "section")
  expect_true(result$`page-break`)
  expect_equal(result$`line-numbers`, "continuous")
})

test_that("validate_docstyle_schema rejects unknown type", {
  payload <- list(type = "unknown", foo = "bar")
  expect_null(validate_docstyle_schema(payload))
})

test_that("validate_docstyle_schema warns on future version in strict mode", {
  payload <- list(type = "char", version = 99, class = "x", source = "y")
  expect_warning(result <- validate_docstyle_schema(payload, strict = TRUE))
  expect_null(result)
})

test_that("validate_docstyle_schema passes future version in non-strict mode", {
  payload <- list(type = "char", version = 99, class = "x", source = "y")
  result <- validate_docstyle_schema(payload, strict = FALSE)
  expect_equal(result$type, "char")
})


# ═══════════════════════════════════════════════════════════════════════════
# docstyle Layer Tests: Type Handlers
# ═══════════════════════════════════════════════════════════════════════════

test_that("handle_docstyle_char returns correct structure", {
  payload <- list(type = "char", class = "date", source = "[2025]{.date}")
  context <- list(display_text = "2025")
  result <- handle_docstyle_char(payload, context)

  expect_equal(result$type, "char")
  expect_equal(result$qmd_source, "[2025]{.date}")
  expect_equal(result$class, "date")
  expect_equal(result$display_text, "2025")
  expect_true(result$skip_display)
  # date class has harvests_to in registry

  expect_equal(result$harvested_metadata$version_summary$date, "2025")
})

test_that("handle_docstyle_char extracts version-summary.date via registry", {
  payload <- list(
    type = "char",
    class = "date",
    source = "[{{< meta version-summary.date >}}]{.date}"
  )
  context <- list(display_text = "2026-02-01")
  result <- handle_docstyle_char(payload, context)

  expect_equal(result$type, "char")
  expect_equal(result$qmd_source, "[{{< meta version-summary.date >}}]{.date}")
  expect_true(result$skip_display)
  # Registry-driven: date class harvests to version_summary.date
  expect_equal(result$harvested_metadata$version_summary$date, "2026-02-01")
})

test_that("handle_docstyle_char extracts version-summary.version via registry", {
  payload <- list(
    type = "char",
    class = "version",
    source = "[{{< meta version-summary.version >}}]{.version}"
  )
  context <- list(display_text = "0.2.3")
  result <- handle_docstyle_char(payload, context)

  # Registry-driven: version class harvests to version_summary.version
  expect_equal(result$harvested_metadata$version_summary$version, "0.2.3")
})

test_that("handle_docstyle_char without harvests_to has no harvested_metadata", {
  payload <- list(type = "char", class = "sc", source = "[POPCORN]{.sc}")
  context <- list(display_text = "POPCORN")
  result <- handle_docstyle_char(payload, context)

  # sc class has no harvests_to in registry
  expect_null(result$harvested_metadata)
})

test_that("handle_docstyle_div returns div fences", {
  payload <- list(type = "div", name = "version-history")
  result <- handle_docstyle_div(payload)

  expect_equal(result$type, "div")
  expect_equal(result$name, "version-history")
  expect_equal(result$div_open, "::: version-history")
  expect_equal(result$div_close, ":::")
})

test_that("handle_docstyle_list returns div with class", {
  payload <- list(type = "list", class = "list-alpha")
  result <- handle_docstyle_list(payload)

  expect_equal(result$type, "list")
  expect_equal(result$class, "list-alpha")
  expect_equal(result$div_open, "::: {.list-alpha}")
  expect_equal(result$div_close, ":::")
})

test_that("handle_docstyle_list includes start attribute", {
  payload <- list(type = "list", class = "list-roman", start = 5)
  result <- handle_docstyle_list(payload)

  expect_equal(result$start, 5)
  expect_equal(result$div_open, '::: {.list-roman start="5"}')
})

test_that("handle_docstyle_section returns section attributes", {
  payload <- list(
    type = "section",
    class = "section-break",
    `page-break` = TRUE,
    `line-numbers` = "restart"
  )
  result <- handle_docstyle_section(payload)

  expect_equal(result$type, "section")
  expect_equal(result$class, "section-break")
  expect_true(result$page_break)
  expect_equal(result$line_numbers, "restart")
  expect_equal(result$div_open, '::: {.section-break page-break="true" line-numbers="restart"}')
  expect_equal(result$div_close, ":::")
})

test_that("handle_docstyle_section omits false page-break", {
  payload <- list(type = "section", class = "section-break")
  result <- handle_docstyle_section(payload)

  expect_false(result$page_break)
  expect_equal(result$div_open, "::: {.section-break}")
})


# ═══════════════════════════════════════════════════════════════════════════
# docstyle Layer Tests: Dispatch
# ═══════════════════════════════════════════════════════════════════════════

test_that("dispatch_docstyle_handler routes to correct handler", {
  char_payload <- list(type = "char", class = "sc", source = "[X]{.sc}")
  result <- dispatch_docstyle_handler(char_payload)
  expect_equal(result$type, "char")
  expect_equal(result$qmd_source, "[X]{.sc}")

  div_payload <- list(type = "div", name = "toc")
  result <- dispatch_docstyle_handler(div_payload)
  expect_equal(result$type, "div")
  expect_equal(result$name, "toc")

  list_payload <- list(type = "list", class = "list-alpha")
  result <- dispatch_docstyle_handler(list_payload)
  expect_equal(result$type, "list")

  section_payload <- list(type = "section", class = "section-break")
  result <- dispatch_docstyle_handler(section_payload)
  expect_equal(result$type, "section")
})

test_that("dispatch_docstyle_handler returns NULL for unknown type", {
  payload <- list(type = "unknown")
  expect_null(dispatch_docstyle_handler(payload))
})

test_that("dispatch_docstyle_handler returns NULL for NULL input", {
  expect_null(dispatch_docstyle_handler(NULL))
})


# ═══════════════════════════════════════════════════════════════════════════
# Integration Tests: Full Parse Flow
# ═══════════════════════════════════════════════════════════════════════════

test_that("full parse flow works for char type", {
  instr <- 'ADDIN DOCSTYLE {"type":"char","class":"date","source":"[{{< meta date >}}]{.date}"}'
  payload <- parse_docstyle_payload(instr)
  expect_false(is.null(payload))

  result <- dispatch_docstyle_handler(payload, list(display_text = "2025-01-15"))
  expect_equal(result$type, "char")
  expect_equal(result$qmd_source, "[{{< meta date >}}]{.date}")
  expect_true(result$skip_display)
})

test_that("full parse flow works for div type", {
  instr <- 'ADDIN DOCSTYLE {"type":"div","name":"author-plate"}'
  payload <- parse_docstyle_payload(instr)
  expect_false(is.null(payload))

  result <- dispatch_docstyle_handler(payload)
  expect_equal(result$type, "div")
  expect_equal(result$div_open, "::: author-plate")
})

test_that("full parse flow works with XML entities", {
  # As it would appear in Word XML
  instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;div&quot;,&quot;name&quot;:&quot;toc&quot;}'
  payload <- parse_docstyle_payload(instr)
  expect_false(is.null(payload))
  expect_equal(payload$name, "toc")
})


# ═══════════════════════════════════════════════════════════════════════════
# Shared Schema Tests: Lua→R Compatibility
# ═══════════════════════════════════════════════════════════════════════════

test_that("shared schema file exists and is valid JSON", {
  schema_path <- system.file(
    "schema", "docstyle-field-codes.json",
    package = "docstyle"
  )

 # In development, try inst/ directly
 if (schema_path == "") {
   dev_path <- file.path(
     getwd(), "..", "..", "inst", "schema", "docstyle-field-codes.json"
   )
   if (file.exists(dev_path)) {
     schema_path <- dev_path
   }
 }

  skip_if(schema_path == "" || !file.exists(schema_path),
          "Schema file not found (installed package only)")

  schema <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)
  expect_true(!is.null(schema$schema_version))
  expect_true(!is.null(schema$char_classes))
  expect_true(!is.null(schema$div_types))
})

test_that("schema char_classes match R registry", {
  schema_path <- system.file(
    "schema", "docstyle-field-codes.json",
    package = "docstyle"
  )

  if (schema_path == "") {
    dev_path <- file.path(
      getwd(), "..", "..", "inst", "schema", "docstyle-field-codes.json"
    )
    if (file.exists(dev_path)) {
      schema_path <- dev_path
    }
  }

  skip_if(schema_path == "" || !file.exists(schema_path),
          "Schema file not found")

  schema <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)

  # Verify key classes exist in schema
  expect_true("date" %in% names(schema$char_classes))
  expect_true("version" %in% names(schema$char_classes))
  expect_true("sc" %in% names(schema$char_classes))

  # Verify schema values match R registry lookups
  date_schema <- schema$char_classes$date
  date_r <- get_char_class_def("date")
  expect_equal(date_schema$word_style, date_r$word_style)
  expect_equal(date_schema$harvests_to, date_r$harvests_to)

  version_schema <- schema$char_classes$version
  version_r <- get_char_class_def("version")
  expect_equal(version_schema$word_style, version_r$word_style)
})

test_that("schema div_types match R registry", {
  schema_path <- system.file(
    "schema", "docstyle-field-codes.json",
    package = "docstyle"
  )

  if (schema_path == "") {
    dev_path <- file.path(
      getwd(), "..", "..", "inst", "schema", "docstyle-field-codes.json"
    )
    if (file.exists(dev_path)) {
      schema_path <- dev_path
    }
  }

  skip_if(schema_path == "" || !file.exists(schema_path),
          "Schema file not found")

  schema <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)

  # Verify key divs exist
  expect_true("toc" %in% names(schema$div_types))
  expect_true("version-history" %in% names(schema$div_types))
  expect_true("author-plate" %in% names(schema$div_types))

  # Verify values match R lookups
  toc_schema <- schema$div_types$toc
  toc_r <- get_div_def("toc")
  expect_equal(toc_schema$div_open, toc_r$div_open)
  expect_equal(toc_schema$div_close, toc_r$div_close)
})

test_that("Lua-style XML-escaped JSON parses correctly for all field types", {
  # These simulate exactly what the Lua filters emit after XML escaping

  # char type (from char-style.lua)
  char_instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;char&quot;,&quot;version&quot;:1,&quot;class&quot;:&quot;date&quot;,&quot;source&quot;:&quot;[{{&lt; meta version-summary.date &gt;}}]{.date}&quot;}'
  char_payload <- parse_docstyle_payload(char_instr)
  expect_equal(char_payload$type, "char")
  expect_equal(char_payload$class, "date")
  expect_true(grepl("meta version-summary.date", char_payload$source))

  # div type (from version-history.lua, author-plate.lua, toc-field.lua)
  div_instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;div&quot;,&quot;version&quot;:1,&quot;name&quot;:&quot;version-history&quot;}'
  div_payload <- parse_docstyle_payload(div_instr)
  expect_equal(div_payload$type, "div")
  expect_equal(div_payload$name, "version-history")

  # list type (from list-style.lua)
  list_instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;list&quot;,&quot;version&quot;:1,&quot;class&quot;:&quot;list-alpha&quot;}'
  list_payload <- parse_docstyle_payload(list_instr)
  expect_equal(list_payload$type, "list")
  expect_equal(list_payload$class, "list-alpha")

  # section type (from page-section.lua)
  section_instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;section&quot;,&quot;version&quot;:1,&quot;class&quot;:&quot;section-body&quot;,&quot;page-break&quot;:true,&quot;line-numbers&quot;:&quot;continuous&quot;}'
  section_payload <- parse_docstyle_payload(section_instr)
  expect_equal(section_payload$type, "section")
  expect_equal(section_payload$class, "section-body")
  expect_true(section_payload$`page-break`)
  expect_equal(section_payload$`line-numbers`, "continuous")
})

test_that("get_list_class_def returns list class definitions", {
  alpha_def <- get_list_class_def("list-alpha")
  expect_equal(alpha_def$div_open, "::: {.list-alpha}")
  expect_equal(alpha_def$div_close, ":::")

  roman_def <- get_list_class_def("list-roman")
  expect_equal(roman_def$div_open, "::: {.list-roman}")
  expect_equal(roman_def$div_close, ":::")

  # Unknown list class
  expect_null(get_list_class_def("list-unknown"))
})


# ═══════════════════════════════════════════════════════════════════════════
# Table Handler Tests
# ═══════════════════════════════════════════════════════════════════════════

test_that("get_table_class_def returns table class definitions", {
  formal_def <- get_table_class_def("table-formal")
  expect_equal(formal_def$div_open, "::: {.table-formal}")
  expect_equal(formal_def$div_close, ":::")

  grid_def <- get_table_class_def("table-grid")
  expect_equal(grid_def$div_open, "::: {.table-grid}")
  expect_equal(grid_def$div_close, ":::")

  # Unknown table class
  expect_null(get_table_class_def("table-unknown"))
})

test_that("handle_docstyle_table returns div fences with class", {
  payload <- list(type = "table", class = "table-formal")
  result <- handle_docstyle_table(payload)

  expect_equal(result$type, "table")
  expect_equal(result$class, "table-formal")
  expect_equal(result$div_open, "::: {.table-formal}")
  expect_equal(result$div_close, ":::")
})

test_that("handle_docstyle_table passes through all attributes", {
  payload <- list(
    type = "table",
    version = 2,
    class = "table-formal",
    widths = "30,70",
    width = "80",
    `font-size` = "9",
    `header-bold` = "true",
    `header-shading` = "D9D9D9"
  )
  result <- handle_docstyle_table(payload)

  expect_equal(result$type, "table")
  expect_equal(result$class, "table-formal")
  # Check that attributes are in div_open (order may vary, so check contains)
  expect_match(result$div_open, 'widths="30,70"')
  expect_match(result$div_open, 'width="80"')
  expect_match(result$div_open, 'font-size="9"')
  expect_match(result$div_open, 'header-bold="true"')
  expect_match(result$div_open, 'header-shading="D9D9D9"')
  # type, version, class should NOT appear as attributes
  expect_no_match(result$div_open, 'type=')
  expect_no_match(result$div_open, 'version=')
})

test_that("handle_docstyle_table passes through unknown attributes", {
  # Forward compatibility: new attributes should round-trip without handler changes
  payload <- list(
    type = "table",
    class = "table-grid",
    `cell-padding` = "5",
    `stripe-color` = "F0F0F0"
  )
  result <- handle_docstyle_table(payload)

  expect_match(result$div_open, 'cell-padding="5"')
  expect_match(result$div_open, 'stripe-color="F0F0F0"')
})

test_that("dispatch routes to table handler", {
  payload <- list(type = "table", class = "table-formal", widths = "30,70")
  result <- dispatch_docstyle_handler(payload)

  expect_equal(result$type, "table")
  expect_equal(result$class, "table-formal")
  expect_match(result$div_open, 'widths="30,70"')
})

test_that("full parse flow works for table type", {
  instr <- 'ADDIN DOCSTYLE {"type":"table","version":2,"class":"table-formal","widths":"30,70","font-size":"9"}'
  payload <- parse_docstyle_payload(instr)
  expect_false(is.null(payload))

  result <- dispatch_docstyle_handler(payload)
  expect_equal(result$type, "table")
  expect_match(result$div_open, '.table-formal')
  expect_match(result$div_open, 'widths="30,70"')
  expect_match(result$div_open, 'font-size="9"')
})

test_that("XML-escaped table JSON parses correctly", {
  instr <- 'ADDIN DOCSTYLE {&quot;type&quot;:&quot;table&quot;,&quot;version&quot;:2,&quot;class&quot;:&quot;table-formal&quot;,&quot;widths&quot;:&quot;30,70&quot;}'
  payload <- parse_docstyle_payload(instr)
  expect_equal(payload$type, "table")
  expect_equal(payload$class, "table-formal")
  expect_equal(payload$widths, "30,70")
})

# ═══════════════════════════════════════════════════════════════════════════
# Anchor Handler Tests
# ═══════════════════════════════════════════════════════════════════════════

test_that("anchor schema validates required fields", {
  payload <- list(type = "anchor", class = "column-margin")
  result <- dispatch_docstyle_handler(payload)
  expect_false(is.null(result))
  expect_equal(result$type, "anchor")
  expect_equal(result$class, "column-margin")
})

test_that("anchor schema accepts all optional fields", {
  payload <- list(
    type = "anchor", version = 3L, class = "column-margin",
    content_hint = "image",
    vertical_anchor = "text", horizontal_anchor = "margin",
    position_y = "0", position_x = "0",
    float_width = "250pt",
    wrap_style = "square", wrap_side = "both",
    wrap_distance = "0 198dxa 0 198dxa",
    z_layer = "front"
  )
  result <- dispatch_docstyle_handler(payload)
  expect_equal(result$class, "column-margin")
})

test_that("float type dispatches to anchor handler (backward compat)", {
  payload <- list(type = "float", class = "column-margin")
  result <- dispatch_docstyle_handler(payload)
  expect_false(is.null(result))
  expect_equal(result$type, "anchor")
  expect_equal(result$class, "column-margin")
})

test_that("handle_docstyle_anchor() builds correct div_open/div_close", {
  payload <- list(type = "anchor", class = "journal-sidebar")
  result <- dispatch_docstyle_handler(payload)
  expect_equal(result$div_open, "::: {.journal-sidebar}")
  expect_equal(result$div_close, ":::")
})

test_that("handle_docstyle_anchor() includes positioning attributes in div_open", {
  payload <- list(
    type = "anchor", class = "column-margin",
    vertical_anchor = "page", position_y = "720"
  )
  result <- dispatch_docstyle_handler(payload)
  expect_true(grepl('vertical-anchor="page"', result$div_open))
  expect_true(grepl('position-y="720"', result$div_open))
})


test_that("schema includes table_classes", {
  schema_path <- system.file(
    "schema", "docstyle-field-codes.json",
    package = "docstyle"
  )

  if (schema_path == "") {
    dev_path <- file.path(
      getwd(), "..", "..", "inst", "schema", "docstyle-field-codes.json"
    )
    if (file.exists(dev_path)) {
      schema_path <- dev_path
    }
  }

  skip_if(schema_path == "" || !file.exists(schema_path),
          "Schema file not found")

  schema <- jsonlite::fromJSON(schema_path, simplifyVector = FALSE)
  expect_true(!is.null(schema$table_classes))
  expect_true("table-formal" %in% names(schema$table_classes))
  expect_true("table-grid" %in% names(schema$table_classes))
})

# ═══════════════════════════════════════════════════════════════════════════
# Anchor handler: content-mode and adjacent
# ═══════════════════════════════════════════════════════════════════════════

test_that("handle_docstyle_anchor() includes content-mode in div attributes", {
  payload <- list(
    type = "anchor",
    class = "sidebar",
    content_mode = "textbox"
  )
  result <- handle_docstyle_anchor(payload)
  expect_true(grepl('content-mode="textbox"', result$div_open))
})

test_that("handle_docstyle_anchor() omits content-mode when auto", {
  payload <- list(type = "anchor", class = "sidebar", content_mode = "auto")
  result <- handle_docstyle_anchor(payload)
  expect_false(grepl("content-mode", result$div_open))
})

test_that("handle_docstyle_anchor() includes adjacent in div attributes", {
  payload <- list(type = "anchor", class = "column-margin", adjacent = "#methods")
  result <- handle_docstyle_anchor(payload)
  expect_true(grepl('adjacent="#methods"', result$div_open))
})


# ═══════════════════════════════════════════════════════════════════════════
# Abstract div type registration (#149)
# ═══════════════════════════════════════════════════════════════════════════

test_that("abstract is a registered div type (#149)", {
  result <- docstyle:::handle_docstyle_div(list(type = "div", name = "abstract"))
  expect_equal(result$div_open, "::: docstyle-abstract")
  expect_equal(result$div_close, ":::")
})
