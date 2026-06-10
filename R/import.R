#' Import a Word Document to Quarto
#'
#' The main entry point for converting Word documents to Quarto format. Extracts
#' content, preserves Zotero citations, and sets up the project for round-trip
#' editing.
#'
#' @param docx_path Path to the input .docx file.
#' @param output_dir Directory for output files. Defaults to the same directory
#'   as the input file.
#' @param qmd_name Name for the output .qmd file (without extension). Defaults
#'   to the input filename.
#' @param extract_images Whether to extract embedded images (default: TRUE).
#' @param image_dir Directory for extracted images, relative to output_dir
#'
#'   (default: "images").
#' @param config_path Optional path to `_quarto.yml`. If provided, the output
#'   QMD will be configured to use docstyle rendering.
#' @param verbose If TRUE (default), prints progress messages.
#'
#' @return Invisibly returns a list with paths to all generated files:
#'   - `qmd_path`: Path to the generated .qmd file
#'   - `references_json`: Path to references.json (CSL-JSON for rendering)
#'   - `field_codes_json`: Path to field-codes.json (for Zotero round-trip)
#'
#' @details
#' ## What `import_docx()` does
#'
#' 1. Extracts Zotero citations and generates:
#'    - `references.json`: CSL-JSON for rendering citations
#'    - `field-codes.json`: Zotero metadata for round-trip field code injection
#' 2. Converts Word content to Quarto markdown
#' 3. Optionally extracts embedded images
#' 4. Creates a ready-to-edit QMD with proper YAML header
#'
#' ## Citation handling
#'
#' Unlike typical Quarto workflows that use `.bib` files, docstyle keeps
#' reference metadata in JSON format—similar to how Zotero manages citations
#' in Word. This approach:
#' - Avoids conflicts when merging citation databases
#' - Keeps metadata "behind the scenes" during editing
#' - Enables seamless round-trip with `quarto render`
#'
#' To add new citations, use Zotero integration directly in the QMD.
#'
#' ## Round-trip workflow
#'
#' ```r
#' # 1. Collaborator sends edited Word document
#' result <- import_docx("collaborator-edits.docx")
#'
#' # 2. Review and edit the QMD
#' # (use git diff to see what changed)
#'
#' # 3. Render back to Word with the docstyle extension
#' # quarto render collaborator-edits.qmd
#' ```
#'
#' @examples
#' \dontrun{
#' # Basic import
#' result <- import_docx("paper.docx")
#'
#' # Import to a specific directory
#' result <- import_docx("paper.docx", output_dir = "project/")
#'
#' # Import with docstyle configuration
#' result <- import_docx("paper.docx", config_path = "_quarto.yml")
#' }
#'
#' @seealso
#' - [extract_citations()] for citation extraction only
#' - [docx_to_qmd()] for content conversion only
#'
#' @export
import_docx <- function(docx_path,
                        output_dir = NULL
,
                        qmd_name = NULL,
                        extract_images = TRUE,
                        image_dir = "images",
                        config_path = NULL,
                        verbose = TRUE) {

  # Validate input
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  docx_path <- normalizePath(docx_path, mustWork = TRUE)
  input_dir <- dirname(docx_path)
  input_basename <- tools::file_path_sans_ext(basename(docx_path))

  # Default output directory
  if (is.null(output_dir)) {
    output_dir <- input_dir
  }
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  output_dir <- normalizePath(output_dir, mustWork = TRUE)

  # Default QMD name
  if (is.null(qmd_name)) {
    qmd_name <- input_basename
  }

  # Output paths
  qmd_path <- file.path(output_dir, paste0(qmd_name, ".qmd"))
  references_json <- file.path(output_dir, "references.json")
  field_codes_json <- file.path(output_dir, "field-codes.json")

  # Step 1: Extract Zotero citations
  if (verbose) message("Extracting citations from Word document...")

  citation_result <- extract_citations(docx_path, output_dir)

  has_citations <- length(citation_result$citations) > 0

  if (verbose) {
    if (has_citations) {
      message("Found ", length(citation_result$citations), " citation(s)")
      message("  - ", basename(references_json))
      message("  - ", basename(field_codes_json))
    } else {
      message("No Zotero citations found")
    }
  }

  # Step 2: Convert content to QMD
  if (verbose) message("Converting document content...")

  # Read document XML
  doc_xml <- extract_docx_content(docx_path)

  # Build YAML header
  yaml_parts <- list()

  # Extract title if present (from document properties or first heading)
  title <- extract_document_title(doc_xml)
  if (!is.null(title)) {
    yaml_parts$title <- title
  }

  # Format settings
  yaml_parts$format <- list(docx = list())

  # Note: We don't add bibliography to YAML header because docstyle
  # uses JSON-based citation management (like Zotero in Word) rather than .bib files.
  # Citations are rendered using references.json and field-codes.json via the docstyle extension.

  # Convert content
  qmd_content <- convert_to_qmd(
    doc_xml = doc_xml,
    docx_path = docx_path,
    extract_images = extract_images,
    image_dir = image_dir,
    citation_map = citation_result$citation_map,
    citation_id_map = citation_result$citation_id_map,
    bib_path = NULL,  # Don't generate .bib; use JSON-based workflow
    reference_doc = NULL
  )

  # Write QMD file
  writeLines(qmd_content, qmd_path)

  if (verbose) message("Created: ", basename(qmd_path))

  # Step 3: Copy config if provided
  if (!is.null(config_path) && file.exists(config_path)) {
    dest_config <- file.path(output_dir, "_quarto.yml")
    if (normalizePath(config_path, mustWork = FALSE) != normalizePath(dest_config, mustWork = FALSE)) {
      file.copy(config_path, dest_config, overwrite = TRUE)
      if (verbose) message("Copied: _quarto.yml")
    }
  }

  # Summary
  if (verbose) {
    message("\n--- Import complete ---")
    message("QMD: ", qmd_path)
    if (has_citations) {
      message("Citations: ", length(citation_result$citations), " references extracted")
      message("  Run 'quarto render' with the docstyle extension to preserve Zotero field codes")
    }
  }

  # Return paths
  result <- list(
    qmd_path = qmd_path,
    references_json = if (has_citations) references_json else NULL,
    field_codes_json = if (has_citations) field_codes_json else NULL,
    n_citations = length(citation_result$citations)
  )

  invisible(result)
}


#' Extract document title from Word XML
#'
#' Looks for the title in document properties or first Title-styled paragraph.
#'
#' @param doc_xml Parsed document XML
#' @return Title string or NULL
#' @keywords internal
extract_document_title <- function(doc_xml) {
  ns <- c(w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

 # Look for paragraph with Title style
  title_para <- xml2::xml_find_first(
    doc_xml,
    "//w:p[w:pPr/w:pStyle[@w:val='Title']]",
    ns
  )

  if (!inherits(title_para, "xml_missing")) {
    # Extract text from all runs
    runs <- xml2::xml_find_all(title_para, ".//w:t", ns)
    title_text <- paste(xml2::xml_text(runs), collapse = "")
    if (nchar(trimws(title_text)) > 0) {
      return(trimws(title_text))
    }
  }

  NULL
}
