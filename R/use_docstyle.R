#' Update and verify a docstyle project
#'
#' One-command maintenance function that checks project health and synchronizes
#' the `_extensions/docstyle/` folder with the installed package version.
#' Equivalent to running `check_project()` followed by `update_extension()`.
#'
#' @param project_dir Path to the Quarto project directory. Defaults to current
#'   working directory.
#' @param backup Logical. If TRUE (default), backs up the existing extension to
#'   `_extensions/docstyle.bak/` before updating.
#' @param verbose Logical. If TRUE (default), prints diagnostic messages.
#'
#' @return Invisibly returns a list with:
#'   - `check`: result of [check_project()]
#'   - `update`: result of [update_extension()], or NULL if already up to date
#'
#' @examples
#' \dontrun{
#' # Update and verify current project
#' docstyle::update()
#'
#' # Update a specific project
#' docstyle::update("path/to/project")
#' }
#'
#' @export
update <- function(project_dir = ".", backup = TRUE, verbose = TRUE) {
  project_dir <- normalizePath(project_dir, mustWork = FALSE)

  if (verbose) message("[docstyle] Checking project health...")
  check <- check_project(project_dir, verbose = verbose)

  if (verbose) message("[docstyle] Synchronizing extension files...")
  upd <- update_extension(project_dir, backup = backup, verbose = verbose)

  if (verbose) {
    n_updated <- length(upd$added) + length(upd$updated)
    if (n_updated == 0) {
      message("[docstyle] Extension is up to date (v", upd$package_version, ")")
    } else {
      message("[docstyle] Updated ", n_updated, " file(s) to v", upd$package_version)
    }
    if (!check$valid) {
      message("[docstyle] Project check found ", length(check$issues$errors),
              " error(s) -- run check_project() for details")
    } else {
      message("[docstyle] Project check passed")
    }
  }

  invisible(list(check = check, update = upd))
}

#' Initialize a Quarto Project with docstyle
#'
#' One-command setup that installs the docstyle extension and configures
#' your Quarto project. This is the recommended way to get started with
#' docstyle.
#'
#' @param path Path to the Quarto project directory. Defaults to current
#'   working directory.
#' @param preset Character. Style preset to use. Can be either:
#'   - A preset name: `"default"`, `"formal"`, or `"academic"` (looks in
#'     package's `inst/presets/` directory)
#'   - A path to a custom preset folder containing `_quarto.yml` and
#'     `styles.css`
#' @param overwrite Logical. If TRUE, overwrites existing extension and
#'   configuration. Default is FALSE.
#'
#' @details
#' This function performs the following setup steps:
#'
#' 1. **Resolves preset**: Validates the preset folder contains `_quarto.yml`
#'    and `styles.css`
#' 2. **Installs extension**: Copies extension files to `_extensions/docstyle/`
#' 3. **Applies preset**: Copies or merges `_quarto.yml`, `styles.css`, and
#'    any extra files from the preset
#' 4. **Installs bootstrap scripts**: Copies pre-render and post-render
#'    scripts to `_docstyle/`
#'
#' After running `init()`, you can immediately render your document:
#'
#' ```r
#' # In R
#' quarto::quarto_render("document.qmd")
#'
#' # Or from terminal
#' # quarto render document.qmd
#' ```
#'
#' @section Presets:
#'
#' Built-in presets:
#' - **default**: Neutral starting point (Arial 11pt, single-spaced)
#' - **formal**: Professional documents like reports and charters
#'   (Calibri, coloured headings, TOC enabled)
#' - **academic**: Journal submission format (Times New Roman 12pt,
#'   double-spaced, paragraph indents)
#'
#' Custom presets can be stored anywhere and referenced by path:
#' ```r
#' init(preset = "~/my-presets/cihr")
#' ```
#'
#' A preset folder must contain:
#' - `_quarto.yml`: Project configuration (merged with existing)
#' - `styles.css`: Stylesheet (copied to project)
#'
#' @return Invisibly returns a list with paths to created/modified files.
#'
#' @examples
#' \dontrun{
#' # Initialize with default preset
#' init()
#'
#' # Initialize with formal preset (for reports)
#' init(preset = "formal")
#'
#' # Initialize with custom preset from path
#' init(preset = "~/github/my-presets/cihr")
#'
#' # Initialize a specific project directory
#' init("path/to/my-project", preset = "academic")
#' }
#'
#' @seealso [use_docstyle()] for extension-only installation without
#'   configuration.
#'
#' @export
init <- function(path = ".",
                 preset = "default",
                 overwrite = FALSE) {

  path <- normalizePath(path, mustWork = FALSE)

  # Resolve preset to a folder path

  preset_path <- resolve_preset(preset)

  # Check directory exists
  if (!dir.exists(path)) {
    stop("Directory does not exist: ", path, call. = FALSE)
  }

  # Install extension
  message("\n--- Installing docstyle extension ---")
  use_docstyle(path = path, overwrite = overwrite)

  # Copy preset files to project
  message("\n--- Applying preset: ", basename(preset_path), " ---")
  apply_preset(preset_path, path, overwrite = overwrite)

  # Copy bootstrap scripts to _docstyle/
  message("\n--- Installing bootstrap scripts ---")
  copy_bootstrap_scripts(path, overwrite = overwrite)

  # Success message
  message("\n", strrep("=", 50))
  message("docstyle initialized successfully!")
  message(strrep("=", 50))
  message("\nYour project is ready. Next steps:")
  message("1. Create a .qmd file (e.g., document.qmd)")
  message("2. Run: quarto render document.qmd")
  message("3. Customize styles in: styles.css")
  message("\n_extensions/ is auto-managed and can be gitignored.")
  message("For documentation: vignette('getting-started', package = 'docstyle')")

  invisible(list(
    quarto_yml = file.path(path, "_quarto.yml"),
    extension = file.path(path, "_extensions", "docstyle"),
    css = file.path(path, "styles.css"),
    bootstrap = file.path(path, "_docstyle"),
    preset = preset_path
  ))
}


