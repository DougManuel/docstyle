#' CSS to Word Style Injection
#'
#' Functions for parsing CSS styles and injecting them into Word documents.
#'
#' @name css_injection
#' @keywords internal
NULL


#' Inject CSS Styles into Word Document
#'
#' Parses CSS styles and injects them into the Word document's styles.xml.
#'
#' @param doc officer document
#' @param css_styles Parsed CSS styles (from `read_css()`)
#' @param toc_config Optional TOC configuration from docstyle.toc section.
#'   Used to set tab-leader for TOC styles.
#' @param template_styles Optional character vector of style IDs from a template
#'   DOCX. Styles in this set are excluded from the CSS cascade (template values
#'   are authoritative).
#' @return Modified document
#' @keywords internal
inject_css_styles <- function(doc, css_styles, toc_config = NULL, template_styles = NULL) {
  # Access the styles XML via officer
  pkg_dir <- doc$package_dir
  styles_path <- file.path(pkg_dir, "word", "styles.xml")

  if (!file.exists(styles_path)) {
    warning("styles.xml not found in document")
    return(doc)
  }

  styles_xml <- xml2::read_xml(styles_path)
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

  # Styles that need linked character companions for inline use
  # These can be applied both as paragraph styles and character styles
  # Note: Author and Affiliation are paragraph-only styles, not inline

  linked_styles <- c("Date", "Version")

  for (selector in names(css_styles)) {
    props <- css_styles[[selector]]

    # Map CSS selector to Word style ID/name
    word_style <- map_selector_to_word_style(selector)
    if (is.null(word_style)) next

    # Check if this style needs a linked character companion
    needs_char_style <- word_style$id %in% linked_styles

    # Find or create the style element
    style_xpath <- sprintf("//w:style[@w:styleId='%s']", word_style$id)
    style_node <- xml2::xml_find_first(styles_xml, style_xpath, ns = ns)

    if (inherits(style_node, "xml_missing")) {
      # Style doesn't exist, create it
      styles_root <- xml2::xml_find_first(styles_xml, "//w:styles", ns = ns)
      style_node <- xml2::xml_add_child(styles_root, "w:style")
      xml2::xml_set_attr(style_node, "w:type", "paragraph")
      xml2::xml_set_attr(style_node, "w:styleId", word_style$id)

      # Add name
      name_node <- xml2::xml_add_child(style_node, "w:name")
      xml2::xml_set_attr(name_node, "w:val", word_style$name)

      # Add link to character style if this is a linked style
      if (needs_char_style) {
        char_style_id <- paste0(word_style$id, "Char")
        link_node <- xml2::xml_add_child(style_node, "w:link")
        xml2::xml_set_attr(link_node, "w:val", char_style_id)
      }

      # Add metadata for TOC styles so Word recognizes them properly
      if (grepl("^TOC[0-9]$", word_style$id)) {
        # TOC styles need uiPriority to be recognized
        ui_priority <- xml2::xml_add_child(style_node, "w:uiPriority")
        xml2::xml_set_attr(ui_priority, "w:val", "39")
        xml2::xml_add_child(style_node, "w:unhideWhenUsed")
      }
    } else if (needs_char_style) {
      # Style exists - add link if not present
      link_xpath <- ".//w:link"
      existing_link <- xml2::xml_find_first(style_node, link_xpath, ns = ns)
      if (inherits(existing_link, "xml_missing")) {
        char_style_id <- paste0(word_style$id, "Char")
        # Insert link after name element
        name_node <- xml2::xml_find_first(style_node, ".//w:name", ns = ns)
        if (!inherits(name_node, "xml_missing")) {
          link_node <- xml2::xml_add_sibling(name_node, "w:link", .where = "after")
          xml2::xml_set_attr(link_node, "w:val", char_style_id)
        }
      }
    }

    # Build and inject run properties (rPr)
    # css_to_rPr is defined in css_parser.R
    rPr <- css_to_rPr(props)
    if (length(rPr) > 0) {
      inject_rPr_to_style(style_node, rPr, ns)
    }

    # Create companion character style for linked styles
    if (needs_char_style && length(rPr) > 0) {
      char_style_id <- paste0(word_style$id, "Char")
      char_style_name <- paste0(word_style$name, " Char")

      # Check if character style already exists
      char_style_xpath <- sprintf("//w:style[@w:styleId='%s']", char_style_id)
      char_style_node <- xml2::xml_find_first(styles_xml, char_style_xpath, ns = ns)

      if (inherits(char_style_node, "xml_missing")) {
        # Create the character style
        styles_root <- xml2::xml_find_first(styles_xml, "//w:styles", ns = ns)
        char_style_node <- xml2::xml_add_child(styles_root, "w:style")
        xml2::xml_set_attr(char_style_node, "w:type", "character")
        xml2::xml_set_attr(char_style_node, "w:styleId", char_style_id)

        # Add name
        char_name_node <- xml2::xml_add_child(char_style_node, "w:name")
        xml2::xml_set_attr(char_name_node, "w:val", char_style_name)

        # Link back to paragraph style
        char_link_node <- xml2::xml_add_child(char_style_node, "w:link")
        xml2::xml_set_attr(char_link_node, "w:val", word_style$id)
      }

      # Apply same run properties to character style
      inject_rPr_to_style(char_style_node, rPr, ns)
    }

    # Build and inject paragraph properties (pPr)
    pPr <- css_to_pPr(props)

    # Special handling for TOC styles: add right-aligned tab with configurable leader
    # Based on harvested values from POPCORN_StrategicAdvisoryCommitteeTOR_V1.0.0.docx
    if (grepl("^TOC[0-9]$", word_style$id)) {
      # Add right-aligned tab at 9350 twips (page width minus margins)
      # Leader from toc_config: "dot", "hyphen", "underscore", or "none" (default)
      if (is.null(pPr$tabs)) pPr$tabs <- list()

      # Get tab leader from config (default: none)
      tab_leader <- NULL
      if (!is.null(toc_config) && !is.null(toc_config$`tab-leader`)) {
        leader_val <- tolower(toc_config$`tab-leader`)
        # Map YAML values to Word values
        if (leader_val %in% c("dot", "hyphen", "underscore")) {
          tab_leader <- leader_val
        }
        # "none" or other values = NULL (no leader attribute)
      }

      tab_def <- list(val = "right", pos = "9350")
      if (!is.null(tab_leader)) {
        tab_def$leader <- tab_leader
      }
      pPr$tabs <- c(pPr$tabs, list(tab_def))

      # Set single line spacing with no space after
      if (is.null(pPr$spacing)) pPr$spacing <- list()
      pPr$spacing$line <- 240
      pPr$spacing$lineRule <- "auto"
      pPr$spacing$after <- 0
    }

    if (length(pPr) > 0) {
      inject_pPr_to_style(style_node, pPr, ns)
    }
  }

  # Cascade CSS from parent to child styles that Pandoc overwrites.
  #
  # Pandoc hardcodes pPr/rPr on BodyText (180/180 spacing), Compact (36/36),
  # Heading1-9 (theme fonts + spacing), and Title/Subtitle during rendering,
  # overriding any inherited values from basedOn chains. To ensure CSS takes
  # effect, we must explicitly set CSS-injected properties on these child
  # styles so they survive Pandoc's overwrite.
  #
  # The cascade only copies properties the child doesn't already have from
  # its own CSS rule (i.e., if .compact sets margin-bottom, that wins over
  # the p value). This happens pre-render, so the reference.docx carries
  # these values. Pandoc respects explicit values in the reference.docx —
  # it only injects its hardcoded defaults when the style has no pPr/rPr.
  cascade_css_to_children(styles_xml, ns, css_styles, template_styles = template_styles)

  # Write back the modified styles.xml
  xml2::write_xml(styles_xml, styles_path)

  doc
}


