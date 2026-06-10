#' Get Asset Path
#'
#' Resolves the file path for a brand asset.
#'
#' @param asset_key Key string (e.g., "logo", "icon").
#' @param style Style name (default: "popcorn").
#' @return Absolute path to the asset file.
#' @keywords internal
#' @export
asset_path <- function(asset_key, style = "popcorn") {
  # Simple mapping for now. In future, could read from a manifest.
  
  root <- system.file("extdata", style, "assets", package = "docstyle")
  if (root == "") root <- file.path("inst/extdata", style, "assets") # Dev fallback
  
  # Conventions
  if (asset_key == "logo") {
    return(file.path(root, "logo", "popcorn_main-wordmark.png"))
  }
  if (asset_key == "icon") {
    return(file.path(root, "icon", "popcorn_icon-black.png"))
  }
  
  # Fallback: assume key is a filename relative to assets root
  candidate <- file.path(root, asset_key)
  if (file.exists(candidate)) return(candidate)
  
  warning("Asset not found: ", asset_key)
  return(NULL)
}
