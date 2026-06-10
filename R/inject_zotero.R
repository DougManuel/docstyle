

#' Find Last Occurrence of a String
#'
#' @param haystack String to search in
#' @param needle String to find
#' @return Position of last occurrence, or -1 if not found
#' @keywords internal
find_last_occurrence <- function(haystack, needle) {
  matches <- gregexpr(needle, haystack, fixed = TRUE)[[1]]
  if (matches[1] == -1) return(-1)

  matches[length(matches)]
}


#' Replace Bibliography Marker with Field Code XML
#'
#' Tries multiple patterns to find and replace the DOCSTYLE_CITE_BIBL marker.
#' Patterns are tried in order of specificity: entire paragraph, run, or
#' fallback to finding the enclosing run manually.
#'
#' @param xml_content The document XML content
#' @param bibl_xml The field code XML to insert
#' @return List with `content` (modified XML) and `replaced` (0 or 1)
#' @keywords internal
replace_bibl_marker <- function(xml_content, bibl_xml) {
  # Pattern 1: Entire paragraph
  para_pattern <- "<w:p[^>]*>\\s*<w:r[^>]*>\\s*<w:t[^>]*>DOCSTYLE_CITE_BIBL</w:t>\\s*</w:r>\\s*</w:p>"
  if (grepl(para_pattern, xml_content, perl = TRUE)) {
    return(list(
      content = sub(para_pattern, paste0("<w:p>", bibl_xml, "</w:p>"), xml_content, perl = TRUE),
      replaced = 1L
    ))
  }

  # Pattern 2: Just the run
  run_pattern <- "<w:r[^>]*>\\s*<w:t[^>]*>DOCSTYLE_CITE_BIBL</w:t>\\s*</w:r>"
  if (grepl(run_pattern, xml_content, perl = TRUE)) {
    return(list(
      content = sub(run_pattern, bibl_xml, xml_content, perl = TRUE),
      replaced = 1L
    ))
  }

  # Pattern 3: Find marker text and replace enclosing run
  marker_pos <- regexpr("DOCSTYLE_CITE_BIBL", xml_content, fixed = TRUE)
  if (marker_pos > 0) {
    before <- substr(xml_content, 1, marker_pos - 1)
    after <- substr(xml_content, marker_pos + nchar("DOCSTYLE_CITE_BIBL"), nchar(xml_content))

    r_start <- find_last_occurrence(before, "<w:r")
    r_end_match <- regexpr("</w:r>", after, fixed = TRUE)

    if (r_start > 0 && r_end_match > 0) {
      abs_r_end <- marker_pos + nchar("DOCSTYLE_CITE_BIBL") - 1 + as.integer(r_end_match) + 5
      return(list(
        content = paste0(
          substr(xml_content, 1, r_start - 1),
          bibl_xml,
          substr(xml_content, abs_r_end + 1, nchar(xml_content))
        ),
        replaced = 1L
      ))
    }
  }

  list(content = xml_content, replaced = 0L)
}


#' Build Field Code XML String
#'
#' Creates the 5-part Word field code structure as a raw XML string
#' without namespace declarations (inherits from parent document).
#'
#' @param instrText The ADDIN ZOTERO_ITEM instruction text
#' @param display The display text (e.g., "(1)")
#' @param display_rpr Optional XML string for run properties on the display
#'   text run (e.g., superscript formatting). If NULL, no run properties are
#'   added to the display run.
#' @return XML string for the complete field code
#' @keywords internal
build_field_code_xml <- function(instrText, display, display_rpr = NULL) {
  # Escape XML special characters
  instr_escaped <- escape_xml_text(instrText)
  display_escaped <- escape_xml_text(display)

  # Pad instruction text (Word requires leading/trailing spaces)
  if (!startsWith(instr_escaped, " ")) instr_escaped <- paste0(" ", instr_escaped)
  if (!endsWith(instr_escaped, " ")) instr_escaped <- paste0(instr_escaped, " ")

  # Build display run with optional run properties
  if (!is.null(display_rpr) && nzchar(display_rpr)) {
    display_run <- paste0('<w:r><w:rPr>', display_rpr, '</w:rPr>',
                          '<w:t>', display_escaped, '</w:t></w:r>')
  } else {
    display_run <- paste0('<w:r><w:t>', display_escaped, '</w:t></w:r>')
  }

  # Build the 5-part structure without any namespace declarations
  paste0(
    '<w:r><w:fldChar w:fldCharType="begin"/></w:r>',
    '<w:r><w:instrText xml:space="preserve">', instr_escaped, '</w:instrText></w:r>',
    '<w:r><w:fldChar w:fldCharType="separate"/></w:r>',
    display_run,
    '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
  )
}




