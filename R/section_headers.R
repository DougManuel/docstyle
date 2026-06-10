#' Per-Section Header and Footer Injection
#'
#' Resolves the "same as previous" cascade for headers and footers,
#' writes footerN.xml/headerN.xml files, and adds references to each
#' section's sectPr.
#'
#' @noRd
NULL


#' Inject Per-Section Headers and Footers
#'
#' Reads header/footer configuration from page_config and field code payloads,
#' resolves the "same as previous" cascade, writes footerN.xml/headerN.xml files,
#' and adds references to each section's sectPr.
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param temp_dir Path to unzipped DOCX directory
#' @param page_config Page configuration from load_page_config()
#' @param assembly_result Result from assemble_section_breaks()
#' @param verbose Print diagnostic messages
#' @return Number of sections that received header/footer references
#' @noRd
inject_section_headers_footers <- function(body, ns, temp_dir, page_config,
                                           assembly_result, verbose = FALSE) {
  footer_config <- page_config$footer
  header_config <- page_config$header
  section_styles <- page_config$sections %||% list()

  footer_enabled <- isTRUE(footer_config$enabled)
  header_enabled <- isTRUE(header_config$enabled)

  if (!footer_enabled && !header_enabled) return(0L)

  section_seq <- assembly_result$section_sequence

  # --- Handle simple documents with no section markers ---
  if (length(section_seq) == 0) {
    return(inject_simple_document_hf(body, ns, temp_dir,
                                     footer_config, header_config,
                                     footer_enabled, header_enabled, verbose,
                                     page_config = page_config))
  }

  # --- Resolve per-section config using "same as previous" cascade ---
  resolved <- resolve_all_sections(section_seq, footer_config, header_config,
                                   section_styles, footer_enabled, header_enabled)

  # --- Deduplicate and generate footer/header XML files ---
  ns_r <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")

  # Caches keyed by config fingerprint to share files across identical sections
  hf_state <- list(
    footer = list(cache = list(), counter = 2L),
    header = list(cache = list(), counter = 2L)
  )

  n_injected <- 0L

  for (i in seq_along(resolved)) {
    r <- resolved[[i]]
    sectpr_para <- r$sectpr_para
    if (is.null(sectpr_para)) next
    sectPr <- xml2::xml_find_first(sectpr_para, "w:pPr/w:sectPr", ns)
    if (inherits(sectPr, "xml_missing")) next

    # Compute tab stops for this section's page dimensions
    section_tab_stops <- compute_hf_tab_stops(page_config, r$section_class)

    for (hf_type in c("footer", "header")) {
      enabled <- if (hf_type == "footer") footer_enabled else header_enabled
      hf_cfg <- r[[hf_type]]
      if (!enabled || is.null(hf_cfg)) next

      if (isTRUE(hf_cfg$suppressed)) {
        # Suppressed: write empty file and add reference. Skipping the
        # reference entirely would cause Word to inherit from previous section.
        hf_state[[hf_type]] <- ensure_empty_hf_cached(hf_state[[hf_type]],
                                                       temp_dir, hf_type)
        cached <- hf_state[[hf_type]]$cache[["__empty__"]]
        add_hf_refs_to_sectpr(sectPr, cached, hf_type, ns, ns_r)
        next
      }

      hf_state[[hf_type]] <- ensure_hf_cached(hf_state[[hf_type]], hf_cfg,
                                               temp_dir, hf_type,
                                               tab_stops = section_tab_stops)
      cached <- hf_state[[hf_type]]$cache[[hf_fingerprint(hf_cfg)]]
      add_hf_refs_to_sectpr(sectPr, cached, hf_type, ns, ns_r)
    }

    n_injected <- n_injected + 1L
  }

  # --- Also inject into body sectPr (the final section) ---
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  if (!inherits(body_sectPr, "xml_missing") && length(resolved) > 0) {
    last <- resolved[[length(resolved)]]

    for (hf_type in c("footer", "header")) {
      enabled <- if (hf_type == "footer") footer_enabled else header_enabled
      hf_cfg <- last[[hf_type]]
      if (!enabled || is.null(hf_cfg)) next

      if (isTRUE(hf_cfg$suppressed)) {
        cached <- hf_state[[hf_type]]$cache[["__empty__"]]
        if (!is.null(cached)) {
          add_hf_refs_to_sectpr(body_sectPr, cached, hf_type, ns, ns_r)
        }
        next
      }

      cached <- hf_state[[hf_type]]$cache[[hf_fingerprint(hf_cfg)]]
      if (!is.null(cached)) {
        add_hf_refs_to_sectpr(body_sectPr, cached, hf_type, ns, ns_r)
      }
    }

    n_injected <- n_injected + 1L
  }

  if (verbose && n_injected > 0) {
    message("[finalize] Injected headers/footers into ", n_injected, " section(s)")
  }

  n_injected
}