#' Cascade CSS Properties to Child Styles
#'
#' Pandoc hardcodes pPr/rPr on certain styles (BodyText, Compact, Heading1-9,
#' Title, Subtitle) during rendering, overriding OOXML basedOn inheritance.
#' If a parent style (e.g., Normal) received CSS properties but a child
#' (e.g., BodyText) did not get its own CSS rule, the child's pPr/rPr will
#' be empty in the reference.docx, and Pandoc will replace them with hardcoded
#' values.
#'
#' This function copies the parent's CSS-injected pPr/rPr onto children that
#' don't have their own, so Pandoc preserves the CSS values instead of
#' injecting defaults.
#'
#' @param styles_xml XML document (styles.xml)
#' @param ns XML namespaces
#' @param css_styles Parsed CSS styles used for injection
#' @param template_styles Optional character vector of template style IDs to
#'   skip during cascade.
#' @keywords internal
cascade_css_to_children <- function(styles_xml, ns, css_styles, template_styles = NULL) {
  # Build set of style IDs that received their own CSS rules
  css_styled_ids <- character(0)
  for (selector in names(css_styles)) {
    word_style <- map_selector_to_word_style(selector)
    if (!is.null(word_style)) {
      css_styled_ids <- c(css_styled_ids, word_style$id)
    }
  }

  # Define basedOn chains: parent -> children that Pandoc overwrites
  # Only cascade to styles that Pandoc is known to hardcode values on
  cascade_chains <- list(
    Normal = c("BodyText", "Heading1", "Heading2", "Heading3", "Heading4",
               "Heading5", "Heading6", "Heading7", "Heading8", "Heading9",
               "Title", "FootnoteText", "Bibliography", "Caption",
               "DefinitionTerm", "Definition"),
    BodyText = c("FirstParagraph", "Compact", "BlockText"),
    Title = c("Subtitle"),
    Caption = c("TableCaption", "ImageCaption")
  )

  for (parent_id in names(cascade_chains)) {
    # Get parent style's pPr and rPr from the XML (after CSS injection)
    parent_xpath <- sprintf("//w:style[@w:styleId='%s']", parent_id)
    parent_node <- xml2::xml_find_first(styles_xml, parent_xpath, ns = ns)
    if (inherits(parent_node, "xml_missing")) next

    parent_pPr <- xml2::xml_find_first(parent_node, "w:pPr", ns = ns)
    parent_rPr <- xml2::xml_find_first(parent_node, "w:rPr", ns = ns)

    # Nothing to cascade if parent has no properties
    has_pPr <- !inherits(parent_pPr, "xml_missing")
    has_rPr <- !inherits(parent_rPr, "xml_missing")
    if (!has_pPr && !has_rPr) next

    for (child_id in cascade_chains[[parent_id]]) {
      # Skip children that got their own CSS rule
      if (child_id %in% css_styled_ids) next

      # Skip children that exist in the template — template values are authoritative
      if (!is.null(template_styles) && child_id %in% template_styles) next

      child_xpath <- sprintf("//w:style[@w:styleId='%s']", child_id)
      child_node <- xml2::xml_find_first(styles_xml, child_xpath, ns = ns)
      if (inherits(child_node, "xml_missing")) {
        message("[css-cascade] Style '", child_id,
                "' not found in styles.xml, skipping cascade from '",
                parent_id, "'")
        next
      }

      # Cascade pPr: copy spacing, jc, ind from parent if child has none.
      # Pandoc injects hardcoded defaults (e.g., 180/180 on BodyText) when
      # a style has no explicit spacing. To prevent this, we ensure every
      # cascaded child has explicit before/after values — defaulting to 0
      # if the parent CSS didn't set margins.
      if (has_pPr) {
        child_pPr <- xml2::xml_find_first(child_node, "w:pPr", ns = ns)
        if (inherits(child_pPr, "xml_missing")) {
          child_pPr <- xml2::xml_add_child(child_node, "w:pPr")
        }

        # Copy spacing if child doesn't have it
        child_spacing <- xml2::xml_find_first(child_pPr, "w:spacing", ns = ns)
        if (inherits(child_spacing, "xml_missing")) {
          parent_spacing <- xml2::xml_find_first(parent_pPr, "w:spacing", ns = ns)
          if (!inherits(parent_spacing, "xml_missing")) {
            xml2::xml_add_child(child_pPr, parent_spacing)
            # Re-find the child spacing we just added
            child_spacing <- xml2::xml_find_first(child_pPr, "w:spacing", ns = ns)
          } else {
            # Parent has pPr but no spacing — create explicit zero spacing
            # to prevent Pandoc from injecting its hardcoded defaults
            child_spacing <- xml2::xml_add_child(child_pPr, "w:spacing")
          }
          # Ensure before/after are explicit (Pandoc fills in defaults if missing)
          if (!inherits(child_spacing, "xml_missing")) {
            if (is.na(xml2::xml_attr(child_spacing, "before"))) {
              xml2::xml_set_attr(child_spacing, "w:before", "0")
            }
            if (is.na(xml2::xml_attr(child_spacing, "after"))) {
              xml2::xml_set_attr(child_spacing, "w:after", "0")
            }
          }
        }

        # Copy jc (alignment) if child doesn't have it
        child_jc <- xml2::xml_find_first(child_pPr, "w:jc", ns = ns)
        if (inherits(child_jc, "xml_missing")) {
          parent_jc <- xml2::xml_find_first(parent_pPr, "w:jc", ns = ns)
          if (!inherits(parent_jc, "xml_missing")) {
            xml2::xml_add_child(child_pPr, parent_jc)
          }
        }

        # Copy ind (indentation) if child doesn't have it
        child_ind <- xml2::xml_find_first(child_pPr, "w:ind", ns = ns)
        if (inherits(child_ind, "xml_missing")) {
          parent_ind <- xml2::xml_find_first(parent_pPr, "w:ind", ns = ns)
          if (!inherits(parent_ind, "xml_missing")) {
            xml2::xml_add_child(child_pPr, parent_ind)
          }
        }
      }

      # Cascade rPr: copy font, size, colour from parent if child has none
      if (has_rPr) {
        child_rPr <- xml2::xml_find_first(child_node, "w:rPr", ns = ns)
        if (inherits(child_rPr, "xml_missing")) {
          child_rPr <- xml2::xml_add_child(child_node, "w:rPr")
        }

        # Copy rFonts if child doesn't have it
        child_fonts <- xml2::xml_find_first(child_rPr, "w:rFonts", ns = ns)
        if (inherits(child_fonts, "xml_missing")) {
          parent_fonts <- xml2::xml_find_first(parent_rPr, "w:rFonts", ns = ns)
          if (!inherits(parent_fonts, "xml_missing")) {
            xml2::xml_add_child(child_rPr, parent_fonts)
          }
        }

        # Copy sz (font size) if child doesn't have it
        child_sz <- xml2::xml_find_first(child_rPr, "w:sz", ns = ns)
        if (inherits(child_sz, "xml_missing")) {
          parent_sz <- xml2::xml_find_first(parent_rPr, "w:sz", ns = ns)
          if (!inherits(parent_sz, "xml_missing")) {
            xml2::xml_add_child(child_rPr, parent_sz)
          }
        }

        # Copy szCs if child doesn't have it
        child_szCs <- xml2::xml_find_first(child_rPr, "w:szCs", ns = ns)
        if (inherits(child_szCs, "xml_missing")) {
          parent_szCs <- xml2::xml_find_first(parent_rPr, "w:szCs", ns = ns)
          if (!inherits(parent_szCs, "xml_missing")) {
            xml2::xml_add_child(child_rPr, parent_szCs)
          }
        }

        # Copy color if child doesn't have it
        child_color <- xml2::xml_find_first(child_rPr, "w:color", ns = ns)
        if (inherits(child_color, "xml_missing")) {
          parent_color <- xml2::xml_find_first(parent_rPr, "w:color", ns = ns)
          if (!inherits(parent_color, "xml_missing")) {
            xml2::xml_add_child(child_rPr, parent_color)
          }
        }

        # Copy bold if child doesn't have it
        child_b <- xml2::xml_find_first(child_rPr, "w:b", ns = ns)
        if (inherits(child_b, "xml_missing")) {
          parent_b <- xml2::xml_find_first(parent_rPr, "w:b", ns = ns)
          if (!inherits(parent_b, "xml_missing")) {
            xml2::xml_add_child(child_rPr, parent_b)
          }
        }

        # Copy italic if child doesn't have it
        child_i <- xml2::xml_find_first(child_rPr, "w:i", ns = ns)
        if (inherits(child_i, "xml_missing")) {
          parent_i <- xml2::xml_find_first(parent_rPr, "w:i", ns = ns)
          if (!inherits(parent_i, "xml_missing")) {
            xml2::xml_add_child(child_rPr, parent_i)
          }
        }
      }
    }
  }
}


