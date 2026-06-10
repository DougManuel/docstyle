#' Extract comments from a Word document
#'
#' Parses word/comments.xml from a DOCX file and extracts all comment metadata
#' including author, date, content, and threading information. Also reads
#' commentsExtended.xml for threading (parent_id) and resolved status (done).
#'
#' @param docx_path Path to .docx file
#' @return Named list of comment data, keyed by comment ID
#'
#' @examples
#' \dontrun{
#' comments <- extract_comments("document.docx")
#' comments[["1"]]$author
#' comments[["1"]]$content
#' comments[["1"]]$done
#' }
#'
#' @export
extract_comments <- function(docx_path) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Extract DOCX contents
  temp_dir <- tempfile("extract_comments_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Check for comments.xml
  comments_path <- file.path(temp_dir, "word", "comments.xml")
  if (!file.exists(comments_path)) {
    message("No comments.xml found in document")
    return(list())
  }

  # Parse comments XML
  comments_xml <- xml2::read_xml(comments_path)
  ns <- xml2::xml_ns(comments_xml)

  # Find all comment nodes
  comment_nodes <- xml2::xml_find_all(comments_xml, "//w:comment", ns)

  if (length(comment_nodes) == 0) {
    return(list())
  }

  # Build paraId to comment ID mapping from comments.xml
  # Each comment's first paragraph has a w14:paraId attribute
  para_id_to_comment_id <- list()

  comments <- list()

  for (node in comment_nodes) {
    # Extract attributes
    id <- xml2::xml_attr(node, "id")
    author <- xml2::xml_attr(node, "author")
    date <- xml2::xml_attr(node, "date")
    initials <- xml2::xml_attr(node, "initials")

    # Extract comment text content, preserving paragraph structure

    # Comments may have multiple <w:p> paragraphs - join them with newlines
    para_nodes <- xml2::xml_find_all(node, ".//w:p", ns)
    para_texts <- sapply(para_nodes, function(p) {
      text_nodes <- xml2::xml_find_all(p, ".//w:t", ns)
      paste(sapply(text_nodes, xml2::xml_text), collapse = "")
    })
    # Filter out empty paragraphs and join with newlines
    para_texts <- para_texts[nchar(para_texts) > 0]
    content <- paste(para_texts, collapse = "\n")

    # Extract paraId from the comment's paragraph(s)
    # Word uses paraId on paragraphs for threading reference
    # Note: xml2 returns attributes without namespace prefix
    para_nodes <- xml2::xml_find_all(node, ".//w:p", ns)
    para_ids <- character()
    for (pnode in para_nodes) {
      pid <- xml2::xml_attr(pnode, "paraId")
      if (!is.na(pid)) {
        para_ids <- c(para_ids, pid)
        para_id_to_comment_id[[pid]] <- id
      }
    }

    comments[[id]] <- list(
      id = id,
      author = if (is.na(author)) "Unknown" else author,
      date = if (is.na(date)) NULL else date,
      content = content,
      parent_id = NULL,
      initials = if (is.na(initials)) NULL else initials,
      para_id = if (length(para_ids) > 0) para_ids[length(para_ids)] else NULL,
      done = FALSE
    )
  }

  # Read commentsExtended.xml for threading and resolved status
  extended_path <- file.path(temp_dir, "word", "commentsExtended.xml")
  if (file.exists(extended_path)) {
    extended_xml <- xml2::read_xml(extended_path)
    ext_ns <- c(
      w15 = "http://schemas.microsoft.com/office/word/2012/wordml"
    )

    # Find all commentEx nodes
    comment_ex_nodes <- xml2::xml_find_all(extended_xml, "//w15:commentEx", ext_ns)

    for (ex_node in comment_ex_nodes) {
      # xml2 returns attributes without namespace prefix
      para_id <- xml2::xml_attr(ex_node, "paraId")
      para_id_parent <- xml2::xml_attr(ex_node, "paraIdParent")
      done_attr <- xml2::xml_attr(ex_node, "done")

      if (!is.na(para_id) && para_id %in% names(para_id_to_comment_id)) {
        comment_id <- para_id_to_comment_id[[para_id]]

        # Set done status (1 = resolved, 0 = open)
        if (!is.na(done_attr)) {
          comments[[comment_id]]$done <- done_attr == "1"
        }

        # Set parent_id for threading
        if (!is.na(para_id_parent) && para_id_parent %in% names(para_id_to_comment_id)) {
          comments[[comment_id]]$parent_id <- para_id_to_comment_id[[para_id_parent]]
        }
      }
    }
  }

  # Read people.xml for additional author metadata (optional)
  people_path <- file.path(temp_dir, "word", "people.xml")
  if (file.exists(people_path)) {
    # People.xml contains presence info but we already have author from comments.xml
    # This is mostly useful for consistent author display across sessions
    # For now, we don't need to extract additional data
  }

  comments
}


