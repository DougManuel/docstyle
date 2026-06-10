# =============================================================================
# ANCHOR ASSEMBLY (post-render)
# =============================================================================
#
# Scans rendered Word XML for DOCSTYLE_ANCHOR:: text markers emitted by the
# anchor Lua filter. Each marker pair (opening + closing) delineates
# content that should be positioned as floating/anchored content. The assembly
# dispatches to different OOXML mechanisms based on content type:
#   - Tables:      floating table with w:tblpPr on the existing w:tbl
#   - Images:      DrawingML wp:anchor wrapping pic:pic
#   - Text/mixed:  invisible single-cell floating table (default) or
#                  DrawingML text box via wps:txbx (content-mode: textbox)
#
# The Lua filter emits:
#   Opening: DOCSTYLE_ANCHOR::{class}::{adjacent}  (in ADDIN DOCSTYLE field code)
#   Closing: DOCSTYLE_ANCHOR_END::{class}
#
# For backward compatibility, legacy DOCSTYLE_FLOAT:: markers are also accepted.
#
# This module:
# 1. Finds opening markers by scanning w:t text nodes
# 2. Extracts JSON payload from the field code's w:instrText
# 3. Finds matching closing marker
# 4. Detects content type, builds appropriate OOXML structure
# 5. Moves content into the assembled structure
# 6. Inserts structure, removes marker paragraphs
# 7. Relocates to adjacent bookmark if specified
# 8. Processes ranges in reverse order to preserve XML indices
# =============================================================================


#' Parse wrap distance shorthand
#'
#' Converts a 4-value shorthand string like "0 198dxa 0 198dxa" to a named
#' list of integer DXA values (top, right, bottom, left).
#'
#' @param distance_str Character string with 4 space-separated values.
#'   Values with "dxa" suffix are parsed as raw DXA. Other CSS units
#'   are converted via css_to_twips().
#' @return Named list with integer elements: top, right, bottom, left
#' @noRd
parse_wrap_distance <- function(distance_str) {
  if (is.null(distance_str) || !nzchar(distance_str)) {
    return(list(top = 0L, right = 198L, bottom = 0L, left = 198L))
  }

  parts <- strsplit(trimws(distance_str), "\\s+")[[1]]

  parse_one <- function(val) {
    if (grepl("dxa$", val)) {
      return(as.integer(sub("dxa$", "", val)))
    }
    css_to_twips(val)
  }

  # CSS shorthand expansion: 1->all, 2->TB/RL, 3->T/RL/B, 4->T/R/B/L
  if (length(parts) == 1) {
    v <- parse_one(parts[1])
    return(list(top = v, right = v, bottom = v, left = v))
  } else if (length(parts) == 2) {
    tb <- parse_one(parts[1])
    rl <- parse_one(parts[2])
    return(list(top = tb, right = rl, bottom = tb, left = rl))
  } else if (length(parts) == 3) {
    t <- parse_one(parts[1])
    rl <- parse_one(parts[2])
    b <- parse_one(parts[3])
    return(list(top = t, right = rl, bottom = b, left = rl))
  } else if (length(parts) != 4) {
    warning("[anchor-assembly] Expected 1-4 values in wrap_distance, got ",
            length(parts), ". Using defaults.")
    return(list(top = 0L, right = 198L, bottom = 0L, left = 198L))
  }

  list(
    top = parse_one(parts[1]),
    right = parse_one(parts[2]),
    bottom = parse_one(parts[3]),
    left = parse_one(parts[4])
  )
}


#' Map CSS anchor value to wp:positionH relativeFrom
#' @noRd
anchor_to_posH_relative <- function(css_value) {
  switch(css_value,
    "text"   = "column",
    "margin" = "margin",
    "page"   = "page",
    "margin"  # default
  )
}

#' Map CSS anchor value to wp:positionV relativeFrom
#' @noRd
anchor_to_posV_relative <- function(css_value) {
  switch(css_value,
    "text"    = "paragraph",
    "margin"  = "margin",
    "page"    = "page",
    "section" = "margin",
    "paragraph"  # default
  )
}

#' Map CSS wrap-side to OOXML wrapText value
#' @noRd
wrap_side_to_ooxml <- function(css_value) {
  switch(css_value %||% "both",
    "both"    = "bothSides",
    "left"    = "left",
    "right"   = "right",
    "largest" = "largest",
    "bothSides"  # default
  )
}

#' Build wp:anchor XML from wp:inline content
#'
#' Rewrites a `wp:inline` image in a paragraph to a positioned `wp:anchor`.
#' Preserves the original `a:graphic` subtree (blip reference, picture properties).
#'
#' @param para xml2 node of the paragraph containing `w:drawing/wp:inline`
#' @param payload Named list of positioning properties from field code
#' @param ns Named character vector of XML namespaces (must include wp, a, pic)
#' @param next_docpr_id Integer. Next available wp:docPr ID.
#' @return List with `success` (logical) and `docpr_id` (integer used)
#' @noRd
build_image_anchor <- function(para, payload, ns, next_docpr_id = 1L) {
  drawing <- xml2::xml_find_first(para, ".//w:drawing", ns = ns)
  if (inherits(drawing, "xml_missing")) {
    return(list(success = FALSE, reason = "no w:drawing element found in paragraph"))
  }

  inline <- xml2::xml_find_first(drawing, "wp:inline", ns = ns)
  if (inherits(inline, "xml_missing")) {
    return(list(success = FALSE, reason = "no wp:inline element found in drawing"))
  }

  # Extract original extent (xml_attr returns NA for missing attributes)
  orig_extent <- xml2::xml_find_first(inline, "wp:extent", ns = ns)
  orig_cx <- as.numeric(xml2::xml_attr(orig_extent, "cx"))
  orig_cy <- as.numeric(xml2::xml_attr(orig_extent, "cy"))
  if (is.na(orig_cx) || is.na(orig_cy)) {
    return(list(success = FALSE,
                reason = "missing cx/cy on wp:extent element"))
  }

  # Calculate new dimensions from float_width (preserve aspect ratio)
  new_cx <- orig_cx
  new_cy <- orig_cy
  if (!is.null(payload$float_width)) {
    new_cx <- css_to_emu(payload$float_width)
    if (orig_cx > 0) {
      new_cy <- as.integer(round(new_cx * (orig_cy / orig_cx)))
    }
    new_cx <- as.integer(new_cx)
  }

  # Extract the a:graphic subtree (preserves blip reference)
  graphic <- xml2::xml_find_first(inline, "a:graphic", ns = ns)
  if (inherits(graphic, "xml_missing")) {
    return(list(success = FALSE, reason = "no a:graphic element found in wp:inline"))
  }

  # Build positioning values
  vert_anchor <- payload$vertical_anchor %||% "text"
  horz_anchor <- payload$horizontal_anchor %||% "margin"
  pos_y_emu <- css_to_emu(payload$position_y %||% "0")
  pos_x_emu <- css_to_emu(payload$position_x %||% "0")
  behind_doc <- if (identical(payload$z_layer, "behind")) "1" else "0"

  # Parse wrap distances
  dist <- parse_wrap_distance(payload$wrap_distance)
  dist_t <- as.integer(dist$top * 635)    # DXA -> EMU
  dist_b <- as.integer(dist$bottom * 635)
  dist_l <- as.integer(dist$left * 635)
  dist_r <- as.integer(dist$right * 635)

  # Build wrap element
  wrap_style <- payload$wrap_style %||% "square"
  wrap_xml <- switch(wrap_style,
    "none" = '<wp:wrapNone/>',
    "square" = sprintf(
      '<wp:wrapSquare wrapText="%s" distT="%d" distB="%d" distL="%d" distR="%d"/>',
      wrap_side_to_ooxml(payload$wrap_side), dist_t, dist_b, dist_l, dist_r
    ),
    "top-and-bottom" = sprintf(
      '<wp:wrapTopAndBottom distT="%d" distB="%d"/>',
      dist_t, dist_b
    ),
    '<wp:wrapSquare wrapText="bothSides"/>'  # fallback
  )

  # Build the wp:anchor XML
  anchor_xml <- sprintf(paste0(
    '<wp:anchor xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"',
    ' distT="%d" distB="%d" distL="%d" distR="%d"',
    ' simplePos="0" relativeHeight="251658240" behindDoc="%s"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionV>',
    '<wp:extent cx="%d" cy="%d"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '%s',
    '<wp:docPr id="%d" name="Picture %d"/>',
    '<wp:cNvGraphicFramePr/>',
    '</wp:anchor>'
  ),
    dist_t, dist_b, dist_l, dist_r,
    behind_doc,
    anchor_to_posH_relative(horz_anchor), pos_x_emu,
    anchor_to_posV_relative(vert_anchor), pos_y_emu,
    new_cx, new_cy,
    wrap_xml,
    next_docpr_id, next_docpr_id
  )

  # Parse the anchor element
  anchor_doc <- tryCatch(
    xml2::read_xml(anchor_xml),
    error = function(e) {
      return(list(success = FALSE,
                  reason = paste0("failed to parse constructed anchor XML: ",
                                  conditionMessage(e))))
    }
  )
  if (is.list(anchor_doc) && !is.null(anchor_doc$success)) {
    return(anchor_doc)
  }

  # Copy the original a:graphic into the anchor (before closing tag)
  xml2::xml_add_child(anchor_doc, graphic)

  # Replace wp:inline with wp:anchor in the drawing element
  xml2::xml_replace(inline, anchor_doc)

  # Update internal pic:spPr extent to match new dimensions
  new_anchor <- xml2::xml_find_first(drawing, "wp:anchor", ns = ns)
  if (!inherits(new_anchor, "xml_missing")) {
    int_ext <- xml2::xml_find_first(new_anchor, ".//pic:spPr/a:xfrm/a:ext", ns = ns)
    if (!inherits(int_ext, "xml_missing")) {
      xml2::xml_set_attr(int_ext, "cx", as.character(new_cx))
      xml2::xml_set_attr(int_ext, "cy", as.character(new_cy))
    }
  }

  list(success = TRUE, docpr_id = next_docpr_id)
}