#' Map CSS Selector to Word Style
#'
#' @param selector CSS selector
#' @return List with id and name, or NULL if unmappable
#' @keywords internal
map_selector_to_word_style <- function(selector) {
  sel <- trimws(tolower(selector))

  # Standard mappings
  if (sel == "h1") return(list(id = "Heading1", name = "heading 1"))
  if (sel == "h2") return(list(id = "Heading2", name = "heading 2"))
  if (sel == "h3") return(list(id = "Heading3", name = "heading 3"))
  if (sel == "h4") return(list(id = "Heading4", name = "heading 4"))
  if (sel == "h5") return(list(id = "Heading5", name = "heading 5"))
  if (sel == "h6") return(list(id = "Heading6", name = "heading 6"))
  if (sel == "h7") return(list(id = "Heading7", name = "heading 7"))
  if (sel == "h8") return(list(id = "Heading8", name = "heading 8"))
  if (sel == "h9") return(list(id = "Heading9", name = "heading 9"))
  if (sel == "p" || sel == "body") return(list(id = "Normal", name = "Normal"))
  if (sel == ".title") return(list(id = "Title", name = "Title"))
  if (sel == ".subtitle") return(list(id = "Subtitle", name = "Subtitle"))
  if (sel == ".author") return(list(id = "Author", name = "Author"))
  if (sel == ".affiliation") return(list(id = "Affiliation", name = "Affiliation"))
  if (sel == ".date") return(list(id = "Date", name = "Date"))
  if (sel == ".version") return(list(id = "Version", name = "Version"))
  if (sel == ".abstract") return(list(id = "Abstract", name = "Abstract"))
  if (sel == ".abstract-title") return(list(id = "AbstractTitle", name = "Abstract Title"))
  if (sel == "blockquote" || sel == ".blockquote") return(list(id = "BlockText", name = "Block Text"))
  if (sel == "code" || sel == ".code") return(list(id = "SourceCode", name = "Source Code"))

  # Pandoc body text styles (basedOn Normal — CSS on p cascades via OOXML
  # inheritance, but these selectors allow explicit overrides)
  if (sel == ".body-text") return(list(id = "BodyText", name = "Body Text"))
  if (sel == ".first-paragraph") return(list(id = "FirstParagraph", name = "First Paragraph"))
  if (sel == ".compact") return(list(id = "Compact", name = "Compact"))

  # Caption styles
  if (sel == "caption" || sel == ".caption") return(list(id = "Caption", name = "Caption"))
  if (sel == ".table-caption") return(list(id = "TableCaption", name = "Table Caption"))
  if (sel == ".image-caption") return(list(id = "ImageCaption", name = "Image Caption"))

  # Bibliography
  if (sel == ".bibliography" || sel == ".references") {
    return(list(id = "Bibliography", name = "Bibliography"))
  }

  # Figure styles
  if (sel == ".figure") return(list(id = "Figure", name = "Figure"))
  if (sel == ".captioned-figure") return(list(id = "CaptionedFigure", name = "Captioned Figure"))

  # Definition list styles
  if (sel == "dt" || sel == ".definition-term") {
    return(list(id = "DefinitionTerm", name = "Definition Term"))
  }
  if (sel == "dd" || sel == ".definition") {
    return(list(id = "Definition", name = "Definition"))
  }

  # Table of Contents styles
  # Word uses "TOC 1", "TOC 2", etc. for TOC entries
  if (sel == ".toc-heading") return(list(id = "TOCHeading", name = "TOC Heading"))
  if (sel == ".toc-1") return(list(id = "TOC1", name = "toc 1"))
  if (sel == ".toc-2") return(list(id = "TOC2", name = "toc 2"))
  if (sel == ".toc-3") return(list(id = "TOC3", name = "toc 3"))
  if (sel == ".toc-4") return(list(id = "TOC4", name = "toc 4"))
  if (sel == ".toc-5") return(list(id = "TOC5", name = "toc 5"))

  # Footnote styles
  if (sel == ".footnote-text") return(list(id = "FootnoteText", name = "footnote text"))

  # Custom class styles
  if (grepl("^\\.", sel)) {
    class_name <- substring(sel, 2)
    # Capitalize for display name
    name <- paste0(toupper(substring(class_name, 1, 1)), substring(class_name, 2))
    return(list(id = class_name, name = name, is_custom = TRUE))
  }

  NULL
}