#' Resolve Preset to Folder Path
#'
#' Resolves a preset specification to an actual folder path. The preset can be:
#' - A path to an existing folder (used directly)
#' - A preset name (looks in package's inst/presets/ directory)
#'
#' @param preset Character. Either a path or a preset name.
#' @return Path to the preset folder.
#' @noRd
resolve_preset <- function(preset) {
  # First check if it's a path that exists
  expanded_path <- path.expand(preset)
  if (dir.exists(expanded_path)) {
    # Validate preset folder structure
    validate_preset_folder(expanded_path)
    return(normalizePath(expanded_path))
  }

  # Otherwise, look for it in package presets
  pkg_preset <- system.file("presets", preset, package = "docstyle")

  if (pkg_preset == "" || !dir.exists(pkg_preset)) {
    # List available presets for helpful error message
    available <- list_available_presets()
    stop(
      "Preset not found: ", preset, "\n",
      "Available presets: ", paste(available, collapse = ", "), "\n",
      "Or provide a path to a custom preset folder.",
      call. = FALSE
    )
  }

  validate_preset_folder(pkg_preset)
  pkg_preset
}


#' Validate Preset Folder Structure
#'
#' Checks that a preset folder contains the required files.
#'
#' @param path Path to preset folder.
#' @noRd
validate_preset_folder <- function(path) {
  required_files <- c("_quarto.yml", "styles.css")
  missing <- required_files[!file.exists(file.path(path, required_files))]

  if (length(missing) > 0) {
    stop(
      "Preset folder missing required files: ", paste(missing, collapse = ", "),
      "\nPreset path: ", path,
      call. = FALSE
    )
  }

  invisible(TRUE)
}


#' List Available Package Presets
#'
#' Returns names of presets available in the package.
#'
#' @return Character vector of preset names.
#' @noRd
list_available_presets <- function() {
  presets_dir <- system.file("presets", package = "docstyle")
  if (presets_dir == "" || !dir.exists(presets_dir)) {
    return(character())
  }
  list.dirs(presets_dir, full.names = FALSE, recursive = FALSE)
}


#' Apply Preset to Project
#'
#' Copies preset files to the project directory.
#'
#' @param preset_path Path to the preset folder.
#' @param project_path Path to the project directory.
#' @param overwrite Logical. If TRUE, overwrites existing files.
#' @noRd
apply_preset <- function(preset_path, project_path, overwrite = FALSE) {
  # Copy _quarto.yml
  quarto_src <- file.path(preset_path, "_quarto.yml")
  quarto_dest <- file.path(project_path, "_quarto.yml")

  if (file.exists(quarto_dest) && !overwrite) {
    message("  _quarto.yml already exists, merging preset config...")
    merge_quarto_config(quarto_src, quarto_dest)
  } else {
    file.copy(quarto_src, quarto_dest, overwrite = TRUE)
    message("  Copied: _quarto.yml")
  }

  # Copy styles.css
  css_src <- file.path(preset_path, "styles.css")
  css_dest <- file.path(project_path, "styles.css")

  if (file.exists(css_dest) && !overwrite) {
    message("  styles.css already exists, keeping existing file.")
    message("  Use overwrite = TRUE to replace.")
  } else {
    file.copy(css_src, css_dest, overwrite = TRUE)
    message("  Copied: styles.css")
  }

  # Copy any additional files from preset (e.g., images, .gitignore, additional CSS)
  all_files <- list.files(preset_path, full.names = TRUE, all.files = TRUE)
  extra_files <- all_files[!basename(all_files) %in% c("_quarto.yml", "styles.css", ".", "..")]

  for (f in extra_files) {
    dest <- file.path(project_path, basename(f))
    if (!file.exists(dest) || overwrite) {
      file.copy(f, dest, overwrite = TRUE, recursive = dir.exists(f))
      message("  Copied: ", basename(f))
    }
  }

  invisible(TRUE)
}


#' Copy Bootstrap Scripts to Project
#'
#' Copies pre-render and post-render bootstrap scripts from the package
#' to the project's `_docstyle/` directory. These scripts auto-restore
#' `_extensions/docstyle/` if missing, allowing the extension directory
#' to be gitignored.
#'
#' @param path Project directory path.
#' @param overwrite Logical. If TRUE, overwrites existing scripts.
#' @noRd
copy_bootstrap_scripts <- function(path, overwrite = FALSE) {
  docstyle_dir <- file.path(path, "_docstyle")
  if (!dir.exists(docstyle_dir)) {
    dir.create(docstyle_dir, recursive = TRUE)
  }

  src_dir <- system.file("bootstrap", package = "docstyle")
  if (!nzchar(src_dir) || !dir.exists(src_dir)) {
    # Fallback for development: try inst/bootstrap relative to package root
    dev_dir <- file.path(find.package("docstyle", quiet = TRUE), "bootstrap")
    if (dir.exists(dev_dir)) {
      src_dir <- dev_dir
    } else {
      warning("Bootstrap scripts not found in docstyle package", call. = FALSE)
      return(invisible(FALSE))
    }
  }

  scripts <- c("pre-render.R", "post-render.R")
  for (script in scripts) {
    src <- file.path(src_dir, script)
    dest <- file.path(docstyle_dir, script)
    if (file.exists(src) && (!file.exists(dest) || overwrite)) {
      file.copy(src, dest, overwrite = TRUE)
      message("  Copied: _docstyle/", script)
    } else if (!file.exists(src)) {
      warning("Bootstrap script not found: ", script, call. = FALSE)
    }
  }

  invisible(TRUE)
}


#' Merge Quarto Configuration
#'
#' Merges preset _quarto.yml into existing project _quarto.yml.
#' Preset values fill in gaps but don't overwrite existing settings.
#'
#' @param preset_yml Path to preset _quarto.yml.
#' @param project_yml Path to project _quarto.yml.
#' @noRd
merge_quarto_config <- function(preset_yml, project_yml) {
  preset_config <- yaml::read_yaml(preset_yml)
  project_config <- yaml::read_yaml(project_yml)

  # Deep merge: preset fills gaps, project takes precedence
  merged <- merge_lists_recursive(preset_config, project_config)

  # Use YAML 1.2 booleans (true/false) -- Quarto rejects YAML 1.1 yes/no
  yaml::write_yaml(
    merged, project_yml,
    handlers = list(
      logical = function(x) {
        result <- ifelse(x, "true", "false")
        class(result) <- "verbatim"
        result
      }
    )
  )
  message("  Merged preset config into existing _quarto.yml")
}


