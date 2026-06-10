#' Internal utility functions for docstyle
#'
#' @name utils
#' @keywords internal
NULL

# Null-coalescing operator: returns x if not NULL, otherwise y. Internal; no
# Rd file is generated because the `%||%` name contains characters R CMD check
# rejects in an Rd `\name` tag even when escaped. R >= 4.4 provides the same
# operator in base; see `?base::"%||%"` for reference docs.
`%||%` <- function(x, y) if (is.null(x)) y else x


#' Unescape XML entities in a string
#'
#' Replaces \code{&quot;}, \code{&lt;}, \code{&gt;}, and \code{&amp;}
#' with their literal equivalents. Order matters: \code{&amp;} must be last.
#'
#' @param text Character string containing XML entities.
#' @return Character string with entities replaced.
#' @keywords internal
unescape_xml_entities <- function(text) {
  text <- gsub("&quot;", '"', text, fixed = TRUE)
  text <- gsub("&lt;", '<', text, fixed = TRUE)
  text <- gsub("&gt;", '>', text, fixed = TRUE)
  text <- gsub("&amp;", '&', text, fixed = TRUE)
  text
}


#' Escape XML special characters (preserving quotes)
#'
#' Escapes \code{&}, \code{<}, \code{>} but NOT quotes.
#' Zotero expects literal quotes in the JSON content of instrText elements.
#'
#' @param text Text to escape.
#' @return Escaped text.
#' @keywords internal
escape_xml_text <- function(text) {
  text <- gsub("&", "&amp;", text, fixed = TRUE)
  text <- gsub("<", "&lt;", text, fixed = TRUE)
  text <- gsub(">", "&gt;", text, fixed = TRUE)
  text
}


#' Escape all XML special characters (including quotes)
#'
#' Escapes all five XML special characters: `&`, `<`, `>`,
#' `"`, and `'`. Use this for XML content where quotes must
#' also be escaped (e.g., ZOTERO_PREF instrText).
#'
#' @param text Text to escape.
#' @return Escaped text safe for XML attribute or content use.
#' @keywords internal
escape_xml_text_full <- function(text) {
  text <- gsub("&", "&amp;", text, fixed = TRUE)
  text <- gsub("<", "&lt;", text, fixed = TRUE)
  text <- gsub(">", "&gt;", text, fixed = TRUE)
  text <- gsub('"', "&quot;", text, fixed = TRUE)
  text <- gsub("'", "&apos;", text, fixed = TRUE)
  text
}


#' Normalize typographic dashes to Pandoc markdown convention
#'
#' Pandoc converts `--` to en dash (U+2013) and `---` to em dash (U+2014)
#' when rendering to Word. This reverses that mapping so harvested text
#' uses the same `--`/`---` convention as the source QMD.
#'
#' @param text Character string extracted from Word XML.
#' @return Text with Unicode dashes replaced by Pandoc hyphen sequences.
#' @keywords internal
normalize_typographic_dashes <- function(text) {
  text <- gsub("\u2014", "---", text, fixed = TRUE)  # em dash → triple hyphen
  text <- gsub("\u2013", "--",  text, fixed = TRUE)  # en dash → double hyphen
  text
}


#' Modify a DOCX file's XML and repackage
#'
#' Extracts a DOCX to a temp directory, applies a modification function
#' to the document.xml content, writes it back, and re-zips. Handles
#' temp directory lifecycle and consistent zip flags.
#'
#' @param docx_path Path to the input DOCX file.
#' @param output_path Path for the output DOCX file.
#' @param modify_fn Function that receives XML content string and returns
#'   modified XML content string, or a list with \code{$xml} (modified
#'   content) and any additional return values.
#' @param ... Additional arguments passed to \code{modify_fn}.
#' @return Result of \code{modify_fn} (invisibly).
#' @keywords internal
modify_docx_xml <- function(docx_path, output_path, modify_fn, ...) {
  temp_dir <- tempfile("docstyle_modify_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  doc_xml_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_xml_path)) {
    stop("Invalid DOCX structure: word/document.xml not found")
  }

  xml_content <- paste(readLines(doc_xml_path, warn = FALSE), collapse = "\n")

  result <- modify_fn(xml_content, ...)

  # modify_fn may return just the modified XML string, or a list with
  # $xml and additional return values
  if (is.list(result) && !is.null(result$xml)) {
    writeLines(result$xml, doc_xml_path)
  } else if (is.character(result)) {
    writeLines(result, doc_xml_path)
  }

  # Re-zip with consistent flags
  output_path_abs <- normalizePath(output_path, mustWork = FALSE)
  output_dir <- dirname(output_path_abs)
  if (!dir.exists(output_dir) && output_dir != ".") {
    dir.create(output_dir, recursive = TRUE)
  }

  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp_dir)

  all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
  if (file.exists(output_path_abs)) file.remove(output_path_abs)

  zip_result <- utils::zip(output_path_abs, files = all_files, flags = "-r9Xq")
  if (zip_result != 0) stop("Failed to create zip file: ", output_path_abs)

  setwd(old_wd)

  invisible(result)
}


#' Get Pandoc version
#'
#' @return A \code{numeric_version} object, or NULL if Pandoc is not found.
#' @keywords internal
get_pandoc_version <- function() {
  tryCatch({
    output <- system2("pandoc", "--version", stdout = TRUE, stderr = TRUE)
    version_line <- output[1]
    version_str <- sub("^pandoc\\s+", "", version_line)
    numeric_version(version_str)
  }, error = function(e) {
    NULL
  })
}


