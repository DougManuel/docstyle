# docstyle pre-render bootstrap
# Auto-restores _extensions/docstyle/ if missing, then runs the real pre-render script.
# This file is committed to version control; _extensions/ is gitignored.

ext_dir <- file.path("_extensions", "docstyle")
if (!dir.exists(ext_dir)) {
  if (requireNamespace("docstyle", quietly = TRUE)) {
    message("[docstyle] Installing extension files...")
    docstyle::use_docstyle(overwrite = FALSE)
  } else {
    stop("[docstyle] R package not installed. Run: install.packages('docstyle')",
         call. = FALSE)
  }
}
source(file.path(ext_dir, "generate-reference.R"), local = TRUE)
