
# =============================================================================
# Tests for style_resolver.R
# =============================================================================
# resolve_to_canonical() maps custom Word style IDs to the canonical dispatch
# keys used by the harvest switch. This is the foundation for harvesting
# non-standard templates (MDPI, journal, institutional) without losing heading
# structure.

# Helper: build a minimal props_lookup from named argument pairs
# Usage: props_lookup("MDPI21heading1", outlineLvl=0, basedOn="Normal")
make_props <- function(...) {
  args <- list(...)
  result <- list()
  for (nm in names(args)) {
    entry <- args[[nm]]
    result[[nm]] <- list(
      name         = nm,                                   # default: id == name
      based_on     = entry$basedOn %||% NULL,
      outline_level = if (!is.null(entry$outlineLvl)) as.integer(entry$outlineLvl)
                      else NA_integer_
    )
    if (!is.null(entry$name)) result[[nm]]$name <- entry$name
  }
  result
}

# ---- resolve_to_canonical: canonical pass-through ---------------------------

test_that("resolve_to_canonical: known heading styles pass through", {
  for (lvl in 1:6) {
    id <- paste0("Heading", lvl)
    expect_equal(resolve_to_canonical(id, list()), id)
  }
})

test_that("resolve_to_canonical: metadata styles pass through", {
  for (id in c("Title", "Subtitle", "Date", "Version")) {
    expect_equal(resolve_to_canonical(id, list()), id)
  }
})

test_that("resolve_to_canonical: TOC styles pass through", {
  for (n in 1:3) {
    id <- paste0("TOC", n)
    expect_equal(resolve_to_canonical(id, list()), id)
  }
})

test_that("resolve_to_canonical: list styles pass through", {
  for (id in c("ListParagraph", "ListBullet", "ListNumber")) {
    expect_equal(resolve_to_canonical(id, list()), id)
  }
})

# ---- outlineLvl resolution --------------------------------------------------

test_that("resolve_to_canonical: outlineLvl 0 → Heading1", {
  props <- make_props("MDPI21heading1" = list(outlineLvl = 0L))
  expect_equal(resolve_to_canonical("MDPI21heading1", props), "Heading1")
})

test_that("resolve_to_canonical: outlineLvl 1 → Heading2", {
  props <- make_props("MDPI21heading2" = list(outlineLvl = 1L))
  expect_equal(resolve_to_canonical("MDPI21heading2", props), "Heading2")
})

test_that("resolve_to_canonical: outlineLvl 5 → Heading6", {
  props <- make_props("DeepStyle" = list(outlineLvl = 5L))
  expect_equal(resolve_to_canonical("DeepStyle", props), "Heading6")
})

test_that("resolve_to_canonical: outlineLvl 6+ treated as non-heading (body)", {
  # outlineLvl 6-8 are used for body text outlines in some templates
  props <- make_props("BodyOutline" = list(outlineLvl = 6L))
  # Should NOT resolve to a heading — returns original style
  result <- resolve_to_canonical("BodyOutline", props)
  expect_equal(result, "BodyOutline")
})

# ---- basedOn chain resolution -----------------------------------------------

test_that("resolve_to_canonical: basedOn Heading2 → Heading2", {
  props <- list(
    "JournalSubhead" = list(name = "JournalSubhead", based_on = "Heading2",
                             outline_level = NA_integer_),
    "Heading2"        = list(name = "Heading 2",    based_on = NULL,
                             outline_level = 1L)
  )
  expect_equal(resolve_to_canonical("JournalSubhead", props), "Heading2")
})

test_that("resolve_to_canonical: two-step basedOn chain → Heading3", {
  props <- list(
    "CustomH3"  = list(name = "CustomH3",  based_on = "JournalH3",
                        outline_level = NA_integer_),
    "JournalH3" = list(name = "JournalH3", based_on = "Heading3",
                        outline_level = NA_integer_),
    "Heading3"  = list(name = "Heading 3", based_on = NULL,
                        outline_level = 2L)
  )
  expect_equal(resolve_to_canonical("CustomH3", props), "Heading3")
})