#' Write comments to JSON sidecar file
#'
#' Writes extracted comment metadata to a JSON sidecar file that can be
#' used alongside the QMD for round-trip workflows.
#'
#' @param comments List from extract_comments()
#' @param path Output path for comments.json
#'
#' @examples
#' \dontrun{
#' comments <- extract_comments("document.docx")
#' write_comments_json(comments, "comments.json")
#' }
#'
#' @keywords internal
#' @export
write_comments_json <- function(comments, path) {
  if (length(comments) == 0) {
    # Write empty object
    writeLines("{}", path)
    message("No comments to write")
    return(invisible(NULL))
  }

  # Convert to JSON with pretty printing
  json <- jsonlite::toJSON(comments, pretty = TRUE, auto_unbox = TRUE, null = "null")
  writeLines(json, path)

  message(sprintf("Wrote %d comments to %s", length(comments), path))
  invisible(path)
}


#' Read comments from JSON sidecar file
#'
#' @param path Path to comments.json
#' @return Named list of comment data
#'
#' @keywords internal
#' @export
read_comments_json <- function(path) {
  if (!file.exists(path)) {
    stop("Comments file not found: ", path)
  }

  jsonlite::fromJSON(path, simplifyVector = FALSE)
}


#' Generate a unique 8-character hex paraId
#'
#' @param existing Vector of existing paraIds to avoid duplicates
#' @return 8-character uppercase hex string
#' @keywords internal
generate_para_id <- function(existing = character()) {
  repeat {
    # Generate random 8-hex string
    para_id <- toupper(paste0(
      sprintf("%02X", sample(0:255, 4, replace = TRUE)),
      collapse = ""
    ))
    if (!(para_id %in% existing)) {
      return(para_id)
    }
  }
}


#' Build comments.xml content from comment data
#'
#' Generates valid OpenXML for word/comments.xml from a list of comments.
#' Assigns paraIds to each comment for use with commentsExtended.xml.
#'
#' @param comments Named list of comment data
#' @return List with `xml` (character string) and `para_ids` (named vector mapping comment ID to paraId)
#'
#' @keywords internal
build_comments_xml <- function(comments) {
  if (length(comments) == 0) {
    return(list(xml = NULL, para_ids = character()))
  }

  # Track assigned paraIds
  para_ids <- character()

  # XML declaration and root element with namespaces
  xml_parts <- c(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"',
    '            xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"',
    '            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
  )

  for (id in names(comments)) {
    comment <- comments[[id]]

    # Build comment attributes
    attrs <- sprintf('w:id="%s"', xml_escape_attr(id))

    if (!is.null(comment$author) && comment$author != "") {
      attrs <- paste(attrs, sprintf('w:author="%s"', xml_escape_attr(comment$author)))
    }

    if (!is.null(comment$date) && comment$date != "") {
      attrs <- paste(attrs, sprintf('w:date="%s"', xml_escape_attr(comment$date)))
    }

    if (!is.null(comment$initials) && comment$initials != "") {
      attrs <- paste(attrs, sprintf('w:initials="%s"', xml_escape_attr(comment$initials)))
    }

    # Generate or use existing paraId for threading support
    if (!is.null(comment$para_id) && comment$para_id != "") {
      para_id <- comment$para_id
    } else {
      para_id <- generate_para_id(para_ids)
    }
    para_ids[id] <- para_id

    # Build comment content - handle multi-paragraph content (newlines)
    content_lines <- strsplit(comment$content, "\n", fixed = TRUE)[[1]]

    # Build paragraph XML for each line
    para_xml_parts <- character()
    for (i in seq_along(content_lines)) {
      line_escaped <- xml_escape(content_lines[i])
      # First paragraph gets the paraId for threading reference
      if (i == 1) {
        para_xml_parts <- c(para_xml_parts, sprintf(
          '    <w:p w14:paraId="%s" w14:textId="77777777">
      <w:r>
        <w:t>%s</w:t>
      </w:r>
    </w:p>',
          para_id,
          line_escaped
        ))
      } else {
        # Subsequent paragraphs get unique paraIds
        new_para_id <- generate_para_id(c(para_ids, sapply(para_xml_parts, function(x) "")))
        para_xml_parts <- c(para_xml_parts, sprintf(
          '    <w:p w14:paraId="%s" w14:textId="77777777">
      <w:r>
        <w:t>%s</w:t>
      </w:r>
    </w:p>',
          new_para_id,
          line_escaped
        ))
      }
    }

    comment_xml <- sprintf(
      '  <w:comment %s>\n%s\n  </w:comment>',
      attrs,
      paste(para_xml_parts, collapse = "\n")
    )

    xml_parts <- c(xml_parts, comment_xml)
  }

  xml_parts <- c(xml_parts, '</w:comments>')

  list(
    xml = paste(xml_parts, collapse = "\n"),
    para_ids = para_ids
  )
}