#' Convert CSS Properties to Word Paragraph Properties
#'
#' @param css_props Named list of CSS properties
#' @return List of Word paragraph properties
#' @keywords internal
css_to_pPr <- function(css_props) {
  pPr <- list()

  # Text align -> w:jc
  if (!is.null(css_props[["text-align"]])) {
    val <- css_props[["text-align"]]
    # Map CSS values to Word values
    # CSS: left, right, center, justify
    # Word: left, right, center, both
    if (val == "justify") val <- "both"
    pPr$jc <- val
  }

  # Line height -> w:spacing
  if (!is.null(css_props[["line-height"]])) {
    val <- css_props[["line-height"]]
    # Check if it's a number (multiplier)
    if (suppressWarnings(!is.na(as.numeric(val)))) {
      # Word uses 240ths of a line for auto spacing
      # e.g. 1.5 -> 360
      line_val <- round(as.numeric(val) * 240)
      pPr$spacing <- list(line = line_val, lineRule = "auto")
    } else {
      # Handle units like pt, px?
      # For now, ignore unit-based line-height to avoid complexity
      warning("Unit-based line-height not supported yet: ", val)
    }
  }

  # Margins (top/bottom) -> w:spacing before/after
  # margin-left and padding-left map to w:ind left; margin-right not yet supported
  if (!is.null(css_props[["margin-top"]])) {
    # Convert to twips
    before <- css_to_twips(css_props[["margin-top"]])
    if (is.null(pPr$spacing)) pPr$spacing <- list()
    pPr$spacing$before <- before
  }

  if (!is.null(css_props[["margin-bottom"]])) {
    # Convert to twips
    after <- css_to_twips(css_props[["margin-bottom"]])
    if (is.null(pPr$spacing)) pPr$spacing <- list()
    pPr$spacing$after <- after
  }

  # Indentation: margin-left -> w:ind left
  if (!is.null(css_props[["margin-left"]])) {
    left <- css_to_twips(css_props[["margin-left"]])
    if (is.null(pPr$ind)) pPr$ind <- list()
    pPr$ind$left <- left
  }

  # Padding-left can also map to indentation
  if (!is.null(css_props[["padding-left"]])) {
    left <- css_to_twips(css_props[["padding-left"]])
    if (is.null(pPr$ind)) pPr$ind <- list()
    pPr$ind$left <- left
  }

  # Background colour -> w:shd fill
  if (!is.null(css_props[["background-color"]])) {
    color <- css_to_ooxml_color(css_props[["background-color"]])
    if (color != "auto") {
      pPr$shd <- color
    }
  }

  # Border sides -> w:pBdr
  for (side in c("top", "bottom", "left", "right")) {
    prop <- paste0("border-", side)
    if (!is.null(css_props[[prop]])) {
      border <- parse_css_border(css_props[[prop]])
      if (!is.null(border)) {
        if (is.null(pPr$pBdr)) pPr$pBdr <- list()
        pPr$pBdr[[side]] <- border
      }
    }
  }

  # Shorthand border applies to all sides not already set
  if (!is.null(css_props[["border"]])) {
    shorthand <- parse_css_border(css_props[["border"]])
    if (!is.null(shorthand)) {
      if (is.null(pPr$pBdr)) pPr$pBdr <- list()
      for (side in c("top", "bottom", "left", "right")) {
        if (is.null(pPr$pBdr[[side]])) pPr$pBdr[[side]] <- shorthand
      }
    }
  }

  pPr
}


