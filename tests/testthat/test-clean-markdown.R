# Tests for post-harvest markdown formatting cleanup
# Addresses:
#   - https://github.com/DougManuel/docstyle/issues/53
#     (Harvest duplicates bold markers around words with mixed formatting)
#   - https://github.com/DougManuel/docstyle/issues/46
#     (Post-harvest markdown cleanup for redundant bold/italic markers)
#   - https://github.com/DougManuel/docstyle/issues/47
#     (Bold leaks into italic spans due to Word run merging)


# ===========================================================================
# Rule 1: Collapse empty bold/italic boundaries (****)
# ===========================================================================

test_that("collapse empty bold boundaries within bold span", {
  # Issue #53: "**text1 ****text2 ****text3**" -> "**text1 text2 text3**"
  expect_equal(
    clean_markdown_formatting("**Validation and uncertainty quantification ****are ****insufficient (R1-W3).**"),
    "**Validation and uncertainty quantification are insufficient (R1-W3).**"
  )
})

test_that("italic-close + italic-open (no space) is not collapsed to avoid bold ambiguity", {
  # *text1* + *text2* concatenated = *text1**text2*
  # The ** is ambiguous (italic boundary or bold marker), so we don't collapse it.
  # This is a known limitation — the Rule 2 whitespace merge handles the
  # more common case where there IS a space between spans.
  input <- "*text1**text2*"
  expect_equal(clean_markdown_formatting(input), input)
})

test_that("collapse empty bold-italic boundaries", {
  expect_equal(
    clean_markdown_formatting("***text one ******text two***"),
    "***text one text two***"
  )
})

test_that("multiple empty boundaries in one line", {
  expect_equal(
    clean_markdown_formatting("**a ****b ****c ****d**"),
    "**a b c d**"
  )
})


# ===========================================================================
# Rule 2: Merge adjacent same-format spans
# ===========================================================================

test_that("merge adjacent bold spans separated by space", {
  expect_equal(
    clean_markdown_formatting("**word1** **word2**"),
    "**word1 word2**"
  )
})

test_that("merge adjacent italic spans separated by space", {
  expect_equal(
    clean_markdown_formatting("*word1* *word2*"),
    "*word1 word2*"
  )
})

test_that("merge adjacent bold-italic spans separated by space", {
  expect_equal(
    clean_markdown_formatting("***word1*** ***word2***"),
    "***word1 word2***"
  )
})

test_that("merge multiple adjacent bold spans", {
  expect_equal(
    clean_markdown_formatting("**a** **b** **c**"),
    "**a b c**"
  )
})

test_that("merge adjacent bold spans with no space (run boundary)", {
  # Two bold runs concatenated directly: "**text1****text2**"
  # The **** in the middle is close-bold + open-bold
  expect_equal(
    clean_markdown_formatting("**text1****text2**"),
    "**text1text2**"
  )
})

test_that("adjacent italic spans with no space are not collapsed (bold ambiguity)", {
  # *text1* + *text2* = *text1**text2* — ** is ambiguous
  input <- "*text1**text2*"
  expect_equal(clean_markdown_formatting(input), input)
})

test_that("issue #46 example: nested bold artifacts in bold span", {
  expect_equal(
    clean_markdown_formatting("**Smoking Initiation ****PoRT****:**"),
    "**Smoking Initiation PoRT:**"
  )
})


# ===========================================================================
# Rule 4: Trim internal whitespace at marker boundaries
# ===========================================================================

test_that("trim leading space inside bold markers", {
  expect_equal(
    clean_markdown_formatting("** text**"),
    "**text**"
  )
})

test_that("trim trailing space inside bold markers", {
  expect_equal(
    clean_markdown_formatting("**text **"),
    "**text**"
  )
})

test_that("trim leading space inside italic markers", {
  expect_equal(
    clean_markdown_formatting("* text*"),
    "*text*"
  )
})

test_that("trim trailing space inside italic markers", {
  expect_equal(
    clean_markdown_formatting("*text *"),
    "*text*"
  )
})

test_that("preserve space outside markers after trimming", {
  expect_equal(
    clean_markdown_formatting("word **text ** next"),
    "word **text** next"
  )
})


# ===========================================================================
# Rule 2: Strip whitespace-only formatting spans
# ===========================================================================

test_that("strip bold-wrapped whitespace", {
  expect_equal(
    clean_markdown_formatting("before** **after"),
    "before after"
  )
})

test_that("strip italic-wrapped whitespace", {
  expect_equal(
    clean_markdown_formatting("before* *after"),
    "before after"
  )
})

test_that("strip bold-italic-wrapped whitespace", {
  expect_equal(
    clean_markdown_formatting("before*** ***after"),
    "before after"
  )
})


