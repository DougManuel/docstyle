#' Extract Zotero Citations from Word Document
#'
#' Extracts embedded Zotero/CSL citation data from a .docx file and writes
#' two output files:
#' - `references.json`: Clean CSL-JSON array for Pandoc/Quarto
#' - `field-codes.json`: Zotero metadata for round-trip field code injection,
#'   including ZOTERO_PREF for preserving Zotero document preferences
#'
#' @param docx_path Path to the input .docx file
#' @param output_dir Directory for output files (default: same directory as input)
#' @param merge If TRUE and field-codes.json exists, new citations are merged
#'   with existing ones rather than overwriting. Used during re-harvest of
#'   collaborator edits (via `docx_to_qmd()`). The post-render hook does not
#'   call this function — `field-codes.json` is immutable from the render
#'   pipeline's perspective.
#' @param verbose If TRUE, print progress messages. Default FALSE.
#'
#' @return Invisibly returns a list with:
#'   - `references_path`: Path to the generated references.json
#'   - `field_codes_path`: Path to the generated field-codes.json
#'   - `citations`: List of CSL-JSON citation data (keyed by citekey)
#'   - `citation_map`: Named list mapping formatted citations to Quarto syntax
#'   - `cite_keys`: Named list mapping Zotero item IDs to generated cite keys
#'   - `zotero_pref`: ZOTERO_PREF data if present (NULL otherwise)
#' @export
extract_citations <- function(docx_path, output_dir = NULL, merge = FALSE,
                              verbose = FALSE) {

  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Default output directory
  if (is.null(output_dir)) {
    output_dir <- dirname(docx_path)
  }

  # Ensure output directory exists
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Output file paths
  references_path <- file.path(output_dir, "references.json")
  field_codes_path <- file.path(output_dir, "field-codes.json")

  # Extract and parse document XML (with automatic temp cleanup)
  doc_text <- with_docx_temp(docx_path, function(temp_dir) {
    doc_path <- file.path(temp_dir, "word", "document.xml")
    if (!file.exists(doc_path)) {
      stop("Invalid docx: word/document.xml not found")
    }
    # Read raw XML text to extract complete citation blocks
    # Word splits long field codes across multiple w:instrText elements,
    # so we need to extract from raw text and strip XML tags
    paste(readLines(doc_path, warn = FALSE), collapse = "")
  })

  # Extract ZOTERO_PREF (document preferences - citation style, etc.)
  # This is required for Zotero to manage the document
  zotero_pref <- NULL
  zotero_pref_raw <- NULL
  pref_pattern <- "ADDIN ZOTERO_PREF\\s+(\\{[^<]+)"
  pref_matches <- regmatches(doc_text, gregexpr(pref_pattern, doc_text, perl = TRUE))[[1]]
  if (length(pref_matches) > 0) {
    # Extract JSON from the match
    pref_json_match <- regmatches(
      pref_matches[1],
      regexpr("\\{.*", pref_matches[1], perl = TRUE)
    )
    if (length(pref_json_match) > 0 && nchar(pref_json_match) > 0) {
      zotero_pref_raw <- trimws(pref_json_match)
      pref_json_clean <- unescape_xml_entities(zotero_pref_raw)
      tryCatch({
        zotero_pref <- jsonlite::fromJSON(pref_json_clean, simplifyVector = FALSE)
        if (verbose) message("Extracted ZOTERO_PREF (style: ", zotero_pref$style$styleID, ")")
      }, error = function(e) {
        if (verbose) message("Warning: Could not parse ZOTERO_PREF JSON: ", conditionMessage(e))
      })
    }
  } else {
    if (verbose) message("No ZOTERO_PREF found in document")
  }

  # Extract ZOTERO_BIBL (bibliography field code)
  # Format: ADDIN ZOTERO_BIBL {JSON} CSL_BIBLIOGRAPHY
  # The JSON is simple: {"uncited":[],"omitted":[],"custom":[]}
  # We store both the full instrText and the parsed JSON for round-trip
  zotero_bibl <- NULL
  bibl_pattern <- "ADDIN ZOTERO_BIBL\\s+(\\{[^}]*\\})\\s*CSL_BIBLIOGRAPHY"
  bibl_matches <- regmatches(doc_text, gregexpr(bibl_pattern, doc_text, perl = TRUE))[[1]]
  if (length(bibl_matches) > 0) {
    # Extract JSON from the match (just the {...} part)
    bibl_json_match <- regmatches(
      bibl_matches[1],
      regexpr("\\{[^}]*\\}", bibl_matches[1], perl = TRUE)
    )
    if (length(bibl_json_match) > 0 && nchar(bibl_json_match) > 0) {
      bibl_json_clean <- unescape_xml_entities(trimws(bibl_json_match))
      tryCatch({
        bibl_json_obj <- jsonlite::fromJSON(bibl_json_clean, simplifyVector = FALSE)
        # Store both the full instrText (for injection) and parsed JSON
        zotero_bibl <- list(
          instrText = paste0("ADDIN ZOTERO_BIBL ", bibl_json_clean, " CSL_BIBLIOGRAPHY"),
          uncited = bibl_json_obj$uncited %||% list(),
          omitted = bibl_json_obj$omitted %||% list(),
          custom = bibl_json_obj$custom %||% list()
        )
        if (verbose) message("Extracted ZOTERO_BIBL")
      }, error = function(e) {
        if (verbose) message("Warning: Could not parse ZOTERO_BIBL JSON: ", conditionMessage(e))
      })
    }
  }

  # Find all complete Zotero citation blocks (from ADDIN to closing schema URL)
  # Match both native Zotero (literal ") and docstyle-injected (&quot;) field codes.
  # When docstyle injects field codes via build_field_code_xml(), escape_xml_text()
  # converts " to &quot; in the instrText XML. The regex must accept both forms.
  pattern <- "ADDIN ZOTERO_ITEM CSL_CITATION.*?csl-citation[.]json(\"|&quot;)[}]"
  matches <- gregexpr(pattern, doc_text, perl = TRUE)
  matched_blocks <- regmatches(doc_text, matches)[[1]]

  if (length(matched_blocks) == 0) {
    if (verbose) message("No Zotero citations found in document")

    # Guard: when merging, never overwrite non-empty citations with empty.
    # This prevents the post-render or re-harvest path from destroying
    # harvested citation data when the source document has no field codes
    # (e.g., first render, regex mismatch, or non-Zotero document).
    if (merge && file.exists(field_codes_path)) {
      existing <- tryCatch(
        jsonlite::fromJSON(field_codes_path, simplifyVector = FALSE),
        error = function(e) NULL
      )
      if (!is.null(existing) && length(existing$citations) > 0) {
        if (verbose) message("Preserving existing field-codes.json (",
                             length(existing$citations), " citations)")
        return(invisible(list(
          references_path = references_path,
          field_codes_path = field_codes_path,
          citations = list(),
          citation_map = list(),
          citation_id_map = list(),
          cite_keys = list(),
          zotero_pref = zotero_pref %||% existing$zotero_pref,
          zotero_bibl = zotero_bibl %||% existing$zotero_bibl
        )))
      }
    }

    # Still write field-codes.json if we have ZOTERO_PREF (for vanilla QMD that adds citations)
    if (!is.null(zotero_pref)) {
      field_codes_obj <- list(
        docstyle_version = as.character(utils::packageVersion("docstyle")),
        source = "harvest",
        extracted_from = basename(docx_path),
        extracted_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
        zotero_pref = zotero_pref,
        zotero_bibl = zotero_bibl,
        citations = list()
      )
      field_codes_json <- jsonlite::toJSON(field_codes_obj, auto_unbox = TRUE, pretty = TRUE)
      writeLines(field_codes_json, field_codes_path)
      if (verbose) message("Wrote field-codes.json (ZOTERO_PREF only): ", field_codes_path)
    }
    return(invisible(list(
      references_path = NULL,
      field_codes_path = if (!is.null(zotero_pref)) field_codes_path else NULL,
      citations = list(),
      citation_map = list(),
      cite_keys = list(),
      zotero_pref = zotero_pref,
      zotero_bibl = zotero_bibl
    )))
  }

  if (verbose) message("Found ", length(matched_blocks), " Zotero citation fields")

  # Parse each citation block and collect:
  # 1. Unique items (for CSL-JSON output)
  # 2. Citation instances with Zotero metadata (for field-codes.json)
  all_items <- list()
  seen_ids <- character()
  citation_instances <- list()
  # Also collect URIs for each item
  all_uris <- list()

  for (json_str in matched_blocks) {
    # Extract JSON portion
    json_start <- regexpr("\\{", json_str)
    json <- substr(json_str, json_start, nchar(json_str))
    json <- gsub("<[^>]+>", "", json)  # Strip XML tags
    json <- unescape_xml_entities(json)  # Handle &quot; etc. from XML-escaped field codes
    json_clean <- clean_rtf_escapes(trimws(json))

    tryCatch({
      citation <- jsonlite::fromJSON(json_clean, simplifyVector = FALSE)

      # Get the formatted citation text
      formatted <- citation$properties$plainCitation
      if (is.null(formatted)) formatted <- citation$properties$formattedCitation
      if (!is.null(formatted)) {
        formatted <- clean_rtf_escapes(formatted)
        formatted <- gsub("\\\\uc0", "", formatted)
        formatted <- gsub("\\{\\}", "", formatted)
      }

      # Collect item IDs and URIs for this citation instance
      instance_ids <- character()

      if (!is.null(citation$citationItems)) {
        for (item in citation$citationItems) {
          if (is.null(item$id)) {
            if (verbose) message("  Skipping citation item with missing ID")
            next
          }
          item_id <- as.character(item$id)
          instance_ids <- c(instance_ids, item_id)

          # Add to unique items if not seen
          if (!item_id %in% seen_ids && !is.null(item$itemData)) {
            seen_ids <- c(seen_ids, item_id)
            all_items[[item_id]] <- item$itemData
            # Store URIs if present
            if (!is.null(item$uris)) {
              all_uris[[item_id]] <- item$uris
            }
          }
        }
      }

      # Store this citation instance
      if (!is.null(formatted) && length(instance_ids) > 0) {
        clean_instr <- gsub("<[^>]+>", "", json_str)
        citation_instances <- c(citation_instances, list(list(
          formatted = formatted,
          item_ids = instance_ids,
          instrText = clean_instr,
          citationID = citation$citationID
        )))
      }
    }, error = function(e) {
      if (verbose) message("  Skipped citation with parse error: ", conditionMessage(e))
    })
  }

  if (verbose) message("Collected ", length(all_items), " unique citation items")

  if (length(all_items) == 0) {
    if (verbose) message("No citation data could be extracted")
    return(invisible(list(
      references_path = NULL,
      field_codes_path = NULL,
      citations = list(),
      citation_map = list(),
      cite_keys = list()
    )))
  }

  # Generate cite keys for all items with collision handling
  cite_keys <- resolve_cite_keys(all_items)

  # Build citation map, citation catalog, and citationGroups
  citation_map <- list()
  field_codes_citations <- list()  # Item catalog: citekey → {itemData, uris}

  # Also build citation_id_map: citationID → quarto syntax.
  # This enables field-code-boundary-aware replacement in extract_formatted_text(),
  # avoiding text-based matching that confuses Vancouver-style "(1)" citations
  # with literal list numbering.
  citation_id_map <- list()

  # citationGroups: each citation instance (single or grouped) as an atomic unit.
  # Keyed by "grp_<citationID>". Each group has: citationID, instrText,
  # properties (display text), and ordered citekeys[].
  citation_groups <- list()

  for (instance in citation_instances) {
    all_keys <- lapply(instance$item_ids, function(id) cite_keys[[id]])
    has_key       <- !vapply(all_keys, is.null, logical(1))
    missing_count <- sum(!has_key)
    if (missing_count > 0L) {
      warning("[citations] ", missing_count, " item(s) in citation group '",
              instance$citationID %||% "unknown",
              "' have no citekey (missing itemData); they will be omitted.")
    }
    # Filter both keys and item_ids together so they stay aligned
    keys     <- unlist(all_keys[has_key], use.names = FALSE)  # character vector, NULLs removed
    item_ids <- instance$item_ids[has_key]

    if (length(keys) == 0L) {
      quarto_cite <- paste0("[missing citation: ", instance$citationID %||% "unknown", "]")
    } else {
      quarto_cite <- paste0("[@", paste(keys, collapse = "; @"), "]")
    }
    citation_map[[normalize_citation_text(instance$formatted)]] <- quarto_cite

    # Map citationID → quarto syntax for XML-boundary-aware replacement
    if (!is.null(instance$citationID)) {
      citation_id_map[[instance$citationID]] <- quarto_cite
    }

    # Store this citation instance as an atomic citationGroup
    group_key <- paste0("grp_", instance$citationID %||% "unknown")
    if (is.null(citation_groups[[group_key]])) {
      display_props <- extract_display_properties(instance$instrText, instance$formatted)
      citation_groups[[group_key]] <- list(
        citationID = instance$citationID,
        instrText = instance$instrText,
        properties = display_props,
        citekeys = as.list(keys)
      )
    }

    # Build the item catalog: each citekey → {itemData, uris}
    for (i in seq_along(item_ids)) {
      item_id <- item_ids[i]
      citekey <- keys[i]

      # Only store if not already present (first occurrence wins)
      if (is.null(field_codes_citations[[citekey]])) {
        field_codes_citations[[citekey]] <- list(
          itemData = all_items[[item_id]],
          uris = all_uris[[item_id]] %||% list()
        )
      }
    }
  }

  if (verbose) message("Built citation map with ", length(citation_map), " unique in-text citations")

  # Build references.json (CSL-JSON array)
  references_list <- lapply(names(cite_keys), function(item_id) {
    item <- all_items[[item_id]]
    citekey <- cite_keys[[item_id]]
    # Add id field for Pandoc
    item$id <- citekey
    item
  })

  # Write references.json
  references_json <- jsonlite::toJSON(references_list, auto_unbox = TRUE, pretty = TRUE)
  writeLines(references_json, references_path)
  if (verbose) message("Wrote references.json: ", references_path)

  # Compute hash of references.json for consistency checking
  references_hash <- digest::digest(references_json, algo = "sha256")

  # Merge with existing field-codes.json if requested
  if (merge && file.exists(field_codes_path)) {
    tryCatch({
      existing <- jsonlite::fromJSON(field_codes_path, simplifyVector = FALSE)

      # Merge citations catalog (itemData + uris per citekey)
      if (!is.null(existing$citations)) {
        merged_citations <- existing$citations
        n_new <- 0L
        for (key in names(field_codes_citations)) {
          if (is.null(merged_citations[[key]])) {
            merged_citations[[key]] <- field_codes_citations[[key]]
            n_new <- n_new + 1L
          }
          # Existing itemData is kept (first occurrence wins for catalog)
        }
        field_codes_citations <- merged_citations
      }

      # Merge citationGroups (keyed by grp_<citationID>)
      if (!is.null(existing$citationGroups)) {
        merged_groups <- existing$citationGroups
        n_new_groups <- 0L
        n_updated_groups <- 0L
        for (gkey in names(citation_groups)) {
          if (is.null(merged_groups[[gkey]])) {
            merged_groups[[gkey]] <- citation_groups[[gkey]]
            n_new_groups <- n_new_groups + 1L
          } else {
            # Both exist — keep whichever has better display text
            existing_plain <- merged_groups[[gkey]]$properties$plainCitation %||% ""
            new_plain <- citation_groups[[gkey]]$properties$plainCitation %||% ""
            existing_has_numbers <- grepl("^[0-9]", existing_plain)
            new_has_numbers <- grepl("^[0-9]", new_plain)
            if (new_has_numbers && !existing_has_numbers) {
              merged_groups[[gkey]] <- citation_groups[[gkey]]
              n_updated_groups <- n_updated_groups + 1L
            }
          }
        }
        citation_groups <- merged_groups
      }

      if (verbose) {
        message("Merged with existing field-codes.json (",
                length(existing$citations), " existing citations, ",
                n_new, " new, ",
                length(existing$citationGroups), " existing groups)")
      }
    }, error = function(e) {
      if (verbose) {
        message("Warning: Could not read existing field-codes.json, overwriting: ",
                conditionMessage(e))
      }
    })
  }

  # Build field-codes.json with citationGroups schema
  field_codes_obj <- list(
    docstyle_version = as.character(utils::packageVersion("docstyle")),
    source = "harvest",
    references_hash = references_hash,
    extracted_from = basename(docx_path),
    extracted_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    zotero_pref = zotero_pref,
    zotero_bibl = zotero_bibl,
    citations = field_codes_citations,
    citationGroups = citation_groups
  )

  # Write field-codes.json
  field_codes_json <- jsonlite::toJSON(field_codes_obj, auto_unbox = TRUE, pretty = TRUE)
  writeLines(field_codes_json, field_codes_path)
  if (verbose) message("Wrote field-codes.json: ", field_codes_path)

  invisible(list(
    references_path = references_path,
    field_codes_path = field_codes_path,
    citations = all_items,
    citation_map = citation_map,
    citation_id_map = citation_id_map,
    cite_keys = cite_keys,
    zotero_pref = zotero_pref,
    zotero_bibl = zotero_bibl
  ))
}


