publication_or <- function(x, y) if (is.null(x)) y else x

publication_sha256 <- function(value) {
  paste0(
    "sha256:",
    digest::digest(value, algo = "sha256", serialize = FALSE)
  )
}

normalize_publication_text <- function(value) {
  gsub("[[:space:]]+", " ", trimws(paste(value, collapse = " ")))
}

run_characterization_command <- function(command, arguments, label) {
  output <- suppressWarnings(system2(
    command,
    arguments,
    stdout = TRUE,
    stderr = TRUE
  ))
  status <- attr(output, "status")
  if (!is.null(status) && status != 0L) {
    stop(
      label, " failed with status ", status, ":\n",
      paste(output, collapse = "\n"),
      call. = FALSE
    )
  }
  unname(output)
}

parse_characterization_pdfinfo <- function(lines) {
  matches <- regexec("^([^:]+):[[:space:]]*(.*)$", lines)
  fields <- regmatches(lines, matches)
  fields <- fields[lengths(fields) == 3L]
  keys <- vapply(fields, function(x) trimws(x[[2]]), character(1))
  values <- vapply(fields, function(x) trimws(x[[3]]), character(1))
  names(values) <- keys

  value_or_null <- function(key) {
    if (!key %in% names(values)) {
      return(NULL)
    }
    value <- unname(values[[key]])
    if (is.null(value) || !nzchar(value)) NULL else value
  }
  integer_or_null <- function(key) {
    value <- value_or_null(key)
    if (is.null(value)) NULL else as.integer(value)
  }
  yes <- function(key) {
    identical(tolower(publication_or(value_or_null(key), "")), "yes")
  }

  list(
    title = value_or_null("Title"),
    pages = integer_or_null("Pages"),
    pageSize = value_or_null("Page size"),
    tagged = yes("Tagged"),
    encrypted = yes("Encrypted"),
    pdfVersion = value_or_null("PDF version")
  )
}

inspect_legacy_pdf <- function(
  path,
  pdfinfo_bin = "pdfinfo",
  pdftotext_bin = "pdftotext"
) {
  if (!file.exists(path)) {
    stop("PDF does not exist: ", path, call. = FALSE)
  }
  info <- parse_characterization_pdfinfo(
    run_characterization_command(
      pdfinfo_bin,
      path,
      "pdfinfo"
    )
  )
  text_path <- tempfile(fileext = ".txt")
  on.exit(unlink(text_path, force = TRUE), add = TRUE)
  run_characterization_command(
    pdftotext_bin,
    c("-enc", "UTF-8", path, text_path),
    "pdftotext"
  )
  text <- if (file.exists(text_path)) {
    readLines(text_path, warn = FALSE, encoding = "UTF-8")
  } else {
    character()
  }

  c(
    list(schemaVersion = 1L, artifact = "pdf"),
    info,
    list(textHash = publication_sha256(normalize_publication_text(text)))
  )
}

inspect_legacy_jats <- function(path) {
  if (!file.exists(path)) {
    stop("JATS XML does not exist: ", path, call. = FALSE)
  }
  document <- xml2::read_xml(path)
  count <- function(xpath) {
    length(xml2::xml_find_all(document, xpath))
  }
  text_at <- function(xpath) {
    nodes <- xml2::xml_find_all(document, xpath)
    normalize_publication_text(xml2::xml_text(nodes))
  }

  list(
    schemaVersion = 1L,
    artifact = "jats",
    articleType = unname(xml2::xml_attr(
      xml2::xml_find_first(document, "/*[local-name()='article']"),
      "article-type"
    )),
    counts = list(
      sections = count("//*[local-name()='sec']"),
      paragraphs = count("//*[local-name()='p']"),
      tables = count("//*[local-name()='table-wrap']"),
      figures = count("//*[local-name()='fig']"),
      references = count(
        "//*[local-name()='ref-list']/*[local-name()='ref']"
      ),
      crossReferences = count("//*[local-name()='xref']")
    ),
    abstractHash = publication_sha256(
      text_at("//*[local-name()='abstract']")
    ),
    textHash = publication_sha256(
      text_at("/*[local-name()='article']")
    )
  )
}

rasterize_pdf_pages <- function(
  path,
  pages,
  output_dir,
  prefix,
  pdftoppm_bin = "pdftoppm",
  resolution = 110L
) {
  if (!file.exists(path)) {
    stop("PDF does not exist: ", path, call. = FALSE)
  }
  pages <- sort(unique(as.integer(pages)))
  if (length(pages) < 1L || any(is.na(pages)) || any(pages < 1L)) {
    stop("pages must contain positive integers", call. = FALSE)
  }
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  outputs <- vapply(pages, function(page) {
    output <- file.path(
      output_dir,
      sprintf("%s-page-%03d", prefix, page)
    )
    run_characterization_command(
      pdftoppm_bin,
      c(
        "-f", page,
        "-l", page,
        "-r", as.integer(resolution),
        "-png",
        "-singlefile",
        path,
        output
      ),
      paste0("pdftoppm page ", page)
    )
    png <- paste0(output, ".png")
    if (!file.exists(png)) {
      stop("pdftoppm did not create: ", png, call. = FALSE)
    }
    normalizePath(png, mustWork = TRUE)
  }, character(1))

  unname(outputs)
}