#' Recursively Merge Two Lists
#'
#' Merges two lists recursively. Values from list2 take precedence.
#'
#' @param list1 Base list (preset defaults).
#' @param list2 Override list (existing project config).
#' @return Merged list.
#' @noRd
merge_lists_recursive <- function(list1, list2) {
  if (is.null(list2)) return(list1)
  if (is.null(list1)) return(list2)

  # If either is not a list, list2 wins
  if (!is.list(list1) || !is.list(list2)) {
    return(list2)
  }

  # Merge keys
  all_keys <- unique(c(names(list1), names(list2)))
  result <- list()

  for (key in all_keys) {
    if (key %in% names(list2) && key %in% names(list1)) {
      # Both have this key - recurse
      result[[key]] <- merge_lists_recursive(list1[[key]], list2[[key]])
    } else if (key %in% names(list2)) {
      # Only list2 has it
      result[[key]] <- list2[[key]]
    } else {
      # Only list1 has it
      result[[key]] <- list1[[key]]
    }
  }

  result
}


#' Install docstyle Quarto Extension
#'
#' Installs the docstyle Quarto extension into a project directory.
#' This copies the extension files from the R package to the project's
#' `_extensions/docstyle/` directory.
#'
#' @param path Path to the Quarto project directory. Defaults to current
#'   working directory.
#' @param overwrite Logical. If TRUE, overwrites existing extension files.
#'
#' @details
#' This function provides an alternative to `quarto add dmanuel/docstyle` that
#' works offline and ensures version consistency with the R package.
#'
#' The extension includes:
#' - Lua filters for character styles, tables, TOC, version history, etc
#' - R scripts for reference document generation and post-render processing
#' - Extension configuration (`_extension.yml`)
#'
#' After installation, configure your `_quarto.yml` to use the extension:
#'
#' ```yaml
#' format:
#'   docstyle-docx:
#'     docstyle:
#'       css: styles.css
#'       # ... other options
#' ```
#'
#' @return Invisibly returns the path to the installed extension directory.
#'
#' @examples
#' \dontrun{
#' # Install in current project
#' use_docstyle()
#'
#' # Install in a specific project
#' use_docstyle("path/to/my-quarto-project")
#'
#' # Force update existing installation
#' use_docstyle(overwrite = TRUE)
#' }
#'
#' @export
use_docstyle <- function(path = ".", overwrite = FALSE) {
  # Resolve paths

path <- normalizePath(path, mustWork = FALSE)

  # Check if path exists
  if (!dir.exists(path)) {
    stop("Directory does not exist: ", path, call. = FALSE)
  }

  # Find extension source in installed package
  ext_source <- system.file("_extensions", "docstyle", package = "docstyle")

  if (ext_source == "" || !dir.exists(ext_source)) {
    stop("Extension files not found in docstyle package. ",
         "The package may not be properly installed.", call. = FALSE)
  }

  # Destination directory
  ext_dest <- file.path(path, "_extensions", "docstyle")

  # Check for existing installation
  if (dir.exists(ext_dest)) {
    if (!overwrite) {
      message("docstyle extension already installed at: ", ext_dest)
      message("Use overwrite = TRUE to update.")
      return(invisible(ext_dest))
    }
    message("Updating existing docstyle extension...")
    unlink(ext_dest, recursive = TRUE)
  }

  # Create _extensions directory if needed
  ext_parent <- file.path(path, "_extensions")
  if (!dir.exists(ext_parent)) {
    dir.create(ext_parent, recursive = TRUE)
  }

  # Copy extension files
  success <- file.copy(
    from = ext_source,
    to = ext_parent,
    recursive = TRUE,
    overwrite = TRUE
  )

  if (!success) {
    stop("Failed to copy extension files to: ", ext_dest, call. = FALSE)
  }

  # Sync the destination _extension.yml's version field with the
  # installed package version (see update_extension() for rationale).
  sync_extension_version(
    file.path(ext_dest, "_extension.yml"),
    as.character(utils::packageVersion("docstyle"))
  )

  # List installed files
  installed_files <- list.files(ext_dest, recursive = TRUE)

  message("Installed docstyle extension to: ", ext_dest)
  message("Files installed:")
  for (f in installed_files) {
    message("- ", f)
  }

  # Provide next steps
  message("\nNext steps:")
  message("1. Create or update _quarto.yml with format: docstyle-docx")
  message("2. Create a CSS file for your styles")
  message("3. Run: quarto render")
  message("\nSee vignette('tutorial-getting-started') for details.")

  invisible(ext_dest)
}


#' Check if docstyle Extension is Installed
#'
#' Checks whether the docstyle Quarto extension is installed in a project.
#'
#' @param path Path to the Quarto project directory. Defaults to current
#'   working directory.
#'
#' @return Logical. TRUE if extension is installed, FALSE otherwise.
#'
#' @examples
#' \dontrun{
#' if (!has_docstyle()) {
#'   use_docstyle()
#' }
#' }
#'
#' @export
has_docstyle <- function(path = ".") {
  ext_path <- file.path(path, "_extensions", "docstyle", "_extension.yml")
  file.exists(ext_path)
}