#' Inject Paragraph Properties into Style Node
#'
#' @param style_node XML style node
#' @param pPr List of paragraph properties
#' @param ns XML namespaces
#' @keywords internal
inject_pPr_to_style <- function(style_node, pPr, ns) {
  # Find or create pPr element
  pPr_node <- xml2::xml_find_first(style_node, "w:pPr", ns = ns)

  if (inherits(pPr_node, "xml_missing")) {
    pPr_node <- xml2::xml_add_child(style_node, "w:pPr")
  }

  # Alignment (w:jc)
  if (!is.null(pPr$jc)) {
    jc_node <- xml2::xml_find_first(pPr_node, "w:jc", ns = ns)
    if (inherits(jc_node, "xml_missing")) {
      jc_node <- xml2::xml_add_child(pPr_node, "w:jc")
    }
    xml2::xml_set_attr(jc_node, "w:val", pPr$jc)
  }

  # Spacing (line height, margins)
  if (!is.null(pPr$spacing)) {
    spacing_node <- xml2::xml_find_first(pPr_node, "w:spacing", ns = ns)
    if (inherits(spacing_node, "xml_missing")) {
      spacing_node <- xml2::xml_add_child(pPr_node, "w:spacing")
    }

    # Line height
    if (!is.null(pPr$spacing$line)) {
      xml2::xml_set_attr(spacing_node, "w:line", pPr$spacing$line)
      if (!is.null(pPr$spacing$lineRule)) {
        xml2::xml_set_attr(spacing_node, "w:lineRule", pPr$spacing$lineRule)
      }
    }

    # Before/After (margins)
    if (!is.null(pPr$spacing$before)) {
      xml2::xml_set_attr(spacing_node, "w:before", pPr$spacing$before)
    }
    if (!is.null(pPr$spacing$after)) {
      xml2::xml_set_attr(spacing_node, "w:after", pPr$spacing$after)
    }
  }

  # Indentation (w:ind)
  if (!is.null(pPr$ind)) {
    ind_node <- xml2::xml_find_first(pPr_node, "w:ind", ns = ns)
    if (inherits(ind_node, "xml_missing")) {
      ind_node <- xml2::xml_add_child(pPr_node, "w:ind")
    }
    if (!is.null(pPr$ind$left)) {
      xml2::xml_set_attr(ind_node, "w:left", pPr$ind$left)
    }
    if (!is.null(pPr$ind$right)) {
      xml2::xml_set_attr(ind_node, "w:right", pPr$ind$right)
    }
    if (!is.null(pPr$ind$hanging)) {
      xml2::xml_set_attr(ind_node, "w:hanging", pPr$ind$hanging)
    }
    if (!is.null(pPr$ind$firstLine)) {
      xml2::xml_set_attr(ind_node, "w:firstLine", pPr$ind$firstLine)
    }
  }

  # Paragraph borders (w:pBdr) — must precede w:shd and w:ind per ECMA-376 §17.3.1.26
  if (!is.null(pPr$pBdr) && length(pPr$pBdr) > 0) {
    pBdr_node <- xml2::xml_find_first(pPr_node, "w:pBdr", ns = ns)
    if (!inherits(pBdr_node, "xml_missing")) xml2::xml_remove(pBdr_node)
    insert_before <- xml2::xml_find_first(pPr_node, "w:shd|w:tabs|w:ind", ns = ns)
    if (inherits(insert_before, "xml_missing")) {
      pBdr_node <- xml2::xml_add_child(pPr_node, "w:pBdr")
    } else {
      pBdr_node <- xml2::xml_add_sibling(insert_before, "w:pBdr", .where = "before")
    }
    for (side in c("top", "bottom", "left", "right")) {
      b <- pPr$pBdr[[side]]
      if (!is.null(b)) {
        side_node <- xml2::xml_add_child(pBdr_node, paste0("w:", side))
        xml2::xml_set_attr(side_node, "w:val", b$val %||% "single")
        xml2::xml_set_attr(side_node, "w:sz",  b$sz  %||% "4")
        xml2::xml_set_attr(side_node, "w:space", "0")
        xml2::xml_set_attr(side_node, "w:color", b$color %||% "auto")
      }
    }
  }

  # Paragraph shading (w:shd) — must precede w:tabs and w:ind per ECMA-376 §17.3.1.26
  if (!is.null(pPr$shd)) {
    shd_node <- xml2::xml_find_first(pPr_node, "w:shd", ns = ns)
    if (!inherits(shd_node, "xml_missing")) xml2::xml_remove(shd_node)
    insert_before <- xml2::xml_find_first(pPr_node, "w:tabs|w:ind", ns = ns)
    if (inherits(insert_before, "xml_missing")) {
      shd_node <- xml2::xml_add_child(pPr_node, "w:shd")
    } else {
      shd_node <- xml2::xml_add_sibling(insert_before, "w:shd", .where = "before")
    }
    xml2::xml_set_attr(shd_node, "w:val", "clear")
    xml2::xml_set_attr(shd_node, "w:color", "auto")
    xml2::xml_set_attr(shd_node, "w:fill", pPr$shd)
  }

  # Tabs (w:tabs)
  if (!is.null(pPr$tabs) && length(pPr$tabs) > 0) {
    tabs_node <- xml2::xml_find_first(pPr_node, "w:tabs", ns = ns)
    if (inherits(tabs_node, "xml_missing")) {
      tabs_node <- xml2::xml_add_child(pPr_node, "w:tabs")
    }
    for (tab in pPr$tabs) {
      tab_node <- xml2::xml_add_child(tabs_node, "w:tab")
      xml2::xml_set_attr(tab_node, "w:val", tab$val %||% "left")
      xml2::xml_set_attr(tab_node, "w:pos", tab$pos)
      # Only add leader if specified (no leader = no dots)
      if (!is.null(tab$leader)) {
        xml2::xml_set_attr(tab_node, "w:leader", tab$leader)
      }
    }
  }
}