# ============================================================================
# Simple document path (no section markers)
# ============================================================================

#' Inject Footer/Header into Body sectPr for Simple Documents
#'
#' @param body xml2 node for w:body
#' @param ns XML namespaces
#' @param temp_dir Path to unzipped DOCX directory
#' @param footer_config Footer configuration from page_config
#' @param header_config Header configuration from page_config
#' @param footer_enabled Whether footer is enabled
#' @param header_enabled Whether header is enabled
#' @param verbose Print diagnostic messages
#' @param page_config Full page configuration (for tab stop computation)
#' @return Number of injected items
#' @noRd
inject_simple_document_hf <- function(body, ns, temp_dir,
                                      footer_config, header_config,
                                      footer_enabled, header_enabled, verbose,
                                      page_config = NULL) {
  body_sectPr <- xml2::xml_find_first(body, "w:sectPr", ns)
  if (inherits(body_sectPr, "xml_missing")) return(0L)

  ns_r <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
            r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
  n_injected <- 0L

  configs <- list()
  if (footer_enabled) configs$footer <- footer_config
  if (header_enabled) configs$header <- header_config

  # Compute tab stops from page config for footer/header alignment
  tab_stops <- compute_hf_tab_stops(page_config)

  for (hf_type in names(configs)) {
    cfg <- configs[[hf_type]]
    positions <- list(left = cfg$left %||% "",
                      center = cfg$center %||% "",
                      right = cfg$right %||% "")
    rPr_xml <- cfg$rPr_xml %||% ""
    first_page <- cfg$`first-page` %||% cfg$first_page %||% TRUE

    content_xml <- build_multi_position_hf_xml_raw(positions, rPr_xml, hf_type,
                                                    tab_stops)
    fname_default <- sprintf("%s3.xml", hf_type)
    rid_default <- write_hf_to_docx(temp_dir, content_xml, fname_default, hf_type)

    # Remove any existing references from body sectPr
    ref_elem <- hf_reference_element[[hf_type]]
    existing <- xml2::xml_find_all(body_sectPr, ref_elem, ns_r)
    for (e in existing) xml2::xml_remove(e)

    ref <- xml2::xml_add_child(body_sectPr, ref_elem, .where = 0)
    xml2::xml_set_attr(ref, "w:type", "default")
    xml2::xml_set_attr(ref, "r:id", rid_default)

    if (!isTRUE(first_page)) {
      empty_xml <- build_hf_xml("", "center", "", hf_type)
      fname_first <- sprintf("%s4.xml", hf_type)
      rid_first <- write_hf_to_docx(temp_dir, empty_xml, fname_first, hf_type)
      ref_first <- xml2::xml_add_child(body_sectPr, ref_elem, .where = 0)
      xml2::xml_set_attr(ref_first, "w:type", "first")
      xml2::xml_set_attr(ref_first, "r:id", rid_first)

      titlePg <- xml2::xml_find_first(body_sectPr, "w:titlePg", ns)
      if (inherits(titlePg, "xml_missing")) {
        xml2::xml_add_child(body_sectPr, "w:titlePg")
      }
    }
    n_injected <- n_injected + 1L
  }

  if (verbose && n_injected > 0) {
    message("[finalize] Injected headers/footers into body sectPr (no section markers)")
  }
  n_injected
}


# ============================================================================
# Cascade resolution
# ============================================================================

#' Build YAML Defaults for a Footer or Header
#'
#' @param config Footer or header config from page_config
#' @return Resolved config list with left/center/right/rPr_xml/first_page/suppressed
#' @noRd
make_hf_yaml_defaults <- function(config) {
  list(
    left = config$left %||% "",
    center = config$center %||% "",
    right = config$right %||% "",
    rPr_xml = config$rPr_xml %||% "",
    first_page = config$`first-page` %||% config$first_page %||% TRUE,
    suppressed = FALSE
  )
}


