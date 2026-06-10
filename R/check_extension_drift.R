#' Check vendored docstyle extension version against installed package
#'
#' Compares the version declared in the project's vendored
#' `_extensions/docstyle/_extension.yml` with the installed docstyle R
#' package version. Returns a structured result so callers can either
#' surface a render-time warning or take action.
#'
#' This is the post-render-validators pattern (#145) applied at the
#' pre-render layer: catch a class of silent failure (vendored
#' extension drifts, the project no longer matches the package's
#' behaviour) at the moment the author is most likely to notice and
#' act on it — render time.
#'
#' @param project_dir Path to the project root (containing `_quarto.yml`
#'   and `_extensions/docstyle/`). Defaults to the current working
#'   directory.
#' @param installed_version Optional character string for the installed
#'   docstyle package version. If NULL, reads from
#'   `utils::packageVersion("docstyle")`. Useful for testing.
#' @param vendored_version Optional character string for the vendored
#'   extension version. If NULL, reads from
#'   `<project_dir>/_extensions/docstyle/_extension.yml`. Useful for
#'   testing.
#'
#' @return A list with:
#'   - `status`: one of `"match"` (versions equal), `"drift"` (different),
#'     `"no-extension"` (vendored extension or its manifest is missing),
#'     `"no-package"` (docstyle R package not installed/findable).
#'   - `installed`: character string of the installed package version,
#'     or NULL if not findable.
#'   - `vendored`: character string of the vendored extension version,
#'     or NULL if not findable.
#'   - `message`: optional user-facing message (NULL when no action
#'     needed). Tagged with the `[check-extension]` prefix.
#'
#' @examples
#' \dontrun{
#' result <- check_extension_drift(".")
#' if (!is.null(result$message)) message(result$message)
#' }
#' @export
check_extension_drift <- function(project_dir = ".",
                                  installed_version = NULL,
                                  vendored_version = NULL) {

  if (is.null(installed_version)) {
    installed_version <- tryCatch(
      as.character(utils::packageVersion("docstyle")),
      error = function(e) NULL)
  }

  if (is.null(vendored_version)) {
    yml_path <- file.path(project_dir, "_extensions", "docstyle",
                          "_extension.yml")
    if (file.exists(yml_path)) {
      vendored_version <- tryCatch({
        cfg <- yaml::read_yaml(yml_path)
        as.character(cfg$version)
      }, error = function(e) NULL)
    }
  }

  out <- list(
    installed = installed_version,
    vendored  = vendored_version,
    status    = NA_character_,
    message   = NULL
  )

  if (is.null(installed_version) || length(installed_version) == 0) {
    out$status <- "no-package"
    out$installed <- NULL
    return(out)
  }
  if (is.null(vendored_version) || length(vendored_version) == 0 ||
      !nzchar(vendored_version)) {
    out$status <- "no-extension"
    out$vendored <- NULL
    return(out)
  }

  if (identical(installed_version, vendored_version)) {
    out$status <- "match"
    return(out)
  }

  out$status <- "drift"
  out$message <- paste0(
    "[check-extension] WARN: Vendored docstyle extension is v",
    vendored_version,
    " but installed R package is v", installed_version,
    ". Run docstyle::update_extension() to bring the project's ",
    "_extensions/docstyle/ in sync. (Set docstyle.silence-version-",
    "warning: true in _quarto.yml to suppress this message.)"
  )
  out
}