test_that("resolve_to_canonical: cycle in basedOn chain terminates gracefully", {
  props <- list(
    "StyleA" = list(name = "StyleA", based_on = "StyleB", outline_level = NA_integer_),
    "StyleB" = list(name = "StyleB", based_on = "StyleA", outline_level = NA_integer_)
  )
  # Should return original style_id without infinite loop
  result <- resolve_to_canonical("StyleA", props)
  expect_equal(result, "StyleA")
})

test_that("resolve_to_canonical: basedOn chain resolves via outlineLvl midway", {
  # Parent has outlineLvl=0 but isn't a canonical name
  props <- list(
    "CustomStyle" = list(name = "CustomStyle", based_on = "BaseH1",
                          outline_level = NA_integer_),
    "BaseH1"      = list(name = "BaseH1",      based_on = NULL,
                          outline_level = 0L)
  )
  expect_equal(resolve_to_canonical("CustomStyle", props), "Heading1")
})

# ---- name-pattern fallback --------------------------------------------------

test_that("resolve_to_canonical: name 'Heading 1' fallback → Heading1", {
  props <- list(
    "h1style" = list(name = "Heading 1", based_on = NULL, outline_level = NA_integer_)
  )
  expect_equal(resolve_to_canonical("h1style", props), "Heading1")
})

test_that("resolve_to_canonical: name 'heading3' (no space) fallback → Heading3", {
  props <- list(
    "myh3" = list(name = "heading3", based_on = NULL, outline_level = NA_integer_)
  )
  expect_equal(resolve_to_canonical("myh3", props), "Heading3")
})

test_that("resolve_to_canonical: name 'TOC 2' fallback → TOC2", {
  props <- list(
    "CustomTOC2" = list(name = "TOC 2", based_on = NULL, outline_level = NA_integer_)
  )
  expect_equal(resolve_to_canonical("CustomTOC2", props), "TOC2")
})

# ---- unknown style ----------------------------------------------------------

test_that("resolve_to_canonical: unknown style returns unchanged", {
  expect_equal(resolve_to_canonical("SomeBodyStyle", list()), "SomeBodyStyle")
})

test_that("resolve_to_canonical: NA outlineLvl and no basedOn returns unchanged", {
  props <- make_props("NormalBody" = list())
  expect_equal(resolve_to_canonical("NormalBody", props), "NormalBody")
})

# ---- defensive input guards -------------------------------------------------

test_that("resolve_to_canonical: NA_character_ input returns NA", {
  expect_equal(resolve_to_canonical(NA_character_, list()), NA_character_)
})

test_that("resolve_to_canonical: empty string returns empty string", {
  expect_equal(resolve_to_canonical("", list()), "")
})

# ---- build_style_props_lookup -----------------------------------------------

test_that("build_style_props_lookup: returns list() for NULL path", {
  result <- build_style_props_lookup(NULL)
  expect_true(is.list(result))
  expect_equal(length(result), 0L)
})

test_that("build_style_props_lookup: returns list() for non-existent file", {
  result <- build_style_props_lookup("/tmp/does_not_exist.docx")
  expect_true(is.list(result))
  expect_equal(length(result), 0L)
})

test_that("build_style_props_lookup: extracts name, based_on, outline_level", {
  skip_if_not_installed("xml2")
  docx_path <- test_path("fixtures/word-native-comments.docx")
  skip_if_not(file.exists(docx_path))

  props <- build_style_props_lookup(docx_path)
  expect_true(is.list(props))
  expect_true(length(props) > 0L)

  # Every entry should have name, based_on, outline_level
  for (entry in props) {
    expect_true(!is.null(entry$name))
    expect_true(is.null(entry$based_on) || is.character(entry$based_on))
    expect_true(is.na(entry$outline_level) || is.integer(entry$outline_level))
  }
})

test_that("build_style_props_lookup: Heading1 has outline_level 0", {
  skip_if_not_installed("xml2")
  docx_path <- test_path("fixtures/word-native-comments.docx")
  skip_if_not(file.exists(docx_path))

  props <- build_style_props_lookup(docx_path)
  h1 <- props[["Heading1"]]
  if (!is.null(h1)) {
    expect_equal(h1$outline_level, 0L)
  } else {
    skip("Heading1 not present in fixture")
  }
})