#' Set Up Preprint Profile
#'
#' Writes `_quarto-preprint.yml` into a docstyle project, enabling the same
#' QMD source to render to preprint-typst (PDF) without modification. The
#' profile uses `strip-docstyle.lua` (bundled in the extension) to handle
#' docstyle-specific constructs -- section wrappers, author plates, version
#' history, bibliography placement -- that don't apply to typst output.
#'
#' To render with the profile:
#' ```
#' quarto render document.qmd --profile preprint
#' ```
#'
#' @param path Path to the Quarto project directory. Defaults to current
#'   working directory.
#' @param overwrite Logical. If TRUE, overwrite an existing
#'   `_quarto-preprint.yml`. Default FALSE. No backup is created before
#'   overwriting.
#' @param theme Character. preprint-typst theme. One of `"jou"` (journal,
#'   two-column), `"man"` (manuscript, one-column), `"stu"` (student,
#'   one-column). Default `"man"`.
#'
#' @return Invisibly returns the path to the written file.
#'
#' @examples
#' \dontrun{
#' use_preprint_profile()
#' use_preprint_profile(theme = "jou")
#' }
#'
#' @seealso [use_docstyle()] to install the extension
#'
#' @export
use_preprint_profile <- function(path = ".", overwrite = FALSE, theme = "man") {
  path <- normalizePath(path, mustWork = FALSE)

  if (!dir.exists(path)) {
    stop("Directory does not exist: ", path, call. = FALSE)
  }

  valid_themes <- c("jou", "man", "stu")
  if (!theme %in% valid_themes) {
    stop("Invalid theme: '", theme, "'. Must be one of: ",
         paste(valid_themes, collapse = ", "), ".", call. = FALSE)
  }

  # Verify extension is installed (strip-docstyle.lua lives there)
  filter_path <- file.path(path, "_extensions", "docstyle", "strip-docstyle.lua")
  if (!file.exists(filter_path)) {
    stop("strip-docstyle.lua not found. Run use_docstyle() first to install ",
         "the extension.", call. = FALSE)
  }

  profile_path <- file.path(path, "_quarto-preprint.yml")
  if (file.exists(profile_path) && !overwrite) {
    message("[use_preprint_profile] _quarto-preprint.yml already exists at: ", profile_path)
    message("[use_preprint_profile] Use overwrite = TRUE to replace it.")
    return(invisible(profile_path))
  }

  profile_content <- paste0(
    "format:\n",
    "  preprint-typst:\n",
    "    filters:\n",
    "      - _extensions/docstyle/strip-docstyle.lua\n",
    "    theme: \"", theme, "\"\n",
    "    line-number: false\n"
  )

  tryCatch(
    writeLines(profile_content, profile_path),
    error = function(e) {
      stop("[use_preprint_profile] Failed to write _quarto-preprint.yml to ",
           profile_path, ": ", conditionMessage(e),
           "\nCheck directory permissions and available disk space.",
           call. = FALSE)
    }
  )

  message("[use_preprint_profile] Written: ", profile_path)
  message("[use_preprint_profile] To render as preprint:")
  message("  quarto render document.qmd --profile preprint")
  message("[use_preprint_profile] Requires the preprint-typst Quarto extension:")
  message("  quarto add andrewheiss/quarto-preprint")

  invisible(profile_path)
}


#' Get docstyle Extension Version
#'
#' Returns version information for the installed docstyle extension.
#'
#' @param path Path to the Quarto project directory. Defaults to current
#'   working directory.
#'
#' @return A list with version information, or NULL if not installed.
#'
#' @examples
#' \dontrun{
#' docstyle_version()
#' }
#'
#' @export
docstyle_version <- function(path = ".") {
  ext_yml <- file.path(path, "_extensions", "docstyle", "_extension.yml")

  if (!file.exists(ext_yml)) {
    return(NULL)
  }

  config <- yaml::read_yaml(ext_yml)

  list(
    title = config$title,
    version = config$version,
    path = dirname(ext_yml)
  )
}


# --- Constants ---------------------------------------------------------------

#' Source files that should be synced between the package and project extensions.
#' Excludes generated files (reference.docx, reference.docx.hash).
#' IMPORTANT: Update this list when adding or removing files from
#' inst/_extensions/docstyle/. A test verifies this list against the actual
#' directory contents.
#' @noRd
EXTENSION_SOURCE_FILES <- c(
  "_extension.yml",
  "default.css",
  "generate-reference.R",
  "update-field-codes.R",
  "validate-markup.R",
  "author-plate.lua",
  "char-style.lua",
  "comment-inject.lua",
  "field-code-utils.lua",
  "figure.lua",
  "abstract.lua",
  "anchor.lua",
  "jats-fixups.lua",
  "list-style.lua",
  "page-section.lua",
  "preprint",
  "revisions-inject.lua",
  "strip-docstyle.lua",
  "table-style.lua",
  "toc-field.lua",
  "typst-bool-overrides.lua",
  "version-history.lua",
  "zotero-inject.lua"
)


# --- Internal helpers --------------------------------------------------------

#' Rewrite the `version:` field of an `_extension.yml` to a target string
#'
#' Line-based regex replacement, deliberately not a full YAML round-trip,
#' to preserve comments and structure. Matches the first top-level
#' `version:` line and substitutes the target value. Returns invisibly.
#' @noRd
sync_extension_version <- function(yml_path, version) {
  if (!file.exists(yml_path)) return(invisible(FALSE))
  lines <- readLines(yml_path, warn = FALSE)
  ver_line <- grep("^version:[[:space:]]", lines)
  if (length(ver_line) == 0) {
    # No version field — append one near the top (after title/author if any)
    insert_at <- max(c(0, grep("^(title|author|description):", lines)))
    lines <- append(lines, paste0("version: ", version), after = insert_at)
  } else {
    lines[ver_line[1]] <- paste0("version: ", version)
  }
  writeLines(lines, yml_path)
  invisible(TRUE)
}


#' Extract YAML Front Matter from a QMD File
#'
#' Reads the YAML block between `---` delimiters at the start of a QMD file.
#'
#' @param qmd_path Path to the QMD file.
#' @return Parsed list from YAML, or NULL if no front matter found.
#' @noRd
extract_qmd_yaml <- function(qmd_path) {
  lines <- readLines(qmd_path, warn = FALSE)
  if (length(lines) == 0 || trimws(lines[1]) != "---") return(NULL)

  # Find closing delimiter
  end <- NULL
  for (i in seq(2, length(lines))) {
    if (trimws(lines[i]) %in% c("---", "...")) {
      end <- i
      break
    }
  }
  if (is.null(end)) return(NULL)

  yaml_text <- paste(lines[2:(end - 1)], collapse = "\n")
  tryCatch(
    yaml::yaml.load(yaml_text),
    error = function(e) {
      warning("Failed to parse YAML in ", basename(qmd_path), ": ",
              conditionMessage(e), call. = FALSE)
      NULL
    }
  )
}


