# =============================================================================
# HARVEST MAP -- paragraph-level source mapping sidecar
# =============================================================================
#
# Writes _docstyle/harvest-map.json after convert_to_qmd() completes.
# Records, for each body child in the source docx, which QMD line(s) it
# produced. This is the foundation for diff-and-patch re-harvesting: on a
# subsequent harvest, the map enables comparing the new docx against the
# baseline paragraph-by-paragraph and only re-converting changed content.
#
# Entry types:
#   "content"  -- regular paragraph that produced one or more QMD lines
#   "metadata" -- paragraph consumed into YAML header (Title, Date, etc.)
#   "range"    -- generated-content div (section, version-history, table, etc.)
#   "skipped"  -- empty paragraph, TOC entry, or field code delimiter
#
# The map is written unconditionally on every harvest (it is small, ~10-30 KB
# for a typical 200-paragraph document) so it is always available for
# validation and future diff passes.
# =============================================================================


#' Build a Harvest Map Entry
#'
#' Constructs a single entry for the harvest map representing one body child
#' (paragraph or table) from the source docx and the QMD line(s) it produced.
#'
#' @param para_index 0-based integer index of the body child.
#' @param type Character: "content", "metadata", "range", or "skipped".
#' @param qmd_lines Integer vector of length 2: c(start, end) 1-based line
#'   numbers in the output QMD. Both values are NA_integer_ for "metadata" and
#'   "skipped" entries where no lines are emitted.
#' @param para_hash Character MD5 of the paragraph's plain text, or NULL.
#' @param style Character Word paragraph style name, or NULL.
#' @param range_name Character name of the generated-content range (for
#'   type = "range"), or NULL.
#' @param range_type Character type of the generated-content range (for
#'   type = "range"), or NULL.
#' @param para_span Integer vector of length 2: c(start, end) 0-based body
#'   child indices spanned by a range entry, or NULL.
#' @param text_preview Character first 80 chars of emitted text for debugging,
#'   or NULL.
#' @return A named list representing one harvest map entry.
#' @noRd
harvest_map_entry <- function(para_index,
                               type,
                               qmd_lines    = c(NA_integer_, NA_integer_),
                               para_hash    = NULL,
                               style        = NULL,
                               range_name   = NULL,
                               range_type   = NULL,
                               para_span    = NULL,
                               text_preview = NULL) {
  # Guards (#115): fail fast on the two always-required fields so a malformed
  # entry surfaces here, not as an opaque error in a downstream consumer.
  # Deliberately NOT a closed type enum and NOT requiring para_hash — real
  # harvest emits 'grouped-figure' and content entries (tables, anchor text
  # boxes) that legitimately have no hash.
  if (!is.numeric(para_index) || length(para_index) != 1L ||
      is.na(para_index)) {
    stop("[harvest_map] para_index must be a single non-NA integer; got ",
         deparse(para_index), call. = FALSE)
  }
  if (!is.character(type) || length(type) != 1L || is.na(type) ||
      !nzchar(type)) {
    stop("[harvest_map] type must be a single non-empty character string; got ",
         deparse(type), call. = FALSE)
  }
  entry <- list(
    para_index = para_index,
    type       = type,
    qmd_lines  = as.integer(qmd_lines)
  )
  if (!is.null(para_hash))    entry$para_hash    <- para_hash
  if (!is.null(style))        entry$style        <- style
  if (!is.null(range_name))   entry$range_name   <- range_name
  if (!is.null(range_type))   entry$range_type   <- range_type
  if (!is.null(para_span))    entry$para_span    <- as.integer(para_span)
  if (!is.null(text_preview)) entry$text_preview <- substr(text_preview, 1L, 80L)
  entry
}


#' Compute MD5 Hash of Paragraph Plain Text
#'
#' Extracts all `w:t` text nodes from a paragraph and returns the MD5 of the
#' concatenated plain text. This is deliberately simpler than
#' `extract_formatted_text()` -- it ignores inline formatting to produce a
#' stable identity hash suitable for paragraph-level diffing.
#'
#' @param para xml2 node of a `w:p` element.
#' @param ns Named character vector of XML namespace prefixes.
#' @return Character MD5 hex string, or NA_character_ if no text found.
#' @noRd
para_plain_text_hash <- function(para, ns) {
  t_nodes <- xml2::xml_find_all(para, ".//w:t", ns)
  if (length(t_nodes) == 0L) return(NA_character_)
  plain <- paste(xml2::xml_text(t_nodes), collapse = "")
  digest::digest(plain, algo = "md5", serialize = FALSE)
}


