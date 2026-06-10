#' Validate Citations
#'
#' Compares citations in a Word document against a canonical BibTeX file.
#' Reports matched items, orphans (in Word but not Bib), and unused items.
#'
#' @param docx_path Path to the Word document.
#' @param bib_path Path to the canonical .bib file.
#' @return A validation object (list) containing matches and issues.
#' @export
validate_citations <- function(docx_path, bib_path) {
  
  # 1. Extract from Word
  message("Extracting citations from Word...")
  word_res <- extract_citations(docx_path, output_dir = tempdir())
  word_items <- word_res$citations
  
  if (length(word_items) == 0) {
    warning("No Zotero citations found in document.")
    return(NULL)
  }
  
  # 2. Read BibTeX
  message("Reading BibTeX reference library...")
  bib_items <- read_bib_as_csl(bib_path)
  
  if (length(bib_items) == 0) {
    warning("BibTeX library is empty or could not be read.")
    return(NULL)
  }
  
  # 3. Match
  message("Comparing citations...")
  res <- match_citations(word_items, bib_items)
  
  # 4. Report
  cat("\n--- Citation Validation Report ---
")
  cat(sprintf("Word Items: %d | Bib Items: %d\n", length(word_items), length(bib_items)))
  cat(sprintf("Matched: %d\n", nrow(res$matches)))
  cat(sprintf("Orphans (In Doc, Not in Bib): %d\n", nrow(res$orphans)))
  
  if (nrow(res$orphans) > 0) {
    cat("\n[!] Orphaned Citations:\n")
    print(res$orphans[, c("title_norm", "year")])
  }
  
  return(invisible(res))
}