#' Resolve Footer or Header for a Single Section
#'
#' Applies "same as previous" cascade logic for one hf_type.
#'
#' @param payload Field code payload from the section marker
#' @param prev Previous section's resolved config
#' @param section_name Section name (without "section-" prefix)
#' @param section_styles Section style overrides from page_config
#' @param global_config Global footer/header config from page_config
#' @param hf_type "footer" or "header"
#' @return Resolved config for this section
#' @noRd
resolve_hf_for_section <- function(payload, prev, section_name,
                                   section_styles, global_config, hf_type) {
  if (identical(payload[[hf_type]], "false")) {
    return(list(suppressed = TRUE))
  }

  prefix <- paste0(hf_type, "-")
  position_keys <- paste0(prefix, c("left", "center", "right"))
  has_text <- any(position_keys %in% names(payload))

  if (!has_text) return(prev)

  # Resolve rPr: section override > global
  rPr_key <- paste0(hf_type, "_rPr_xml")
  section_rPr <- ""
  if (!is.null(section_styles[[section_name]][[rPr_key]])) {
    section_rPr <- section_styles[[section_name]][[rPr_key]]
  } else if (!is.null(global_config$rPr_xml)) {
    section_rPr <- global_config$rPr_xml
  }

  list(
    left = payload[[paste0(prefix, "left")]] %||% prev$left %||% "",
    center = payload[[paste0(prefix, "center")]] %||% prev$center %||% "",
    right = payload[[paste0(prefix, "right")]] %||% prev$right %||% "",
    rPr_xml = section_rPr,
    first_page = prev$first_page %||% TRUE,
    suppressed = FALSE
  )
}


#' Resolve All Sections
#'
#' Walks the section sequence and resolves footer/header config for each,
#' applying the "same as previous" cascade.
#'
#' @param section_seq Section sequence from assembly_result
#' @param footer_config Footer config from page_config
#' @param header_config Header config from page_config
#' @param section_styles Section style overrides
#' @param footer_enabled Whether footer is enabled
#' @param header_enabled Whether header is enabled
#' @return List of resolved section configs
#' @noRd
resolve_all_sections <- function(section_seq, footer_config, header_config,
                                 section_styles, footer_enabled, header_enabled) {
  resolved <- list()

  prev <- list(
    footer = if (footer_enabled) make_hf_yaml_defaults(footer_config) else NULL,
    header = if (header_enabled) make_hf_yaml_defaults(header_config) else NULL
  )

  for (i in seq_along(section_seq)) {
    s <- section_seq[[i]]
    payload <- s$field_code_payload %||% list()
    section_name <- sub("^section-", "", s$section_class)

    this <- list()
    for (hf_type in c("footer", "header")) {
      enabled <- if (hf_type == "footer") footer_enabled else header_enabled
      global_cfg <- if (hf_type == "footer") footer_config else header_config

      if (enabled) {
        this[[hf_type]] <- resolve_hf_for_section(
          payload, prev[[hf_type]], section_name,
          section_styles, global_cfg, hf_type
        )
      } else {
        this[[hf_type]] <- prev[[hf_type]]
      }
    }

    resolved[[i]] <- list(
      section_class = s$section_class,
      sectpr_para = s$sectpr_para,
      is_closing = s$is_closing,
      footer = this$footer,
      header = this$header
    )

    # Cascade text content but NOT first_page suppression.
    # first_page: false means "suppress footer on the document's title page"
    # which only applies to the first section. Subsequent sections should
    # show the default footer on all their pages (first_page = TRUE).
    for (hf_type in c("footer", "header")) {
      prev[[hf_type]] <- this[[hf_type]]
      if (!is.null(prev[[hf_type]]) && !isTRUE(prev[[hf_type]]$suppressed)) {
        prev[[hf_type]]$first_page <- TRUE
      }
    }
  }

  resolved
}


# ============================================================================
# Cache, write, and inject helpers
# ============================================================================

#' Compute Cache Fingerprint for a Footer/Header Config
#'
#' @param hf_cfg Resolved footer or header config
#' @return Character string fingerprint
#' @noRd
hf_fingerprint <- function(hf_cfg) {
  paste(hf_cfg$left, hf_cfg$center, hf_cfg$right,
        hf_cfg$rPr_xml, hf_cfg$first_page, sep = "||")
}


#' Ensure Footer/Header XML is Cached (Write if New)
#'
#' Checks the cache for an existing entry matching the config fingerprint.
#' If not found, writes the XML file(s) and updates the cache.
#'
#' @param state List with `cache` and `counter` for one hf_type
#' @param hf_cfg Resolved footer or header config
#' @param temp_dir Path to unzipped DOCX directory
#' @param hf_type "footer" or "header"
#' @return Updated state with new cache entry and counter
#' @noRd
ensure_hf_cached <- function(state, hf_cfg, temp_dir, hf_type,
                             tab_stops = NULL) {
  fp <- hf_fingerprint(hf_cfg)
  if (!is.null(state$cache[[fp]])) return(state)

  state$counter <- state$counter + 1L

  config <- list(left = hf_cfg$left, center = hf_cfg$center,
                 right = hf_cfg$right)
  xml <- build_multi_position_hf_xml_raw(config, hf_cfg$rPr_xml, hf_type,
                                          tab_stops)

  fname <- sprintf("%s%d.xml", hf_type, state$counter)
  rid_default <- write_hf_to_docx(temp_dir, xml, fname, hf_type)

  rid_first <- NULL
  if (!isTRUE(hf_cfg$first_page)) {
    state$counter <- state$counter + 1L
    empty_xml <- build_hf_xml("", "center", "", hf_type)
    empty_fname <- sprintf("%s%d.xml", hf_type, state$counter)
    rid_first <- write_hf_to_docx(temp_dir, empty_xml, empty_fname, hf_type)
  }

  state$cache[[fp]] <- list(rid_default = rid_default, rid_first = rid_first)
  state
}