#' Build a DrawingML text box anchor
#'
#' Constructs a `wp:anchor` containing `wps:wsp` with `wps:txbx/w:txbxContent`.
#' Content paragraphs are serialised to XML and embedded in the text box body. Returns a new `w:p`
#' containing the `w:drawing` element.
#'
#' @param content_paras xml2 nodeset of `w:p` elements to place inside the text box
#' @param payload Named list of positioning properties from field code
#' @param ns Named character vector of XML namespaces (must include wp, a, wps)
#' @param next_docpr_id Integer. Next available wp:docPr ID.
#' @return List with `success` (logical), `para` (xml2 node of the wrapper w:p),
#'   and `docpr_id` (integer used)
#' @noRd
build_text_box_anchor <- function(content_paras, payload, ns, next_docpr_id = 1L) {
  if (length(content_paras) == 0) {
    return(list(success = FALSE, reason = "no content paragraphs provided"))
  }

  # Width from payload
  width_emu <- css_to_emu(payload$float_width %||% "3000dxa")
  # Height: generous default — Word auto-sizes text boxes
  height_emu <- 9144000L  # 10 inches

  # Positioning
  vert_anchor <- payload$vertical_anchor %||% "text"
  horz_anchor <- payload$horizontal_anchor %||% "margin"
  pos_y_emu <- css_to_emu(payload$position_y %||% "0")
  pos_x_emu <- css_to_emu(payload$position_x %||% "0")
  behind_doc <- if (identical(payload$z_layer, "behind")) "1" else "0"

  # Wrap distances
  dist <- parse_wrap_distance(payload$wrap_distance)
  dist_t <- as.integer(dist$top * 635)
  dist_b <- as.integer(dist$bottom * 635)
  dist_l <- as.integer(dist$left * 635)
  dist_r <- as.integer(dist$right * 635)

  # Wrap element
  wrap_style <- payload$wrap_style %||% "square"
  wrap_xml <- switch(wrap_style,
    "none" = '<wp:wrapNone/>',
    "square" = sprintf(
      '<wp:wrapSquare wrapText="%s" distT="%d" distB="%d" distL="%d" distR="%d"/>',
      wrap_side_to_ooxml(payload$wrap_side), dist_t, dist_b, dist_l, dist_r
    ),
    "top-and-bottom" = sprintf(
      '<wp:wrapTopAndBottom distT="%d" distB="%d"/>',
      dist_t, dist_b
    ),
    '<wp:wrapSquare wrapText="bothSides"/>'  # fallback
  )

  # Serialize content paragraphs to XML strings
  para_xml_parts <- vapply(content_paras, function(p) {
    as.character(p)
  }, character(1))
  content_xml <- paste(para_xml_parts, collapse = "")

  # Build the full structure
  full_xml <- sprintf(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor distT="%d" distB="%d" distL="%d" distR="%d"',
    ' simplePos="0" relativeHeight="251658240" behindDoc="%s"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionV>',
    '<wp:extent cx="%d" cy="%d"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '%s',
    '<wp:docPr id="%d" name="TextBox %d"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape">',
    '<wps:wsp>',
    '<wps:cNvSpPr txBox="1"/>',
    '<wps:spPr>',
    '<a:xfrm><a:off x="0" y="0"/><a:ext cx="%d" cy="%d"/></a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>',
    '<a:noFill/>',
    '<a:ln><a:noFill/></a:ln>',
    '</wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '%s',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr rot="0" spcFirstLastPara="0" vertOverflow="overflow"',
    ' horzOverflow="overflow" wrap="square"',
    ' lIns="91440" tIns="45720" rIns="91440" bIns="45720"',
    ' anchor="t" anchorCtr="0"/>',
    '</wps:wsp>',
    '</a:graphicData></a:graphic>',
    '</wp:anchor>',
    '</w:drawing></w:r></w:p>'
  ),
    dist_t, dist_b, dist_l, dist_r,
    behind_doc,
    anchor_to_posH_relative(horz_anchor), pos_x_emu,
    anchor_to_posV_relative(vert_anchor), pos_y_emu,
    width_emu, height_emu,
    wrap_xml,
    next_docpr_id, next_docpr_id,
    width_emu, height_emu,
    content_xml
  )

  result_doc <- tryCatch(
    xml2::read_xml(full_xml),
    error = function(e) e
  )
  if (inherits(result_doc, "error")) {
    return(list(success = FALSE,
                reason = paste0("failed to parse constructed text box XML: ",
                                conditionMessage(result_doc))))
  }

  list(success = TRUE, para = result_doc, docpr_id = next_docpr_id)
}


