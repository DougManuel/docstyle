#' Annotation Classification and Detection
#'
#' Functions for classifying expected vs unexpected annotation loss during
#' document harvesting, and detecting ad-hoc lists that could use CSS classes.
#'
#' @name validate_annotations
#' @keywords internal
NULL


#' Classify missing annotations as expected or unexpected loss
#'
#' Runs missing annotation IDs through a registry of expected loss patterns in
#' the source XML. Used for both revision and comment loss classification.
#'
#' @param missing_ids Character vector of IDs missing from QMD
#' @param doc_xml Parsed document.xml
#' @param ns XML namespace
#' @param registry Named list of pattern functions, each taking (doc_xml, ns)
#'   and returning a character vector of IDs expected to be missing
#' @return List with expected, unexpected, by_pattern
#' @noRd
classify_loss <- function(missing_ids, doc_xml, ns, registry) {
  result <- list(
    expected = character(),
    unexpected = missing_ids,
    by_pattern = list()
  )

  for (pattern_name in names(registry)) {
    pattern_fn <- registry[[pattern_name]]
    expected_ids <- pattern_fn(doc_xml, ns)

    matched <- intersect(result$unexpected, expected_ids)
    if (length(matched) > 0) {
      result$expected <- c(result$expected, matched)
      result$unexpected <- setdiff(result$unexpected, matched)
      result$by_pattern[[pattern_name]] <- matched
    }
  }

  result
}

#' Find annotations (revisions or comments) inside _docstyle_* bookmark ranges
#'
#' Walks body children and collects IDs of tracked changes or comment markers
#' that fall within generated content bookmarks. These annotations are expected
#' to be lost during harvest because the bookmark range is replaced by a div
#' placeholder.
#'
#' @param doc_xml Parsed document.xml
#' @param ns XML namespace
#' @param type Either "revisions" or "comments"
#' @return Character vector of annotation IDs (without prefix)
#' @noRd
find_annotations_in_bookmarks <- function(doc_xml, ns, type = c("revisions", "comments")) {
  type <- match.arg(type)
  body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
  if (inherits(body, "xml_missing")) return(character())

  children <- xml2::xml_children(body)
  ranges <- detect_docstyle_bookmarks(body, children, ns)
  collect_annotations_in_ranges(children, ranges, ns, type)
}


#' Find annotations (revisions or comments) inside ADDIN DOCSTYLE field code ranges
#'
#' Scans w:body children for block-spanning ADDIN DOCSTYLE field codes and
#' collects IDs of tracked changes or comment markers within those ranges.
#' These annotations are expected to be lost during harvest because field code
#' ranges are replaced by div placeholders.
#'
#' Uses an independent field code scanner (not reusing detect_docstyle_field_codes()
#' from docx_to_qmd.R) so that validation uses a separate code path from extraction.
#'
#' @param doc_xml Parsed document.xml
#' @param ns XML namespace
#' @param type Either "revisions" or "comments"
#' @return Character vector of annotation IDs (without rev_ prefix for revisions)
#' @noRd
find_annotations_in_field_codes <- function(doc_xml, ns, type = c("revisions", "comments")) {
  type <- match.arg(type)
  body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
  if (inherits(body, "xml_missing")) return(character())

  children <- xml2::xml_children(body)
  n <- length(children)
  if (n == 0) return(character())

  # Scan for ADDIN DOCSTYLE field code ranges at body level
  ranges <- list()
  in_field <- FALSE
  start_idx <- NA_integer_

  for (i in seq_len(n)) {
    child <- children[[i]]

    if (!in_field) {
      # Look for fldChar begin with ADDIN DOCSTYLE instrText in the same paragraph
      has_begin <- length(xml2::xml_find_all(
        child, ".//w:fldChar[@w:fldCharType='begin']", ns)) > 0
      if (has_begin) {
        instr_text <- paste(xml2::xml_text(
          xml2::xml_find_all(child, ".//w:instrText", ns)), collapse = "")
        if (grepl("ADDIN\\s+DOCSTYLE", instr_text)) {
          start_idx <- i
          in_field <- TRUE
        }
      }
    } else {
      # Look for fldChar end
      has_end <- length(xml2::xml_find_all(
        child, ".//w:fldChar[@w:fldCharType='end']", ns)) > 0
      if (has_end) {
        ranges <- c(ranges, list(list(start_idx = start_idx, end_idx = i)))
        in_field <- FALSE
      }
    }
  }

  collect_annotations_in_ranges(children, ranges, ns, type)
}


#' Collect annotation IDs from XML children within index ranges
#'
#' Shared helper for find_annotations_in_bookmarks and
#' find_annotations_in_field_codes. Searches for revision or comment
#' markers within the specified body-child index ranges.
#'
#' @param children XML node list of w:body children
#' @param ranges List of lists, each with start_idx and end_idx
#' @param ns XML namespace
#' @param type "revisions" or "comments"
#' @return Character vector of unique annotation IDs
#' @noRd
collect_annotations_in_ranges <- function(children, ranges, ns, type) {
  if (length(ranges) == 0) return(character())

  ids <- character()
  for (rng in ranges) {
    range_children <- children[rng$start_idx:rng$end_idx]

    if (type == "revisions") {
      for (child in range_children) {
        found <- xml2::xml_find_all(child, ".//w:ins|.//w:del", ns)
        rev_ids <- xml2::xml_attr(found, "id")
        ids <- c(ids, rev_ids[!is.na(rev_ids) & rev_ids != ""])
      }
    } else {
      for (child in range_children) {
        markers <- xml2::xml_find_all(child, ".//w:commentRangeStart", ns)
        cids <- xml2::xml_attr(markers, "id")
        ids <- c(ids, cids[!is.na(cids) & cids != ""])
      }
    }
  }

  unique(ids)
}


