## build-fixture.R
## Rebuilds comments-revisions-test-roundtrip.docx with enriched comment data:
##   - Threaded comment chains (paraIdParent in commentsExtended.xml)
##   - Resolved comments (done="1")
##   - Special-character comment text
##
## Run from the package root:
##   Rscript inst/extdata/minimal-example/build-fixture.R

docx_path <- file.path(
  "inst", "extdata", "minimal-example",
  "comments-revisions-test-roundtrip.docx"
)
stopifnot(file.exists(docx_path))

td <- tempfile("build_fixture_")
if (!dir.create(td)) stop("Failed to create temp directory: ", td)
on.exit(unlink(td, recursive = TRUE), add = TRUE)

unzip_status <- utils::unzip(docx_path, exdir = td)
if (is.null(unzip_status)) stop("unzip failed for: ", docx_path)

# ---------------------------------------------------------------------------
# 1. comments.xml — add three new comments
# ---------------------------------------------------------------------------

comments_path <- file.path(td, "word", "comments.xml")
if (!file.exists(comments_path)) stop("comments.xml not found after unzip: ", comments_path)
comments_txt <- readLines(comments_path, encoding = "UTF-8", warn = FALSE)
comments_raw <- paste(comments_txt, collapse = "\n")

new_comments <- paste0(
  # Reply 1 to comment 3 (Reviewer 1 thread)
  '<w:comment w:id="13" w:author="Reviewer 1" ',
  'w:date="2025-01-15T11:00:00Z" w:initials="R1">',
  '<w:p w14:paraId="A1B2C3D4" w14:textId="77777777" ',
  'w:rsidR="00453D61" w:rsidRDefault="00000000">',
  '<w:r><w:t>Agree, let\'s simplify.</w:t></w:r>',
  '</w:p></w:comment>',
  # Reply 2 to comment 3 (deeper thread)
  '<w:comment w:id="14" w:author="Editor" ',
  'w:date="2025-01-15T11:30:00Z" w:initials="ED">',
  '<w:p w14:paraId="B2C3D4E5" w14:textId="77777777" ',
  'w:rsidR="00453D61" w:rsidRDefault="00000000">',
  '<w:r><w:t>Second reply in thread.</w:t></w:r>',
  '</w:p></w:comment>',
  # Special characters (resolved)
  '<w:comment w:id="15" w:author="Doug Manuel" ',
  'w:date="2025-01-16T09:00:00Z" w:initials="DGM">',
  '<w:p w14:paraId="C3D4E5F6" w14:textId="77777777" ',
  'w:rsidR="00CA2FA2" w:rsidRDefault="00CA2FA2">',
  '<w:r><w:t>Test: &amp; &lt; &gt; &quot; \u2014 special chars</w:t></w:r>',
  '</w:p></w:comment>'
)

# Insert before the closing </w:comments> tag
comments_raw_new <- sub(
  "</w:comments>",
  paste0(new_comments, "</w:comments>"),
  comments_raw,
  fixed = TRUE
)
if (identical(comments_raw_new, comments_raw)) {
  stop("sub() no-op: </w:comments> closing tag not found in comments.xml")
}
writeLines(comments_raw_new, comments_path)

# ---------------------------------------------------------------------------
# 2. commentsExtended.xml — add threading + mark comment 4 and 15 resolved
# ---------------------------------------------------------------------------

ext_path <- file.path(td, "word", "commentsExtended.xml")
if (!file.exists(ext_path)) stop("commentsExtended.xml not found after unzip: ", ext_path)
ext_txt <- readLines(ext_path, encoding = "UTF-8", warn = FALSE)
ext_raw <- paste(ext_txt, collapse = "\n")

# Mark comment 4 (paraId 512765A3) as resolved
ext_raw_resolved <- gsub(
  'w15:paraId="512765A3" w15:done="0"',
  'w15:paraId="512765A3" w15:done="1"',
  ext_raw, fixed = TRUE
)
if (identical(ext_raw_resolved, ext_raw)) {
  stop("gsub() no-op: paraId 512765A3 with done=\"0\" not found in commentsExtended.xml")
}
ext_raw <- ext_raw_resolved

new_ext_entries <- paste0(
  # Reply 1 to comment 3
  '<w15:commentEx w15:paraId="A1B2C3D4" w15:done="0" ',
  'w15:paraIdParent="072FD5BD"/>',
  # Reply 2 to comment 3
  '<w15:commentEx w15:paraId="B2C3D4E5" w15:done="0" ',
  'w15:paraIdParent="072FD5BD"/>',
  # Special-char comment — resolved
  '<w15:commentEx w15:paraId="C3D4E5F6" w15:done="1"/>'
)

ext_raw_new <- sub(
  "</w15:commentsEx>",
  paste0(new_ext_entries, "</w15:commentsEx>"),
  ext_raw, fixed = TRUE
)
if (identical(ext_raw_new, ext_raw)) {
  stop("sub() no-op: </w15:commentsEx> closing tag not found in commentsExtended.xml")
}
writeLines(ext_raw_new, ext_path)

# ---------------------------------------------------------------------------
# 3. commentsIds.xml — register new paraIds
# ---------------------------------------------------------------------------

ids_path <- file.path(td, "word", "commentsIds.xml")
if (!file.exists(ids_path)) stop("commentsIds.xml not found after unzip: ", ids_path)
ids_txt <- readLines(ids_path, encoding = "UTF-8", warn = FALSE)
ids_raw <- paste(ids_txt, collapse = "\n")

new_ids <- paste0(
  '<w16cid:commentId w16cid:paraId="A1B2C3D4" w16cid:durableId="A1B2C3D4"/>',
  '<w16cid:commentId w16cid:paraId="B2C3D4E5" w16cid:durableId="B2C3D4E5"/>',
  '<w16cid:commentId w16cid:paraId="C3D4E5F6" w16cid:durableId="C3D4E5F6"/>'
)

ids_raw_new <- sub(
  "</w16cid:commentsIds>",
  paste0(new_ids, "</w16cid:commentsIds>"),
  ids_raw, fixed = TRUE
)
if (identical(ids_raw_new, ids_raw)) {
  stop("sub() no-op: </w16cid:commentsIds> closing tag not found in commentsIds.xml")
}
writeLines(ids_raw_new, ids_path)

# ---------------------------------------------------------------------------
# 4. Rezip
# ---------------------------------------------------------------------------

out_path <- normalizePath(docx_path, mustWork = TRUE)
old_wd <- getwd()
setwd(td)
on.exit(setwd(old_wd), add = TRUE)
all_files <- list.files(".", recursive = TRUE, all.files = TRUE)
# Exclude hidden OS files
all_files <- all_files[!grepl("^\\.", basename(all_files))]
if (length(all_files) == 0L) stop("No files found in temp dir to rezip — unzip may have failed silently")
zip_status <- zip(out_path, files = all_files, flags = "-q")
if (zip_status != 0L) stop("zip() failed with status: ", zip_status)

message("Fixture rebuilt: ", docx_path)