#' Build group shape anchor for image+caption figures
#'
#' Constructs a `wpg:wgp` inside `wp:anchor` containing a `pic:pic` member
#' (image) and a `wps:wsp` member (caption text box). Follows the same
#' interface as `build_text_box_anchor()`.
#'
#' @param content_nodes xml2 nodeset of body children between markers
#' @param payload Named list of positioning properties from field code
#' @param ns Named character vector of XML namespaces (must include wp, a, pic, wps, r)
#' @param next_docpr_id Integer. Next available wp:docPr ID.
#' @return List with `success` (logical), `para` (xml2 node), `docpr_id` (integer),
#'   and optionally `reason` (character) on failure.
#' @noRd
build_group_anchor <- function(content_nodes, payload, ns, next_docpr_id = 1L) {
  # Separate content into image paragraphs and caption paragraphs
  image_paras <- list()
  caption_paras <- list()

  for (node in content_nodes) {
    node_name <- xml2::xml_name(node)
    if (node_name != "p") {
      caption_paras <- c(caption_paras, list(node))
      next
    }
    drawings <- xml2::xml_find_all(node, ".//w:drawing", ns = ns)
    has_pic <- FALSE
    if (length(drawings) > 0) {
      pics <- xml2::xml_find_all(node,
        ".//pic:pic",
        ns = c(ns, pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"))
      if (length(pics) > 0) has_pic <- TRUE
    }
    if (has_pic) {
      image_paras <- c(image_paras, list(node))
    } else {
      caption_paras <- c(caption_paras, list(node))
    }
  }

  if (length(image_paras) == 0) {
    return(list(success = FALSE, reason = "no image found in group content"))
  }

  # Extract pic:pic from first image paragraph's wp:inline
  img_para <- image_paras[[1]]
  pic_node <- xml2::xml_find_first(img_para,
    ".//pic:pic",
    ns = c(ns, pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"))
  if (inherits(pic_node, "xml_missing")) {
    return(list(success = FALSE,
                reason = "could not extract pic:pic from image paragraph"))
  }

  # Extract original image dimensions from pic:spPr/a:xfrm/a:ext
  pic_ext <- xml2::xml_find_first(pic_node, ".//a:xfrm/a:ext", ns = ns)
  pic_cx_emu <- if (!inherits(pic_ext, "xml_missing")) {
    as.numeric(xml2::xml_attr(pic_ext, "cx"))
  } else {
    NA_real_
  }
  pic_cy_emu <- if (!inherits(pic_ext, "xml_missing")) {
    as.numeric(xml2::xml_attr(pic_ext, "cy"))
  } else {
    NA_real_
  }

  # Serialize caption paragraphs
  caption_xml <- ""
  if (length(caption_paras) > 0) {
    caption_parts <- vapply(caption_paras, function(p) as.character(p),
                            character(1))
    caption_xml <- paste(caption_parts, collapse = "")
  }

  # --- Dimensions ---
  # Group width from payload
  group_width_emu <- css_to_emu(payload$float_width %||% "5000dxa")

  # Image height: from payload or compute from aspect ratio
  if (!is.null(payload$image_height)) {
    image_height_emu <- css_to_emu(payload$image_height)
  } else if (!is.na(pic_cy_emu) && !is.na(pic_cx_emu) && pic_cx_emu > 0) {
    # Scale to group width preserving aspect ratio
    image_height_emu <- as.integer(round(
      group_width_emu * (pic_cy_emu / pic_cx_emu)))
  } else {
    # Default: 3 inches
    message("[anchor-assembly] No image dimensions available; using 3-inch fallback height")
    image_height_emu <- 2743200L
  }
  image_height_emu <- as.integer(image_height_emu)

  # Rescale pic:pic dimensions to match group coordinate space.
  # The original a:xfrm/a:ext carries standalone dimensions from wp:inline context;
  # inside wpg:wgp the image must use group_width_emu x image_height_emu.
  if (!inherits(pic_ext, "xml_missing")) {
    xml2::xml_set_attr(pic_ext, "cx", as.character(group_width_emu))
    xml2::xml_set_attr(pic_ext, "cy", as.character(image_height_emu))
  }

  # Serialize pic:pic to XML string (after dimension rescaling)
  pic_xml <- as.character(pic_node)

  # Caption Y offset: from payload or image_height + small gap
  if (!is.null(payload$caption_y)) {
    caption_y_emu <- css_to_emu(payload$caption_y)
  } else {
    caption_y_emu <- image_height_emu + 91440L  # 0.1 inch gap
  }
  caption_y_emu <- as.integer(caption_y_emu)

  # Caption text box height: generous default -- Word auto-sizes
  caption_height_emu <- 914400L  # 1 inch

  # Group total height
  group_height_emu <- caption_y_emu + caption_height_emu

  # --- Positioning ---
  vert_anchor <- payload$vertical_anchor %||% "text"
  horz_anchor <- payload$horizontal_anchor %||% "margin"
  pos_y_emu <- css_to_emu(payload$position_y %||% "0")
  pos_x_emu <- css_to_emu(payload$position_x %||% "0")
  behind_doc <- if (identical(payload$z_layer, "behind")) "1" else "0"

  # Wrap distances
  dist <- parse_wrap_distance(payload$wrap_distance)
  dist_t <- as.integer(dist$top * 635)
  dist_b <- as.integer(dist$bottom * 635)
  dist_l <- as.integer(dist$left * 635)
  dist_r <- as.integer(dist$right * 635)

  # Wrap element
  wrap_style <- payload$wrap_style %||% "square"
  wrap_xml <- switch(wrap_style,
    "none" = "<wp:wrapNone/>",
    "square" = sprintf(
      '<wp:wrapSquare wrapText="%s" distT="%d" distB="%d" distL="%d" distR="%d"/>',
      wrap_side_to_ooxml(payload$wrap_side), dist_t, dist_b, dist_l, dist_r
    ),
    "top-and-bottom" = sprintf(
      '<wp:wrapTopAndBottom distT="%d" distB="%d"/>',
      dist_t, dist_b
    ),
    '<wp:wrapSquare wrapText="bothSides"/>'
  )

  # --- Build XML ---
  full_xml <- sprintf(paste0(
    '<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"',
    ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"',
    ' xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"',
    ' xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"',
    ' xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"',
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    '<w:r><w:drawing>',
    '<wp:anchor distT="%d" distB="%d" distL="%d" distR="%d"',
    ' simplePos="0" relativeHeight="251658240" behindDoc="%s"',
    ' locked="0" layoutInCell="1" allowOverlap="1">',
    '<wp:simplePos x="0" y="0"/>',
    '<wp:positionH relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionH>',
    '<wp:positionV relativeFrom="%s"><wp:posOffset>%d</wp:posOffset></wp:positionV>',
    '<wp:extent cx="%d" cy="%d"/>',
    '<wp:effectExtent l="0" t="0" r="0" b="0"/>',
    '%s',
    '<wp:docPr id="%d" name="Group %d"/>',
    '<wp:cNvGraphicFramePr/>',
    '<a:graphic>',
    '<a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup">',
    '<wpg:wgp>',
    '<wpg:cNvGrpSpPr/>',
    '<wpg:grpSpPr>',
    '<a:xfrm>',
    '<a:off x="0" y="0"/>',
    '<a:ext cx="%d" cy="%d"/>',
    '<a:chOff x="0" y="0"/>',
    '<a:chExt cx="%d" cy="%d"/>',
    '</a:xfrm>',
    '</wpg:grpSpPr>',
    '%s',
    '<wps:wsp>',
    '<wps:cNvSpPr txBox="1"/>',
    '<wps:spPr>',
    '<a:xfrm>',
    '<a:off x="0" y="%d"/>',
    '<a:ext cx="%d" cy="%d"/>',
    '</a:xfrm>',
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>',
    '<a:noFill/>',
    '<a:ln><a:noFill/></a:ln>',
    '</wps:spPr>',
    '<wps:txbx><w:txbxContent>',
    '%s',
    '</w:txbxContent></wps:txbx>',
    '<wps:bodyPr rot="0" wrap="square"',
    ' lIns="91440" tIns="45720" rIns="91440" bIns="45720"',
    ' anchor="t" anchorCtr="0"/>',
    '</wps:wsp>',
    '</wpg:wgp>',
    '</a:graphicData>',
    '</a:graphic>',
    '</wp:anchor>',
    '</w:drawing></w:r></w:p>'
  ),
    dist_t, dist_b, dist_l, dist_r,
    behind_doc,
    anchor_to_posH_relative(horz_anchor), pos_x_emu,
    anchor_to_posV_relative(vert_anchor), pos_y_emu,
    group_width_emu, group_height_emu,
    wrap_xml,
    next_docpr_id, next_docpr_id,
    group_width_emu, group_height_emu,
    group_width_emu, group_height_emu,
    pic_xml,
    caption_y_emu,
    group_width_emu, caption_height_emu,
    caption_xml
  )

  result_doc <- tryCatch(
    xml2::read_xml(full_xml),
    error = function(e) e
  )
  if (inherits(result_doc, "error")) {
    return(list(success = FALSE,
                reason = paste0("failed to parse constructed group XML: ",
                                conditionMessage(result_doc))))
  }

  list(success = TRUE, para = result_doc, docpr_id = next_docpr_id)
}


#' Build floating table XML
#'
#' Constructs a `w:tbl` XML string with `w:tblpPr` positioning, zero borders,
#' zero cell margins, and a single empty cell. Content paragraphs are added
#' to the cell by the caller after parsing.
#'
#' @param float_config Named list with positioning properties:
#'   vertical_anchor, horizontal_anchor, position_y, position_x,
#'   float_width, wrap_distance.
#' @return Character string of w:tbl XML (without namespace declarations).
#' @noRd
build_table_anchor_xml <- function(float_config) {
  # Parse width — "5000dxa" -> 5000, CSS units -> twips
  width_str <- float_config$float_width %||% "5000dxa"
  if (grepl("dxa$", width_str)) {
    width_dxa <- as.integer(sub("dxa$", "", width_str))
  } else {
    width_dxa <- css_to_twips(width_str)
  }

  # Parse wrap distances
  dist <- parse_wrap_distance(float_config$wrap_distance)

  # Parse position values — plain numbers treated as DXA
  parse_pos <- function(val) {
    if (is.null(val)) return("0")
    val <- as.character(val)
    if (grepl("^-?[0-9]+$", val)) return(val)
    if (grepl("dxa$", val)) return(sub("dxa$", "", val))
    as.character(css_to_twips(val))
  }

  pos_y <- parse_pos(float_config$position_y)
  pos_x <- parse_pos(float_config$position_x)

  vert_anchor <- float_config$vertical_anchor %||% "text"
  horz_anchor <- float_config$horizontal_anchor %||% "margin"

  # Build the table XML
  xml_parts <- c(
    '<w:tbl>',
    '  <w:tblPr>',
    sprintf('    <w:tblpPr w:leftFromText="%d" w:rightFromText="%d" w:topFromText="%d" w:bottomFromText="%d" w:vertAnchor="%s" w:horzAnchor="%s" w:tblpY="%s" w:tblpX="%s"/>',
            dist$left, dist$right, dist$top, dist$bottom,
            vert_anchor, horz_anchor, pos_y, pos_x),
    sprintf('    <w:tblW w:w="%d" w:type="dxa"/>', width_dxa),
    '    <w:tblLayout w:type="fixed"/>',
    '    <w:tblBorders>',
    '      <w:top w:val="none" w:sz="0" w:space="0" w:color="auto"/>',
    '      <w:left w:val="none" w:sz="0" w:space="0" w:color="auto"/>',
    '      <w:bottom w:val="none" w:sz="0" w:space="0" w:color="auto"/>',
    '      <w:right w:val="none" w:sz="0" w:space="0" w:color="auto"/>',
    '      <w:insideH w:val="none" w:sz="0" w:space="0" w:color="auto"/>',
    '      <w:insideV w:val="none" w:sz="0" w:space="0" w:color="auto"/>',
    '    </w:tblBorders>',
    '    <w:tblCellMar>',
    '      <w:left w:w="0" w:type="dxa"/>',
    '      <w:right w:w="0" w:type="dxa"/>',
    '    </w:tblCellMar>',
    '  </w:tblPr>',
    sprintf('  <w:tblGrid><w:gridCol w:w="%d"/></w:tblGrid>', width_dxa),
    '  <w:tr>',
    '    <w:tc>',
    sprintf('      <w:tcPr><w:tcW w:w="%d" w:type="dxa"/></w:tcPr>', width_dxa),
    '    </w:tc>',
    '  </w:tr>',
    '</w:tbl>'
  )

  paste(xml_parts, collapse = "")
}


#' Detect content type inside anchor markers
#'
#' Inspects body children between anchor markers to classify the content.
#' Used by `assemble_anchors()` to pick the correct OOXML mechanism.
#'
#' @param content_nodes xml2 nodeset of children between markers
#' @param ns Named character vector of XML namespaces
#' @return Character: "table", "image", "text", "group", or "mixed"
#' @noRd
detect_anchor_content <- function(content_nodes, ns) {
  has_table <- FALSE
  has_image <- FALSE
  has_text <- FALSE

  for (node in content_nodes) {
    node_name <- xml2::xml_name(node)

    if (node_name == "tbl") {
      has_table <- TRUE
      next
    }

    if (node_name == "p") {
      # Check for drawing with image
      drawings <- xml2::xml_find_all(node, ".//w:drawing", ns = ns)
      if (length(drawings) > 0) {
        for (drawing in drawings) {
          pic_nodes <- xml2::xml_find_all(drawing, ".//pic:pic",
            ns = c(ns, pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"))
          if (length(pic_nodes) > 0) {
            has_image <- TRUE
          }
        }
      }

      # Check for text content (paragraphs that aren't purely image)
      # A paragraph counts as text if it has non-empty w:t outside drawings,
      # or if it has no drawings at all but has text
      if (length(drawings) == 0) {
        text_nodes <- xml2::xml_find_all(node, ".//w:t", ns = ns)
        para_text <- paste(xml2::xml_text(text_nodes), collapse = "")
        if (nzchar(trimws(para_text))) {
          has_text <- TRUE
        }
      }
    }
  }

  # Classification logic
  # Image+text (no table) is a grouped figure — semantic mapping to wpg:wgp
  if (has_image && has_text && !has_table) return("group")
  # Any other combination of two+ types is "mixed"
  if (has_table && has_image) return("mixed")
  if (has_table && has_text) return("mixed")
  if (has_table) return("table")
  if (has_image) return("image")
  "text"
}


#' Find the paragraph containing a bookmark
#'
#' Scans `w:bookmarkStart` elements in the body for a matching bookmark name.
#' Checks both bare name and `_docstyle_` prefixed form (Quarto heading IDs).
#'
#' @param body xml2 node of the `w:body` element
#' @param bookmark_id Character. The bookmark ID (with or without `#` prefix).
#' @param ns Named character vector of XML namespaces.
#' @return xml2 node of the `w:p` containing the bookmark, or NULL if not found.
#' @noRd
find_bookmark_paragraph <- function(body, bookmark_id, ns) {
  # Strip # prefix
  bm_id <- sub("^#", "", bookmark_id)

  # Search for bare name and _docstyle_ prefixed form
  candidates <- c(bm_id, paste0("_docstyle_", bm_id))

  bookmarks <- xml2::xml_find_all(body, ".//w:bookmarkStart", ns)
  for (bm in bookmarks) {
    bm_name <- xml2::xml_attr(bm, "name")
    if (is.na(bm_name)) next
    if (bm_name %in% candidates) {
      # Return the parent paragraph
      parent <- xml2::xml_parent(bm)
      if (xml2::xml_name(parent) == "p") {
        return(parent)
      }
    }
  }

  NULL
}


#' Relocate an assembled anchor to a target bookmark paragraph
#'
#' @param body xml2 node of w:body
#' @param assembled_node xml2 node to relocate (already inserted in body)
#' @param adjacent Character. Bookmark ID (with or without # prefix).
#' @param ns Named character vector of XML namespaces.
#' @return Logical. TRUE if relocation succeeded, FALSE if bookmark not found.
#' @noRd
relocate_to_adjacent <- function(body, assembled_node, adjacent, ns) {
  target_para <- find_bookmark_paragraph(body, adjacent, ns)
  if (is.null(target_para)) {
    warning("[anchor-assembly] Bookmark '", sub("^#", "", adjacent),
            "' not found, using source position", call. = FALSE)
    return(FALSE)
  }

  # Move the assembled node before the target paragraph.
  # xml_add_sibling with an existing in-tree node performs a MOVE
  # (implicit detach + re-insert), not a copy.
  xml2::xml_add_sibling(target_para, assembled_node, .where = "before")

  TRUE
}


#' Assemble anchored content from DOCSTYLE_ANCHOR markers
#'
#' Scans body children for `DOCSTYLE_ANCHOR::` (or legacy `DOCSTYLE_FLOAT::`)
#' opening markers and matching `DOCSTYLE_ANCHOR_END::` (or `DOCSTYLE_FLOAT_END::`)
#' closing markers. Content-aware: detects whether the content is a table, image,
#' or text, then applies the appropriate OOXML mechanism — `w:tblpPr` for tables,
#' `wp:anchor` for images, invisible floating table or DrawingML text box for
#' text (depending on `content-mode`).
#'
#' @param body xml2 node of the `w:body` element
#' @param ns Named character vector of XML namespaces
#' @param page_config List from `load_page_config()`, may contain `anchor_styles`
#' @param verbose Logical. Print diagnostic messages.
#' @return List with `n_assembled` (integer count of anchors assembled)
#' @keywords internal
#' @export
assemble_anchors <- function(body, ns, page_config, verbose = FALSE) {
  n_assembled <- 0L

  # === PASS 1: Collect anchor ranges ===
  children <- xml2::xml_children(body)
  ranges <- list()

  # Build index of opening and closing markers
  open_markers <- list()  # class -> list(idx, payload)

  for (i in seq_along(children)) {
    child <- children[[i]]
    child_name <- xml2::xml_name(child)

    # Only paragraphs can contain markers
    if (child_name != "p") next

    text_nodes <- xml2::xml_find_all(child, ".//w:t", ns = ns)
    if (length(text_nodes) == 0) next
    para_text <- paste(xml2::xml_text(text_nodes), collapse = "")

    # Check for opening marker (anchor or legacy float)
    if (grepl("^DOCSTYLE_(ANCHOR|FLOAT)::", para_text)) {
      parts <- strsplit(para_text, "::")[[1]]
      if (length(parts) < 2) next
      class_name <- parts[2]

      # Extract JSON payload from instrText
      payload <- NULL
      instr_nodes <- xml2::xml_find_all(child, ".//w:instrText", ns = ns)
      for (instr_node in instr_nodes) {
        instr_text <- xml2::xml_text(instr_node)
        json_match <- regmatches(instr_text, regexpr("\\{.*\\}", instr_text))
        if (length(json_match) == 1 && nzchar(json_match)) {
          payload <- tryCatch(
            jsonlite::fromJSON(json_match, simplifyVector = FALSE),
            error = function(e) {
              warning("[anchor-assembly] Failed to parse JSON payload: ",
                      e$message, "\n  Raw: ", substr(json_match, 1, 200),
                      call. = FALSE)
              NULL
            }
          )
        }
      }

      open_markers[[class_name]] <- list(idx = i, payload = payload)
      next
    }

    # Check for closing marker (anchor or legacy float)
    if (grepl("^DOCSTYLE_(ANCHOR|FLOAT)_END::", para_text)) {
      parts <- strsplit(para_text, "::")[[1]]
      if (length(parts) < 2) next
      class_name <- parts[2]

      if (!is.null(open_markers[[class_name]])) {
        ranges <- c(ranges, list(list(
          start_idx = open_markers[[class_name]]$idx,
          end_idx = i,
          class = class_name,
          payload = open_markers[[class_name]]$payload
        )))
        open_markers[[class_name]] <- NULL
      }
    }
  }

  # Warn about unmatched opening markers
  if (length(open_markers) > 0) {
    for (cls in names(open_markers)) {
      warning("[anchor-assembly] Opening marker for anchor class '", cls,
              "' at body child ", open_markers[[cls]]$idx,
              " has no matching closing marker.",
              call. = FALSE)
    }
  }

  if (length(ranges) == 0) {
    return(list(n_assembled = 0L))
  }

  if (verbose) {
    message("[anchor-assembly] Found ", length(ranges), " anchor range(s)")
  }

  # === PASS 2: Process ranges in REVERSE order (preserves indices) ===
  for (ri in rev(seq_along(ranges))) {
    fr <- ranges[[ri]]

    # Build anchor config from payload (preferred) or page_config$anchor_styles
    anchor_config <- fr$payload
    if (is.null(anchor_config) && !is.null(page_config$anchor_styles[[fr$class]])) {
      anchor_config <- page_config$anchor_styles[[fr$class]]
    }
    if (is.null(anchor_config)) {
      if (verbose) {
        message("[anchor-assembly] No config for anchor class '", fr$class,
                "', using defaults")
      }
      anchor_config <- list(
        vertical_anchor = "text",
        horizontal_anchor = "margin",
        position_y = "0",
        position_x = "0",
        float_width = "5000dxa",
        wrap_distance = "0 198dxa 0 198dxa"
      )
    }

    # Detect content type
    children <- xml2::xml_children(body)
    content_start <- fr$start_idx + 1L
    content_end <- fr$end_idx - 1L
    content_type <- "table"  # default
    if (content_start <= content_end) {
      content_nodes <- children[content_start:content_end]
      content_type <- detect_anchor_content(content_nodes, ns)
    }

    if (content_type == "image") {
      # Find the paragraph containing the image
      children <- xml2::xml_children(body)
      assembled_image <- FALSE
      if (content_start > content_end) {
        warning("[anchor-assembly] Empty content range for image anchor class '",
                fr$class, "'.", call. = FALSE)
        next
      }
      for (ci in content_start:content_end) {
        img_drawings <- xml2::xml_find_all(children[[ci]], ".//w:drawing", ns = ns)
        if (length(img_drawings) > 0) {
          # Extend ns with DrawingML namespaces for image rewrite
          ns_ext <- c(ns,
            wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
            a = "http://schemas.openxmlformats.org/drawingml/2006/main",
            pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
          )

          # Determine next docPr ID (scan existing)
          existing_ids <- xml2::xml_find_all(body, ".//wp:docPr", ns = ns_ext)
          max_id <- 0L
          for (dp in existing_ids) {
            dp_id <- as.integer(xml2::xml_attr(dp, "id"))
            if (!is.na(dp_id) && dp_id > max_id) max_id <- dp_id
          }
          next_id <- max_id + 1L

          result <- build_image_anchor(children[[ci]], anchor_config, ns_ext,
                                       next_docpr_id = next_id)
          if (!result$success) {
            reason <- result$reason %||% "unknown"
            warning("[anchor-assembly] Failed to build image anchor for class '",
                    fr$class, "': ", reason, call. = FALSE)
            next
          }
          assembled_image <- TRUE
          image_para <- children[[ci]]  # save reference for adjacency relocation
          break
        }
      }

      if (!assembled_image) {
        if (verbose) {
          message("[anchor-assembly] No drawing found for image class '", fr$class, "'")
        }
        next
      }

      # Remove marker paragraphs (start and end), keep content paragraphs
      children <- xml2::xml_children(body)
      # Remove end marker first (higher index)
      xml2::xml_remove(children[[fr$end_idx]])
      children <- xml2::xml_children(body)
      # Remove start marker
      xml2::xml_remove(children[[fr$start_idx]])

      n_assembled <- n_assembled + 1L

      # Adjacency relocation for image anchor
      if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
        # image_para was captured before marker removal — still valid in tree
        relocate_to_adjacent(body, image_para, fr$payload$adjacent, ns)
      }

      if (verbose) {
        message("[anchor-assembly] Assembled image anchor: ", fr$class)
      }
      next
    }

    if (content_type == "group") {
      # Grouped figure: image + caption → wpg:wgp
      children <- xml2::xml_children(body)
      content_start <- fr$start_idx + 1L
      content_end <- fr$end_idx - 1L

      if (content_start > content_end) {
        warning("[anchor-assembly] Empty content range for group class '",
                fr$class, "'.", call. = FALSE)
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[fr$end_idx]])
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[fr$start_idx]])
        next
      }

      content_nodes <- children[content_start:content_end]

      # Extend ns with DrawingML + group namespaces
      ns_ext <- c(ns,
        wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        a = "http://schemas.openxmlformats.org/drawingml/2006/main",
        pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
        wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
        wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
        r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      )

      # Determine next docPr ID
      existing_ids <- xml2::xml_find_all(body, ".//wp:docPr", ns = ns_ext)
      max_id <- 0L
      for (dp in existing_ids) {
        dp_id <- as.integer(xml2::xml_attr(dp, "id"))
        if (!is.na(dp_id) && dp_id > max_id) max_id <- dp_id
      }
      next_id <- max_id + 1L

      grp_result <- build_group_anchor(content_nodes, anchor_config, ns_ext,
                                        next_docpr_id = next_id)
      if (!grp_result$success) {
        reason <- grp_result$reason %||% "unknown"
        warning("[anchor-assembly] Failed to build group for class '",
                fr$class, "': ", reason, call. = FALSE)
        # Clean up marker paragraphs so they don't appear as visible text
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[fr$end_idx]])
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[fr$start_idx]])
        next
      }

      # Insert the group paragraph before the start marker
      children <- xml2::xml_children(body)
      xml2::xml_add_sibling(children[[fr$start_idx]], grp_result$para, .where = "before")

      # Get in-tree reference (xml_add_sibling copies; original ref is detached)
      children <- xml2::xml_children(body)
      group_node <- children[[fr$start_idx]]

      # Remove original nodes (start marker, content, end marker)
      remove_start <- fr$start_idx + 1L
      remove_end <- fr$end_idx + 1L
      for (ri in remove_end:remove_start) {
        children <- xml2::xml_children(body)
        xml2::xml_remove(children[[ri]])
      }

      n_assembled <- n_assembled + 1L

      # Adjacency relocation for group
      # After xml_add_sibling on line above, grp_result$para is the detached
      # original (xml2 copied it into the tree as group_node). To relocate,
      # remove the in-tree copy and insert the original at the target.
      if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
        target_para <- find_bookmark_paragraph(body, fr$payload$adjacent, ns)
        if (!is.null(target_para)) {
          xml2::xml_remove(group_node)
          xml2::xml_add_sibling(target_para, grp_result$para, .where = "before")
        } else {
          warning("[anchor-assembly] Bookmark '",
                  sub("^#", "", fr$payload$adjacent),
                  "' not found, using source position", call. = FALSE)
        }
      }

      if (verbose) {
        message("[anchor-assembly] Assembled group: ", fr$class)
      }
      next
    }

    if (content_type %in% c("text", "mixed")) {
      content_mode <- anchor_config$content_mode %||% "auto"

      if (content_mode == "textbox") {
        # DrawingML text box: wp:anchor with wps:txbx
        children <- xml2::xml_children(body)
        content_start <- fr$start_idx + 1L
        content_end <- fr$end_idx - 1L

        if (content_start > content_end) {
          warning("[anchor-assembly] Empty content range for textbox class '",
                  fr$class, "'.", call. = FALSE)
          # Remove marker paragraphs so they don't appear as visible text
          children <- xml2::xml_children(body)
          xml2::xml_remove(children[[fr$end_idx]])
          children <- xml2::xml_children(body)
          xml2::xml_remove(children[[fr$start_idx]])
          next
        }

        content_nodes <- children[content_start:content_end]

        # Extend ns with DrawingML namespaces
        ns_ext <- c(ns,
          wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
          a = "http://schemas.openxmlformats.org/drawingml/2006/main",
          wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
          r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        )

        # Determine next docPr ID
        existing_ids <- xml2::xml_find_all(body, ".//wp:docPr", ns = ns_ext)
        max_id <- 0L
        for (dp in existing_ids) {
          dp_id <- as.integer(xml2::xml_attr(dp, "id"))
          if (!is.na(dp_id) && dp_id > max_id) max_id <- dp_id
        }
        next_id <- max_id + 1L

        tb_result <- build_text_box_anchor(content_nodes, anchor_config, ns_ext,
                                            next_docpr_id = next_id)
        if (!tb_result$success) {
          reason <- tb_result$reason %||% "unknown"
          warning("[anchor-assembly] Failed to build text box for class '",
                  fr$class, "': ", reason, call. = FALSE)
          # Clean up marker paragraphs so they don't appear as visible text
          children <- xml2::xml_children(body)
          xml2::xml_remove(children[[fr$end_idx]])
          children <- xml2::xml_children(body)
          xml2::xml_remove(children[[fr$start_idx]])
          next
        }

        # Insert the text box paragraph before the start marker
        children <- xml2::xml_children(body)
        xml2::xml_add_sibling(children[[fr$start_idx]], tb_result$para, .where = "before")

        # Remove original nodes (start marker, content, end marker)
        children <- xml2::xml_children(body)
        remove_start <- fr$start_idx + 1L
        remove_end <- fr$end_idx + 1L
        for (ri in remove_end:remove_start) {
          xml2::xml_remove(children[[ri]])
          children <- xml2::xml_children(body)
        }

        n_assembled <- n_assembled + 1L

        # Adjacency relocation for text box.
        # tb_result$para is from read_xml() (cross-document), so xml_add_sibling
        # copied it into the tree. tb_result$para still points at the source
        # document. Use the same remove-then-insert pattern as the group path.
        if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
          target_para <- find_bookmark_paragraph(body, fr$payload$adjacent, ns)
          if (!is.null(target_para)) {
            # Find the in-tree copy (it's at start_idx after marker removal)
            children <- xml2::xml_children(body)
            tb_in_tree <- children[[fr$start_idx]]
            xml2::xml_remove(tb_in_tree)
            xml2::xml_add_sibling(target_para, tb_result$para, .where = "before")
          } else {
            warning("[anchor-assembly] Bookmark '",
                    sub("^#", "", fr$payload$adjacent),
                    "' not found, using source position", call. = FALSE)
          }
        }

        if (verbose) {
          message("[anchor-assembly] Assembled text box: ", fr$class)
        }
        next
      }

      # Default: wrap text/mixed content in invisible floating table
      # (same mechanism as table content)
    }

    # content_type in ("table", "text", "mixed"): proceed with floating table assembly

    # Build table XML
    tbl_xml_str <- build_table_anchor_xml(anchor_config)

    # Parse into xml2 node (needs namespace wrapper)
    tbl_doc <- xml2::read_xml(paste0(
      '<?xml version="1.0"?>',
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
      tbl_xml_str,
      '</w:document>'
    ))
    tbl_node <- xml2::xml_find_first(tbl_doc, "//w:tbl", ns = ns)
    if (inherits(tbl_node, "xml_missing")) {
      warning("[anchor-assembly] Failed to construct table XML for anchor class '",
              fr$class, "'. Skipping.", call. = FALSE)
      # Clean up marker paragraphs so they don't appear as visible text
      children <- xml2::xml_children(body)
      xml2::xml_remove(children[[fr$end_idx]])
      children <- xml2::xml_children(body)
      xml2::xml_remove(children[[fr$start_idx]])
      next
    }
    tc_node <- xml2::xml_find_first(tbl_node, ".//w:tc", ns = ns)
    if (inherits(tc_node, "xml_missing")) {
      warning("[anchor-assembly] No tc node in constructed table for anchor class '",
              fr$class, "'. Skipping.", call. = FALSE)
      children <- xml2::xml_children(body)
      xml2::xml_remove(children[[fr$end_idx]])
      children <- xml2::xml_children(body)
      xml2::xml_remove(children[[fr$start_idx]])
      next
    }

    # Re-read children (indices may have shifted from prior iterations)
    children <- xml2::xml_children(body)

    # Copy content paragraphs (between start+1 and end-1) into the tc
    content_start <- fr$start_idx + 1L
    content_end <- fr$end_idx - 1L

    if (content_start > content_end) {
      warning("[anchor-assembly] Anchor class '", fr$class,
              "' has no content paragraphs.", call. = FALSE)
    }

    if (content_start <= content_end) {
      for (ci in content_start:content_end) {
        xml2::xml_add_child(tc_node, children[[ci]])
      }
    }

    # Insert the table node before the start marker paragraph
    xml2::xml_add_sibling(children[[fr$start_idx]], tbl_node, .where = "before")

    # Remove original nodes (start marker, content, end marker)
    # After inserting tbl, indices shift by +1
    # Remove in reverse order to maintain index validity
    children <- xml2::xml_children(body)
    # The original nodes are now at indices: start+1, start+2, ..., end+1
    remove_start <- fr$start_idx + 1L
    remove_end <- fr$end_idx + 1L

    for (ri2 in remove_end:remove_start) {
      xml2::xml_remove(children[[ri2]])
      # Re-read after each removal to keep indices valid
      children <- xml2::xml_children(body)
    }

    n_assembled <- n_assembled + 1L

    # Adjacency relocation for floating table.
    # tbl_node is from read_xml() (cross-document), so xml_add_sibling copied
    # it into the tree. Use the same remove-then-insert pattern as group path.
    if (!is.null(fr$payload$adjacent) && nzchar(fr$payload$adjacent)) {
      target_para <- find_bookmark_paragraph(body, fr$payload$adjacent, ns)
      if (!is.null(target_para)) {
        # Find the in-tree copy (it's at start_idx after marker removal)
        children <- xml2::xml_children(body)
        tbl_in_tree <- children[[fr$start_idx]]
        xml2::xml_remove(tbl_in_tree)
        xml2::xml_add_sibling(target_para, tbl_node, .where = "before")
      } else {
        warning("[anchor-assembly] Bookmark '",
                sub("^#", "", fr$payload$adjacent),
                "' not found, using source position", call. = FALSE)
      }
    }

    if (verbose) {
      message("[anchor-assembly] Assembled anchor: ", fr$class)
    }
  }

  list(n_assembled = n_assembled)
}


