characterization_w_ns <- c(
  w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
)

characterization_sha256 <- function(value) {
  paste0(
    "sha256:",
    digest::digest(value, algo = "sha256", serialize = FALSE)
  )
}

classify_docx_field <- function(instruction) {
  normalized <- toupper(trimws(instruction))
  if (startsWith(normalized, "ADDIN ZOTERO_ITEM")) {
    return("zotero-citation")
  }
  if (startsWith(normalized, "ADDIN ZOTERO_BIBL")) {
    return("zotero-bibliography")
  }
  if (startsWith(normalized, "ADDIN ZOTERO_PREF")) {
    return("zotero-preferences")
  }
  if (startsWith(normalized, "ADDIN DOCSTYLE")) {
    return("docstyle")
  }
  if (startsWith(normalized, "TOC")) {
    return("toc")
  }
  if (startsWith(normalized, "NUMPAGES")) {
    return("num-pages")
  }
  if (startsWith(normalized, "SECTIONPAGES")) {
    return("section-pages")
  }
  if (startsWith(normalized, "PAGE")) {
    return("page")
  }
  if (startsWith(normalized, "HYPERLINK")) {
    return("hyperlink")
  }
  "other"
}

extract_docx_field_instructions <- function(document) {
  nodes <- xml2::xml_find_all(
    document,
    ".//w:fldChar | .//w:instrText",
    ns = characterization_w_ns
  )
  stack <- list()
  instructions <- character()

  for (node in nodes) {
    if (identical(xml2::xml_name(node), "fldChar")) {
      field_type <- xml2::xml_attr(node, "fldCharType")
      if (identical(field_type, "begin")) {
        stack[[length(stack) + 1L]] <- list(
          capture = TRUE,
          parts = character()
        )
      } else if (
        identical(field_type, "separate") &&
          length(stack) > 0L
      ) {
        stack[[length(stack)]]$capture <- FALSE
      } else if (
        identical(field_type, "end") &&
          length(stack) > 0L
      ) {
        current <- stack[[length(stack)]]
        instruction <- trimws(paste0(current$parts, collapse = ""))
        if (nzchar(instruction)) {
          instructions <- c(instructions, instruction)
        }
        stack <- stack[-length(stack)]
      }
    } else if (
      length(stack) > 0L &&
        isTRUE(stack[[length(stack)]]$capture)
    ) {
      index <- length(stack)
      stack[[index]]$parts <- c(
        stack[[index]]$parts,
        xml2::xml_text(node)
      )
    }
  }
  instructions
}

docx_section_record <- function(section) {
  page_size <- xml2::xml_find_first(
    section,
    "./w:pgSz",
    ns = characterization_w_ns
  )
  margins <- xml2::xml_find_first(
    section,
    "./w:pgMar",
    ns = characterization_w_ns
  )
  line_numbers <- xml2::xml_find_first(
    section,
    "./w:lnNumType",
    ns = characterization_w_ns
  )
  value <- function(node, attribute) {
    result <- xml2::xml_attr(node, attribute)
    if (is.na(result)) NULL else unname(result)
  }
  list(
    width = value(page_size, "w"),
    height = value(page_size, "h"),
    orientation = value(page_size, "orient"),
    marginTop = value(margins, "top"),
    marginRight = value(margins, "right"),
    marginBottom = value(margins, "bottom"),
    marginLeft = value(margins, "left"),
    lineNumbering = value(line_numbers, "countBy")
  )
}

inspect_legacy_docx <- function(path) {
  if (!file.exists(path)) {
    stop("DOCX does not exist: ", path, call. = FALSE)
  }
  unpacked <- tempfile("docstyle-characterization-docx-")
  dir.create(unpacked)
  on.exit(unlink(unpacked, recursive = TRUE, force = TRUE), add = TRUE)
  utils::unzip(path, exdir = unpacked)

  document_path <- file.path(unpacked, "word", "document.xml")
  if (!file.exists(document_path)) {
    stop("DOCX lacks word/document.xml", call. = FALSE)
  }
  document <- xml2::read_xml(document_path)
  instructions <- extract_docx_field_instructions(document)
  field_types <- vapply(
    instructions,
    classify_docx_field,
    character(1)
  )
  field_counts <- as.list(as.integer(table(field_types)))
  names(field_counts) <- names(table(field_types))

  text_nodes <- xml2::xml_find_all(
    document,
    ".//w:t | .//w:delText",
    ns = characterization_w_ns
  )
  visible_text <- gsub(
    "[[:space:]]+",
    " ",
    trimws(paste(xml2::xml_text(text_nodes), collapse = " "))
  )
  sections <- xml2::xml_find_all(
    document,
    ".//w:sectPr",
    ns = characterization_w_ns
  )
  style_values <- xml2::xml_attr(
    xml2::xml_find_all(
      document,
      ".//w:pStyle",
      ns = characterization_w_ns
    ),
    "val"
  )
  package_parts <- sort(utils::unzip(path, list = TRUE)$Name)

  list(
    schemaVersion = 1L,
    artifact = "docx",
    packageParts = unname(package_parts),
    counts = list(
      paragraphs = length(xml2::xml_find_all(
        document,
        ".//w:p",
        ns = characterization_w_ns
      )),
      tables = length(xml2::xml_find_all(
        document,
        ".//w:tbl",
        ns = characterization_w_ns
      )),
      tableRows = length(xml2::xml_find_all(
        document,
        ".//w:tr",
        ns = characterization_w_ns
      )),
      tableCells = length(xml2::xml_find_all(
        document,
        ".//w:tc",
        ns = characterization_w_ns
      )),
      sections = length(sections),
      comments = length(xml2::xml_find_all(
        document,
        ".//w:commentRangeStart",
        ns = characterization_w_ns
      )),
      insertions = length(xml2::xml_find_all(
        document,
        ".//w:ins",
        ns = characterization_w_ns
      )),
      deletions = length(xml2::xml_find_all(
        document,
        ".//w:del",
        ns = characterization_w_ns
      ))
    ),
    fields = list(
      total = length(instructions),
      byType = field_counts,
      instructionHashes = unname(vapply(
        instructions,
        characterization_sha256,
        character(1)
      ))
    ),
    paragraphStyles = sort(unique(style_values[!is.na(style_values)])),
    sections = unname(lapply(sections, docx_section_record)),
    textHash = characterization_sha256(visible_text)
  )
}
