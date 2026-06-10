#' Relocate the abstract to its placeholder position (#149)
#'
#' Pandoc's docx writer hoists the YAML `abstract:` to the top of the
#' document as `AbstractTitle` + `Abstract`-styled paragraphs, before any
#' body content. When the author opts in with a `:::docstyle-abstract:::`
#' placeholder, `abstract.lua` plants a `DOCSTYLE_ABSTRACT` marker at that
#' body position, wrapped in a three-paragraph `ADDIN DOCSTYLE` field code
#' (field-start | marker | field-end). This finisher MOVES the hoisted
#' abstract paragraphs to sit INSIDE that field code — between the
#' field-start and field-end paragraphs — and removes ONLY the
#' `DOCSTYLE_ABSTRACT` marker paragraph (it would otherwise render as visible
#' "DOCSTYLE_ABSTRACT" text in Word, and it is redundant once the abstract is
#' in place).
#'
#' Preserve the wrapper, don't delete it: harvest (`docx_to_qmd`) re-detects
#' the abstract by finding the `ADDIN DOCSTYLE {type:div,name:abstract}` field
#' code that WRAPS it (`detect_docstyle_field_codes` in
#' `R/generated_content.R` opens a range on `fldChar begin` and closes it on
#' `fldChar end`, treating everything between as the range content). If we
#' deleted the wrapper, a re-harvested docx would see plain `Abstract`-styled
#' prose, not a `:::docstyle-abstract:::` placeholder — the round-trip would
#' break. Keeping the field-start/field-end paragraphs and moving the abstract
#' between them makes the field code the detection anchor on re-harvest.
#'
#' Move, don't rebuild: relocating Pandoc's already-styled paragraphs
#' preserves the CSS-driven `Abstract`/`AbstractTitle` styling and any
#' multi-paragraph structure intact.
#'
#' @param body The `<w:body>` xml2 node.
#' @param ns Namespace map (`w = ...`).
#' @param verbose Logical; print a diagnostic.
#' @return Integer count of relocations performed (0 or 1).
#' @noRd
relocate_abstract <- function(body, ns, verbose = FALSE) {
  paras <- xml2::xml_find_all(body, "./w:p", ns)
  if (length(paras) == 0L) return(0L)

  # Find the marker paragraph (a w:p whose text is exactly DOCSTYLE_ABSTRACT).
  marker_idx <- NA_integer_
  for (i in seq_along(paras)) {
    txt <- xml2::xml_text(paras[[i]])
    if (identical(trimws(txt), "DOCSTYLE_ABSTRACT")) { marker_idx <- i; break }
  }
  if (is.na(marker_idx)) return(0L)  # no opt-in; leave document untouched

  marker <- paras[[marker_idx]]

  # abstract.lua wraps the marker in a 3-paragraph ADDIN DOCSTYLE field code
  # (field-start | marker | field-end) via field-code-utils.lua. Detect the
  # wrapper so we can drop the abstract INSIDE it (between field-start and
  # field-end) and remove ONLY the marker, KEEPING the field-start/field-end
  # paragraphs as the harvest detection anchor. The field code is what
  # docx_to_qmd uses to round-trip the abstract back to a
  # :::docstyle-abstract::: placeholder; deleting it would re-harvest as bare
  # prose. See R/anchor_assembly.R (~990) for the matching multi-paragraph idiom.
  field_start <- NULL
  field_end   <- NULL
  if (marker_idx > 1L) {
    cand <- paras[[marker_idx - 1L]]
    if (length(xml2::xml_find_all(cand, ".//w:fldChar[@w:fldCharType='begin']", ns))) {
      field_start <- cand
    }
  }
  if (marker_idx < length(paras)) {
    cand <- paras[[marker_idx + 1L]]
    if (length(xml2::xml_find_all(cand, ".//w:fldChar[@w:fldCharType='end']", ns))) {
      field_end <- cand
    }
  }
  # Treat the wrapper as present only when BOTH halves are found; a lone half
  # is not a field code we recognise, so fall back to the bare-marker path.
  has_wrapper <- !is.null(field_start) && !is.null(field_end)

  # Insert anchor: the `.where = "before"` target — each abstract node is
  # inserted just before this. With a wrapper present, target the FIELD-END
  # paragraph so the abstract lands BETWEEN field-start and field-end (inside
  # the field code, where harvest expects the range content). Without a
  # wrapper (bare-marker fallback), target the marker itself.
  insert_anchor <- if (has_wrapper) field_end else marker

  # Find the contiguous abstract block: an AbstractTitle paragraph followed
  # by one or more contiguous Abstract paragraphs (the hoisted block).
  abstract_nodes <- find_abstract_block(paras, ns)

  if (length(abstract_nodes) == 0L) {
    # Marker present but no abstract content (author opted in with
    # :::docstyle-abstract::: but has no abstract yet). Remove ONLY the visible
    # DOCSTYLE_ABSTRACT marker. When a wrapper is present, KEEP it: an empty
    # field code round-trips to an empty placeholder, which is correct — the
    # author's opt-in survives re-harvest. No abstract was relocated, so 0L.
    if (verbose) {
      message("[finalize] abstract placeholder present but no abstract ",
              "content found")
    }
    xml2::xml_remove(marker)
    return(0L)
  }

  # Capture every node reference we need BEFORE mutating: xml2 sibling
  # indices and xml_find_all results shift as nodes are inserted/removed,
  # so resolve abstract_nodes / insert_anchor / wrapper paragraphs first.
  #
  # Then: (1) move each abstract node to just before the insert anchor (in
  # order) — with a wrapper, insert_anchor is the field-end paragraph, so the
  # abstract lands between field-start and field-end (inside the field code);
  # (2) remove ONLY the marker, KEEPING the field-start/field-end wrapper so
  # the field code remains as the harvest detection anchor. In this xml2
  # version (1.5.2) `xml_add_sibling` COPIES an in-tree node rather than moving
  # it (verified empirically: a single add_sibling turns 5 paragraphs into 6,
  # leaving the source in place), so we explicitly remove each original after
  # inserting its copy to complete the move and avoid a duplicated abstract at
  # the top. (Note: the comment at R/anchor_assembly.R:797 describes this as a
  # MOVE; the empirical copy-then-remove behaviour verified here is why this
  # file removes originals explicitly.)
  for (node in abstract_nodes) {
    xml2::xml_add_sibling(insert_anchor, node, .where = "before")
    xml2::xml_remove(node)
  }
  # Remove only the marker. The field-start/field-end paragraphs stay put,
  # now wrapping the relocated abstract. (Bare-marker fallback: no wrapper to
  # keep, so this just removes the marker the abstract was inserted before.)
  xml2::xml_remove(marker)

  if (verbose) {
    message("[finalize] Relocated abstract (", length(abstract_nodes),
            " paragraph(s)) to placeholder position")
  }
  1L
}

