#' Finalize DOCX Section Structure
#'
#' Post-processes a rendered DOCX to fix section breaks, line numbering,
#' page layout, and per-section headers/footers based on DOCSTYLE markers.
#' This runs after Pandoc renders the document and corrects structural issues
#' that Pandoc's docx writer introduces.
#'
#' The actual work is delegated to four focused modules:
#' - `section_assembly.R`: v2 marker-based assembly engine
#' - `section_headers.R`: per-section header/footer injection
#' - `section_legacy.R`: v1 field-code-based section fixing
#' - `section_cleanup.R`: document invariant enforcement
#'
#' @param docx_path Path to rendered DOCX
#' @param output_path Path for finalized DOCX (default: overwrite input)
#' @param sidecar_path Path to _docstyle/ directory for sidecar files.
#'   Defaults to searching from the DOCX directory upward (same search as
#'   load_page_config). Pass explicitly when the caller already knows the
#'   project root (e.g. from update-field-codes.R).
#' @param verbose Print diagnostic messages
#' @return Invisibly returns a list with summary info
#' @export
finalize_docx <- function(docx_path, output_path = docx_path,
                          sidecar_path = NULL,
                          verbose = FALSE) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Unzip DOCX to temp directory
  temp_dir <- tempfile("docstyle_finalize_")
  dir.create(temp_dir)
  utils::unzip(docx_path, exdir = temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    stop("Invalid DOCX structure: word/document.xml not found")
  }

  # Read document.xml with xml2 for DOM manipulation
  xml <- xml2::read_xml(doc_xml_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  body <- xml2::xml_find_first(xml, "//w:body", ns = ns)
  if (inherits(body, "xml_missing")) {
    if (verbose) message("[finalize] No w:body found, skipping")
    return(invisible(list(markers = 0L, fixed = 0L)))
  }

  # === R-FIRST ASSEMBLY (v2) ===
  # Assemble sections from text markers BEFORE processing field codes.
  # This handles v2 documents where Lua emits DOCSTYLE_SECTION:: text markers
  # instead of complex sectPr XML.
  page_config <- load_page_config(dirname(docx_path))
  assembly_result <- assemble_section_breaks(body, ns, page_config, verbose = verbose)
  n_assembled <- assembly_result$n_assembled

  # Suppress top spacing on first paragraph after section breaks.
  # Must run after assembly (section boundaries established, markers removed)
  # but before payload shift (which reindexes payloads for footer/header use).
  n_top_suppressed <- suppress_first_paragraph_spacing(
    body, ns, page_config, assembly_result$section_sequence, verbose = verbose
  )

  # === ANCHOR ASSEMBLY ===
  # Assemble anchored content from DOCSTYLE_ANCHOR:: text markers.
  # Must run after section assembly (markers may be near section boundaries).
  anchor_result <- assemble_anchors(body, ns, page_config, verbose = verbose)
  if (verbose && anchor_result$n_assembled > 0) {
    message("[finalize] Assembled ", anchor_result$n_assembled, " anchor(s)")
  }

  # === ABSTRACT RELOCATION (#149) ===
  # Move Pandoc's hoisted AbstractTitle+Abstract paragraphs to the
  # DOCSTYLE_ABSTRACT marker (if the author opted in via :::docstyle-abstract:::).
  # Runs after anchor assembly, before body sectPr / header-footer / pruning
  # steps, so the abstract paragraphs are in their final position before any
  # section/style finalisation touches the body.
  n_abstract <- relocate_abstract(body, ns, verbose = verbose)

  # Find DOCSTYLE section markers (field-code based, for v1 compatibility)
  markers <- find_section_markers(body, ns)

  if (verbose) {
    message("[finalize] Found ", length(markers), " section marker(s)")
  }

  # Fix section breaks based on markers
  n_fixed <- 0L
  n_page_starts <- 0L
  if (length(markers) > 0) {
    n_fixed <- fix_section_breaks(markers, body, ns, verbose = verbose)
    n_page_starts <- apply_page_start(markers, body, ns, verbose = verbose)
  }

  # Fix body-level sectPr (remove leaked line numbers and header/footer refs)
  body_fixed <- fix_body_sectPr(body, ns, markers, verbose = verbose)

  # Shift footer/header payloads in section_sequence to match Word's
  # backward-looking section model. Each marker's preceding sectPr ends the
  # PREVIOUS section, not the marker's own section. So marker N's footer
  # should be applied to the NEXT sectPr in document order (the one that
  # ends marker N's section). We shift field_code_payload forward by one
  # position, with the first sectPr getting YAML defaults.
  seq <- assembly_result$section_sequence
  if (length(seq) > 1) {
    original_payloads <- lapply(seq, function(s) s$field_code_payload)
    # First sectPr gets YAML defaults (no field code overrides)
    seq[[1]]$field_code_payload <- list()
    # Each subsequent sectPr gets the PREVIOUS marker's payload
    for (i in 2:length(seq)) {
      seq[[i]]$field_code_payload <- original_payloads[[i - 1]]
    }
    # The last marker's payload goes to the body sectPr, which is handled
    # by inject_section_headers_footers's body sectPr logic. Store it
    # as a final entry with NULL sectpr_para.
    last_payload <- original_payloads[[length(original_payloads)]]
    seq <- c(seq, list(list(
      section_class = "final-cascade",
      sectpr_para = NULL,
      is_closing = TRUE,
      field_code_payload = last_payload
    )))
    assembly_result$section_sequence <- seq
  }

  # === INVARIANT ENFORCEMENT ===
  # These functions enforce global document invariants rather than
  # targeting specific symptom patterns.
  # Run ALL DOM mutations before writing the section map and injecting
  # headers/footers, so paragraph positions are stable at write time and
  # node pointers in section_sequence remain valid at injection time.

  # Invariant 1: No consecutive page breaks without intervening content
  n_deduped <- deduplicate_page_breaks(body, ns, verbose = verbose)

  # Invariant 2: Structural paragraphs (no text) never display line numbers
  n_structural <- suppress_structural_paragraphs(body, ns, verbose = verbose)

  # Remove trailing closing sectPr that creates empty final section
  # Guard: intentional closing section breaks (from wrapping divs) are preserved
  trailing_removed <- remove_trailing_sectPr(body, ns,
    closing_sectpr_paras = assembly_result$closing_sectpr_paras,
    verbose = verbose)

  # Clean up orphaned empty paragraphs
  n_cleaned <- clean_orphaned_paragraphs(body, ns, verbose = verbose)

  # === Paragraph positions are now stable — write structural metadata sidecar ===
  # All paragraph-level DOM mutations are complete. section-map.json records
  # paragraph positions and section state at this point so indices are correct
  # for the final document. Note: footer/header XML references are still
  # injected after this point (inject_section_headers_footers), so node
  # pointers in assembly_result$section_sequence remain in use.
  # The sidecar persists this information for debugging and future cold-read
  # injection passes; the current session continues to use in-memory node pointers.
  seq_for_map <- assembly_result$section_sequence
  body_section_for_map <- list(
    line_numbers       = if (length(seq_for_map) > 0)
      seq_for_map[[length(seq_for_map)]]$line_numbers %||% "none"
    else
      "none",
    field_code_payload = if (length(seq_for_map) > 0)
      seq_for_map[[length(seq_for_map)]]$field_code_payload
    else
      list()
  )
  # Resolve _docstyle/ directory. If caller passed sidecar_path explicitly
  # (e.g. from update-field-codes.R which knows the project root), use it.
  # Otherwise try three candidates in order: DOCX dir/_docstyle, parent dir/_docstyle,
  # getwd()/_docstyle. First existing directory wins; if none exist, use the first.
  if (is.null(sidecar_path)) {
    sidecar_search <- unique(c(
      file.path(dirname(docx_path), "_docstyle"),
      file.path(dirname(dirname(docx_path)), "_docstyle"),
      file.path(getwd(), "_docstyle")
    ))
    existing <- Filter(dir.exists, sidecar_search)
    sidecar_path <- if (length(existing) > 0) existing[[1]] else sidecar_search[[1]]
  }

  map_written <- write_section_map(
    section_sequence = seq_for_map,
    body_section     = body_section_for_map,
    body             = body,
    sidecar_path     = sidecar_path
  )
  if (length(seq_for_map) > 0 && is.null(map_written)) {
    message("[finalize] section-map.json could not be written to: ", sidecar_path)
  }

  # Inject per-section headers and footers (after all DOM mutations are complete,
  # so node pointers in section_sequence remain valid)
  n_hf_injected <- inject_section_headers_footers(body, ns, temp_dir, page_config,
    assembly_result, verbose = verbose)

  # Write modified XML
  xml2::write_xml(xml, doc_xml_path)

  # Remove redundant namespace declarations that xml2 adds to sectPr elements
  n_ns_removed <- strip_redundant_sectpr_namespaces(doc_xml_path, verbose = verbose)

  # Ensure field codes (PAGE, NUMPAGES, etc.) update when document is opened
  enable_field_updates(temp_dir, verbose = verbose)

  # Remove orphaned footer/header files left by the pre-render phase
  n_orphaned <- cleanup_orphaned_hf_files(doc_xml_path, temp_dir, verbose = verbose)

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
  if (file.exists(output_path_abs)) {
    file.remove(output_path_abs)
  }

  result <- utils::zip(output_path_abs, files = all_files, flags = "-r9Xq")
  if (result != 0) {
    stop("Failed to create zip file: ", output_path_abs)
  }

  setwd(old_wd)

  if (verbose) {
    message("[finalize] Done: ",
            if (n_assembled > 0) paste0(n_assembled, " section(s) assembled, ") else "",
            n_fixed, " section(s) fixed, ",
            if (body_fixed) "body sectPr cleaned" else "body sectPr OK",
            if (n_hf_injected > 0) paste0(", ", n_hf_injected, " section(s) with headers/footers") else "",
            ", ", n_deduped, " redundant page break(s) removed",
            ", ", n_structural, " structural paragraph(s) line-suppressed",
            if (n_top_suppressed > 0) paste0(", ", n_top_suppressed, " top spacing suppressed") else "",
            if (trailing_removed) ", trailing sectPr removed" else "",
            ", ", n_cleaned, " orphaned para(s) removed",
            if (n_abstract > 0) paste0(", abstract relocated") else "")
  }

  invisible(list(
    assembled = n_assembled,
    markers = length(markers),
    fixed = n_fixed,
    body_fixed = body_fixed,
    hf_injected = n_hf_injected,
    breaks_deduped = n_deduped,
    structural_suppressed = n_structural,
    top_spacing_suppressed = n_top_suppressed,
    trailing_removed = trailing_removed,
    cleaned = n_cleaned,
    abstract_relocated = n_abstract,
    section_map_written = !is.null(map_written)
  ))
}