#' Extract Citation Keys from a QMD File
#'
#' Reads QMD text (excluding YAML front matter) and extracts all Pandoc-style
#' citation keys: `[@key]`, `[-@key]`, and `[@key1; @key2]`.
#'
#' Only detects bracketed citations; in-text citations without brackets (e.g.,
#' `@smith2020`) are not extracted. Keys must begin with a letter.
#'
#' @param qmd_path Path to the QMD file.
#' @return Character vector of unique citation keys (without @ prefix).
#' @noRd
extract_qmd_citekeys <- function(qmd_path) {
  lines <- readLines(qmd_path, warn = FALSE)

  # Skip YAML front matter
  start <- 1L
  if (length(lines) > 0 && trimws(lines[1]) == "---") {
    for (i in seq(2, length(lines))) {
      if (trimws(lines[i]) %in% c("---", "...")) {
        start <- i + 1L
        break
      }
    }
  }

  if (start > length(lines)) return(character())
  text <- paste(lines[start:length(lines)], collapse = "\n")

  # Match citation groups: [@key], [-@key], [see @key1; @key2, p. 42]
  # Extracts all @citekey tokens from within [...] brackets
  bracket_pattern <- "\\[[^\\]]*@[a-zA-Z][^\\]]*\\]"
  brackets <- regmatches(text, gregexpr(bracket_pattern, text, perl = TRUE))[[1]]

  if (length(brackets) == 0) return(character())

  # Extract individual @keys from each bracket group
  key_pattern <- "-?@([a-zA-Z][a-zA-Z0-9_:./-]*)"
  keys <- character()
  for (group in brackets) {
    matches <- regmatches(group, gregexpr(key_pattern, group, perl = TRUE))[[1]]
    # Strip optional - and @ prefix
    parts <- gsub("^-?@", "", matches)
    keys <- c(keys, parts)
  }

  unique(keys)
}


#' Compare Extension Files Between Source and Destination
#'
#' @param source_dir Path to the package extension directory.
#' @param dest_dir Path to the project extension directory.
#' @param inventory Character vector of expected filenames.
#' @return List with `added`, `updated`, `unchanged`, `extra` character vectors.
#' @noRd
compare_extension_files <- function(source_dir, dest_dir, inventory) {
  added <- character()
  updated <- character()
  unchanged <- character()

  for (f in inventory) {
    src <- file.path(source_dir, f)
    dst <- file.path(dest_dir, f)

    if (!file.exists(src)) next  # source missing -- skip

    if (!file.exists(dst) && !dir.exists(dst)) {
      added <- c(added, f)
    } else if (dir.exists(src)) {
      # For directories, compare all contained files recursively
      src_files <- list.files(src, recursive = TRUE, full.names = FALSE)
      changed <- FALSE
      for (sf in src_files) {
        sf_src <- file.path(src, sf)
        sf_dst <- file.path(dst, sf)
        if (!file.exists(sf_dst)) { changed <- TRUE; break }
        if (digest::digest(file = sf_src, algo = "md5") !=
            digest::digest(file = sf_dst, algo = "md5")) { changed <- TRUE; break }
      }
      # Also flag as changed if destination has files not present in source
      if (!changed && dir.exists(dst)) {
        dst_sub_files <- list.files(dst, recursive = TRUE, full.names = FALSE)
        if (length(setdiff(dst_sub_files, src_files)) > 0) changed <- TRUE
      }
      if (changed) updated <- c(updated, f) else unchanged <- c(unchanged, f)
    } else {
      src_hash <- digest::digest(file = src, algo = "md5")
      dst_hash <- digest::digest(file = dst, algo = "md5")
      if (src_hash != dst_hash) {
        updated <- c(updated, f)
      } else {
        unchanged <- c(unchanged, f)
      }
    }
  }

  # Files in dest not in inventory (and not generated)
  dest_files <- list.files(dest_dir, recursive = FALSE)
  generated <- c("reference.docx", "reference.docx.hash")
  extra <- setdiff(dest_files, c(inventory, generated))
  # For inventory entries that are directories, also flag stale files inside them
  for (f in inventory) {
    src_d <- file.path(source_dir, f)
    dst_d <- file.path(dest_dir, f)
    if (dir.exists(src_d) && dir.exists(dst_d)) {
      src_sub <- list.files(src_d, recursive = TRUE, full.names = FALSE)
      dst_sub <- list.files(dst_d, recursive = TRUE, full.names = FALSE)
      stale <- setdiff(dst_sub, src_sub)
      if (length(stale) > 0) {
        extra <- c(extra, file.path(f, stale))
      }
    }
  }

  list(added = added, updated = updated,
       unchanged = unchanged, extra = extra)
}


# --- Exported functions ------------------------------------------------------