#' Check if a paragraph contains an anchored (positioned) image
#'
#' Detects `w:drawing/wp:anchor` containing `pic:pic`.
#'
#' @param para xml2 node for w:p
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @keywords internal
#' @export
is_anchored_image <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  anchors <- xml2::xml_find_all(para, ".//wp:anchor", ns = ns_ext)
  if (length(anchors) == 0) return(FALSE)

  for (anchor in anchors) {
    pics <- xml2::xml_find_all(anchor, ".//pic:pic", ns = ns_ext)
    if (length(pics) > 0) return(TRUE)
  }
  FALSE
}


#' Map OOXML positionH relativeFrom to CSS horizontal-anchor
#' @noRd
posH_relative_to_css <- function(rel) {
  switch(rel %||% "margin",
    "column" = "text",
    "margin" = "margin",
    "page"   = "page",
    "margin"  # default
  )
}

#' Map OOXML positionV relativeFrom to CSS vertical-anchor
#' @noRd
posV_relative_to_css <- function(rel) {
  switch(rel %||% "paragraph",
    "paragraph" = "text",
    "margin"    = "margin",
    "page"      = "page",
    "text"  # default
  )
}


#' Extract positioning properties from an anchored image
#'
#' Reads `wp:anchor` attributes and converts to CSS vocabulary.
#' EMU values are converted to DXA for consistency with the field code payload.
#'
#' @param para xml2 node for w:p containing wp:anchor
#' @param ns Named character vector of XML namespaces
#' @return Named list of positioning properties, or NULL if not an anchored image
#' @keywords internal
#' @export
extract_anchor_image_properties <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
  )

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_ext)
  if (inherits(anchor, "xml_missing")) return(NULL)

  # Positioning
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_ext)
  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_ext)

  relH <- if (!inherits(posH, "xml_missing")) xml2::xml_attr(posH, "relativeFrom") else "margin"
  relV <- if (!inherits(posV, "xml_missing")) xml2::xml_attr(posV, "relativeFrom") else "paragraph"

  offsetH <- "0"
  if (!inherits(posH, "xml_missing")) {
    off_node <- xml2::xml_find_first(posH, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      offsetH <- as.character(as.integer(round(emu_val / 635)))
    }
  }

  offsetV <- "0"
  if (!inherits(posV, "xml_missing")) {
    off_node <- xml2::xml_find_first(posV, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      offsetV <- as.character(as.integer(round(emu_val / 635)))
    }
  }

  # Extent (width)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_ext)
  width_dxa <- NULL
  if (!inherits(extent, "xml_missing")) {
    cx <- as.numeric(xml2::xml_attr(extent, "cx"))
    width_dxa <- as.character(as.integer(round(cx / 635)))
  }

  # Behind doc (xml_attr returns NA for missing attributes, not NULL)
  behind_doc <- xml2::xml_attr(anchor, "behindDoc")
  if (is.na(behind_doc)) behind_doc <- "0"
  z_layer <- if (behind_doc == "1") "behind" else "front"

  # Wrap style
  wrap_style <- "square"
  if (length(xml2::xml_find_all(anchor, "wp:wrapNone", ns = ns_ext)) > 0) wrap_style <- "none"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTopAndBottom", ns = ns_ext)) > 0) wrap_style <- "top-and-bottom"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTight", ns = ns_ext)) > 0) wrap_style <- "tight"

  list(
    horizontal_anchor = posH_relative_to_css(relH),
    vertical_anchor   = posV_relative_to_css(relV),
    position_x        = offsetH,
    position_y        = offsetV,
    float_width       = width_dxa,
    z_layer           = z_layer,
    wrap_style        = wrap_style
  )
}


