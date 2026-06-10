# =============================================================================
# SECTION MAP — structural metadata sidecar
# =============================================================================
#
# Writes _docstyle/section-map.json after all DOM mutations are complete.
# Records paragraph positions, section classes, and applied payloads so that
# downstream injection passes can operate on stable indices rather than
# carrying ad-hoc in-memory state.
#
# This is the foundation for issue #72: unifying section attribute injection
# into a single post-assembly step. The in-memory section_sequence (with xml2
# node pointers) drives the current session; section-map.json persists the
# same information for debugging and future cold-read injection passes.
# =============================================================================


#' Compute Paragraph Position in Body
#'
#' Returns the 1-based integer position of a paragraph node among the direct
#' children of `body`. Stable only after all DOM mutations are complete.
#'
#' @param para xml2 node of the target paragraph
#' @param body xml2 node of w:body
#' @return 1-based integer position, or NA_integer_ if not found
#' @noRd
compute_para_position <- function(para, body) {
  children <- xml2::xml_children(body)
  for (i in seq_along(children)) {
    if (identical(children[[i]], para)) return(i)
  }
  NA_integer_
}


#' Write Section Map to Sidecar
#'
#' Serializes the in-memory section sequence to `_docstyle/section-map.json`
#' after all DOM mutations are complete. Paragraph positions are computed at
#' write time so they reflect the final document structure.
#'
#' Uses an atomic write (tmp file + rename) to avoid corrupt state if the
#' process is interrupted mid-write.
#'
#' @param section_sequence List of section entries from assemble_section_breaks().
#'   Each entry has: section_class, sectpr_para (xml2 node or NULL), is_closing,
#'   line_numbers, field_code_payload.
#' @param body_section List with line_numbers and field_code_payload for the
#'   final (body) section.
#' @param body xml2 node of w:body (used to compute paragraph positions).
#' @param sidecar_path Path to the _docstyle/ directory.
#' @param docstyle_version Package version string. Default: current package version.
#' @return Invisibly returns the path written, or NULL if nothing was written.
#' @noRd
write_section_map <- function(section_sequence, body_section, body,
                              sidecar_path,
                              docstyle_version = NULL) {
  if (length(section_sequence) == 0) return(invisible(NULL))

  if (is.null(docstyle_version)) {
    docstyle_version <- tryCatch(
      as.character(utils::packageVersion("docstyle")),
      error = function(e) "unknown"
    )
  }

  sections <- lapply(seq_along(section_sequence), function(i) {
    s <- section_sequence[[i]]
    para_pos <- if (!is.null(s$sectpr_para)) {
      compute_para_position(s$sectpr_para, body)
    } else {
      NA_integer_
    }

    list(
      index             = i - 1L,
      section_class     = s$section_class,
      para_position     = if (is.na(para_pos)) NULL else para_pos,
      is_closing        = isTRUE(s$is_closing),
      line_numbers      = s$line_numbers %||% "none",
      field_code_payload = s$field_code_payload %||% list()
    )
  })

  map <- list(
    docstyle_version = docstyle_version,
    sections         = sections,
    body_section     = list(
      line_numbers       = body_section$line_numbers %||% "none",
      field_code_payload = body_section$field_code_payload %||% list()
    )
  )

  out_path <- file.path(sidecar_path, "section-map.json")
  tmp_path <- paste0(out_path, ".tmp")

  tryCatch({
    dir.create(sidecar_path, showWarnings = FALSE, recursive = TRUE)
    jsonlite::write_json(map, tmp_path, pretty = TRUE, auto_unbox = TRUE,
                         null = "null")
    ok <- file.rename(tmp_path, out_path)
    if (!ok) {
      if (file.exists(tmp_path)) unlink(tmp_path)
      warning("[section_map] Could not rename section-map.json.tmp to section-map.json",
              call. = FALSE)
      return(invisible(NULL))
    }
    invisible(out_path)
  }, error = function(e) {
    if (file.exists(tmp_path)) unlink(tmp_path)
    warning("[section_map] Could not write section-map.json: ", conditionMessage(e),
            call. = FALSE)
    invisible(NULL)
  })
}


#' Read Section Map from Sidecar
#'
#' Reads `_docstyle/section-map.json`. Returns NULL if the file is missing or
#' contains invalid JSON. Warns on missing file only when `required = TRUE`
#' (e.g. cold-read injection passes); silent on first render when the sidecar
#' does not yet exist.
#'
#' @param sidecar_path Path to the _docstyle/ directory.
#' @param required If TRUE, emit a warning when the file does not exist.
#'   Default FALSE (silent on first render).
#' @return Parsed list from section-map.json, or NULL if unavailable.
#' @noRd
read_section_map <- function(sidecar_path, required = FALSE) {
  path <- file.path(sidecar_path, "section-map.json")
  if (!file.exists(path)) {
    if (required) {
      warning("[section_map] section-map.json not found at: ", path, call. = FALSE)
    }
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) {
      warning("[section_map] Could not parse section-map.json: ",
              conditionMessage(e), call. = FALSE)
      NULL
    }
  )
}