#' Find the hoisted abstract paragraph block
#'
#' Returns the `AbstractTitle` paragraph (if present) plus all immediately
#' following contiguous `Abstract`-styled paragraphs, as a list of xml2
#' nodes. An `AbstractTitle` with no following `Abstract` paragraphs yields a
#' title-only block. Returns an empty list if neither an `AbstractTitle` nor
#' an `Abstract` paragraph exists.
#' @noRd
find_abstract_block <- function(paras, ns) {
  para_style <- function(p) {
    s <- xml2::xml_text(xml2::xml_find_first(p, "./w:pPr/w:pStyle/@w:val", ns))
    if (is.na(s)) "" else s
  }
  styles <- vapply(paras, para_style, character(1))

  # Locate the first Abstract or AbstractTitle paragraph.
  start <- which(styles %in% c("AbstractTitle", "Abstract"))
  if (length(start) == 0L) return(list())
  start <- start[[1]]

  # Collect AbstractTitle (if at start) + contiguous Abstract paragraphs.
  block <- list()
  i <- start
  if (styles[i] == "AbstractTitle") {
    block[[length(block) + 1L]] <- paras[[i]]
    i <- i + 1L
  }
  while (i <= length(styles) && styles[i] == "Abstract") {
    block[[length(block) + 1L]] <- paras[[i]]
    i <- i + 1L
  }
  block
}