#' Check if a paragraph contains a text box
#'
#' Detects `wp:anchor` containing `wps:txbx` but NOT `pic:pic`.
#'
#' @param para xml2 node for w:p
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @keywords internal
#' @export
is_text_box <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
  )
  anchors <- xml2::xml_find_all(para, ".//wp:anchor", ns = ns_ext)
  if (length(anchors) == 0) return(FALSE)

  for (anchor in anchors) {
    txbx <- xml2::xml_find_first(anchor, ".//wps:txbx", ns = ns_ext)
    pics <- xml2::xml_find_all(anchor, ".//pic:pic", ns = ns_ext)
    if (!inherits(txbx, "xml_missing") && length(pics) == 0) return(TRUE)
  }
  FALSE
}


#' Check if a paragraph contains a grouped figure (image + caption)
#'
#' Detects `wp:anchor` containing `wpg:wgp` with both `pic:pic` and `wps:txbx`
#' descendants. Handles `mc:AlternateContent/mc:Choice` wrapping (Word always
#' emits grouped shapes inside `mc:Choice Requires="wpg"`).
#'
#' @param para xml2 node for w:p
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @keywords internal
#' @export
is_grouped_figure <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
  )

  # Look for wp:anchor both directly and inside mc:Choice
  anchors <- xml2::xml_find_all(para, ".//wp:anchor", ns = ns_ext)
  if (length(anchors) == 0) return(FALSE)

  for (anchor in anchors) {
    wgp <- xml2::xml_find_first(anchor, ".//wpg:wgp", ns = ns_ext)
    if (inherits(wgp, "xml_missing")) next

    pics <- xml2::xml_find_all(wgp, ".//pic:pic", ns = ns_ext)
    txbx <- xml2::xml_find_first(wgp, ".//wps:txbx", ns = ns_ext)

    if (length(pics) > 0 && !inherits(txbx, "xml_missing")) return(TRUE)
  }
  FALSE
}