#' Export bibliography as BibTeX from harvested sidecar data
#'
#' Reads citation data from the sidecar directory (`field-codes.json` or
#' `references.json`) and writes a `.bib` file with BibTeX entries. Citation
#' keys match those used in the QMD (`[@key]` syntax).
#'
#' @param sidecar_dir Path to the `_docstyle` sidecar directory containing
#'   `field-codes.json` and/or `references.json`.
#' @param output Path for the output `.bib` file. Default writes
#'   `references.bib` in the sidecar directory.
#' @param verbose Print progress messages. Default TRUE.
#'
#' @return Invisibly returns the output path.
#'
#' @details
#' The function prefers `field-codes.json` as the source because it contains
#' citation keys that match the QMD. Falls back to `references.json` if
#' field-codes.json is absent. Uses the internal `csl_to_bibtex_with_key()`
#' converter for each item.
#'
#' @examples
#' \dontrun{
#' # After harvest, export bibliography for preprint rendering
#' export_bibliography("_docstyle")
#'
#' # Custom output path
#' export_bibliography("_docstyle", output = "references.bib")
#' }
#'
#' @export
export_bibliography <- function(sidecar_dir, output = NULL, verbose = TRUE) {
  if (!dir.exists(sidecar_dir)) {
    stop("Sidecar directory not found: ", sidecar_dir)
  }

  field_codes_path <- file.path(sidecar_dir, "field-codes.json")
  references_path <- file.path(sidecar_dir, "references.json")

  # Default output: references.bib in sidecar directory
  if (is.null(output)) {
    output <- file.path(sidecar_dir, "references.bib")
  }

  items <- list()

  # Prefer field-codes.json (has cite keys as object keys)
  if (file.exists(field_codes_path)) {
    fc <- tryCatch(
      jsonlite::fromJSON(field_codes_path, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(fc) && !is.null(fc$citations)) {
      for (key in names(fc$citations)) {
        item_data <- fc$citations[[key]]$itemData
        if (!is.null(item_data)) {
          items[[key]] <- item_data
        }
      }
      if (verbose) {
        message("[export_bibliography] Read ", length(items),
                " citations from field-codes.json")
      }
    }
  }

  # Fall back to references.json
  if (length(items) == 0 && file.exists(references_path)) {
    refs <- tryCatch(
      jsonlite::fromJSON(references_path, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(refs) && length(refs) > 0) {
      for (ref in refs) {
        key <- ref$id
        if (is.null(key)) {
          key <- generate_base_key(ref)
        }
        items[[key]] <- ref
      }
      if (verbose) {
        message("[export_bibliography] Read ", length(items),
                " citations from references.json")
      }
    }
  }

  if (length(items) == 0) {
    if (verbose) message("[export_bibliography] No citations found in sidecar directory")
    return(invisible(output))
  }

  # Convert each item to BibTeX
  bib_entries <- vapply(names(items), function(key) {
    csl_to_bibtex_with_key(items[[key]], key)
  }, character(1))

  writeLines(paste(bib_entries, collapse = "\n\n"), output)

  if (verbose) {
    message("[export_bibliography] Wrote ", length(bib_entries),
            " entries to ", output)
  }

  invisible(output)
}


#' Normalize citation display text for consistent matching
#'
#' Converts en-dashes (U+2013) and em-dashes (U+2014) to hyphens,
#' and collapses whitespace. This ensures citation map keys match
#' regardless of which dash character Word/Zotero uses.
#'
#' @param text Character string of citation display text
#' @return Normalized text with dashes and whitespace standardized
#' @noRd
normalize_citation_text <- function(text) {
  text <- gsub("\u2013", "-", text)  # en-dash → hyphen
  text <- gsub("\u2014", "-", text)  # em-dash → hyphen
  text <- gsub("\\s+", " ", text)
  trimws(text)
}


#' Extract Display Properties from Citation instrText
#'
#' Parses the JSON in an instrText string to extract plainCitation and
#' formattedCitation properties. Falls back to the provided default if parsing fails.
#'
#' @param instr_text The full instrText string containing JSON
#' @param fallback Default text to use if parsing fails
#' @return List with formattedCitation and plainCitation
#' @noRd
extract_display_properties <- function(instr_text, fallback) {
  plain_text <- fallback
  formatted_text <- fallback

  json_start <- regexpr("\\{", instr_text)
  if (json_start > 0) {
    tryCatch({
      instr_json <- substr(instr_text, json_start, nchar(instr_text))
      parsed <- jsonlite::fromJSON(instr_json, simplifyVector = FALSE)
      plain_text <- parsed$properties$plainCitation %||% fallback
      formatted_text <- parsed$properties$formattedCitation %||% fallback
    }, error = function(e) NULL)
  }

  list(formattedCitation = formatted_text, plainCitation = plain_text)
}


#' Clean RTF escapes from JSON string
#' @noRd
clean_rtf_escapes <- function(json_str) {
  json_clean <- json_str

  # Handle double-backslash RTF escapes (in JSON strings)
  json_clean <- gsub("\\\\uc0\\\\u8211\\{\\}", "-", json_clean, fixed = TRUE)
  json_clean <- gsub("\\\\u8211", "-", json_clean, fixed = TRUE)
  json_clean <- gsub("\\\\u8217", "'", json_clean, fixed = TRUE)

  # Handle single-backslash versions (outside JSON strings)
  json_clean <- gsub("\\uc0\\u8211\\{\\}", "-", json_clean, fixed = TRUE)
  json_clean <- gsub("\\u8211", "-", json_clean, fixed = TRUE)
  json_clean <- gsub("\\u8217", "'", json_clean, fixed = TRUE)

  # Handle literal Unicode dashes that Word may output directly
  json_clean <- gsub("\u2013", "-", json_clean)  # en-dash (U+2013) → hyphen
  json_clean <- gsub("\u2014", "-", json_clean)  # em-dash (U+2014) → hyphen

  # Handle literal newlines/tabs in abstracts (replace with spaces)
  json_clean <- gsub("\n", " ", json_clean, fixed = TRUE)
  json_clean <- gsub("\t", " ", json_clean, fixed = TRUE)
  json_clean <- gsub("\\s+", " ", json_clean)  # Collapse multiple spaces

  json_clean
}


#' Convert CSL-JSON item to BibTeX entry with explicit key
#' @noRd
csl_to_bibtex_with_key <- function(item, key) {
  # Map CSL types to BibTeX types
  type_map <- list(
    "article-journal" = "article",
    "book" = "book",
    "chapter" = "incollection",
    "paper-conference" = "inproceedings",
    "report" = "techreport",
    "thesis" = "phdthesis",
    "webpage" = "misc"
  )

  bib_type <- type_map[[item$type]]
  if (is.null(bib_type)) bib_type <- "misc"

  # Build fields
  fields <- list()

  # Authors
  if (!is.null(item$author)) {
    authors <- sapply(item$author, function(a) {
      if (!is.null(a$family) && !is.null(a$given)) {
        paste0(a$family, ", ", a$given)
      } else if (!is.null(a$family)) {
        a$family
      } else {
        ""
      }
    })
    fields$author <- paste(authors, collapse = " and ")
  }

  # Title
  if (!is.null(item$title)) {
    fields$title <- paste0("{", item$title, "}")
  }

  # Journal/container
  if (!is.null(item$`container-title`)) {
    if (bib_type == "article") {
      fields$journal <- item$`container-title`
    } else {
      fields$booktitle <- item$`container-title`
    }
  }

  # Year (try issued, then accessed)
  year <- extract_year(item)
  if (nchar(year) > 0) {
    fields$year <- year
  }

  # Volume, issue, pages
  # Only output simple scalar values, not nested structures
  if (!is.null(item$volume) && is.character(item$volume)) {
    fields$volume <- item$volume
  }
  if (!is.null(item$issue) && is.character(item$issue)) {
    fields$number <- item$issue
  }
  if (!is.null(item$page)) {
    fields$pages <- gsub("-", "--", as.character(item$page))
  }

  # Report number (for techreport type) - use 'number' from CSL if it's a simple string
  if (bib_type == "techreport" && !is.null(item$number) && is.character(item$number)) {
    fields$number <- item$number
  }

  # DOI
  if (!is.null(item$DOI)) fields$doi <- item$DOI

  # URL
  if (!is.null(item$URL)) fields$url <- item$URL

  # Format as BibTeX
  field_strings <- sapply(names(fields), function(name) {
    paste0("  ", name, " = {", fields[[name]], "}")
  })

  paste0(
    "@", bib_type, "{", key, ",\n",
    paste(field_strings, collapse = ",\n"),
    "\n}"
  )
}


#' Convert CSL-JSON item to BibTeX entry (convenience wrapper)
#' @noRd
csl_to_bibtex <- function(item, index) {
  # Note: This convenience function generates a fresh key and doesn't handle collisions.
  # It is mainly for testing/internal use of single items.
  key <- generate_base_key(item)
  csl_to_bibtex_with_key(item, key)
}


#' Generate a base citation key from CSL item (without disambiguation)
#' @noRd
generate_base_key <- function(item) {
  # Try to use first author's family name + year
  author_part <- ""
  if (!is.null(item$author) && length(item$author) > 0) {
    first_author <- item$author[[1]]
    if (!is.null(first_author$family)) {
      # Remove non-alphanumeric, keep dashes? Standard is usually just alphanumeric.
      # Converting to lowercase.
      author_part <- tolower(gsub("[^a-zA-Z0-9]", "", first_author$family))
    }
  }

  # Try issued date, then accessed date as fallback
  year_part <- extract_year(item)

  if (nchar(author_part) > 0 && nchar(year_part) > 0) {
    paste0(author_part, year_part)
  } else if (nchar(author_part) > 0) {
    # Use author only if no year available (e.g., websites)
    author_part
  } else {
    # Fallback if no author and no year?
    # Use title? or "anonymous" + year?
    # Let's use "ref" + random suffix or similar if absolutely nothing.
    # But wait, we don't have index here.
    # Let's use title first word.
    if (!is.null(item$title)) {
      title_word <- strsplit(gsub("[^a-zA-Z0-9 ]", "", item$title), " ")[[1]][1]
      tolower(title_word)
    } else {
      "anonymous"
    }
  }
}


#' Extract year from CSL item
#'
#' Tries issued date first, then accessed date as fallback.
#' @noRd
extract_year <- function(item) {
  # Try issued date first
  if (!is.null(item$issued) && !is.null(item$issued$`date-parts`)) {
    date_parts <- item$issued$`date-parts`
    if (length(date_parts) > 0 && length(date_parts[[1]]) > 0) {
      return(as.character(date_parts[[1]][[1]]))
    }
  }

  # Try accessed date as fallback (common for websites)
  if (!is.null(item$accessed) && !is.null(item$accessed$`date-parts`)) {
    date_parts <- item$accessed$`date-parts`
    if (length(date_parts) > 0 && length(date_parts[[1]]) > 0) {
      return(as.character(date_parts[[1]][[1]]))
    }
  }

  ""
}