#' Detect ad-hoc lists that could use CSS list classes
#'
#' Scans the DOCX for list paragraphs with non-standard numbering formats
#' (lowerLetter, lowerRoman) that are NOT inside ADDIN DOCSTYLE field code
#' ranges. These are lists that a collaborator created manually in Word
#' rather than using CSS classes in QMD.
#'
#' Reports suggestions via vh_info() (informational only, does not affect
#' validation result). Returns a data frame for programmatic access via
#' result$details$adhoc_lists.
#'
#' @param docx_path Path to .docx file
#' @param doc_xml Parsed document.xml
#' @param ns XML namespace
#' @param verbose Logical; print informational messages
#' @return Data frame with columns: num_id, num_fmt, suggested_class, count.
#'   Zero-row data frame if no suggestions.
#' @noRd
detect_adhoc_lists <- function(docx_path, doc_xml, ns, verbose) {
  empty_result <- data.frame(
    num_id = character(), num_fmt = character(),
    suggested_class = character(), count = integer(),
    stringsAsFactors = FALSE
  )

  # Build numbering lookup (reuse utility from list_processing.R)
  numbering_lookup <- build_numbering_lookup(docx_path)
  if (length(numbering_lookup) == 0) return(empty_result)

  body <- xml2::xml_find_first(doc_xml, "//w:body", ns)
  if (inherits(body, "xml_missing")) return(empty_result)

  children <- xml2::xml_children(body)
  n <- length(children)
  if (n == 0) return(empty_result)

  # Find ADDIN DOCSTYLE field code ranges (independent scanner)
  fc_ranges <- list()
  in_field <- FALSE
  start_idx <- NA_integer_
  for (i in seq_len(n)) {
    child <- children[[i]]
    if (!in_field) {
      has_begin <- length(xml2::xml_find_all(
        child, ".//w:fldChar[@w:fldCharType='begin']", ns)) > 0
      if (has_begin) {
        instr_text <- paste(xml2::xml_text(
          xml2::xml_find_all(child, ".//w:instrText", ns)), collapse = "")
        if (grepl("ADDIN\\s+DOCSTYLE", instr_text)) {
          start_idx <- i
          in_field <- TRUE
        }
      }
    } else {
      has_end <- length(xml2::xml_find_all(
        child, ".//w:fldChar[@w:fldCharType='end']", ns)) > 0
      if (has_end) {
        fc_ranges <- c(fc_ranges, list(c(start_idx, i)))
        in_field <- FALSE
      }
    }
  }

  # Helper: is index inside any field code range?
  in_fc_range <- function(idx) {
    for (rng in fc_ranges) {
      if (idx >= rng[1] && idx <= rng[2]) return(TRUE)
    }
    FALSE
  }

  # CSS class mapping for suggestable formats
  fmt_to_class <- c(
    lowerLetter = ".list-alpha",
    lowerRoman = ".list-roman"
  )

  # Scan paragraphs for ad-hoc styled lists
  hits <- list()  # list of num_id values with their fmt
  for (i in seq_len(n)) {
    if (length(fc_ranges) > 0 && in_fc_range(i)) next

    child <- children[[i]]
    if (xml2::xml_name(child) != "p") next

    num_id_node <- xml2::xml_find_first(child, ".//w:numPr/w:numId/@w:val", ns)
    if (inherits(num_id_node, "xml_missing")) next
    num_id <- xml2::xml_text(num_id_node)
    if (is.na(num_id) || num_id == "") next

    num_fmt <- lookup_num_fmt(numbering_lookup, num_id, "0")
    if (is.na(num_fmt)) next
    if (!(num_fmt %in% names(fmt_to_class))) next

    key <- num_id
    if (is.null(hits[[key]])) {
      hits[[key]] <- list(num_id = num_id, num_fmt = num_fmt, count = 1L)
    } else {
      hits[[key]]$count <- hits[[key]]$count + 1L
    }
  }

  if (length(hits) == 0) return(empty_result)

  # Build result data frame
  result_df <- do.call(rbind, lapply(hits, function(h) {
    data.frame(
      num_id = h$num_id,
      num_fmt = h$num_fmt,
      suggested_class = fmt_to_class[[h$num_fmt]],
      count = h$count,
      stringsAsFactors = FALSE
    )
  }))
  rownames(result_df) <- NULL

  # Report informational hints
  for (i in seq_len(nrow(result_df))) {
    row <- result_df[i, ]
    vh_info(verbose, sprintf(
      "Ad-hoc %s list (%d paragraphs) could use ::: {%s} wrapper",
      row$num_fmt, row$count, row$suggested_class
    ))
  }

  result_df
}