#' Extract positioning properties from a grouped figure
#'
#' Reads standard `wp:anchor` positioning plus group-specific internal layout:
#' `caption_y` (from `wps:wsp/wps:spPr/a:xfrm/a:off@y`) and `image_height`
#' (from `pic:pic/pic:spPr/a:xfrm/a:ext@cy`). EMU values are converted to DXA.
#'
#' @param para xml2 node for w:p containing a grouped figure
#' @param ns Named character vector of XML namespaces
#' @return Named list with standard anchor properties plus `caption_y` and
#'   `image_height`, or NULL if `wp:anchor` is missing
#' @keywords internal
#' @export
extract_group_properties <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
  )

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_ext)
  if (inherits(anchor, "xml_missing")) return(NULL)

  # Horizontal position
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_ext)
  relH <- if (!inherits(posH, "xml_missing")) xml2::xml_attr(posH, "relativeFrom") else "margin"
  offsetH <- "0"
  if (!inherits(posH, "xml_missing")) {
    off_node <- xml2::xml_find_first(posH, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      if (!is.na(emu_val)) {
        offsetH <- as.character(as.integer(round(emu_val / 635)))
      }
    }
  }

  # Vertical position
  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_ext)
  relV <- if (!inherits(posV, "xml_missing")) xml2::xml_attr(posV, "relativeFrom") else "text"
  offsetV <- "0"
  if (!inherits(posV, "xml_missing")) {
    off_node <- xml2::xml_find_first(posV, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      if (!is.na(emu_val)) {
        offsetV <- as.character(as.integer(round(emu_val / 635)))
      }
    }
  }

  # Extent (width)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_ext)
  width_dxa <- NULL
  if (!inherits(extent, "xml_missing")) {
    cx <- as.numeric(xml2::xml_attr(extent, "cx"))
    if (!is.na(cx) && cx > 0) {
      width_dxa <- as.character(as.integer(round(cx / 635)))
    }
  }

  # Behind doc
  behind_doc <- xml2::xml_attr(anchor, "behindDoc")
  if (is.na(behind_doc)) behind_doc <- "0"
  z_layer <- if (behind_doc == "1") "behind" else "front"

  # Wrap style
  wrap_style <- "square"
  if (length(xml2::xml_find_all(anchor, "wp:wrapNone", ns = ns_ext)) > 0) wrap_style <- "none"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTopAndBottom", ns = ns_ext)) > 0) wrap_style <- "top-and-bottom"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTight", ns = ns_ext)) > 0) wrap_style <- "tight"

  # Group-specific: caption_y from wps:wsp/wps:spPr/a:xfrm/a:off@y
  caption_y <- NULL
  wsp_off <- xml2::xml_find_first(anchor, ".//wps:wsp/wps:spPr/a:xfrm/a:off", ns = ns_ext)
  if (!inherits(wsp_off, "xml_missing")) {
    y_emu <- as.numeric(xml2::xml_attr(wsp_off, "y"))
    if (!is.na(y_emu)) {
      caption_y <- as.character(as.integer(round(y_emu / 635)))
    }
  }

  # Group-specific: image_height from pic:pic/pic:spPr/a:xfrm/a:ext@cy
  image_height <- NULL
  pic_ext <- xml2::xml_find_first(anchor, ".//pic:pic/pic:spPr/a:xfrm/a:ext", ns = ns_ext)
  if (!inherits(pic_ext, "xml_missing")) {
    cy_emu <- as.numeric(xml2::xml_attr(pic_ext, "cy"))
    if (!is.na(cy_emu)) {
      image_height <- as.character(as.integer(round(cy_emu / 635)))
    }
  }

  list(
    horizontal_anchor = posH_relative_to_css(relH),
    vertical_anchor   = posV_relative_to_css(relV),
    position_x        = offsetH,
    position_y        = offsetV,
    float_width       = width_dxa,
    z_layer           = z_layer,
    wrap_style        = wrap_style,
    caption_y         = caption_y,
    image_height      = image_height
  )
}