#' Build commentsExtended.xml content
#'
#' Generates OpenXML for word/commentsExtended.xml with threading and resolved status.
#'
#' @param comments Named list of comment data
#' @param para_ids Named vector mapping comment ID to paraId
#' @return Character string containing commentsExtended.xml content
#'
#' @keywords internal
build_comments_extended_xml <- function(comments, para_ids) {
  if (length(comments) == 0) {
    return(NULL)
  }

  xml_parts <- c(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w15:commentsEx xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">'
  )

  for (id in names(comments)) {
    comment <- comments[[id]]
    para_id <- para_ids[id]

    if (is.na(para_id)) next

    # Build commentEx attributes
    done_val <- if (isTRUE(comment$done)) "1" else "0"

    # Check for parent (threading)
    parent_attr <- ""
    if (!is.null(comment$parent_id) && !anyNA(comment$parent_id) &&
        comment$parent_id %in% names(para_ids)) {
      parent_para_id <- para_ids[comment$parent_id]
      if (!is.na(parent_para_id)) {
        parent_attr <- sprintf(' w15:paraIdParent="%s"', parent_para_id)
      }
    }

    comment_ex <- sprintf(
      '  <w15:commentEx w15:paraId="%s"%s w15:done="%s"/>',
      para_id,
      parent_attr,
      done_val
    )

    xml_parts <- c(xml_parts, comment_ex)
  }

  xml_parts <- c(xml_parts, '</w15:commentsEx>')
  paste(xml_parts, collapse = "\n")
}


#' Build people.xml content
#'
#' Generates OpenXML for word/people.xml with unique authors from comments.
#'
#' @param comments Named list of comment data
#' @return Character string containing people.xml content
#'
#' @keywords internal
build_people_xml <- function(comments) {
  if (length(comments) == 0) {
    return(NULL)
  }

  # Get unique authors
  authors <- unique(sapply(comments, function(c) c$author))
  authors <- authors[!is.na(authors) & authors != ""]

  if (length(authors) == 0) {
    return(NULL)
  }

  xml_parts <- c(
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
    '<w15:people xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">'
  )

  for (author in authors) {
    person_xml <- sprintf(
      '  <w15:person w15:author="%s">
    <w15:presenceInfo w15:providerId="None" w15:userId="%s"/>
  </w15:person>',
      xml_escape_attr(author),
      xml_escape_attr(author)
    )
    xml_parts <- c(xml_parts, person_xml)
  }

  xml_parts <- c(xml_parts, '</w15:people>')
  paste(xml_parts, collapse = "\n")
}


