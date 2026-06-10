# #149: relocate_abstract() moves Pandoc's hoisted AbstractTitle+Abstract
# paragraphs INSIDE the DOCSTYLE_ABSTRACT field code (between the field-start
# and field-end paragraphs), then removes ONLY the DOCSTYLE_ABSTRACT marker
# paragraph. The field-code wrapper is PRESERVED: harvest (docx_to_qmd) detects
# the abstract for re-harvesting by the `ADDIN DOCSTYLE {type:div,name:abstract}`
# field code that must WRAP it. Deleting the wrapper broke round-trip — a
# re-harvested docx saw plain prose, not a :::docstyle-abstract::: placeholder.

ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

# Build a w:body from a vector of paragraph XML strings; return the parsed
# <w:body> node (matching how finalize_docx passes `body`).
make_body <- function(paras) {
  doc <- paste0(
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    '<w:body>', paste(paras, collapse = ""), '</w:body></w:document>')
  xml2::xml_find_first(xml2::read_xml(doc), "//w:body", ns)
}

styled_p <- function(style, text) {
  sprintf('<w:p><w:pPr><w:pStyle w:val="%s"/></w:pPr><w:r><w:t>%s</w:t></w:r></w:p>',
          style, text)
}
plain_p  <- function(text) sprintf('<w:p><w:r><w:t>%s</w:t></w:r></w:p>', text)

# A bare DOCSTYLE_ABSTRACT marker with no field-code wrapper. The real
# pipeline never emits this (abstract.lua always wraps it — see
# abstract_field_code() below), but the function must degrade gracefully
# rather than corrupt the document if it ever appears.
marker_p <- '<w:p><w:r><w:t>DOCSTYLE_ABSTRACT</w:t></w:r></w:p>'

# The real :::docstyle-abstract::: marker as abstract.lua emits it: a
# 3-paragraph ADDIN DOCSTYLE field code (start | DOCSTYLE_ABSTRACT | end).
# Built via read_xml, so the instrText JSON quotes must be XML-safe (&quot;).
# The function detects the field code by the fldChar begin/end elements and
# the marker text, not by parsing the JSON.
abstract_field_code <- function() {
  c(
    paste0('<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>',
           '<w:r><w:instrText xml:space="preserve"> ADDIN DOCSTYLE ',
           '{&quot;type&quot;:&quot;div&quot;,&quot;name&quot;:&quot;abstract&quot;} </w:instrText></w:r>',
           '<w:r><w:fldChar w:fldCharType="separate"/></w:r></w:p>'),
    '<w:p><w:r><w:t xml:space="preserve">DOCSTYLE_ABSTRACT</w:t></w:r></w:p>',
    '<w:p><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>'
  )
}

# Return the ordered vector of (style|text) signatures for body paragraphs.
para_sig <- function(body) {
  ps <- xml2::xml_find_all(body, "./w:p", ns)
  vapply(ps, function(p) {
    style <- xml2::xml_text(xml2::xml_find_first(p, "./w:pPr/w:pStyle/@w:val", ns))
    txt   <- xml2::xml_text(xml2::xml_find_first(p, ".//w:t", ns))
    paste0(if (is.na(style)) "" else style, "|", if (is.na(txt)) "" else txt)
  }, character(1))
}

test_that("relocate_abstract moves abstract inside the field-code wrapper and preserves it (#149)", {
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "The abstract text."),
    plain_p("Author plate stand-in."),
    abstract_field_code(),  # 3-paragraph ADDIN DOCSTYLE wrapper around the marker
    plain_p("Body intro.")
  ))

  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)

  expect_equal(n, 1L)

  sig <- para_sig(body)
  # The DOCSTYLE_ABSTRACT marker text is gone (would otherwise render visibly).
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))
  # The abstract block is MOVED to sit BETWEEN the field-start and field-end
  # paragraphs (the wrapper is preserved as the harvest detection anchor). The
  # field-start carries the ADDIN DOCSTYLE instrText (so its signature has a
  # leading "|" with empty text); the field-end is the bare fldChar end ("|").
  expect_equal(sig, c(
    "|Author plate stand-in.",
    "|",                              # field-start (instrText, no w:t)
    "AbstractTitle|Abstract",         # abstract block, now inside the wrapper
    "Abstract|The abstract text.",
    "|",                              # field-end (bare fldChar end)
    "|Body intro."
  ))

  # The field-code wrapper is PRESERVED: field-start (begin + separate = 2
  # fldChars) + field-end (end = 1 fldChar) = 3 fldChars total. The instrText
  # ADDIN DOCSTYLE payload (name:abstract) also remains as the detection anchor.
  expect_equal(length(xml2::xml_find_all(body, ".//w:fldChar", ns)), 3L)
  expect_equal(length(xml2::xml_find_all(body, ".//w:instrText", ns)), 1L)
  instr <- xml2::xml_text(xml2::xml_find_first(body, ".//w:instrText", ns))
  expect_match(instr, "ADDIN DOCSTYLE")
  expect_match(instr, "\"name\":\"abstract\"")

  # Ordering: the abstract paragraphs sit AFTER the field-start (the paragraph
  # carrying fldChar begin) and BEFORE the field-end (fldChar end).
  paras <- xml2::xml_find_all(body, "./w:p", ns)
  begin_idx <- which(vapply(paras, function(p)
    length(xml2::xml_find_all(p, ".//w:fldChar[@w:fldCharType='begin']", ns)) > 0L,
    logical(1)))
  end_idx <- which(vapply(paras, function(p)
    length(xml2::xml_find_all(p, ".//w:fldChar[@w:fldCharType='end']", ns)) > 0L,
    logical(1)))
  styles <- vapply(paras, function(p)
    xml2::xml_text(xml2::xml_find_first(p, "./w:pPr/w:pStyle/@w:val", ns)),
    character(1))
  abstract_idx <- which(styles %in% c("AbstractTitle", "Abstract"))
  expect_true(all(abstract_idx > begin_idx))
  expect_true(all(abstract_idx < end_idx))
})