#' Extract image and caption content from a grouped figure
#'
#' Returns the image's `r:embed` relationship ID from `a:blip` and
#' the caption `w:p` elements from `wps:txbx/w:txbxContent`.
#' Handles `mc:AlternateContent/mc:Choice` wrapping.
#'
#' @param para xml2 node for w:p containing a grouped figure
#' @param ns Named character vector of XML namespaces
#' @return List with `$image_rel_id` (character) and `$caption_nodes` (xml2 nodeset)
#' @keywords internal
#' @export
extract_group_content <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wpg = "http://schemas.microsoft.com/office/word/2010/wordprocessingGroup",
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main",
    mc = "http://schemas.openxmlformats.org/markup-compatibility/2006",
    r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  )

  # Image rel ID from a:blip inside pic:pic
  blip <- xml2::xml_find_first(para, ".//pic:pic//a:blip", ns = ns_ext)
  image_rel_id <- NA_character_
  if (!inherits(blip, "xml_missing")) {
    embed <- xml2::xml_attr(blip, "embed")
    if (is.na(embed)) embed <- xml2::xml_attr(blip, "r:embed")
    if (!is.na(embed)) image_rel_id <- embed
  }

  # Caption paragraphs from wps:txbx/w:txbxContent
  caption_nodes <- xml2::xml_find_all(para, ".//wps:txbx/w:txbxContent/w:p", ns = ns_ext)

  list(
    image_rel_id = image_rel_id,
    caption_nodes = caption_nodes
  )
}