#' Extract DOCX to a temporary directory with automatic cleanup
#'
#' Creates a unique temporary directory, extracts the DOCX contents,
#' and returns both the directory path and a cleanup function.
#' Uses on.exit() pattern for guaranteed cleanup.
#'
#' @param docx_path Path to the .docx file
#' @param files Optional character vector of specific files to extract.
#'   If NULL (default), extracts all files.
#' @return A list with:
#'   - `dir`: Path to the temporary directory containing extracted files
#'   - `cleanup`: Function to call to remove the temp directory (usually not needed
#'     if using with_docx_temp())
#' @noRd
extract_docx_temp <- function(docx_path, files = NULL) {
  temp_dir <- file.path(tempdir(), paste0("docstyle_", basename(docx_path), "_",
                                           format(Sys.time(), "%Y%m%d%H%M%S"),
                                           "_", sample(1000:9999, 1)))
  dir.create(temp_dir, recursive = TRUE, showWarnings = FALSE)

  if (is.null(files)) {
    utils::unzip(docx_path, exdir = temp_dir)
  } else {
    utils::unzip(docx_path, files = files, exdir = temp_dir)
  }

  list(
    dir = temp_dir,
    cleanup = function() {
      if (dir.exists(temp_dir)) {
        unlink(temp_dir, recursive = TRUE)
      }
    }
  )
}

#' Check if Zotero with Better BibTeX is Running
#'
#' Attempts to connect to Better BibTeX's local HTTP endpoint.
#'
#' @return TRUE if Zotero with Better BibTeX is responding, FALSE otherwise.
#'
#' @details
#' Better BibTeX exposes an HTTP API at `http://127.0.0.1:23119/better-bibtex/`.
#' This function attempts a simple request to check connectivity.
#'
#' @export
is_zotero_running <- function() {
  url <- "http://127.0.0.1:23119/better-bibtex/cayw?probe=true"

  tryCatch({
    con <- url(url, open = "r")
    on.exit(close(con), add = TRUE)

    response <- readLines(con, n = 1, warn = FALSE)
    return(TRUE)
  }, error = function(e) {
    return(FALSE)
  }, warning = function(w) {
    return(FALSE)
  })
}


#' Find the docstyle project root directory
#'
#' Walks upward from `start` looking for the nearest ancestor that contains
#' `_quarto.yml` with a `docstyle:` section, a root `_quarto.yml` (project
#' file), or a `.git` directory. Falls back to `QUARTO_PROJECT_DIR` if set,
#' then to `start` itself.
#'
#' This is used by the pre- and post-render scripts to resolve sidecar paths
#' robustly when rendering from a subdirectory (e.g., `docs/`) that has its
#' own `_quarto.yml`.
#'
#' @param start Directory to start searching from. Defaults to the current
#'   working directory.
#' @param max_levels Maximum number of parent directories to check. Default 8.
#' @return Absolute path to the project root directory.
#' @export
find_project_root <- function(start = getwd(), max_levels = 8) {
  # Prefer QUARTO_PROJECT_DIR when available (authoritative)
  env_dir <- Sys.getenv("QUARTO_PROJECT_DIR", "")
  if (nzchar(env_dir) && dir.exists(env_dir)) {
    return(normalizePath(env_dir, mustWork = FALSE))
  }

  start <- normalizePath(start, mustWork = FALSE)
  candidate <- start

  for (i in seq_len(max_levels)) {
    # A root _quarto.yml has `project:` at top level
    quarto_yml <- file.path(candidate, "_quarto.yml")
    if (file.exists(quarto_yml)) {
      cfg <- tryCatch(yaml::read_yaml(quarto_yml), error = function(e) NULL)
      if (!is.null(cfg) && (!is.null(cfg$project) || !is.null(cfg$docstyle))) {
        return(candidate)
      }
    }

    # Git root is a reliable project boundary
    if (dir.exists(file.path(candidate, ".git"))) {
      return(candidate)
    }

    parent <- dirname(candidate)
    if (parent == candidate) break  # filesystem root
    candidate <- parent
  }

  # No anchor found — return start
  start
}

#' Execute a function with DOCX contents in a temp directory
#'
#' Extracts DOCX to a temp directory, runs the provided function,
#' and cleans up automatically regardless of success or failure.
#'
#' @param docx_path Path to the .docx file
#' @param fn Function to execute. Receives the temp directory path as first argument.
#' @param files Optional character vector of specific files to extract.
#' @param ... Additional arguments passed to fn
#' @return Result of fn
#' @noRd
with_docx_temp <- function(docx_path, fn, files = NULL, ...) {
  temp <- extract_docx_temp(docx_path, files)
  on.exit(temp$cleanup(), add = TRUE)
  fn(temp$dir, ...)
}

#' XML Escape
#'
#' Escapes special characters for XML text content.
#'
#' @param text Text to escape
#' @return Escaped text
#' @keywords internal
xml_escape <- function(text) {
  text <- gsub("&", "&amp;", text)
  text <- gsub("<", "&lt;", text)
  text <- gsub(">", "&gt;", text)
  text
}

#' XML Escape for Attribute Values
#'
#' Escapes all five XML entities for use in attribute values.
#'
#' @param text Text to escape for use in XML attributes
#' @return Escaped text safe for XML attributes
#' @keywords internal
xml_escape_attr <- function(text) {
  text <- xml_escape(text)
  text <- gsub('"', "&quot;", text)
  text <- gsub("'", "&apos;", text)
  text
}
