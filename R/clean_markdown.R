#' Clean redundant markdown formatting from harvested text
#'
#' Post-processes a single paragraph of markdown text to remove formatting
#' artifacts caused by Word's run-level formatting model. Word stores bold,
#' italic, etc. per-run (\code{<w:r>}), and runs don't align with markdown
#' formatting spans. This produces artifacts like \code{****} (empty bold
#' boundaries) and \code{**word1** **word2**} (adjacent same-format spans).
#'
#' Applied automatically after \code{extract_formatted_text()} during harvest.
#'
#' @param text Character string. A single paragraph of markdown text.
#' @return Cleaned character string with redundant formatting collapsed.
#'
#' @details
#' The harvest code produces these marker pairs: \code{**} (bold),
#' \code{*} (italic), \code{_**...**_} (bold-italic, since v0.8.1).
#' Legacy \code{***} (bold-italic) from older harvests is also handled.
#'
#' Cleanup rules:
#' \enumerate{
#'   \item Collapse contiguous boundaries (bold-italic close+open, bold close+open)
#'   \item Merge adjacent same-format spans separated by whitespace
#'   \item Strip whitespace-only formatting spans
#'   \item Trim leading/trailing whitespace inside markers
#' }
#'
#' Conservative by design: only performs mechanical transformations that are
#' always safe. Does not attempt heuristic detection of spurious formatting
#' (e.g., bold leaked into italic from style inheritance — see #47).
#'
#' @seealso \code{\link{docx_to_qmd}} for the harvest pipeline
#' @keywords internal
clean_markdown_formatting <- function(text) {
  if (nchar(text) == 0) return(text)

  # --- Rule 1: Collapse contiguous boundaries ---
  #
  # Bold-italic uses _**...**_ (v0.8.1+). Boundaries:
  #   **__** = bold-italic close (**_) + bold-italic open (_**) → remove
  #   ****   = bold close (**) + bold open (**) → remove
  #
  # Legacy (pre-v0.8.1): ***text*** still handled for backward compat.
  #   6 stars (******) = *** close + *** open → remove
  #
  # Loop since collapsing can create new sequences.

  repeat {
    prev <- text
    # New format: **_ + _** boundary → nothing
    text <- gsub("\\*\\*__\\*\\*", "", text)
    # Legacy: 6 stars → nothing (backward compat)
    text <- gsub("\\*{6}", "", text)
    # Bold: 4 stars → nothing
    text <- gsub("\\*{4}", "", text)
    if (identical(text, prev)) break
  }

  # --- Rule 2: Strip whitespace-only formatting spans ---
  # "_** **_" -> " "   (bold-italic — must run before bold merge to avoid
  #   _** **_ being consumed by the bold **..ws..** pattern)
  # "** **" -> " "     (bold)
  # "* *" -> " "       (italic)
  text <- gsub("_\\*\\*(\\s+)\\*\\*_", "\\1", text)
  text <- gsub("\\*{3}(\\s+)\\*{3}", "\\1", text)  # legacy bold-italic
  text <- gsub("(?<!\\*)\\*{2}(?!\\*)(\\s+)(?<!\\*)\\*{2}(?!\\*)", "\\1", text, perl = TRUE)
  text <- gsub("(?<!\\*)\\*(?!\\*)(\\s+)(?<!\\*)\\*(?!\\*)", "\\1", text, perl = TRUE)

  # --- Rule 3: Merge adjacent same-format spans separated by whitespace ---
  #
  # After Rules 1-2, we still have:
  #   "_**text1**_ _**text2**_"  (space between close and open)
  #   "**text1** **text2**"     (bold)
  #   "*text1* *text2*"         (italic)
  #
  # Strategy: find close-marker + whitespace + open-marker of the same type
  # and replace with just the whitespace.

  repeat {
    prev <- text

    # Bold-italic (_**...**_): close **_ + ws + open _**
    text <- gsub("(?<=\\S)\\*\\*_(\\s+)_\\*\\*(?=\\S)", "\\1", text, perl = TRUE)

    # Legacy bold-italic (***...***): close *** + ws + open ***
    text <- gsub("(?<=\\S)\\*{3}(\\s+)\\*{3}(?=\\S)", "\\1", text, perl = TRUE)

    # Bold: **...ws...**
    text <- gsub("(?<=[^*\\s])\\*{2}(\\s+)\\*{2}(?=[^*\\s])", "\\1", text, perl = TRUE)

    # Italic: *...ws...*
    text <- gsub("(?<=[^*\\s])\\*(\\s+)\\*(?=[^*\\s])", "\\1", text, perl = TRUE)

    if (identical(text, prev)) break
  }

  # --- Rule 4: Trim leading/trailing whitespace inside markers ---
  # "_** text**_" -> "_**text**_"  (Pandoc requires markers flush against content)
  # Bold-italic (_**...**_)
  text <- gsub("(_\\*\\*)\\s+([^*]*\\S)(\\*\\*_)", "\\1\\2\\3", text)
  text <- gsub("(_\\*\\*)(\\S[^*]*)\\s+(\\*\\*_)", "\\1\\2\\3", text)
  # Legacy bold-italic (***...***) — backward compat
  text <- gsub("(\\*{3})\\s+([^*]*\\S)(\\*{3})", "\\1\\2\\3", text)
  text <- gsub("(\\*{3})(\\S[^*]*)\\s+(\\*{3})", "\\1\\2\\3", text)
  # Bold (exactly 2 stars)
  text <- gsub("(?<!\\*)(\\*{2})(?!\\*)\\s+([^*]*\\S)(?<!\\*)(\\*{2})(?!\\*)", "\\1\\2\\3", text, perl = TRUE)
  text <- gsub("(?<!\\*)(\\*{2})(?!\\*)(\\S[^*]*)\\s+(?<!\\*)(\\*{2})(?!\\*)", "\\1\\2\\3", text, perl = TRUE)
  # Italic (exactly 1 star)
  text <- gsub("(?<!\\*)(\\*)(?!\\*)\\s+([^*]*\\S)(?<!\\*)(\\*)(?!\\*)", "\\1\\2\\3", text, perl = TRUE)
  text <- gsub("(?<!\\*)(\\*)(?!\\*)(\\S[^*]*)\\s+(?<!\\*)(\\*)(?!\\*)", "\\1\\2\\3", text, perl = TRUE)

  text
}