# ===========================================================================
# Safety: don't break valid markdown
# ===========================================================================

test_that("preserve valid bold text unchanged", {
  expect_equal(
    clean_markdown_formatting("This is **bold** text"),
    "This is **bold** text"
  )
})

test_that("preserve valid italic text unchanged", {
  expect_equal(
    clean_markdown_formatting("This is *italic* text"),
    "This is *italic* text"
  )
})

test_that("preserve valid bold-italic text unchanged", {
  expect_equal(
    clean_markdown_formatting("This is ***bold italic*** text"),
    "This is ***bold italic*** text"
  )
})

test_that("preserve intentional bold within italic", {
  # This is valid markdown: italic span containing a bold word
  expect_equal(
    clean_markdown_formatting("*This is **important** text*"),
    "*This is **important** text*"
  )
})

test_that("preserve plain text unchanged", {
  expect_equal(
    clean_markdown_formatting("No formatting here at all."),
    "No formatting here at all."
  )
})

test_that("preserve strikethrough unchanged", {
  expect_equal(
    clean_markdown_formatting("This is ~~deleted~~ text"),
    "This is ~~deleted~~ text"
  )
})

test_that("handle empty string", {
  expect_equal(clean_markdown_formatting(""), "")
})

test_that("handle string with only markers", {
  # "****" alone is just an empty bold boundary — collapses to nothing
  expect_equal(clean_markdown_formatting("****"), "")
})

test_that("preserve markdown links", {
  expect_equal(
    clean_markdown_formatting("See [this link](http://example.com) for details"),
    "See [this link](http://example.com) for details"
  )
})

test_that("preserve footnote references", {
  expect_equal(
    clean_markdown_formatting("Some text[^1] and more"),
    "Some text[^1] and more"
  )
})

test_that("preserve citation syntax", {
  expect_equal(
    clean_markdown_formatting("According to [@smith2023; @jones2024]"),
    "According to [@smith2023; @jones2024]"
  )
})


# ===========================================================================
# Combined patterns (real-world scenarios)
# ===========================================================================

test_that("real-world: multiple artifacts in heading", {
  # Bold heading with tracked-change run splits
  expect_equal(
    clean_markdown_formatting("**The ****quick ****brown ****fox**"),
    "**The quick brown fox**"
  )
})

test_that("real-world: bold with colon artifact", {
  # Common pattern: bold label ending with colon
  expect_equal(
    clean_markdown_formatting("**Methods****:**"),
    "**Methods:**"
  )
})

test_that("real-world: adjacent spans with punctuation", {
  expect_equal(
    clean_markdown_formatting("**Results** **and Discussion**"),
    "**Results and Discussion**"
  )
})

test_that("real-world: italic with inner bold artifact from style inheritance", {
  # From issue #47 — bold genuinely in XML but not in source
  # This is the conservative case: we don't strip the bold because
  # we can't know if it's intentional
  input <- "*What **this delivers**: validated synthetic cohort...*"
  expect_equal(
    clean_markdown_formatting(input),
    input
  )
})


# ===========================================================================
# Bold-italic with _**...**_ format (v0.8.1+, #47)
# ===========================================================================

test_that("collapse bold-italic boundary (_**...**_ format)", {
  # close **_ + open _** → nothing (no space inserted — runs are adjacent)
  expect_equal(
    clean_markdown_formatting("_**text one**__**text two**_"),
    "_**text onetext two**_"
  )
})

test_that("merge adjacent bold-italic _**...**_ spans separated by space", {
  expect_equal(
    clean_markdown_formatting("_**word1**_ _**word2**_"),
    "_**word1 word2**_"
  )
})

test_that("strip whitespace-only _**...**_ span", {
  expect_equal(
    clean_markdown_formatting("before_** **_after"),
    "before after"
  )
})

test_that("trim leading whitespace inside _**...**_ markers", {
  expect_equal(
    clean_markdown_formatting("_** text**_"),
    "_**text**_"
  )
})

test_that("trim trailing whitespace inside _**...**_ markers", {
  expect_equal(
    clean_markdown_formatting("_**text **_"),
    "_**text**_"
  )
})

test_that("preserve valid _**...**_ text unchanged", {
  expect_equal(
    clean_markdown_formatting("This is _**bold italic**_ text"),
    "This is _**bold italic**_ text"
  )
})

test_that("legacy ***...*** still handled for backward compat", {
  # Older harvest output used ***text*** — should still collapse
  expect_equal(
    clean_markdown_formatting("***text one ****** text two***"),
    "***text one  text two***"
  )
  expect_equal(
    clean_markdown_formatting("***word1*** ***word2***"),
    "***word1 word2***"
  )
})