#' Update docstyle Extension in a Project
#'
#' Syncs extension files from the installed docstyle R package to the project's
#' `_extensions/docstyle/` directory. Only copies files that have changed,
#' optionally backing up the existing extension first.
#'
#' @param project_dir Path to the Quarto project directory. Defaults to
#'   current working directory.
#' @param backup Logical. If TRUE (default), backs up the existing extension
#'   to `_extensions/docstyle.bak/` before updating.
#' @param verbose Logical. If TRUE (default), prints progress messages.
#'
#' @return Invisibly returns a list with:
#'   - `added`: filenames added (new in this version)
#'   - `updated`: filenames that changed
#'   - `unchanged`: filenames identical to package version
#'   - `extra`: filenames in project not in package inventory
#'   - `backup_path`: path to backup directory, or NULL
#'   - `cache_invalidated`: whether the reference.docx cache was cleared
#'   - `package_version`: installed docstyle version string
#'
#' @examples
#' \dontrun{
#' # Update extension in current project
#' update_extension()
#'
#' # Update without backup
#' update_extension(backup = FALSE)
#'
#' # Update a specific project
#' update_extension("path/to/project")
#' }
#'
#' @export
update_extension <- function(project_dir = ".",
                             backup = TRUE,
                             verbose = TRUE) {
  project_dir <- normalizePath(project_dir, mustWork = FALSE)
  if (!dir.exists(project_dir)) {
    stop("Directory does not exist: ", project_dir, call. = FALSE)
  }

  # Locate source in installed package
  ext_source <- system.file("_extensions", "docstyle", package = "docstyle")
  if (ext_source == "" || !dir.exists(ext_source)) {
    stop("Extension files not found in docstyle package. ",
         "The package may not be properly installed.", call. = FALSE)
  }

  ext_dest <- file.path(project_dir, "_extensions", "docstyle")
  pkg_version <- as.character(utils::packageVersion("docstyle"))

  # If no existing extension, delegate to use_docstyle
  if (!has_docstyle(project_dir)) {
    if (verbose) {
      message("[update-extension] No existing extension found, installing fresh")
    }
    use_docstyle(project_dir, overwrite = TRUE)
    return(invisible(list(
      added = EXTENSION_SOURCE_FILES,
      updated = character(),
      unchanged = character(),
      extra = character(),
      backup_path = NULL,
      cache_invalidated = FALSE,
      package_version = pkg_version
    )))
  }

  # Compare files
  diff <- compare_extension_files(ext_source, ext_dest, EXTENSION_SOURCE_FILES)

  n_changes <- length(diff$added) + length(diff$updated)
  if (n_changes == 0) {
    if (verbose) {
      message("[update-extension] Extension is up to date (",
              length(diff$unchanged), " files match package v", pkg_version, ")")
    }
    return(invisible(list(
      added = character(),
      updated = character(),
      unchanged = diff$unchanged,
      extra = diff$extra,
      backup_path = NULL,
      cache_invalidated = FALSE,
      package_version = pkg_version
    )))
  }

  # Backup existing extension
  backup_path <- NULL
  if (backup) {
    backup_path <- file.path(project_dir, "_extensions", "docstyle.bak")
    if (dir.exists(backup_path)) {
      result <- unlink(backup_path, recursive = TRUE)
      if (result != 0) {
        warning("Could not fully remove previous backup at ", backup_path,
                call. = FALSE)
      }
    }
    ok <- dir.create(backup_path, recursive = TRUE)
    if (!ok && !dir.exists(backup_path)) {
      stop("Cannot create backup directory: ", backup_path,
           "\nCheck file permissions.", call. = FALSE)
    }
    old_files <- list.files(ext_dest, full.names = TRUE)
    backup_ok <- file.copy(old_files, backup_path, recursive = TRUE)
    if (!all(backup_ok)) {
      failed <- basename(old_files[!backup_ok])
      stop("Backup failed for ", length(failed), " file(s): ",
           paste(failed, collapse = ", "),
           "\nAborting update to protect existing extension files.",
           call. = FALSE)
    }
    if (verbose) {
      message("[update-extension] Backed up existing extension to docstyle.bak/")
    }
  }

  # Copy changed files
  copy_failures <- character()
  for (f in c(diff$added, diff$updated)) {
    src <- file.path(ext_source, f)
    dst <- file.path(ext_dest, f)
    if (dir.exists(src)) {
      src_rel <- list.files(src, recursive = TRUE)
      dst_files <- file.path(dst, src_rel)
      needed_dirs <- unique(dirname(dst_files))
      dir_ok <- vapply(needed_dirs, dir.create, logical(1),
                       recursive = TRUE, showWarnings = FALSE)
      failed_dirs <- needed_dirs[!dir_ok & !dir.exists(needed_dirs)]
      if (length(failed_dirs) > 0) {
        stop("Cannot create destination directories: ",
             paste(failed_dirs, collapse = ", "),
             "\nCheck file permissions.", call. = FALSE)
      }
      copied <- file.copy(file.path(src, src_rel), dst_files, overwrite = TRUE)
      copy_failures <- c(copy_failures, dst_files[!copied])
    } else {
      if (!file.copy(src, dst, overwrite = TRUE)) copy_failures <- c(copy_failures, f)
    }
  }
  if (length(copy_failures) > 0) {
    stop("Failed to copy ", length(copy_failures), " file(s): ",
         paste(copy_failures, collapse = ", "),
         "\nCheck file permissions and disk space.", call. = FALSE)
  }

  # Rewrite the destination _extension.yml's version field to match the
  # installed package. The bundled source manifest's version isn't
  # tightly coupled to DESCRIPTION's Version (historically frozen at
  # an early value), so without this rewrite check_extension_drift()
  # would falsely report drift on every render right after update.
  sync_extension_version(file.path(ext_dest, "_extension.yml"), pkg_version)

  # Invalidate reference.docx cache
  cache_invalidated <- FALSE
  sidecar_dir <- "_docstyle"
  proj_config <- suppressWarnings(tryCatch(
    read_quarto_config(project_dir),
    error = function(e) NULL
  ))
  if (!is.null(proj_config) && !is.null(proj_config$docstyle$`sidecar-dir`)) {
    sidecar_dir <- proj_config$docstyle$`sidecar-dir`
  }
  hash_file <- file.path(project_dir, sidecar_dir, "reference.docx.hash")
  if (file.exists(hash_file)) {
    removed <- file.remove(hash_file)
    if (removed) {
      cache_invalidated <- TRUE
    } else {
      warning("Could not remove cache file: ", hash_file,
              "\nDelete it manually to force reference.docx regeneration.",
              call. = FALSE)
    }
  }

  # Report
  if (verbose) {
    message("[update-extension] Updated to package v", pkg_version, ":")
    if (length(diff$added) > 0) {
      message("  Added: ", paste(diff$added, collapse = ", "))
    }
    if (length(diff$updated) > 0) {
      message("  Updated: ", paste(diff$updated, collapse = ", "))
    }
    message("  Unchanged: ", length(diff$unchanged), " file(s)")
    if (length(diff$extra) > 0) {
      message("  Extra (not in package): ", paste(diff$extra, collapse = ", "))
    }
    if (cache_invalidated) {
      message("  Cache: reference.docx.hash removed (will regenerate on next render)")
    }
  }

  invisible(list(
    added = diff$added,
    updated = diff$updated,
    unchanged = diff$unchanged,
    extra = diff$extra,
    backup_path = backup_path,
    cache_invalidated = cache_invalidated,
    package_version = pkg_version
  ))
}