# ---------------------------------------------------------------------------
# Marker-based Zotero citation injection (finisher)
# ---------------------------------------------------------------------------

#' Inject Zotero Citation Field Codes from Markers
#'
#' Replaces `DOCSTYLE_CITE::` text markers (emitted by `zotero-inject.lua`)
#' with real Word field code XML in a rendered DOCX. Also handles
#' `DOCSTYLE_CITE_BIBL` for the bibliography placeholder.
#'
#' This function is the R finisher counterpart to the simplified Lua filter.
#' The Lua filter emits lightweight text markers during Pandoc rendering;
#' this function runs post-Pandoc to inject the actual field code XML.
#'
#' @param docx_path Path to the Pandoc-rendered DOCX file containing markers.
#' @param field_codes_path Path to field-codes.json (citationGroups schema).
#' @param output_path Path to write the modified DOCX. Defaults to overwriting.
#' @param verbose Logical; if TRUE, print progress messages.
#'
#' @return A list with `n_injected` (citation markers replaced),
#'   `n_bibl` (bibliography markers replaced), and `n_fallback`
#'   (citations where synthetic instrText was built).
#' @export
inject_zotero_citations <- function(docx_path, field_codes_path,
                                     output_path = docx_path,
                                     verbose = FALSE) {
  if (!file.exists(docx_path)) {
    stop("Input DOCX not found: ", docx_path)
  }
  if (!file.exists(field_codes_path)) {
    stop("field-codes.json not found: ", field_codes_path)
  }

  # Read field-codes.json
  fc_obj <- jsonlite::fromJSON(field_codes_path, simplifyVector = FALSE)

  citations <- fc_obj$citations %||% list()
  citation_groups <- fc_obj$citationGroups %||% list()
  zotero_bibl <- fc_obj$zotero_bibl

  # Backward compat: detect old schema (citations have instrText per citekey)
  if (length(citations) > 0) {
    first_cite <- citations[[1]]
    if (!is.null(first_cite$instrText)) {
      warning("[inject_zotero_citations] Old field-codes.json schema detected ",
              "(citations have instrText). Re-harvest the source document to ",
              "generate citationGroups schema.")
    }
  }

  # Build group lookup: sorted citekeys string -> group entry
  # This allows marker "DOCSTYLE_CITE::b;a" to match group with citekeys ["a","b"]
  group_lookup <- list()
  for (gkey in names(citation_groups)) {
    grp <- citation_groups[[gkey]]
    sorted_key <- paste(sort(unlist(grp$citekeys)), collapse = ";")
    # Keep the first (or best) match if duplicates exist
    if (is.null(group_lookup[[sorted_key]])) {
      group_lookup[[sorted_key]] <- grp
    }
  }

  # Detect citation display style from formattedCitation RTF markup.
  # Zotero Vancouver styles use \super...\nosupersub{} for superscript numbers.
  # We apply matching Word XML run properties to the display text.
  display_rpr <- NULL
  for (grp in citation_groups) {
    fmt <- grp$properties$formattedCitation
    if (!is.null(fmt) && nzchar(fmt)) {
      if (grepl("\\super ", fmt, fixed = TRUE)) {
        display_rpr <- '<w:vertAlign w:val="superscript"/>'
        if (verbose) {
          message("[inject_zotero_citations] Detected superscript citation style")
        }
      }
      break
    }
  }

  if (verbose) {
    message("[inject_zotero_citations] Loaded ", length(citations),
            " citation(s), ", length(citation_groups), " group(s)")
  }

  # Unzip DOCX
  temp_dir <- tempfile("docstyle_inject_cite_")
  dir.create(temp_dir)
  utils::unzip(docx_path, exdir = temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    stop("Invalid DOCX structure: word/document.xml not found")
  }

  xml_content <- paste(readLines(doc_xml_path, warn = FALSE), collapse = "\n")

  n_injected <- 0L
  n_bibl <- 0L
  n_fallback <- 0L

 # --- Replace DOCSTYLE_CITE:: markers ---
  # Markers appear as text within <w:t> elements, potentially sharing a run
  # with surrounding paragraph text. We must split the text run rather than
  # replacing the entire <w:r>, to preserve surrounding text.
  #
  # Strategy: find the enclosing <w:r>, extract any <w:rPr> (run properties),
  # then split into: pre-text run + field code XML + post-text run.

  while (grepl("DOCSTYLE_CITE::", xml_content, fixed = TRUE)) {
    # Find the marker text
    marker_match <- regexpr("DOCSTYLE_CITE::[A-Za-z0-9_;-]+", xml_content)
    if (marker_match == -1) break

    marker_text <- regmatches(xml_content, marker_match)
    marker_pos <- as.integer(marker_match)

    # Parse citekeys from marker
    keys_str <- sub("^DOCSTYLE_CITE::", "", marker_text)
    citekeys <- strsplit(keys_str, ";")[[1]]

    # Look up the matching citationGroup
    sorted_key <- paste(sort(citekeys), collapse = ";")
    grp <- group_lookup[[sorted_key]]

    if (!is.null(grp)) {
      # Found matching group -- use stored instrText and display
      instr_text <- sanitize_instr_text_r(grp$instrText)
      display <- grp$properties$plainCitation %||%
        grp$properties$formattedCitation %||% "(REF)"
    } else if (all(citekeys %in% names(citations))) {
      # No group match but all citekeys are known -- build synthetic instrText
      instr_text <- build_citation_instr(citekeys, citations)
      display <- "(REF)"
      n_fallback <- n_fallback + 1L
      if (verbose) {
        message("[inject_zotero_citations] Fallback synthetic instrText for: ",
                paste(citekeys, collapse = "; "))
      }
    } else {
      # Unknown citekey(s) -- replace marker with [@citekey] text and warn
      unknown <- citekeys[!citekeys %in% names(citations)]
      warning("[inject_zotero_citations] Unknown citekey(s): ",
              paste(unknown, collapse = ", "), " -- replacing with text")
      fallback_text <- paste0("[@", paste(citekeys, collapse = "; @"), "]")
      xml_content <- sub(marker_text, fallback_text, xml_content, fixed = TRUE)
      next
    }

    # Build field code XML
    field_xml <- build_field_code_xml(instrText = instr_text, display = display,
                                      display_rpr = display_rpr)

    # Find the enclosing <w:r>...</w:r> that contains this marker
    before_marker <- substr(xml_content, 1, marker_pos - 1)
    after_marker <- substr(xml_content, marker_pos + nchar(marker_text),
                           nchar(xml_content))

    # Find opening <w:r
    r_start <- find_last_occurrence(before_marker, "<w:r")
    if (r_start == -1) {
      xml_content <- sub(marker_text, field_xml, xml_content, fixed = TRUE)
      n_injected <- n_injected + 1L
      next
    }

    # Find closing </w:r> after the marker
    r_end_match <- regexpr("</w:r>", after_marker, fixed = TRUE)
    if (r_end_match == -1) {
      xml_content <- sub(marker_text, field_xml, xml_content, fixed = TRUE)
      n_injected <- n_injected + 1L
      next
    }

    abs_r_end <- marker_pos + nchar(marker_text) - 1 +
      as.integer(r_end_match) + 5  # +5 for "</w:r>"

    # Extract the full <w:r>...</w:r> element
    full_run <- substr(xml_content, r_start, abs_r_end)

    # Extract <w:rPr>...</w:rPr> if present (run properties like font, size)
    rpr_match <- regexpr("<w:rPr>.*?</w:rPr>", full_run)
    rpr_xml <- if (rpr_match > 0) regmatches(full_run, rpr_match) else ""

    # Extract text before and after the marker within the <w:t> element
    # The marker is at a known position within the full run
    t_match <- regexpr("<w:t[^>]*>", full_run)
    t_tag <- if (t_match > 0) regmatches(full_run, t_match) else '<w:t xml:space="preserve">'
    t_tag_end <- if (t_match > 0) t_match + attr(t_match, "match.length") else -1

    # Get the text content from the <w:t> element
    # Use sub() to extract content between <w:t...> and </w:t>
    full_text <- ""
    if (t_match > 0) {
      t_start <- t_match + attr(t_match, "match.length")
      t_end_pos <- regexpr("</w:t>", full_run, fixed = TRUE)
      if (t_end_pos > 0) {
        full_text <- substr(full_run, t_start, t_end_pos - 1)
      }
    }

    # Split the text at the marker
    marker_in_text <- regexpr(marker_text, full_text, fixed = TRUE)
    if (marker_in_text > 0) {
      pre_text <- substr(full_text, 1, marker_in_text - 1)
      post_text <- substr(full_text, marker_in_text + nchar(marker_text),
                          nchar(full_text))
    } else {
      pre_text <- ""
      post_text <- ""
    }

    # Build replacement: pre-text run + field code + post-text run
    replacement <- ""

    # Pre-text run (only if there's text before the marker)
    if (nchar(pre_text) > 0) {
      replacement <- paste0(
        replacement,
        "<w:r>", rpr_xml,
        '<w:t xml:space="preserve">', pre_text, "</w:t></w:r>"
      )
    }

    # Field code XML (the 5-run structure)
    replacement <- paste0(replacement, field_xml)

    # Post-text run (only if there's text after the marker)
    if (nchar(post_text) > 0) {
      replacement <- paste0(
        replacement,
        "<w:r>", rpr_xml,
        '<w:t xml:space="preserve">', post_text, "</w:t></w:r>"
      )
    }

    # Replace the entire <w:r>...</w:r> with the split runs + field code
    xml_content <- paste0(
      substr(xml_content, 1, r_start - 1),
      replacement,
      substr(xml_content, abs_r_end + 1, nchar(xml_content))
    )

    n_injected <- n_injected + 1L
  }

  # --- Replace DOCSTYLE_CITE_BIBL marker ---
  if (grepl("DOCSTYLE_CITE_BIBL", xml_content, fixed = TRUE)) {
    bibl_instr <- zotero_bibl$instrText %||%
      "ADDIN ZOTERO_BIBL {\"uncited\":[],\"omitted\":[],\"custom\":[]} CSL_BIBLIOGRAPHY"
    bibl_display <- zotero_bibl$display %||% "[Bibliography]"
    bibl_xml <- build_field_code_xml(instrText = bibl_instr, display = bibl_display)

    result <- replace_bibl_marker(xml_content, bibl_xml)
    xml_content <- result$content
    n_bibl <- result$replaced

    if (n_bibl == 0L) {
      warning("[inject_zotero_citations] Could not find proper structure for DOCSTYLE_CITE_BIBL marker")
    } else if (verbose) {
      message("[inject_zotero_citations] Injected bibliography field code")
    }
  }

  # Write modified XML
  writeLines(xml_content, doc_xml_path)

  # Re-zip the DOCX
  output_path_abs <- normalizePath(output_path, mustWork = FALSE)
  output_dir <- dirname(output_path_abs)
  if (!dir.exists(output_dir) && output_dir != ".") {
    dir.create(output_dir, recursive = TRUE)
  }

  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp_dir)

  all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
  if (file.exists(output_path_abs)) file.remove(output_path_abs)

  result <- utils::zip(output_path_abs, files = all_files, flags = "-r9Xq")
  if (result != 0) stop("Failed to create zip file: ", output_path_abs)

  setwd(old_wd)

  if (verbose || n_injected > 0 || n_bibl > 0) {
    message("[inject_zotero_citations] Injected ", n_injected,
            " citation(s), ", n_bibl, " bibliography, ",
            n_fallback, " fallback(s) into: ", basename(output_path))
  }

  invisible(list(
    n_injected = n_injected,
    n_bibl = n_bibl,
    n_fallback = n_fallback
  ))
}