# =============================================================================
# SECTION-LEVEL SUMMARIES
# =============================================================================
#
# Computes section-level hashes, citation keys, and comment counts from the
# harvest entries and QMD output. This enables hierarchical change detection:
#   Document level: source_hash -- anything changed at all?
#   Section level:  section_hash -- which sections changed?
#   Paragraph level: para_hash -- which specific paragraphs changed?
#
# Writes section summaries to the sidecar so that future diff-and-patch logic
# (#105) and Google Docs round-trip detection (#111) can compare section hashes
# without re-processing unchanged content.
# =============================================================================


#' Compute Section-Level Summaries for Harvest Map
#'
#' Post-processes harvest entries and QMD output to build section-level
#' summaries with content hashes, citation keys, and comment counts.
#'
#' @param entries List of harvest map entry lists (from `harvest_map_entry()`).
#' @param all_ranges List of range objects from the pre-scan phase of
#'   `docx_to_qmd()`. Each range has `name`, `type`, `start_idx`, `end_idx`
#'   (1-based body child indices). Only ranges with `type` equal to
#'   `"section"` or `"native-section"` are processed; all others are ignored.
#' @param qmd_lines Character vector of all emitted QMD lines.
#' @return List of section summary lists, each with `name`, `section_hash`,
#'   `para_range`, `qmd_range`, `citation_keys`, `comment_count`.
#' @noRd
compute_section_summaries <- function(entries, all_ranges, qmd_lines) {
  # Filter for section-type ranges only
  section_ranges <- Filter(
    function(r) r$type %in% c("section", "native-section"),
    all_ranges
  )

  # Guards (#114): validate bounds on the section ranges we will actually
  # process, before any index arithmetic. A missing/non-integer/inverted
  # bound previously produced silently-wrong para ranges (spurious gaps,
  # mis-attributed content). Only section ranges are checked — other range
  # types were already filtered out above and never reach the arithmetic.
  for (rng in section_ranges) {
    nm <- rng$name %||% "<unnamed>"
    if (!is.numeric(rng$start_idx) || length(rng$start_idx) != 1L ||
        is.na(rng$start_idx) ||
        !is.numeric(rng$end_idx) || length(rng$end_idx) != 1L ||
        is.na(rng$end_idx)) {
      stop("[harvest_map] section range '", nm,
           "' has missing or non-integer start_idx/end_idx", call. = FALSE)
    }
    if (rng$start_idx < 1L || rng$end_idx < rng$start_idx) {
      stop("[harvest_map] section range '", nm, "': invalid bounds [",
           rng$start_idx, ", ", rng$end_idx,
           "] (need start_idx >= 1 and end_idx >= start_idx)", call. = FALSE)
    }
  }

  # Sort by start_idx
  if (length(section_ranges) > 1L) {
    starts <- vapply(section_ranges, function(r) r$start_idx, integer(1))
    section_ranges <- section_ranges[order(starts)]
  }

  para_count <- length(entries)

  # No sections -> single "document" section covering everything
  if (length(section_ranges) == 0L) {
    return(list(
      build_section_summary("document", entries, qmd_lines,
                            para_start_0 = 0L,
                            para_end_0   = para_count - 1L)
    ))
  }

  sections <- list()

  # Helper: append a named block only if it has at least one content entry.
  # Guards three boundary cases: preamble, inter-section gaps, postamble.
  # (Skipped/metadata-only gaps are suppressed to keep the output clean.)
  # The end_0 < start_0 guard handles adjacent sections with no gap between them.
  add_if_content <- function(name, start_0, end_0) {
    if (end_0 < start_0) return(invisible(NULL))
    has_content <- any(vapply(entries, function(e) {
      e$para_index >= start_0 && e$para_index <= end_0 && e$type == "content"
    }, logical(1)))
    if (has_content) {
      sections[[length(sections) + 1L]] <<- build_section_summary(
        name, entries, qmd_lines, start_0, end_0
      )
    }
  }

  # Preamble: paragraphs before the first section.
  # 0-based first-section start = start_idx - 1; one before that = start_idx - 2.
  add_if_content("preamble", 0L, section_ranges[[1]]$start_idx - 2L)

  # Each explicit section, plus any gap before the next one.
  # Index arithmetic (all values 0-based):
  #   section end   = end_idx - 1              (1-based -> 0-based)
  #   gap start     = (end_idx - 1) + 1 = end_idx  (0-based section end + 1)
  #   gap end       = next$start_idx - 2       (0-based next start is
  #                                             next$start_idx - 1; one before
  #                                             that is next$start_idx - 2)
  for (i in seq_along(section_ranges)) {
    rng <- section_ranges[[i]]
    sections[[length(sections) + 1L]] <- build_section_summary(
      rng$name, entries, qmd_lines,
      para_start_0 = rng$start_idx - 1L,
      para_end_0   = rng$end_idx   - 1L
    )

    if (i < length(section_ranges)) {
      next_rng <- section_ranges[[i + 1L]]
      add_if_content(
        paste0("gap_", i),
        rng$end_idx,               # 0-based start of gap
        next_rng$start_idx - 2L    # 0-based end of gap
      )
    }
  }

  # Postamble: paragraphs after the last section
  last_end_0 <- section_ranges[[length(section_ranges)]]$end_idx - 1L
  add_if_content("postamble", last_end_0 + 1L, para_count - 1L)

  sections
}