#' Inject Run Properties into Style Node
#'
#' Handles rPr format from css_parser.R where properties are lists
#' (e.g., `rPr$b <- list()` for bold, `rPr$sz <- list(val = "24")`).
#'
#' @param style_node XML style node
#' @param rPr List of run properties from css_to_rPr()
#' @param ns XML namespaces
#' @keywords internal
inject_rPr_to_style <- function(style_node, rPr, ns) {
  # Find or create rPr element
  rPr_node <- xml2::xml_find_first(style_node, "w:rPr", ns = ns)

  if (inherits(rPr_node, "xml_missing")) {
    rPr_node <- xml2::xml_add_child(style_node, "w:rPr")
  }

  # Font family
  if (!is.null(rPr$rFonts)) {
    fonts_node <- xml2::xml_find_first(rPr_node, "w:rFonts", ns = ns)
    # Remove existing fonts node (to clear theme attributes) and create fresh
    if (!inherits(fonts_node, "xml_missing")) {
      xml2::xml_remove(fonts_node)
    }
    fonts_node <- xml2::xml_add_child(rPr_node, "w:rFonts", .where = 0)
    # Set explicit font names (no theme attributes)
    xml2::xml_set_attr(fonts_node, "w:ascii", rPr$rFonts$ascii)
    xml2::xml_set_attr(fonts_node, "w:hAnsi", rPr$rFonts$hAnsi)
    if (!is.null(rPr$rFonts$eastAsia)) {
      xml2::xml_set_attr(fonts_node, "w:eastAsia", rPr$rFonts$eastAsia)
    }
    if (!is.null(rPr$rFonts$cs)) {
      xml2::xml_set_attr(fonts_node, "w:cs", rPr$rFonts$cs)
    }
  }

  # Font size - css_parser.R returns list(val = "24")
  if (!is.null(rPr$sz)) {
    sz_node <- xml2::xml_find_first(rPr_node, "w:sz", ns = ns)
    if (inherits(sz_node, "xml_missing")) {
      sz_node <- xml2::xml_add_child(rPr_node, "w:sz")
    }
    sz_val <- if (is.list(rPr$sz)) rPr$sz$val else rPr$sz
    xml2::xml_set_attr(sz_node, "w:val", sz_val)
  }

  # Complex script font size
  if (!is.null(rPr$szCs)) {
    szCs_node <- xml2::xml_find_first(rPr_node, "w:szCs", ns = ns)
    if (inherits(szCs_node, "xml_missing")) {
      szCs_node <- xml2::xml_add_child(rPr_node, "w:szCs")
    }
    szCs_val <- if (is.list(rPr$szCs)) rPr$szCs$val else rPr$szCs
    xml2::xml_set_attr(szCs_node, "w:val", szCs_val)
  }

  # Colour - css_parser.R returns list(val = "FF0000")
  if (!is.null(rPr$color)) {
    color_node <- xml2::xml_find_first(rPr_node, "w:color", ns = ns)
    # Remove existing color node (to clear themeColor) and create fresh
    if (!inherits(color_node, "xml_missing")) {
      xml2::xml_remove(color_node)
    }
    color_node <- xml2::xml_add_child(rPr_node, "w:color")
    color_val <- if (is.list(rPr$color)) rPr$color$val else rPr$color
    xml2::xml_set_attr(color_node, "w:val", color_val)
  }

  # Bold - css_parser.R returns list() for on, list(val = "0") for off
  if (!is.null(rPr$b)) {
    b_node <- xml2::xml_find_first(rPr_node, "w:b", ns = ns)
    if (is.list(rPr$b) && !is.null(rPr$b$val) && rPr$b$val == "0") {
      # Explicitly off - remove if present
      if (!inherits(b_node, "xml_missing")) {
        xml2::xml_remove(b_node)
      }
    } else {
      # On (empty list or TRUE)
      if (inherits(b_node, "xml_missing")) {
        xml2::xml_add_child(rPr_node, "w:b")
      }
    }
  }

  # Italic - same pattern as bold
  if (!is.null(rPr$i)) {
    i_node <- xml2::xml_find_first(rPr_node, "w:i", ns = ns)
    if (is.list(rPr$i) && !is.null(rPr$i$val) && rPr$i$val == "0") {
      if (!inherits(i_node, "xml_missing")) {
        xml2::xml_remove(i_node)
      }
    } else {
      if (inherits(i_node, "xml_missing")) {
        xml2::xml_add_child(rPr_node, "w:i")
      }
    }
  }

  # Underline
  if (!is.null(rPr$u)) {
    u_node <- xml2::xml_find_first(rPr_node, "w:u", ns = ns)
    if (inherits(u_node, "xml_missing")) {
      u_node <- xml2::xml_add_child(rPr_node, "w:u")
    }
    u_val <- if (is.list(rPr$u)) rPr$u$val else rPr$u
    xml2::xml_set_attr(u_node, "w:val", u_val)
  }

  # Strikethrough
  if (!is.null(rPr$strike)) {
    strike_node <- xml2::xml_find_first(rPr_node, "w:strike", ns = ns)
    if (inherits(strike_node, "xml_missing")) {
      xml2::xml_add_child(rPr_node, "w:strike")
    }
  }
}