#' Extract positioning properties from a text box anchor
#'
#' Reads `wp:anchor` attributes and converts to CSS vocabulary.
#' EMU values are converted to DXA for consistency with the field code payload.
#'
#' @param para xml2 node for w:p containing a text box
#' @param ns Named character vector of XML namespaces
#' @return Named list with horizontal_anchor, vertical_anchor, position_x,
#'   position_y, float_width, z_layer, wrap_style. NULL if not a text box.
#' @keywords internal
#' @export
extract_text_box_properties <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape",
    a = "http://schemas.openxmlformats.org/drawingml/2006/main"
  )

  anchor <- xml2::xml_find_first(para, ".//wp:anchor", ns = ns_ext)
  if (inherits(anchor, "xml_missing")) return(NULL)

  # Horizontal position
  posH <- xml2::xml_find_first(anchor, "wp:positionH", ns = ns_ext)
  relH <- if (!inherits(posH, "xml_missing")) xml2::xml_attr(posH, "relativeFrom") else "margin"
  offsetH <- "0"
  if (!inherits(posH, "xml_missing")) {
    off_node <- xml2::xml_find_first(posH, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      if (!is.na(emu_val)) {
        offsetH <- as.character(as.integer(round(emu_val / 635)))
      }
    }
  }

  # Vertical position
  posV <- xml2::xml_find_first(anchor, "wp:positionV", ns = ns_ext)
  relV <- if (!inherits(posV, "xml_missing")) xml2::xml_attr(posV, "relativeFrom") else "text"
  offsetV <- "0"
  if (!inherits(posV, "xml_missing")) {
    off_node <- xml2::xml_find_first(posV, "wp:posOffset", ns = ns_ext)
    if (!inherits(off_node, "xml_missing")) {
      emu_val <- as.numeric(xml2::xml_text(off_node))
      if (!is.na(emu_val)) {
        offsetV <- as.character(as.integer(round(emu_val / 635)))
      }
    }
  }

  # Extent (width)
  extent <- xml2::xml_find_first(anchor, "wp:extent", ns = ns_ext)
  width_dxa <- NULL
  if (!inherits(extent, "xml_missing")) {
    cx <- as.numeric(xml2::xml_attr(extent, "cx"))
    if (!is.na(cx) && cx > 0) {
      width_dxa <- as.character(as.integer(round(cx / 635)))
    } else {
      warning("[anchor-harvest] Could not extract text box width (cx=",
              xml2::xml_attr(extent, "cx"), ")", call. = FALSE)
    }
  }

  # Behind doc
  behind_doc <- xml2::xml_attr(anchor, "behindDoc")
  if (is.na(behind_doc)) behind_doc <- "0"
  z_layer <- if (behind_doc == "1") "behind" else "front"

  # Wrap style
  wrap_style <- "square"
  if (length(xml2::xml_find_all(anchor, "wp:wrapNone", ns = ns_ext)) > 0) wrap_style <- "none"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTopAndBottom", ns = ns_ext)) > 0) wrap_style <- "top-and-bottom"
  if (length(xml2::xml_find_all(anchor, "wp:wrapTight", ns = ns_ext)) > 0) wrap_style <- "tight"

  list(
    horizontal_anchor = posH_relative_to_css(relH),
    vertical_anchor   = posV_relative_to_css(relV),
    position_x        = offsetH,
    position_y        = offsetV,
    float_width       = width_dxa,
    z_layer           = z_layer,
    wrap_style        = wrap_style
  )
}


#' Extract content paragraphs from a text box
#'
#' Returns `w:p` elements inside `wps:txbx/w:txbxContent`.
#'
#' @param para xml2 node for w:p containing a text box
#' @param ns Named character vector of XML namespaces
#' @return xml2 nodeset of w:p elements, or empty nodeset
#' @keywords internal
#' @export
extract_text_box_content <- function(para, ns) {
  ns_ext <- c(ns,
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
    wps = "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
  )
  xml2::xml_find_all(para, ".//wps:txbx/w:txbxContent/w:p", ns = ns_ext)
}


#' Check if a Table is a Floating Table
#'
#' Detects `w:tblpPr` inside the table properties, indicating a floating
#' (positioned) table.
#'
#' @param tbl xml2 node for w:tbl
#' @param ns Named character vector of XML namespaces
#' @return Logical
#' @keywords internal
#' @export
is_floating_table <- function(tbl, ns) {
  tblpPr <- xml2::xml_find_first(tbl, "w:tblPr/w:tblpPr", ns = ns)
  !inherits(tblpPr, "xml_missing")
}


#' Extract Float Positioning Properties from a Table
#'
#' Reads `w:tblpPr` attributes and table width from a floating table.
#'
#' @param tbl xml2 node for w:tbl
#' @param ns Named character vector of XML namespaces
#' @return Named list of positioning properties, or NULL if not floating
#' @keywords internal
#' @export
extract_float_properties <- function(tbl, ns) {
  tblpPr <- xml2::xml_find_first(tbl, "w:tblPr/w:tblpPr", ns = ns)
  if (inherits(tblpPr, "xml_missing")) return(NULL)

  tblW <- xml2::xml_find_first(tbl, "w:tblPr/w:tblW", ns = ns)
  width <- if (!inherits(tblW, "xml_missing")) xml2::xml_attr(tblW, "w") else NULL

  # xml2::xml_attr() returns NA (not NULL) for missing attributes;
  # %||% only checks NULL, so use an NA-aware helper
  na_default <- function(x, default) if (is.na(x)) default else x

  list(
    vertical_anchor  = na_default(xml2::xml_attr(tblpPr, "vertAnchor"), "text"),
    horizontal_anchor = na_default(xml2::xml_attr(tblpPr, "horzAnchor"), "margin"),
    position_y       = na_default(xml2::xml_attr(tblpPr, "tblpY"), "0"),
    position_x       = na_default(xml2::xml_attr(tblpPr, "tblpX"), "0"),
    float_width      = width,
    left_from_text   = na_default(xml2::xml_attr(tblpPr, "leftFromText"), "0"),
    right_from_text  = na_default(xml2::xml_attr(tblpPr, "rightFromText"), "0"),
    top_from_text    = na_default(xml2::xml_attr(tblpPr, "topFromText"), "0"),
    bottom_from_text = na_default(xml2::xml_attr(tblpPr, "bottomFromText"), "0")
  )
}
