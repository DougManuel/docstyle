#' Extract revisions (track changes) from a Word document
#'
#' Parses document.xml from a DOCX file and extracts all tracked changes
#' including insertions (w:ins) and deletions (w:del) with their metadata.
#'
#' @param docx_path Path to .docx file
#' @return Named list of revision data, keyed by revision ID
#'
#' @examples
#' \dontrun{
#' revisions <- extract_revisions("document.docx")
#' revisions[["rev_1"]]$type
#' revisions[["rev_1"]]$author
#' }
#'
#' @export
extract_revisions <- function(docx_path) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Extract DOCX contents
  temp_dir <- tempfile("extract_revisions_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Parse document.xml
  doc_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    stop("document.xml not found in DOCX")
  }

  doc_xml <- xml2::read_xml(doc_path)
  ns <- xml2::xml_ns(doc_xml)

  revisions <- list()
  rev_counter <- 1

  # Find all insertions (w:ins)
  ins_nodes <- xml2::xml_find_all(doc_xml, "//w:ins", ns)

  for (node in ins_nodes) {
    id <- xml2::xml_attr(node, "id")
    author <- xml2::xml_attr(node, "author")
    date <- xml2::xml_attr(node, "date")

    # Generate stable ID if Word's ID is just numeric
    rev_id <- if (!is.na(id) && id != "") {
      paste0("rev_", id)
    } else {
      paste0("rev_ins_", rev_counter)
    }
    rev_counter <- rev_counter + 1

    # Extract inserted text
    text_nodes <- xml2::xml_find_all(node, ".//w:t", ns)
    content <- paste(sapply(text_nodes, xml2::xml_text), collapse = "")

    revisions[[rev_id]] <- list(
      id = rev_id,
      type = "insertion",
      author = if (is.na(author)) "Unknown" else author,
      date = if (is.na(date)) NULL else date,
      content = content,
      initials = extract_initials(author)
    )
  }

  # Find all deletions (w:del)
  del_nodes <- xml2::xml_find_all(doc_xml, "//w:del", ns)

  for (node in del_nodes) {
    id <- xml2::xml_attr(node, "id")
    author <- xml2::xml_attr(node, "author")
    date <- xml2::xml_attr(node, "date")

    rev_id <- if (!is.na(id) && id != "") {
      paste0("rev_", id)
    } else {
      paste0("rev_del_", rev_counter)
    }
    rev_counter <- rev_counter + 1

    # Extract deleted text (from w:delText)
    text_nodes <- xml2::xml_find_all(node, ".//w:delText", ns)
    content <- paste(sapply(text_nodes, xml2::xml_text), collapse = "")

    revisions[[rev_id]] <- list(
      id = rev_id,
      type = "deletion",
      author = if (is.na(author)) "Unknown" else author,
      date = if (is.na(date)) NULL else date,
      content = content,
      initials = extract_initials(author)
    )
  }

  revisions
}


#' Extract initials from author name
#'
#' @param author Author name string
#' @return Initials string
#' @keywords internal
extract_initials <- function(author) {
  if (is.na(author) || is.null(author) || author == "") {
    return("U")
  }

  # Split on spaces and take first letter of each word
  words <- strsplit(author, "\\s+")[[1]]
  initials <- paste(substr(words, 1, 1), collapse = "")
  toupper(initials)
}


#' Write revisions to JSON sidecar file
#'
#' Writes extracted revision metadata to a JSON sidecar file that can be
#' used alongside the QMD for round-trip workflows.
#'
#' @param revisions List from extract_revisions()
#' @param path Output path for revisions.json
#'
#' @examples
#' \dontrun{
#' revisions <- extract_revisions("document.docx")
#' write_revisions_json(revisions, "revisions.json")
#' }
#'
#' @keywords internal
#' @export
write_revisions_json <- function(revisions, path) {
  if (length(revisions) == 0) {
    writeLines("{}", path)
    message("No revisions to write")
    return(invisible(NULL))
  }

  json <- jsonlite::toJSON(revisions, pretty = TRUE, auto_unbox = TRUE, null = "null")
  writeLines(json, path)

  message(sprintf("Wrote %d revisions to %s", length(revisions), path))
  invisible(path)
}


#' Read revisions from JSON sidecar file
#'
#' @param path Path to revisions.json
#' @return Named list of revision data
#'
#' @keywords internal
#' @export
read_revisions_json <- function(path) {
  if (!file.exists(path)) {
    stop("Revisions file not found: ", path)
  }

  jsonlite::fromJSON(path, simplifyVector = FALSE)
}


#' Count revisions by type
#'
#' @param revisions List from extract_revisions()
#' @return Named vector with counts by type
#'
#' @export
count_revisions <- function(revisions) {
  if (length(revisions) == 0) {
    return(c(insertions = 0, deletions = 0, total = 0))
  }

  types <- sapply(revisions, function(r) r$type)
  c(
    insertions = sum(types == "insertion"),
    deletions = sum(types == "deletion"),
    total = length(revisions)
  )
}


#' Summarise revisions by author
#'
#' @param revisions List from extract_revisions()
#' @return Data frame with author-level summary
#'
#' @export
summarise_revisions_by_author <- function(revisions) {
  if (length(revisions) == 0) {
    return(data.frame(
      author = character(0),
      insertions = integer(0),
      deletions = integer(0),
      total = integer(0)
    ))
  }

  # Extract author and type from each revision
  df <- data.frame(
    author = sapply(revisions, function(r) r$author),
    type = sapply(revisions, function(r) r$type),
    stringsAsFactors = FALSE
  )

  # Aggregate by author
  authors <- unique(df$author)
  result <- data.frame(
    author = authors,
    insertions = sapply(authors, function(a) sum(df$author == a & df$type == "insertion")),
    deletions = sapply(authors, function(a) sum(df$author == a & df$type == "deletion")),
    stringsAsFactors = FALSE
  )
  result$total <- result$insertions + result$deletions

  result[order(-result$total), ]
}