#' Sanitize instrText: clean RTF artifacts from formattedCitation
#'
#' When Zotero embeds RTF control words in formattedCitation, replace it
#' with plainCitation to prevent display artefacts in Word.
#'
#' @param instr_text The full instrText string
#'   (e.g. `ADDIN ZOTERO_ITEM CSL_CITATION {json}`).
#' @return Cleaned instrText
#' @keywords internal
sanitize_instr_text_r <- function(instr_text) {
  if (is.null(instr_text)) return(instr_text)

  json_start <- regexpr("\\{", instr_text)
  if (json_start == -1) return(instr_text)

  prefix <- substr(instr_text, 1, json_start - 1)
  json_str <- substr(instr_text, json_start, nchar(instr_text))

  parsed <- tryCatch(
    jsonlite::fromJSON(json_str, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(parsed)) return(instr_text)

  formatted <- parsed$properties$formattedCitation
  if (!is.null(formatted) && grepl("\\\\[a-z]+\\{", formatted)) {
    plain <- parsed$properties$plainCitation
    if (!is.null(plain) && nchar(plain) > 0) {
      parsed$properties$formattedCitation <- plain
      new_json <- jsonlite::toJSON(parsed, auto_unbox = TRUE)
      return(paste0(prefix, new_json))
    }
  }

  instr_text
}


#' Build synthetic instrText for one or more citations
#'
#' Creates a Zotero CSL_CITATION instrText from citation catalog entries
#' when no matching citationGroup exists (e.g., new citations added in QMD).
#' Works for both single and grouped citations.
#'
#' @param citekeys Character vector of citation keys (length 1 for single).
#' @param citations The citations catalog from field-codes.json.
#' @return instrText string.
#' @keywords internal
build_citation_instr <- function(citekeys, citations) {
  citation_id <- paste0(sample(c(letters, LETTERS, 0:9), 8, replace = TRUE),
                        collapse = "")

  items_json <- vapply(citekeys, function(ck) {
    cite <- citations[[ck]]
    item <- cite$itemData %||% list()
    uri <- if (length(cite$uris) > 0) cite$uris[[1]] else ""
    item_json <- jsonlite::toJSON(item, auto_unbox = TRUE)
    sprintf(
      '{"id":%s,"uris":["%s"],"itemData":%s}',
      jsonlite::toJSON(item$id %||% 0, auto_unbox = TRUE),
      uri,
      item_json
    )
  }, character(1))

  instr_json <- sprintf(
    '{"citationID":"%s","properties":{"formattedCitation":"(REF)","plainCitation":"(REF)","noteIndex":0},"citationItems":[%s],"schema":"https://github.com/citation-style-language/schema/raw/master/csl-citation.json"}',
    citation_id,
    paste(items_json, collapse = ",")
  )

  paste0("ADDIN ZOTERO_ITEM CSL_CITATION ", instr_json)
}


#' Scan rendered DOCX for unresolved citation markers
#'
#' After rendering and injection, any `[@citekey]` text remaining in
#' `document.xml` represents citations that could not be resolved to
#' Zotero field codes. This function extracts those citekeys.
#'
#' Two paths produce unresolved citations:
#' 1. Citekeys unknown to the Lua filter (not in `field-codes.json` at
#'    filter time) -- Pandoc renders them as literal `[@citekey]` text
#' 2. Citekeys known to Lua but missing from `field-codes.json` citations
#'    at R finisher time -- replaced with `[@citekey]` fallback text
#'
#' @param docx_path Path to the rendered .docx file
#' @return Character vector of unresolved citekeys (empty if all resolved)
#' @keywords internal
#' @export
scan_unresolved_citations <- function(docx_path) {
  if (!file.exists(docx_path)) return(character())

  # Read document.xml from the zip
  doc_xml <- tryCatch({
    con <- unz(docx_path, "word/document.xml")
    on.exit(close(con), add = TRUE)
    paste(readLines(con, warn = FALSE), collapse = "\n")
  }, error = function(e) return(character()))

  if (length(doc_xml) == 0 || !nzchar(doc_xml)) return(character())

  # Remove <w:instrText>...</w:instrText> elements entirely before extracting text.

  # These contain Zotero field code JSON metadata with "id" fields that look like
  # citekeys (e.g., "id":"Tricco_AIM_2018]"). We don't want to match these.
  doc_xml <- gsub("(?s)<w:instrText[^>]*>.*?</w:instrText>", "", doc_xml, perl = TRUE)

  # Strip remaining XML tags to get visible text content
  text_content <- gsub("<[^>]+>", "", doc_xml)

  # Find [@citekey] patterns (single or grouped)
  # Matches: [@key], [@key1; @key2], [@key1; @key2; @key3]
  pattern <- "\\[@([A-Za-z0-9._:-]+(?:;\\s*@[A-Za-z0-9._:-]+)*)\\]"
  matches <- gregexpr(pattern, text_content, perl = TRUE)
  matched_text <- regmatches(text_content, matches)[[1]]

  if (length(matched_text) == 0) return(character())

  # Extract individual citekeys from matches
  keys <- unlist(lapply(matched_text, function(m) {
    # Remove outer [@ ... ]
    inner <- sub("^\\[@", "", sub("\\]$", "", m))
    # Split on ; @
    parts <- strsplit(inner, ";\\s*@")[[1]]
    trimws(parts)
  }))

  unique(keys)
}