#' Build a Single Section Summary
#'
#' @param name Character section name.
#' @param entries List of all harvest map entries.
#' @param qmd_lines Character vector of all QMD lines.
#' @param para_start_0 Integer 0-based start index (inclusive).
#' @param para_end_0 Integer 0-based end index (inclusive).
#' @return Named list with section summary fields.
#' @noRd
build_section_summary <- function(name, entries, qmd_lines,
                                  para_start_0, para_end_0) {
  # Filter entries within this section's para range
  section_entries <- Filter(function(e) {
    e$para_index >= para_start_0 && e$para_index <= para_end_0
  }, entries)

  # Compute section hash from content entries' para_hashes
  content_hashes <- character(0)
  for (e in section_entries) {
    if (e$type == "content" && !is.null(e$para_hash) && !is.na(e$para_hash)) {
      content_hashes <- c(content_hashes, e$para_hash)
    }
  }
  # NA_character_ when a section has no content paragraphs (e.g. all images or
  # spacing). Callers comparing hashes across harvests must use identical()
  # rather than ==, since NA == NA returns NA (not TRUE) in R.
  section_hash <- if (length(content_hashes) > 0L) {
    digest::digest(paste(content_hashes, collapse = ""), algo = "md5",
                   serialize = FALSE)
  } else {
    NA_character_
  }

  # Compute QMD line range from entries
  qmd_range <- compute_section_qmd_range(section_entries)

  # Extract citation keys from QMD lines
  citation_keys <- if (!is.na(qmd_range[1]) && !is.na(qmd_range[2]) &&
                       qmd_range[1] <= length(qmd_lines)) {
    end_line <- min(qmd_range[2], length(qmd_lines))
    extract_citation_keys_from_lines(qmd_lines[qmd_range[1]:end_line])
  } else {
    character(0)
  }

  # Count comment markers in QMD lines
  comment_count <- if (!is.na(qmd_range[1]) && !is.na(qmd_range[2]) &&
                       qmd_range[1] <= length(qmd_lines)) {
    end_line <- min(qmd_range[2], length(qmd_lines))
    length(grep("comment:start", qmd_lines[qmd_range[1]:end_line],
                fixed = TRUE))
  } else {
    0L
  }

  list(
    name          = name,
    section_hash  = section_hash,
    para_range    = as.integer(c(para_start_0, para_end_0)),
    qmd_range     = as.integer(qmd_range),
    citation_keys = as.list(citation_keys),
    comment_count = as.integer(comment_count)
  )
}


#' Compute QMD Line Range for a Set of Entries
#'
#' @param section_entries List of harvest map entries within a section.
#' @return Integer vector c(min_start, max_end), or c(NA, NA) if no entries
#'   have QMD lines.
#' @noRd
compute_section_qmd_range <- function(section_entries) {
  qmd_start <- NA_integer_
  qmd_end   <- NA_integer_
  for (e in section_entries) {
    if (!is.null(e$qmd_lines) && !is.na(e$qmd_lines[1])) {
      if (is.na(qmd_start) || e$qmd_lines[1] < qmd_start) {
        qmd_start <- e$qmd_lines[1]
      }
    }
    if (!is.null(e$qmd_lines) && length(e$qmd_lines) >= 2L &&
        !is.na(e$qmd_lines[2])) {
      if (is.na(qmd_end) || e$qmd_lines[2] > qmd_end) {
        qmd_end <- e$qmd_lines[2]
      }
    }
  }
  c(qmd_start, qmd_end)
}


