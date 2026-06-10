#' Read BibTeX as CSL-JSON
#'
#' Converts a BibTeX file to CSL-JSON using Pandoc.
#' This ensures robust parsing and normalization of citation data.
#'
#' @param bib_path Path to the .bib file.
#' @return A list of CSL-JSON items.
#' @keywords internal
#' @export
read_bib_as_csl <- function(bib_path) {
  if (!file.exists(bib_path)) {
    stop("BibTeX file not found: ", bib_path)
  }
  
  # Check for pandoc
  if (Sys.which("pandoc") == "") {
    stop("Pandoc is required but not found in PATH.")
  }
  
  # Create temp output file
  temp_json <- tempfile(fileext = ".json")
  on.exit(unlink(temp_json))
  
  # Run pandoc conversion
  # pandoc refs.bib -t csljson -o out.json
  args <- c(shQuote(bib_path), "-t", "csljson", "-o", shQuote(temp_json))
  res <- system2("pandoc", args, stdout = TRUE, stderr = TRUE)
  
  if (!file.exists(temp_json)) {
    stop("Pandoc conversion failed: ", paste(res, collapse = "\n"))
  }
  
  # Read JSON
  jsonlite::read_json(temp_json, simplifyVector = FALSE)
}

