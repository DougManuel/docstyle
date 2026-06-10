#' Import citations from another project's field-codes.json
#'
#' Copies citation entries from a source `field-codes.json` into a destination
#' `field-codes.json`. Only the `citations` list is merged --
#' `zotero_pref`, `zotero_bibl`, and project metadata are never overwritten,
#' preserving the destination project's Zotero citation style.
#'
#' @param source_path Path to the source `field-codes.json` (or a directory
#'   containing `_docstyle/field-codes.json`).
#' @param dest_path Path to the destination `field-codes.json` (or a directory
#'   containing `_docstyle/field-codes.json`). Created if the file does not
#'   exist yet.
#' @param citekeys Character vector of citekeys to import. `NULL` (default)
#'   imports all citations from the source.
#' @param overwrite Logical. If `TRUE`, existing destination entries are
#'   replaced when the same citekey appears in the source. Default `FALSE`.
#' @param verbose Logical. Print progress messages. Default `TRUE`.
#'
#' @return Invisibly returns a list with:
#' \describe{
#'   \item{added}{Character vector of citekeys added}
#'   \item{skipped}{Character vector of citekeys skipped (already present)}
#'   \item{overwritten}{Character vector of citekeys overwritten}
#' }
#'
#' @examples
#' \dontrun{
#' # Import two specific citations from a sibling project
#' import_citations(
#'   source_path = "../other-project/_docstyle/field-codes.json",
#'   citekeys    = c("smith2020", "jones2021")
#' )
#'
#' # Import all citations from another project, overwriting conflicts
#' import_citations(
#'   source_path = "../other-project/_docstyle",
#'   overwrite   = TRUE
#' )
#' }
#'
#' @export
import_citations <- function(source_path,
                             dest_path  = "_docstyle/field-codes.json",
                             citekeys   = NULL,
                             overwrite  = FALSE,
                             verbose    = TRUE) {

  source_path <- resolve_field_codes_path(source_path)
  dest_path   <- resolve_field_codes_path(dest_path, must_exist = FALSE)

  source_fc <- tryCatch(
    jsonlite::fromJSON(source_path, simplifyVector = FALSE),
    error = function(e) stop("[import_citations] Failed to parse source: ", conditionMessage(e))
  )
  source_citations <- source_fc[["citations"]] %||% list()

  if (length(source_citations) == 0L) {
    if (verbose) message("[import_citations] No citations in source -- nothing to import")
    return(invisible(list(added = character(), skipped = character(), overwritten = character())))
  }

  # Filter to requested citekeys
  if (!is.null(citekeys)) {
    missing_keys <- setdiff(citekeys, names(source_citations))
    if (length(missing_keys) > 0L) {
      warning("[import_citations] Citekeys not found in source: ",
              paste(missing_keys, collapse = ", "))
    }
    source_citations <- source_citations[intersect(citekeys, names(source_citations))]
    if (length(source_citations) == 0L) {
      if (verbose) message("[import_citations] No requested citekeys found in source -- nothing to import")
      return(invisible(list(added = character(), skipped = character(), overwritten = character())))
    }
  }

  # Read or initialise destination
  if (file.exists(dest_path)) {
    dest_fc <- tryCatch(
      jsonlite::fromJSON(dest_path, simplifyVector = FALSE),
      error = function(e) stop("[import_citations] Failed to parse destination: ", conditionMessage(e))
    )
  } else {
    dest_dir <- dirname(dest_path)
    if (!dir.exists(dest_dir)) {
      ok <- dir.create(dest_dir, recursive = TRUE)
      if (!ok) stop("[import_citations] Cannot create destination directory: ", dest_dir)
    }
    dest_fc <- list(
      docstyle_version = as.character(utils::packageVersion("docstyle")),
      citations        = list(),
      citationGroups   = list()
    )
    if (verbose) message("[import_citations] Creating new ", dest_path)
  }

  dest_citations <- dest_fc[["citations"]] %||% list()

  added       <- character()
  skipped     <- character()
  overwritten <- character()

  for (key in names(source_citations)) {
    if (key %in% names(dest_citations)) {
      if (overwrite) {
        dest_citations[[key]] <- source_citations[[key]]
        overwritten <- c(overwritten, key)
      } else {
        skipped <- c(skipped, key)
      }
    } else {
      dest_citations[[key]] <- source_citations[[key]]
      added <- c(added, key)
    }
  }

  dest_fc[["citations"]] <- dest_citations

  # Write back -- preserve all other top-level fields (zotero_pref, zotero_bibl, etc.).
  # Write to a temp file first, then rename atomically to avoid partial writes on error.
  tmp_path <- paste0(dest_path, ".tmp")
  tryCatch(
    writeLines(
      jsonlite::toJSON(dest_fc, auto_unbox = TRUE, pretty = TRUE, null = "null"),
      tmp_path
    ),
    error = function(e) {
      unlink(tmp_path)
      stop("[import_citations] Failed to write destination: ", conditionMessage(e))
    }
  )
  if (!file.rename(tmp_path, dest_path)) {
    unlink(tmp_path)
    stop("[import_citations] Failed to rename temporary file to destination: ", dest_path)
  }

  if (verbose) {
    message("[import_citations] Added: ",    length(added),
            "  Skipped: ",                   length(skipped),
            "  Overwritten: ",               length(overwritten))
    if (length(added) > 0L)
      message("[import_citations]   Added: ", paste(added, collapse = ", "))
    if (length(skipped) > 0L)
      message("[import_citations]   Skipped (already present): ",
              paste(skipped, collapse = ", "))
    if (length(overwritten) > 0L)
      message("[import_citations]   Overwritten: ", paste(overwritten, collapse = ", "))
  }

  invisible(list(added = added, skipped = skipped, overwritten = overwritten))
}


# Resolve a path argument to a field-codes.json file path.
# If given a directory, looks for _docstyle/field-codes.json inside it, then
# field-codes.json directly. Always reaches the must_exist guard -- early returns
# only occur when the file was found, so must_exist is implicitly satisfied.
resolve_field_codes_path <- function(path, must_exist = TRUE) {
  resolved <- if (dir.exists(path)) {
    candidate  <- file.path(path, "_docstyle", "field-codes.json")
    candidate2 <- file.path(path, "field-codes.json")
    if      (file.exists(candidate))  candidate
    else if (file.exists(candidate2)) candidate2
    else                               candidate   # neither exists -- used for creation
  } else {
    path
  }
  if (must_exist && !file.exists(resolved)) {
    stop("[import_citations] File not found: ", resolved)
  }
  resolved
}