#' Check Project Health
#'
#' Validates that a docstyle project is correctly configured. Checks extension
#' installation and completeness, Quarto format configuration, QMD header
#' pitfalls, sidecar directory and JSON validity, citation coverage and
#' bibliography placeholder, and version consistency.
#'
#' @param project_dir Path to the Quarto project directory. Defaults to
#'   current working directory.
#' @param qmd_files Character vector of QMD file paths to check. If NULL
#'   (default), auto-detects QMD files in the project directory.
#' @param verbose Logical. If TRUE (default), prints diagnostic messages.
#'
#' @return A list with:
#'   - `valid`: TRUE if no errors found
#'   - `checks`: named logical list of individual check results
#'   - `issues`: list with `errors` and `warnings` character vectors
#'
#' @examples
#' \dontrun{
#' result <- check_project()
#' if (!result$valid) {
#'   cat("Errors:\n")
#'   for (err in result$issues$errors) cat("  -", err, "\n")
#' }
#' }
#'
#' @export
check_project <- function(project_dir = ".",
                          qmd_files = NULL,
                          verbose = TRUE) {
  project_dir <- normalizePath(project_dir, mustWork = FALSE)
  if (!dir.exists(project_dir)) {
    stop("Directory does not exist: ", project_dir, call. = FALSE)
  }

  errors <- character()
  warnings <- character()
  checks <- list()

  msg <- function(...) if (verbose) message("[check-project] ", ...)

  # --- Check 1: Extension installed ---
  checks$extension_installed <- has_docstyle(project_dir)
  if (!checks$extension_installed) {
    errors <- c(errors, "docstyle extension not installed (run init() or use_docstyle())")
    msg("FAIL: Extension not installed")
  } else {
    msg("OK: Extension installed")
  }

  # --- Check 2: Extension completeness ---
  ext_dir <- file.path(project_dir, "_extensions", "docstyle")
  if (checks$extension_installed) {
    ext_files <- list.files(ext_dir, recursive = FALSE)
    missing_files <- setdiff(EXTENSION_SOURCE_FILES, ext_files)
    # For directory entries, also verify the directory is non-empty
    empty_dirs <- character()
    for (f in intersect(EXTENSION_SOURCE_FILES, ext_files)) {
      fpath <- file.path(ext_dir, f)
      if (dir.exists(fpath) && length(list.files(fpath, recursive = TRUE)) == 0) {
        empty_dirs <- c(empty_dirs, f)
      }
    }
    checks$extension_complete <- length(missing_files) == 0 && length(empty_dirs) == 0
    if (length(missing_files) > 0) {
      errors <- c(errors, paste0("Missing extension files: ",
                                 paste(missing_files, collapse = ", ")))
      msg("FAIL: Missing ", length(missing_files), " extension file(s)")
    } else if (length(empty_dirs) > 0) {
      errors <- c(errors, paste0("Empty extension directories: ",
                                 paste(empty_dirs, collapse = ", ")))
      msg("FAIL: Empty extension director(ies): ", paste(empty_dirs, collapse = ", "))
    } else {
      msg("OK: Extension complete (", length(EXTENSION_SOURCE_FILES), " files)")
    }
  } else {
    checks$extension_complete <- FALSE
  }

  # --- Check 3: Quarto format ---
  config_parse_failed <- FALSE
  config <- suppressWarnings(tryCatch(
    read_quarto_config(project_dir),
    error = function(e) {
      errors <<- c(errors, paste0("_quarto.yml is malformed: ", conditionMessage(e)))
      msg("FAIL: _quarto.yml parse error")
      config_parse_failed <<- TRUE
      NULL
    }
  ))
  if (is.null(config)) {
    checks$quarto_format <- FALSE
    if (!config_parse_failed) {
      errors <- c(errors, "_quarto.yml not found")
      msg("FAIL: No _quarto.yml")
    }
  } else {
    # Check for docstyle-docx format (can be nested under format: key)
    format_keys <- names(config$format)
    has_docstyle_format <- "docstyle-docx" %in% format_keys
    has_plain_docx <- "docx" %in% format_keys

    if (has_plain_docx && !has_docstyle_format) {
      checks$quarto_format <- FALSE
      errors <- c(errors,
                  "format: docx in _quarto.yml bypasses Lua filters; use docstyle-docx")
      msg("FAIL: format is 'docx' instead of 'docstyle-docx'")
    } else if (has_docstyle_format) {
      checks$quarto_format <- TRUE
      msg("OK: Format is docstyle-docx")
    } else {
      checks$quarto_format <- FALSE
      warnings <- c(warnings,
                    "No docx format found in _quarto.yml (expected docstyle-docx)")
      msg("WARN: No docx format found in _quarto.yml")
    }
  }

  # --- Auto-detect QMD files ---
  if (is.null(qmd_files)) {
    qmd_files <- list.files(project_dir, pattern = "\\.qmd$",
                            full.names = TRUE, recursive = FALSE)
  }

  # --- Check 4: QMD headers ---
  checks$qmd_headers <- TRUE
  if (length(qmd_files) == 0) {
    warnings <- c(warnings, "No QMD files found in project directory")
    msg("WARN: No QMD files found")
  } else {
    for (qmd in qmd_files) {
      qmd_name <- basename(qmd)
      yaml_parse_failed <- FALSE
      yaml_data <- withCallingHandlers(
        extract_qmd_yaml(qmd),
        warning = function(w) {
          if (grepl("Failed to parse YAML", conditionMessage(w))) {
            warnings <<- c(warnings, paste0(qmd_name,
                                            ": could not parse YAML (skipped header checks)"))
            yaml_parse_failed <<- TRUE
            invokeRestart("muffleWarning")
          }
        }
      )
      if (is.null(yaml_data)) next

      if (!is.null(yaml_data$bibliography)) {
        checks$qmd_headers <- FALSE
        errors <- c(errors, paste0(qmd_name,
                                   ": has 'bibliography:' (causes duplicate citation processing)"))
      }
      if (!is.null(yaml_data$csl)) {
        checks$qmd_headers <- FALSE
        errors <- c(errors, paste0(qmd_name,
                                   ": has 'csl:' (citations handled by Zotero field codes)"))
      }
      if (!is.null(yaml_data$`reference-doc`)) {
        checks$qmd_headers <- FALSE
        errors <- c(errors, paste0(qmd_name,
                                   ": has 'reference-doc:' (bypasses dynamic style generation)"))
      }
      # Check for format: docx override in QMD (both scalar and named-list forms)
      if (!is.null(yaml_data$format)) {
        has_qmd_docx <- FALSE
        if (is.character(yaml_data$format) && "docx" %in% yaml_data$format) {
          has_qmd_docx <- TRUE
        } else if (is.list(yaml_data$format) && "docx" %in% names(yaml_data$format)) {
          has_qmd_docx <- TRUE
        }
        if (has_qmd_docx) {
          checks$qmd_headers <- FALSE
          errors <- c(errors, paste0(qmd_name,
                                     ": has 'format: docx' (use docstyle-docx in _quarto.yml)"))
        }
      }
    }
    if (checks$qmd_headers) {
      msg("OK: QMD headers clean (", length(qmd_files), " file(s))")
    }
  }

  # --- Check 5: Sidecar directory ---
  sidecar_dir <- "_docstyle"
  if (!is.null(config) && !is.null(config$docstyle$`sidecar-dir`)) {
    sidecar_dir <- config$docstyle$`sidecar-dir`
  }
  sidecar_path <- file.path(project_dir, sidecar_dir)
  checks$sidecar_exists <- dir.exists(sidecar_path)
  if (!checks$sidecar_exists) {
    warnings <- c(warnings, paste0("Sidecar directory '", sidecar_dir,
                                   "' not found (needed for citations and comments)"))
    msg("WARN: Sidecar directory not found")
  } else {
    msg("OK: Sidecar directory exists")
  }

  # --- Check 6: Sidecar JSON validity ---
  # Parse field-codes.json once here, reuse in checks 7 and 9
  checks$sidecar_valid <- TRUE
  fc_parsed <- NULL
  if (checks$sidecar_exists) {
    json_files <- list.files(sidecar_path, pattern = "\\.json$",
                             full.names = TRUE)
    for (jf in json_files) {
      parsed <- tryCatch(
        jsonlite::fromJSON(jf, simplifyVector = FALSE),
        error = function(e) e
      )
      if (inherits(parsed, "error")) {
        checks$sidecar_valid <- FALSE
        errors <- c(errors, paste0("Invalid JSON: ", basename(jf),
                                   " (", conditionMessage(parsed), ")"))
        msg("FAIL: ", basename(jf), " is not valid JSON")
      } else if (basename(jf) == "field-codes.json") {
        fc_parsed <- parsed
      }
    }
    if (checks$sidecar_valid) {
      msg("OK: Sidecar JSON files valid (", length(json_files), " file(s))")
    }
  }

  # --- Check 7: Citation coverage ---
  checks$citation_coverage <- TRUE
  all_qmd_keys <- character()
  for (qmd in qmd_files) {
    all_qmd_keys <- c(all_qmd_keys, extract_qmd_citekeys(qmd))
  }
  all_qmd_keys <- unique(all_qmd_keys)

  if (length(all_qmd_keys) > 0 && checks$sidecar_exists) {
    fc_path <- file.path(sidecar_path, "field-codes.json")
    if (!is.null(fc_parsed)) {
      # Use already-parsed field-codes.json from Check 6
      if (!is.null(fc_parsed$citations)) {
        available_keys <- names(fc_parsed$citations)
        missing_keys <- setdiff(all_qmd_keys, available_keys)
        if (length(missing_keys) > 0) {
          checks$citation_coverage <- FALSE
          errors <- c(errors, paste0(length(missing_keys),
                                     " citation key(s) in QMD not found in field-codes.json: ",
                                     paste(utils::head(missing_keys, 5), collapse = ", "),
                                     if (length(missing_keys) > 5) " ..." else ""))
          msg("FAIL: ", length(missing_keys), " uncovered citation key(s)")
        } else {
          msg("OK: All ", length(all_qmd_keys),
              " citation key(s) found in field-codes.json")
        }
      } else {
        checks$citation_coverage <- FALSE
        warnings <- c(warnings,
                      "field-codes.json exists but has no citations entry")
        msg("WARN: field-codes.json has no citations")
      }
    } else if (file.exists(fc_path)) {
      # field-codes.json exists but failed parsing in Check 6
      checks$citation_coverage <- FALSE
      errors <- c(errors, "Cannot check citation coverage: field-codes.json is invalid")
      msg("FAIL: Cannot check citations (invalid field-codes.json)")
    } else {
      checks$citation_coverage <- FALSE
      errors <- c(errors, paste0(length(all_qmd_keys),
                                 " citation(s) in QMD but field-codes.json not found"))
      msg("FAIL: Citations found but no field-codes.json")
    }
  } else if (length(all_qmd_keys) == 0) {
    msg("OK: No citations in QMD (skipping coverage check)")
  } else {
    # Citations exist but sidecar directory is missing
    checks$citation_coverage <- FALSE
    errors <- c(errors, paste0(length(all_qmd_keys),
                               " citation(s) in QMD but sidecar directory not found"))
    msg("FAIL: Citations found but no sidecar directory")
  }

  # --- Check 8: Bibliography div ---
  checks$bibliography_div <- TRUE
  if (length(all_qmd_keys) > 0) {
    has_bibl_div <- FALSE
    for (qmd in qmd_files) {
      text <- paste(readLines(qmd, warn = FALSE), collapse = "\n")
      if (grepl(":::\\s*\\{?\\.?bibliography", text, perl = TRUE)) {
        has_bibl_div <- TRUE
        break
      }
    }
    if (!has_bibl_div) {
      checks$bibliography_div <- FALSE
      warnings <- c(warnings,
                    "QMD has citations but no '::: bibliography :::' div placeholder")
      msg("WARN: No bibliography div found (citations won't have a bibliography)")
    } else {
      msg("OK: Bibliography div placeholder present")
    }
  }

  # --- Check 9: Version consistency ---
  checks$version_consistent <- TRUE
  pkg_version <- as.character(utils::packageVersion("docstyle"))
  if (checks$sidecar_exists && !is.null(fc_parsed)) {
    if (!is.null(fc_parsed$docstyle_version)) {
      sidecar_version <- fc_parsed$docstyle_version
      if (sidecar_version != pkg_version) {
        checks$version_consistent <- FALSE
        warnings <- c(warnings, paste0(
          "Sidecar data harvested with docstyle v", sidecar_version,
          " but installed version is v", pkg_version,
          " (consider re-harvesting)"))
        msg("WARN: Version mismatch (sidecar: v", sidecar_version,
            ", installed: v", pkg_version, ")")
      } else {
        msg("OK: Version consistent (v", pkg_version, ")")
      }
    }
  }

  # --- Summary ---
  valid <- length(errors) == 0
  if (verbose) {
    message("[check-project] ", if (valid) "PASS" else "FAIL",
            " (", length(errors), " error(s), ",
            length(warnings), " warning(s))")
  }

  invisible(list(
    valid = valid,
    checks = checks,
    issues = list(errors = errors, warnings = warnings)
  ))
}
