legacy_sidecar_contract <- function() {
  records <- list(
    c(
      "field-codes.json", "durable", "mixed",
      "Zotero fields, references hash and extraction provenance"
    ),
    c(
      "comments.json", "durable", "returned-docx",
      "Word comments and replies"
    ),
    c(
      "revisions.json", "durable", "returned-docx",
      "Tracked insertion and deletion metadata"
    ),
    c(
      "references.json", "generated", "source",
      "CSL JSON reference cache"
    ),
    c(
      "page-config.json", "generated", "source",
      "Resolved document, page and named-section properties"
    ),
    c(
      "style-map.json", "generated", "source",
      "Resolved Word style identifiers"
    ),
    c(
      "section-map.json", "generated", "rendered-docx",
      "Section boundary inventory"
    ),
    c(
      "harvest-map.json", "generated", "rendered-docx",
      "Paragraph correspondence cache"
    ),
    c(
      "figures.json", "generated", "mixed",
      "Figure identifiers and source paths"
    ),
    c(
      "styles.json", "generated", "rendered-docx",
      "Extracted style inventory"
    )
  )
  lapply(records, function(record) {
    list(
      name = record[[1]],
      lifecycle = record[[2]],
      authority = record[[3]],
      purpose = record[[4]],
      versioning = "unversioned"
    )
  })
}

read_characterized_package_version <- function(repo_root) {
  fields <- read.dcf(file.path(repo_root, "DESCRIPTION"))
  unname(fields[1, "Version"])
}

characterize_legacy_contract <- function(repo_root) {
  schema_path <- file.path(
    repo_root,
    "inst", "schema", "docstyle-field-codes.json"
  )
  schema <- jsonlite::read_json(schema_path, simplifyVector = FALSE)
  writer_version <- as.integer(schema$schema_version)

  list(
    schemaVersion = 1L,
    characterizedRelease = read_characterized_package_version(repo_root),
    fieldCodes = list(
      instructionPrefix = "ADDIN DOCSTYLE",
      writerVersion = writer_version,
      readerVersions = as.list(seq_len(writer_version)),
      futureVersionPolicy = paste(
        "Strict reading rejects versions greater than",
        writer_version
      ),
      payloadTypes = as.list(c(
        "char", "div", "list", "section", "table", "figure",
        "float", "anchor"
      )),
      interoperablePrefixes = as.list(c(
        "ADDIN ZOTERO_ITEM",
        "ADDIN ZOTERO_BIBL",
        "ADDIN ZOTERO_PREF"
      ))
    ),
    sidecars = legacy_sidecar_contract()
  )
}

validate_legacy_contract <- function(contract) {
  if (!identical(as.integer(contract$schemaVersion), 1L)) {
    stop("legacy contract schemaVersion must be 1", call. = FALSE)
  }
  writer <- as.integer(contract$fieldCodes$writerVersion)
  readers <- as.integer(unlist(
    contract$fieldCodes$readerVersions,
    use.names = FALSE
  ))
  if (!identical(readers, seq_len(writer))) {
    stop(
      "field-code readerVersions must cover 1 through writerVersion",
      call. = FALSE
    )
  }
  sidecar_names <- vapply(
    contract$sidecars,
    function(x) as.character(x$name),
    character(1)
  )
  if (anyDuplicated(sidecar_names)) {
    stop("legacy sidecar names must be unique", call. = FALSE)
  }
  valid_lifecycles <- c("durable", "generated")
  if (!all(vapply(
    contract$sidecars,
    function(x) as.character(x$lifecycle) %in% valid_lifecycles,
    logical(1)
  ))) {
    stop("legacy sidecar lifecycle is invalid", call. = FALSE)
  }
  invisible(TRUE)
}

write_legacy_contract <- function(repo_root, path) {
  contract <- characterize_legacy_contract(repo_root)
  validate_legacy_contract(contract)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    contract,
    path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  invisible(path)
}