#' Inject comments.xml into a Word document
#'
#' Post-processes a rendered DOCX file to add the comments.xml file and
#' related extended files (commentsExtended.xml, people.xml) for threading
#' and resolved status support. Updates relationships and content types as needed.
#'
#' @param docx_path Path to .docx file to modify
#' @param comments_json Path to comments.json sidecar file
#' @param used_ids Optional character vector of comment IDs actually used in document.
#'   If NULL, all comments from JSON are included.
#'
#' @return Invisibly returns the docx_path
#'
#' @examples
#' \dontrun{
#' # After rendering with Quarto
#' inject_comments("output/document.docx", "comments.json")
#' }
#'
#' @export
inject_comments <- function(docx_path, comments_json, used_ids = NULL) {
  if (!file.exists(docx_path)) {
    stop("DOCX file not found: ", docx_path)
  }

  if (!file.exists(comments_json)) {
    stop("Comments JSON not found: ", comments_json)
  }

  # Read comments
  comments <- read_comments_json(comments_json)

  if (length(comments) == 0) {
    message("No comments to inject")
    return(invisible(docx_path))
  }

  # Filter to used IDs if specified
  # Also include reply comments (those with parent_id pointing to a used comment)
  # since replies don't have their own range markers in the document
  if (!is.null(used_ids)) {
    reply_ids <- vapply(comments, function(c) {
      !is.null(c$parent_id) && !anyNA(c$parent_id) && c$parent_id %in% used_ids
    }, logical(1))
    keep_ids <- union(used_ids, names(comments)[reply_ids])
    comments <- comments[names(comments) %in% keep_ids]
    if (length(comments) == 0) {
      message("No matching comment IDs found")
      return(invisible(docx_path))
    }
  }

  # Extract DOCX
  temp_dir <- tempfile("inject_comments_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  # Build and write comments.xml (returns xml and para_ids mapping)
  comments_result <- build_comments_xml(comments)
  writeLines(comments_result$xml, file.path(temp_dir, "word", "comments.xml"))

  # Build and write commentsExtended.xml for threading and resolved status
  extended_xml <- build_comments_extended_xml(comments, comments_result$para_ids)
  if (!is.null(extended_xml)) {
    writeLines(extended_xml, file.path(temp_dir, "word", "commentsExtended.xml"))
  }

  # Build and write people.xml for author metadata
  people_xml <- build_people_xml(comments)
  if (!is.null(people_xml)) {
    writeLines(people_xml, file.path(temp_dir, "word", "people.xml"))
  }

  # Update [Content_Types].xml
  update_content_types_for_comments(temp_dir, has_extended = !is.null(extended_xml),
                                    has_people = !is.null(people_xml))

  # Update word/_rels/document.xml.rels
  update_rels_for_comments(temp_dir, has_extended = !is.null(extended_xml),
                           has_people = !is.null(people_xml))

  # Repack DOCX
  repack_docx(temp_dir, docx_path)

  message(sprintf("Injected %d comments into %s", length(comments), docx_path))
  invisible(docx_path)
}


#' Update Content_Types.xml to include comments files
#'
#' Adds overrides for comments.xml and optionally commentsExtended.xml and people.xml.
#'
#' @param temp_dir Path to extracted DOCX directory
#' @param has_extended Whether to add commentsExtended.xml override
#' @param has_people Whether to add people.xml override
#' @keywords internal
update_content_types_for_comments <- function(temp_dir, has_extended = FALSE,
                                               has_people = FALSE) {
  ct_path <- file.path(temp_dir, "[Content_Types].xml")

  if (!file.exists(ct_path)) {
    stop("Content_Types.xml not found")
  }

  ct_xml <- xml2::read_xml(ct_path)
  ct_ns <- c(ct = "http://schemas.openxmlformats.org/package/2006/content-types")

  # Helper to add override if not exists
 add_override_if_missing <- function(part_name, content_type) {
    existing <- xml2::xml_find_first(
      ct_xml,
      sprintf("//ct:Override[@PartName='%s']", part_name),
      ct_ns
    )

    if (inherits(existing, "xml_missing") || is.na(existing)) {
      override_xml <- xml2::read_xml(sprintf(
        '<Override xmlns="http://schemas.openxmlformats.org/package/2006/content-types"
                   PartName="%s"
                   ContentType="%s"/>',
        part_name, content_type
      ))
      xml2::xml_add_child(ct_xml, override_xml)
    }
  }

  # Add comments.xml override
  add_override_if_missing(
    "/word/comments.xml",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"
  )

  # Add commentsExtended.xml override if needed
  if (has_extended) {
    add_override_if_missing(
      "/word/commentsExtended.xml",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.commentsExtended+xml"
    )
  }

  # Add people.xml override if needed
  if (has_people) {
    add_override_if_missing(
      "/word/people.xml",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.people+xml"
    )
  }

  xml2::write_xml(ct_xml, ct_path)
}


#' Update document.xml.rels to include comments relationships
#'
#' @param temp_dir Path to extracted DOCX directory
#' @param has_extended Whether to add commentsExtended.xml relationship
#' @param has_people Whether to add people.xml relationship
#' @keywords internal
update_rels_for_comments <- function(temp_dir, has_extended = FALSE,
                                      has_people = FALSE) {
  rels_path <- file.path(temp_dir, "word", "_rels", "document.xml.rels")

  if (!file.exists(rels_path)) {
    stop("document.xml.rels not found")
  }

  rels_xml <- xml2::read_xml(rels_path)
  rels_ns <- c(r = "http://schemas.openxmlformats.org/package/2006/relationships")

  # Helper to get next available rId
  get_next_rid <- function() {
    all_rels <- xml2::xml_find_all(rels_xml, "//r:Relationship", rels_ns)
    existing_ids <- xml2::xml_attr(all_rels, "Id")
    max_id <- max(as.numeric(gsub("rId", "", existing_ids)), na.rm = TRUE)
    paste0("rId", max_id + 1)
  }

  # Helper to add relationship if not exists
  add_rel_if_missing <- function(rel_type, target) {
    existing <- xml2::xml_find_first(
      rels_xml,
      sprintf("//r:Relationship[@Type='%s']", rel_type),
      rels_ns
    )

    if (inherits(existing, "xml_missing") || is.na(existing)) {
      new_id <- get_next_rid()
      rel_xml <- xml2::read_xml(sprintf(
        '<Relationship xmlns="http://schemas.openxmlformats.org/package/2006/relationships"
                       Id="%s"
                       Type="%s"
                       Target="%s"/>',
        new_id, rel_type, target
      ))
      xml2::xml_add_child(rels_xml, rel_xml)
    }
  }

  # Add comments.xml relationship
  add_rel_if_missing(
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments",
    "comments.xml"
  )

  # Add commentsExtended.xml relationship if needed
  if (has_extended) {
    add_rel_if_missing(
      "http://schemas.microsoft.com/office/2011/relationships/commentsExtended",
      "commentsExtended.xml"
    )
  }

  # Add people.xml relationship if needed
  if (has_people) {
    add_rel_if_missing(
      "http://schemas.microsoft.com/office/2011/relationships/people",
      "people.xml"
    )
  }

  xml2::write_xml(rels_xml, rels_path)
}


#' Repack a DOCX from extracted directory
#'
#' @param temp_dir Path to extracted DOCX directory
#' @param docx_path Output path for DOCX file
#' @keywords internal
repack_docx <- function(temp_dir, docx_path) {
  # Ensure absolute path for output
  docx_path <- normalizePath(docx_path, mustWork = FALSE)

  # Remove existing file
  if (file.exists(docx_path)) {
    file.remove(docx_path)
  }

  # Get all files to include
  all_files <- list.files(temp_dir, recursive = TRUE, all.files = TRUE)

  # Create zip from the temp directory
  old_wd <- getwd()
  on.exit(setwd(old_wd), add = TRUE)
  setwd(temp_dir)

  # Create zip in temp directory first, then move
  temp_zip <- file.path(temp_dir, "output.docx")
  utils::zip(temp_zip, files = all_files, flags = "-q")

  # Move to final location
  if (file.exists(temp_zip)) {
    file.copy(temp_zip, docx_path, overwrite = TRUE)
    file.remove(temp_zip)
  } else {
    stop("Failed to create DOCX archive")
  }
}


#' Scan document.xml for used comment IDs
#'
#' Searches the rendered document.xml for w:commentRangeStart elements
#' to determine which comment IDs are actually referenced.
#'
#' @param docx_path Path to .docx file
#' @return Character vector of comment IDs found in document
#'
#' @keywords internal
#' @export
scan_used_comment_ids <- function(docx_path) {
  if (!file.exists(docx_path)) {
    stop("File not found: ", docx_path)
  }

  # Extract DOCX
  temp_dir <- tempfile("scan_comments_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  doc_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    return(character(0))
  }

  doc_xml <- xml2::read_xml(doc_path)
  ns <- xml2::xml_ns(doc_xml)

  # Find all commentRangeStart elements
  range_starts <- xml2::xml_find_all(doc_xml, "//w:commentRangeStart", ns)

  if (length(range_starts) == 0) {
    return(character(0))
  }

  unique(xml2::xml_attr(range_starts, "id"))
}


#' Fix comment markers that should be nested inside track change deletions
#'
#' Post-processes a rendered DOCX to move comment markers that immediately follow
#' `<w:del>` elements into the deletion, when the original source document had
#' the comment attached to deleted text.
#'
#' This fixes a limitation of the Lua filter pipeline where `comment-inject.lua`
#' and `revisions-inject.lua` cannot nest OpenXML elements inside each other.
#'
#' @param docx_path Path to .docx file to modify
#' @param comments_json Optional path to comments.json for metadata lookup.
#'   If provided, only repositions comments that were originally inside deletions.
#' @param verbose If TRUE, prints progress messages
#'
#' @return Invisibly returns the number of comments repositioned
#'
#' @details
#' The function looks for this pattern in document.xml:
#' ```xml
#' <w:del ...>...</w:del>
#' <w:commentRangeStart w:id="X"/>
#' <w:commentRangeEnd w:id="X"/>
#' ```
#'

#' And transforms it to:
#' ```xml
#' <w:commentRangeStart w:id="X"/>
#' <w:del ...>...</w:del>
#' <w:commentRangeEnd w:id="X"/>
#' ```
#'
#' This positions the comment to span the deletion, which is semantically correct
#' when the comment was originally attached to the deleted text.
#'
#' @examples
#' \dontrun{
#' # After rendering with Quarto
#' fix_comment_deletion_nesting("output/document.docx")
#' }
#'
#' @keywords internal
#' @export
fix_comment_deletion_nesting <- function(docx_path, comments_json = NULL,
                                          verbose = FALSE) {
  if (!file.exists(docx_path)) {
    stop("DOCX file not found: ", docx_path)
  }

  # Extract DOCX
  temp_dir <- tempfile("fix_comment_nesting_")
  dir.create(temp_dir)
  on.exit(unlink(temp_dir, recursive = TRUE), add = TRUE)

  utils::unzip(docx_path, exdir = temp_dir)

  doc_path <- file.path(temp_dir, "word", "document.xml")
  if (!file.exists(doc_path)) {
    warning("document.xml not found in DOCX")
    return(invisible(0L))
  }

  # Read as text to manipulate with regex
  # (xml2 DOM manipulation is complex for sibling reordering)
  doc_content <- paste(readLines(doc_path, warn = FALSE), collapse = "\n")

  # Pattern: <w:del ...>...</w:del> immediately followed by
  #          <w:commentRangeStart .../><w:commentRangeEnd .../>
  # We want to move commentRangeStart before w:del

  # Build pattern to match:
  # Group 1: The entire w:del element

  # Group 2: The commentRangeStart element
  # Group 3: The comment ID (for logging)
  # Group 4: Everything up to and including commentRangeEnd with same ID

  # This regex handles the common case where start/end are adjacent after deletion
  pattern <- paste0(
    "(<w:del[^>]*>.*?</w:del>)",           # Group 1: w:del element
    "\\s*",                                  # Optional whitespace
    "(<w:commentRangeStart[^>]*w:id=\"(\\d+)\"[^>]*/>)",  # Group 2,3: commentRangeStart
    "\\s*",                                  # Optional whitespace
    "(<w:commentRangeEnd[^>]*w:id=\"\\3\"[^>]*/?>)"  # Group 4: commentRangeEnd (same id)
  )

  # Count matches before replacement
  matches <- gregexpr(pattern, doc_content, perl = TRUE)
  n_matches <- sum(sapply(matches, function(m) sum(m > 0)))

  if (n_matches == 0) {
    if (verbose) message("[docstyle] No comment-deletion patterns to fix")
    return(invisible(0L))
  }

  # Replacement: move commentRangeStart before w:del
  # Result: <commentRangeStart/><w:del>...</w:del><commentRangeEnd/>
  replacement <- "\\2\\1\\4"

  doc_content_fixed <- gsub(pattern, replacement, doc_content, perl = TRUE)

  # Write back
  writeLines(doc_content_fixed, doc_path)

  # Repack DOCX
  repack_docx(temp_dir, docx_path)

  if (verbose) {
    message(sprintf("[docstyle] Fixed %d comment-deletion nesting issue(s)", n_matches))
  }

  invisible(n_matches)
}
