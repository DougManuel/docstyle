#' Add citations to field-codes.json via local Zotero API
#'
#' Searches the Zotero library for each citekey and appends the item metadata
#' to `_docstyle/field-codes.json`. Does not require Word or a harvest
#' round-trip. After running, `quarto render` injects live Zotero field codes
#' automatically via the `build_citation_instr()` fallback in
#' `inject_zotero_citations()`.
#'
#' @param citekeys Character vector of Better BibTeX citation keys
#'   (e.g. `c("tyas1998", "vangeli2011")`).
#' @param project_dir Path to the project root directory. Default: current
#'   working directory.
#' @param sidecar_dir Name of the sidecar directory within `project_dir`.
#'   Default: `"_docstyle"`.
#' @param write_bib If `TRUE` (default), calls [export_bibliography()] after
#'   adding entries so that `references.bib` is kept in sync for LaTeX/Typst
#'   workflows. Set to `FALSE` to skip BibTeX export.
#'
#' @return Invisibly returns the updated field-codes list.
#'
#' @details
#' Requires Zotero to be running with the Better BibTeX extension installed.
#' Connectivity is checked via [is_zotero_running()] before any queries are
#' made.
#'
#' Each citekey is looked up using the local Zotero HTTP API
#' (`http://127.0.0.1:23119/api/`). The returned CSL-JSON `itemData` and
#' Zotero item URI are written into the `citations` catalog of
#' `field-codes.json`.
#'
#' Existing entries are never overwritten. Citekeys not found in Zotero
#' produce a warning and are skipped.
#'
#' @seealso [export_bibliography()] to export the full bibliography to BibTeX.
#'
#' @examples
#' \dontrun{
#' # Add two citations to the sidecar, then render
#' add_citations_from_zotero(c("tyas1998", "vangeli2011"))
#'
#' # Suppress BibTeX sync (e.g. docx-only workflow)
#' add_citations_from_zotero("tyas1998", write_bib = FALSE)
#' }
#'
#' @export
add_citations_from_zotero <- function(citekeys,
                                       project_dir = ".",
                                       sidecar_dir = "_docstyle",
                                       write_bib = TRUE) {
  if (!is_zotero_running()) {
    stop("[add_citations] Zotero is not running or Better BibTeX is not installed.\n",
         "Please start Zotero and ensure the Better BibTeX extension is active.")
  }

  sidecar_path     <- file.path(project_dir, sidecar_dir)
  field_codes_path <- file.path(sidecar_path, "field-codes.json")

  fc <- if (file.exists(field_codes_path)) {
    tryCatch(
      jsonlite::fromJSON(field_codes_path, simplifyVector = FALSE),
      error = function(e) {
        stop("[add_citations] Could not read field-codes.json: ", conditionMessage(e))
      }
    )
  } else {
    list(
      docstyle_version = as.character(utils::packageVersion("docstyle")),
      source           = "mcp",
      citations        = list(),
      citationGroups   = list()
    )
  }

  if (is.null(fc$citations)) fc$citations <- list()

  added     <- character(0)
  skipped   <- character(0)
  not_found <- character(0)

  for (ck in citekeys) {
    if (ck %in% names(fc$citations)) {
      skipped <- c(skipped, ck)
      next
    }
    entry <- fetch_zotero_item(ck)
    if (is.null(entry)) {
      not_found <- c(not_found, ck)
      next
    }
    fc$citations[[ck]] <- entry
    added <- c(added, ck)
  }

  if (length(added) > 0) {
    dir.create(sidecar_path, showWarnings = FALSE, recursive = TRUE)
    jsonlite::write_json(fc, field_codes_path, pretty = TRUE, auto_unbox = TRUE)
    message("[add_citations] Added: ", paste(added, collapse = ", "))
  }
  if (length(skipped) > 0) {
    message("[add_citations] Already present (skipped): ", paste(skipped, collapse = ", "))
  }
  if (length(not_found) > 0) {
    warning("[add_citations] Not found in Zotero: ", paste(not_found, collapse = ", "),
            call. = FALSE)
  }

  if (write_bib && length(added) > 0 && dir.exists(sidecar_path)) {
    tryCatch(
      export_bibliography(sidecar_path, verbose = FALSE),
      error = function(e) {
        message("[add_citations] BibTeX export failed: ", conditionMessage(e))
      }
    )
    bib_path <- file.path(sidecar_path, "references.bib")
    if (file.exists(bib_path)) {
      message("[add_citations] Updated references.bib (", length(fc$citations), " entries)")
    }
  }

  invisible(fc)
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#' Fetch a single Zotero item by Better BibTeX citekey
#'
#' Two-step lookup via the local Zotero HTTP API:
#' 1. CSL-JSON search to find itemData
#' 2. Raw item fetch to extract the Zotero URI
#'
#' @param citekey Better BibTeX citation key
#' @return List with `itemData` and `uris`, or NULL if not found
#' @noRd
fetch_zotero_item <- function(citekey) {
  base_url <- "http://127.0.0.1:23119/api/users/0"

  # Step 1: CSL-JSON search — get itemData
  item_data <- fetch_csljson_item(citekey, base_url)
  if (is.null(item_data)) return(NULL)

  # Step 2: Raw item search — extract Zotero URI
  uri <- fetch_zotero_uri(citekey, base_url)

  list(itemData = item_data, uris = list(uri %||% ""))
}


#' Search for an item by citekey and return its CSL-JSON itemData
#' @noRd
fetch_csljson_item <- function(citekey, base_url) {
  url <- paste0(base_url, "/items?format=csljson&q=",
                utils::URLencode(citekey, reserved = TRUE))

  resp <- tryCatch(httr::GET(url), error = function(e) NULL)
  if (is.null(resp) || httr::status_code(resp) != 200) return(NULL)

  items <- tryCatch(
    jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                       simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (!is.list(items) || length(items) == 0) return(NULL)

  # Exact match on citation-key field (BBT citekey)
  for (item in items) {
    if (identical(item[["citation-key"]], citekey)) return(item)
  }
  NULL
}


#' Fetch raw item metadata to extract the Zotero URI
#'
#' The URI format is `http://zotero.org/users/{userID}/items/{itemKey}`.
#' We derive it from `links.self.href` in the non-csljson API response.
#' @noRd
fetch_zotero_uri <- function(citekey, base_url) {
  url <- paste0(base_url, "/items?q=",
                utils::URLencode(citekey, reserved = TRUE))

  resp <- tryCatch(httr::GET(url), error = function(e) NULL)
  if (is.null(resp) || httr::status_code(resp) != 200) return(NULL)

  items <- tryCatch(
    jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                       simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (!is.list(items) || length(items) == 0) return(NULL)

  for (item in items) {
    href <- item$links$self$href %||% ""
    # href: http://localhost:23119/api/users/6858935/items/9N7228GU
    m <- regmatches(href, regexpr("users/(\\d+)/items/([A-Z0-9]+)", href, perl = TRUE))
    if (length(m) > 0 && nchar(m) > 0) {
      parts <- strsplit(m, "/")[[1]]
      # parts: c("users", userID, "items", itemKey)
      if (length(parts) == 4) {
        return(paste0("http://zotero.org/users/", parts[2], "/items/", parts[4]))
      }
    }
  }
  NULL
}