test_that("relocate_abstract degrades gracefully on a bare marker with no field wrapper (#149)", {
  # Defensive path: the real pipeline never produces a bare marker, but if one
  # appears, relocate just the marker without corrupting surrounding paragraphs.
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "The abstract text."),
    plain_p("Author plate stand-in."),
    marker_p,
    plain_p("Body intro.")
  ))

  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)

  expect_equal(n, 1L)
  sig <- para_sig(body)
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))
  expect_equal(sig, c(
    "|Author plate stand-in.",
    "AbstractTitle|Abstract",
    "Abstract|The abstract text.",
    "|Body intro."
  ))
})

test_that("relocate_abstract returns 0L and leaves the document untouched when no marker (#149)", {
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "The abstract text."),
    plain_p("Body intro.")
  ))

  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)

  expect_equal(n, 0L)
  expect_equal(para_sig(body), c(
    "AbstractTitle|Abstract",
    "Abstract|The abstract text.",
    "|Body intro."
  ))
})

test_that("relocate_abstract removes only the marker but keeps the wrapper when no abstract content (#149)", {
  body <- make_body(c(
    plain_p("Author plate stand-in."),
    abstract_field_code(),
    plain_p("Body intro.")
  ))

  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)

  expect_equal(n, 0L)
  sig <- para_sig(body)
  # The visible DOCSTYLE_ABSTRACT marker text is gone...
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))
  # ...but the EMPTY field-code wrapper is PRESERVED. An author who opted in
  # with :::docstyle-abstract::: but has no abstract yet still round-trips to an
  # empty placeholder, not bare prose. Body is: real content, the now-empty
  # field-start + field-end wrapper (both "|"), and the trailing body para.
  expect_equal(sig, c(
    "|Author plate stand-in.",
    "|",                 # field-start (instrText, no w:t)
    "|",                 # field-end (bare fldChar end)
    "|Body intro."
  ))
  # Wrapper preserved: 3 fldChars (begin + separate + end), instrText retained.
  expect_equal(length(xml2::xml_find_all(body, ".//w:fldChar", ns)), 3L)
  expect_equal(length(xml2::xml_find_all(body, ".//w:instrText", ns)), 1L)
})

test_that("relocate_abstract moves all contiguous Abstract paragraphs as a block (#149)", {
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "Para one."),
    styled_p("Abstract", "Para two."),
    styled_p("Abstract", "Para three."),
    plain_p("Author plate."),
    abstract_field_code(),
    plain_p("Body.")
  ))
  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)
  expect_equal(n, 1L)
  sig <- para_sig(body)
  # All four abstract paragraphs relocated, in order, INSIDE the field-code
  # wrapper (between field-start and field-end). Wrapper preserved.
  expect_equal(sig, c(
    "|Author plate.",
    "|",                       # field-start
    "AbstractTitle|Abstract",
    "Abstract|Para one.",
    "Abstract|Para two.",
    "Abstract|Para three.",
    "|",                       # field-end
    "|Body."
  ))
  # Field-code wrapper preserved: 3 fldChars, 1 instrText.
  expect_equal(length(xml2::xml_find_all(body, ".//w:fldChar", ns)), 3L)
  expect_equal(length(xml2::xml_find_all(body, ".//w:instrText", ns)), 1L)
  expect_false(any(grepl("DOCSTYLE_ABSTRACT", sig)))
})

test_that("relocate_abstract is non-greedy: stray Abstract after a gap is not moved (#149)", {
  body <- make_body(c(
    styled_p("AbstractTitle", "Abstract"),
    styled_p("Abstract", "The real abstract."),
    plain_p("A gap paragraph."),
    styled_p("Abstract", "A stray abstract-styled para."),
    plain_p("Author plate."),
    abstract_field_code(),
    plain_p("Body.")
  ))
  n <- docstyle:::relocate_abstract(body, ns, verbose = FALSE)
  expect_equal(n, 1L)
  sig <- para_sig(body)
  # Only the title + the contiguous real abstract move INSIDE the wrapper; the
  # stray Abstract paragraph (after the gap) stays where it was, exactly once.
  expect_equal(sig, c(
    "|A gap paragraph.",
    "Abstract|A stray abstract-styled para.",
    "|Author plate.",
    "|",                            # field-start
    "AbstractTitle|Abstract",
    "Abstract|The real abstract.",
    "|",                            # field-end
    "|Body."
  ))
  # The stray Abstract para appears exactly once (not duplicated, not lost).
  expect_equal(sum(sig == "Abstract|A stray abstract-styled para."), 1L)
  # Field-code wrapper preserved.
  expect_equal(length(xml2::xml_find_all(body, ".//w:fldChar", ns)), 3L)
  expect_equal(length(xml2::xml_find_all(body, ".//w:instrText", ns)), 1L)
})
