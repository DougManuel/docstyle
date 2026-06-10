#' Parse Dynamic Keywords
#'
#' Resolves keywords like `asset:logo`, `metadata:title`, and `field:page_number`.
#'
#' @param val_str The string to parse (e.g., "asset:logo-primary").
#' @param config Global configuration object (for assets).
#' @param metadata Document metadata (for metadata lookup).
#' @return The resolved value (path for assets, string for metadata, or a field code structure).
#' @keywords internal
#' @export
parse_keyword <- function(val_str, config, metadata) {
  if (is.null(val_str) || !is.character(val_str)) return(val_str)
  
  # Check for prefixes
  if (grepl("^asset:", val_str)) {
    key <- substring(val_str, 7) # Length of "asset:" + 1
    return(resolve_asset_path(key, config))
  }
  
  if (grepl("^metadata:", val_str)) {
    key <- substring(val_str, 10) # Length of "metadata:" + 1
    return(metadata[[key]]) # Returns NULL if not found
  }
  
  if (grepl("^field:", val_str)) {
    key <- substring(val_str, 7)
    return(resolve_field_code(key))
  }
  
  # Return original string if no keyword matched
  return(val_str)
}

#' Resolve Asset Path
#'
#' Looks up an asset key in the configuration.
#' Supports dot notation for nested keys (e.g., "logo.primary").
#'
#' @param key Asset key string.
#' @param config Configuration object.
#' @return Resolved file path or NULL.
#' @keywords internal
resolve_asset_path <- function(key, config) {
  # Allow dot or dash separator? Spec uses "logo-primary"
  # But config structure is assets -> logo -> primary.
  # If user writes "asset:logo-primary", we might need fuzzy matching or strict convention.
  # Spec says: "left: 'asset:logo-primary'"
  # Config has:
  # assets:
  #   logo:
  #     primary: ...
  
  # Let's support dot notation first as it's standard: "logo.primary"
  # If "logo-primary" is passed, we might treat it as a single key if it exists, 
  # or try to split.
  
  # Recursive lookup
  val <- config$assets
  
  # Try direct match first (flat structure)
  if (!is.null(val[[key]])) return(val[[key]])
  
  # Try splitting by dash or dot
  # If key is "logo-primary", try val[["logo"]][["primary"]]
  parts <- strsplit(key, "[.-]")[[1]]
  
  for (part in parts) {
    if (is.list(val) && !is.null(val[[part]])) {
      val <- val[[part]]
    } else {
      warning("Asset key '", key, "' not found in configuration.")
      return(NULL)
    }
  }
  
  return(val)
}

#' Resolve Field Code
#'
#' Maps generic field names to Word Field Codes.
#'
#' @param key Field key (e.g., "page_number").
#' @return A list indicating this is a field code, e.g., list(type = "field", code = "PAGE").
#' @keywords internal
resolve_field_code <- function(key) {
  code_map <- list(
    page_number = "PAGE",
    page_total = "NUMPAGES",
    section_pages = "SECTIONPAGES",
    print_date = "PRINTDATE",
    date = "DATE",
    time = "TIME"
  )
  
  code <- code_map[[key]]
  if (is.null(code)) {
    warning("Unknown field key: ", key)
    return(NULL)
  }
  
  return(list(type = "field", code = code))
}