#' Ensure Empty Footer/Header XML is Cached (for Suppression)
#'
#' Creates a single empty footer/header file shared by all suppressed sections.
#' In Word, omitting a footerReference causes inheritance from the previous
#' section. To truly suppress, we must reference an empty file.
#'
#' @param state List with `cache` and `counter` for one hf_type
#' @param temp_dir Path to unzipped DOCX directory
#' @param hf_type "footer" or "header"
#' @return Updated state with `__empty__` cache entry
#' @noRd
ensure_empty_hf_cached <- function(state, temp_dir, hf_type) {
  fp <- "__empty__"
  if (!is.null(state$cache[[fp]])) return(state)

  state$counter <- state$counter + 1L
  empty_xml <- build_hf_xml("", "center", "", hf_type)
  fname <- sprintf("%s%d.xml", hf_type, state$counter)
  rid <- write_hf_to_docx(temp_dir, empty_xml, fname, hf_type)

  state$cache[[fp]] <- list(rid_default = rid, rid_first = NULL)
  state
}


#' Add Footer/Header References to a sectPr Element
#'
#' Removes existing references of the given type and adds new ones
#' from the cache entry.
#'
#' @param sectPr xml2 node for w:sectPr
#' @param cached Cache entry with rid_default and rid_first
#' @param hf_type "footer" or "header"
#' @param ns Base XML namespaces
#' @param ns_r Extended namespaces including r:
#' @noRd
add_hf_refs_to_sectpr <- function(sectPr, cached, hf_type, ns, ns_r) {
  ref_elem <- hf_reference_element[[hf_type]]

  # Remove any existing references (prevents duplicates)
  existing <- xml2::xml_find_all(sectPr, ref_elem, ns_r)
  for (e in existing) xml2::xml_remove(e)

  ref <- xml2::xml_add_child(sectPr, ref_elem, .where = 0)
  xml2::xml_set_attr(ref, "w:type", "default")
  xml2::xml_set_attr(ref, "r:id", cached$rid_default)

  if (!is.null(cached$rid_first)) {
    ref_first <- xml2::xml_add_child(sectPr, ref_elem, .where = 0)
    xml2::xml_set_attr(ref_first, "w:type", "first")
    xml2::xml_set_attr(ref_first, "r:id", cached$rid_first)

    titlePg <- xml2::xml_find_first(sectPr, "w:titlePg", ns)
    if (inherits(titlePg, "xml_missing")) {
      xml2::xml_add_child(sectPr, "w:titlePg")
    }
  }
}


# ============================================================================
# Raw multi-position XML builder (pre-computed rPr, used by the finisher)
# ============================================================================

#' Build Multi-Position Footer or Header XML from Raw Config
#'
#' Like build_multi_position_hf_xml() but takes pre-computed rPr_xml
#' instead of css_styles (for use in the post-render finisher).
#'
#' @param config List with left/center/right text
#' @param rPr_xml Pre-computed run properties XML string
#' @param hf_type "footer" or "header"
#' @return Complete footer/header XML string
#' @noRd
build_multi_position_hf_xml_raw <- function(config, rPr_xml = "",
                                            hf_type = "footer",
                                            tab_stops = NULL) {
  left <- config$left %||% ""
  center <- config$center %||% ""
  right <- config$right %||% ""

  runs_xml <- build_multi_position_runs(left, center, right,
                                        rPr_xml, rPr_xml, rPr_xml)
  wrap_multi_position_xml(runs_xml, hf_type,
                          tab_stops$center %||% 4680L,
                          tab_stops$right %||% 9360L)
}

#' @noRd
build_multi_position_footer_xml_raw <- function(config, rPr_xml = "",
                                                tab_stops = NULL) {
  build_multi_position_hf_xml_raw(config, rPr_xml, "footer", tab_stops)
}

#' @noRd
build_multi_position_header_xml_raw <- function(config, rPr_xml = "",
                                                tab_stops = NULL) {
  build_multi_position_hf_xml_raw(config, rPr_xml, "header", tab_stops)
}