#' Parse CSS Font Shorthand
#'
#' @param font_str The font shorthand string
#' @return List with weight, size, family components
#' @keywords internal
parse_font_shorthand <- function(font_str) {
  result <- list()
  if (is.null(font_str) || font_str == "") return(result)

  # Extract font-weight
  weight_match <- regexpr("\\b(normal|bold|bolder|lighter|[1-9]00)\\b", font_str)
  if (weight_match > 0) {
    result$weight <- regmatches(font_str, weight_match)
  }

  # Extract font-size
  size_match <- regexpr("[0-9]+\\.?[0-9]*(px|pt|em|rem|%)", font_str)
  if (size_match > 0) {
    result$size <- regmatches(font_str, size_match)
  }

  # Extract font-family (everything after size)
  family_match <- regexpr("[0-9]+\\.?[0-9]*(px|pt|em|rem|%)\\s+(.+)$", font_str, perl = TRUE)
  if (family_match > 0) {
    full_match <- regmatches(font_str, family_match)
    family_part <- sub("^[0-9]+\\.?[0-9]*(px|pt|em|rem|%)\\s+", "", full_match)
    result$family <- trimws(family_part)
  }

  result
}


#' Preview how CSS selectors map to Word styles
#'
#' Dry-run the CSS-to-Word style translation pipeline without rendering a
#' document. Reads a CSS file (or uses the docstyle default), maps each
#' selector to its Word style equivalent, and summarizes the translated
#' properties in human-readable form.
#'
#' Useful for debugging CSS configurations and understanding how CSS properties
#' will appear in the final Word document.
#'
#' @param css_path Path to a CSS file, or NULL to use the extension's
#'   `default.css`. Accepts a character vector of multiple paths (merged in
#'   order, later files win).
#' @param project_dir Path to the project directory, used to resolve relative
#'   CSS paths. Defaults to the current working directory.
#'
#' @return Invisibly returns a list of style mappings. Each element has:
#'   - `selector`: the CSS selector
#'   - `word_style`: the mapped Word style name (or `"(unmapped)"`)
#'   - `word_style_id`: the Word style ID
#'   - `properties`: named character vector of CSS properties
#'   - `pPr`: translated paragraph properties (list)
#'   - `rPr`: translated run properties (list)
#' Prints a formatted summary to the console.
#'
#' @examples
#' \dontrun{
#' # Preview default CSS
#' preview_css_mapping()
#'
#' # Preview a project CSS file
#' preview_css_mapping("styles.css")
#'
#' # Preview multiple CSS files (merged)
#' preview_css_mapping(c("base.css", "overrides.css"))
#' }
#'
#' @export
preview_css_mapping <- function(css_path = NULL, project_dir = ".") {
  project_dir <- normalizePath(project_dir, mustWork = FALSE)

  # Resolve CSS paths
  if (is.null(css_path)) {
    default_css <- system.file("_extensions", "docstyle", "default.css",
                               package = "docstyle")
    if (!nzchar(default_css) || !file.exists(default_css)) {
      stop("default.css not found in docstyle package installation.", call. = FALSE)
    }
    css_paths <- default_css
    cat("Previewing: default.css (built-in)\n\n")
  } else {
    css_paths <- vapply(css_path, function(p) {
      full <- if (file.exists(p)) p else file.path(project_dir, p)
      if (!file.exists(full)) stop("CSS file not found: ", p, call. = FALSE)
      normalizePath(full)
    }, character(1))
    cat("Previewing:", paste(basename(css_paths), collapse = " + "), "\n\n")
  }

  # Parse CSS
  css_styles <- read_css(css_paths)

  if (length(css_styles) == 0) {
    cat("No CSS rules found.\n")
    return(invisible(list()))
  }

  # Build mapping for each selector
  results <- lapply(names(css_styles), function(sel) {
    props  <- css_styles[[sel]]
    mapped <- map_selector_to_word_style(sel)
    pPr    <- tryCatch(css_to_pPr(props), error = function(e) list())
    rPr    <- tryCatch(css_to_rPr(props), error = function(e) list())

    list(
      selector      = sel,
      word_style    = if (is.null(mapped)) "(unmapped)" else mapped$name,
      word_style_id = if (is.null(mapped)) NA_character_ else mapped$id,
      properties    = props,
      pPr           = pPr,
      rPr           = rPr
    )
  })
  names(results) <- names(css_styles)

  # Print summary
  for (r in results) {
    cat(sprintf("%-30s  ->  %s\n", r$selector, r$word_style))

    prop_lines <- character()

    # Paragraph properties
    if (!is.null(r$pPr$spacing)) {
      sp <- r$pPr$spacing
      if (!is.null(sp$before))
        prop_lines <- c(prop_lines,
          sprintf("  margin-top:    %s pt  (w:spacing before=%s twips)",
                  round(as.numeric(sp$before) / 20, 1), sp$before))
      if (!is.null(sp$after))
        prop_lines <- c(prop_lines,
          sprintf("  margin-bottom: %s pt  (w:spacing after=%s twips)",
                  round(as.numeric(sp$after) / 20, 1), sp$after))
      if (!is.null(sp$line))
        prop_lines <- c(prop_lines,
          sprintf("  line-height:   w:line=%s (%s)",
                  sp$line, sp$lineRule %||% "auto"))
    }
    if (!is.null(r$pPr$ind)) {
      ind <- r$pPr$ind
      if (!is.null(ind$left))
        prop_lines <- c(prop_lines,
          sprintf("  margin-left:   %s pt  (w:ind left=%s twips)",
                  round(as.numeric(ind$left) / 20, 1), ind$left))
    }
    if (!is.null(r$pPr$jc))
      prop_lines <- c(prop_lines,
        sprintf("  text-align:    %s", r$pPr$jc))
    if (!is.null(r$pPr$shd))
      prop_lines <- c(prop_lines,
        sprintf("  background:    #%s  (w:shd fill)", r$pPr$shd))
    if (!is.null(r$pPr$pBdr)) {
      for (side in c("top", "bottom", "left", "right")) {
        b <- r$pPr$pBdr[[side]]
        if (!is.null(b))
          prop_lines <- c(prop_lines,
            sprintf("  border-%s:    %s %s #%s  (w:pBdr)",
                    side, b$val, b$sz, b$color))
      }
    }

    # Run properties
    if (!is.null(r$rPr$rFonts))
      prop_lines <- c(prop_lines,
        sprintf("  font-family:   %s", r$rPr$rFonts$ascii %||% "(inherited)"))
    if (!is.null(r$rPr$sz))
      prop_lines <- c(prop_lines,
        sprintf("  font-size:     %s pt  (w:sz=%s half-points)",
                as.numeric(r$rPr$sz$val) / 2, r$rPr$sz$val))
    if (!is.null(r$rPr$color))
      prop_lines <- c(prop_lines,
        sprintf("  color:         #%s", r$rPr$color$val))
    if (!is.null(r$rPr$b))
      prop_lines <- c(prop_lines,
        sprintf("  font-weight:   %s", if (is.null(r$rPr$b$val)) "bold" else "normal"))
    if (!is.null(r$rPr$i))
      prop_lines <- c(prop_lines,
        sprintf("  font-style:    %s", if (is.null(r$rPr$i$val)) "italic" else "normal"))

    if (length(prop_lines) > 0) {
      cat(prop_lines, sep = "\n")
      cat("\n")
    }
  }

  # Unmapped selectors summary
  unmapped <- Filter(function(r) r$word_style == "(unmapped)", results)
  if (length(unmapped) > 0) {
    cat(sprintf("Note: %d selector(s) not mapped to a Word style: %s\n",
                length(unmapped),
                paste(names(unmapped), collapse = ", ")))
  }

  invisible(results)
}
