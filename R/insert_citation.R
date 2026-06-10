#' Insert Zotero Citation
#'
#' Opens the Zotero "Cite as you write" (Cayw) picker, allows the user to
#' select references, and inserts the formatted citation key (e.g., `[@knuth1984]`)
#' at the current cursor position in the source editor.
#'
#' @details
#' This function communicates with the Zotero Better BibTeX extension via its
#' local HTTP API.
#'
#' **Requirements:**
#' 1. Zotero must be running.
#' 2. Better BibTeX extension must be installed in Zotero.
#' 3. The document being edited should be a .qmd or .Rmd file.
#'
#' **Compatibility:**
#' - **RStudio:** Works natively as an Addin.
#' - **Positron:** Works via the `rstudioapi` compatibility layer.
#'
#' @return NULL (invisibly). The side effect is text insertion in the active editor.
#'
#' @export
insert_citation <- function() {
  # 1. Check if Zotero is reachable
  if (!is_zotero_running()) {
    stop("Zotero is not running or Better BibTeX is not installed.\n",
         "Please start Zotero and ensure the Better BibTeX extension is active.")
  }
  
  # 2. Call Better BibTeX Cayw API
  # URL: http://127.0.0.1:23119/better-bibtex/cayw
  # Params:
  #   format=pandoc (returns [@key])
  #   minimize=true (minimizes Zotero window after selection)
  
  url <- "http://127.0.0.1:23119/better-bibtex/cayw"
  
  tryCatch({
    # Make the request
    response <- httr::GET(
      url,
      query = list(
        format = "pandoc",
        minimize = "true"
      )
    )

    
    # Check for errors
    if (httr::status_code(response) != 200) {
      stop("Failed to retrieve citations from Zotero. Status: ", httr::status_code(response))
    }
    
    # Parse text content (should be like "[@key1; @key2]")
    citation_text <- httr::content(response, "text", encoding = "UTF-8")
    
    
    if (nchar(citation_text) == 0) {
      return(invisible(NULL)) # User cancelled
    }
    
    # --- Robust Formatting ---
    # 1. Trim whitespace
    citation_text <- trimws(citation_text)

    # 2. Remove ANY brackets [ or ] anywhere in the string to start clean
    #    This handles nesting like [@[@key]]
    citation_text <- gsub("\\[|\\]", "", citation_text)

    # 3. Clean up individual keys
    keys_raw <- strsplit(citation_text, ";\\s*")[[1]]
    keys_cleaned <- sapply(keys_raw, function(key) {
      key <- trimws(key)
      # Remove ALL leading @ symbols
      key <- gsub("^@+", "", key) 
      return(key)
    })
    
    # 4. Reconstruct with correct Pandoc format: [@key1; @key2]
    citation_text <- paste0("[@", paste(keys_cleaned, collapse = "; @"), "]")
    # --- End Robust Formatting ---
    
    # 3. Insert into editor
    # Try rstudioapi::insertText first for RStudio/Positron
    inserted_successfully <- FALSE
    if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
      tryCatch({
        # Explicitly get context to ensure we have a valid location
        # (Positron shim requires explicit location)
        context <- rstudioapi::getSourceEditorContext()
        location <- context$selection[[1]]$range
        
        rstudioapi::insertText(location = location, text = citation_text)
        inserted_successfully <- TRUE
      }, error = function(e) {
        message("Failed to insert text directly into editor using rstudioapi: ", conditionMessage(e))
      })
    }

    # Fallback: print to console and copy to clipboard if not inserted
    if (!inserted_successfully) {
      message("\n--- Inserted Citation (please copy and paste) ---")
      message(citation_text)
      message("-------------------------------------------------\n")

      # Attempt to copy to clipboard (cross-platform)
      if (Sys.info()["sysname"] == "Windows") {
        tryCatch({
          utils::writeClipboard(citation_text)
          message("Citation copied to clipboard.")
        }, error = function(e) {
          message("Failed to copy to clipboard on Windows: ", conditionMessage(e))
        })
      } else if (Sys.info()["sysname"] == "Darwin") { # macOS
        tryCatch({
          system(paste0("echo '", citation_text, "' | pbcopy"))
          message("Citation copied to clipboard.")
        }, error = function(e) {
          message("Failed to copy to clipboard on macOS: ", conditionMessage(e))
        })
      } else { # Linux/other Unix-like
        # Needs xclip or xsel, may not be present
        message("To copy to clipboard on this system, you may need 'xclip' or 'xsel'.")
      }
    }
    
  }, error = function(e) {
    stop("Error communicating with Zotero: ", conditionMessage(e))
  })
  
  invisible(NULL)
}