#' Extract Citation Keys from QMD Lines
#'
#' Extracts `[@citekey]` patterns from a character vector of QMD lines.
#' Uses the same bracket and key regex as `extract_qmd_citekeys()` in
#' use_docstyle.R, but without YAML front-matter skipping. Callers must pass
#' only post-front-matter lines to avoid false matches on YAML strings.
#'
#' @param lines Character vector of QMD lines.
#' @return Character vector of unique citation keys (without `@` prefix).
#' @noRd
extract_citation_keys_from_lines <- function(lines) {
  if (length(lines) == 0L) return(character(0))
  text <- paste(lines, collapse = "\n")

  # Match citation groups: [@key], [-@key], [see @key1; @key2, p. 42]
  bracket_pattern <- "\\[[^\\]]*@[a-zA-Z][^\\]]*\\]"
  brackets <- regmatches(text, gregexpr(bracket_pattern, text, perl = TRUE))[[1]]
  if (length(brackets) == 0L) return(character(0))

  # Extract individual @keys from each bracket group
  key_pattern <- "-?@([a-zA-Z][a-zA-Z0-9_.:/-]*)"
  keys <- character(0)
  for (group in brackets) {
    matches <- regmatches(group, gregexpr(key_pattern, group, perl = TRUE))[[1]]
    parts <- gsub("^-?@", "", matches)
    keys <- c(keys, parts)
  }
  unique(keys)
}


#' Write Harvest Map to Sidecar
#'
#' Serializes the list of harvest map entries to `_docstyle/harvest-map.json`
#' using an atomic write (tmp file + rename) matching the `section_map.R`
#' pattern.
#'
#' @param entries List of harvest map entry lists (from `harvest_map_entry()`).
#' @param source_docx Character path to the source docx file.
#' @param para_count Integer total number of body children in the source docx.
#' @param output_path Character path of the output QMD file (used to locate
#'   the `_docstyle/` sidecar directory).
#' @param sidecar_path Character path to the `_docstyle/` directory. Derived
#'   from `output_path` when NULL.
#' @param docstyle_version Character package version string.
#' @return Invisibly returns the path written, or NULL on failure.
#' @noRd
write_harvest_map <- function(entries,
                               source_docx,
                               para_count,
                               qmd_line_count   = NULL,
                               sections         = NULL,
                               output_path      = NULL,
                               sidecar_path     = NULL,
                               docstyle_version = NULL) {
  if (is.null(sidecar_path)) {
    if (is.null(output_path)) return(invisible(NULL))
    sidecar_path <- file.path(dirname(normalizePath(output_path,
                                                     mustWork = FALSE)),
                               "_docstyle")
  }

  if (is.null(docstyle_version)) {
    docstyle_version <- tryCatch(
      as.character(utils::packageVersion("docstyle")),
      error = function(e) "unknown"
    )
  }

  source_hash <- tryCatch(
    digest::digest(file = source_docx, algo = "md5"),
    error = function(e) {
      message("[harvest_map] WARNING: could not hash '", basename(source_docx),
              "': ", conditionMessage(e),
              " -- source_hash will be NA, document-level change detection unreliable.")
      NA_character_
    }
  )

  map <- list(
    docstyle_version = docstyle_version,
    source_docx      = basename(source_docx),
    source_hash      = source_hash,
    paragraph_count  = as.integer(para_count),
    qmd_line_count   = if (!is.null(qmd_line_count)) as.integer(qmd_line_count) else NULL,
    entries          = entries
  )
  if (!is.null(sections)) map$sections <- sections

  out_path <- file.path(sidecar_path, "harvest-map.json")
  tmp_path <- paste0(out_path, ".tmp")

  tryCatch({
    dir.create(sidecar_path, showWarnings = FALSE, recursive = TRUE)
    jsonlite::write_json(map, tmp_path, pretty = TRUE, auto_unbox = TRUE,
                         null = "null")
    ok <- file.rename(tmp_path, out_path)
    if (!ok) {
      unlink(tmp_path)
      message("[harvest_map] ERROR: atomic rename failed -- harvest-map.json may be stale.",
              "\n  From: ", tmp_path, "\n  To:   ", out_path,
              "\n  Check filesystem permissions or cross-device link restrictions.")
      return(invisible(NULL))
    }
    message("[harvest] wrote harvest map (", length(entries), " entries) to harvest-map.json")
    invisible(out_path)
  }, error = function(e) {
    unlink(tmp_path)
    message("[harvest_map] ERROR: could not write harvest-map.json: ",
            conditionMessage(e))
    invisible(NULL)
  })
}


#' Read Harvest Map from Sidecar
#'
#' Reads `_docstyle/harvest-map.json`. Returns NULL if the file is missing or
#' unreadable.
#'
#' @param sidecar_path Character path to the `_docstyle/` directory.
#' @return List with the harvest map, or NULL.
#' @noRd
read_harvest_map <- function(sidecar_path) {
  path <- file.path(sidecar_path, "harvest-map.json")
  if (!file.exists(path)) return(NULL)
  tryCatch(
    jsonlite::read_json(path, simplifyVector = FALSE),
    error = function(e) {
      message("[harvest_map] ERROR: harvest-map.json exists but could not be parsed: ",
              conditionMessage(e),
              "\n  Path: ", path,
              "\n  The file may be corrupted -- delete it to force a fresh harvest.")
      NULL
    }
  )
}
