# ── Helper: minimal tex + figures fixture ─────────────────────────────────────

make_arxiv_fixture <- function(dir,
                               tex_content = NULL,
                               figures = c("images/fig1.png",
                                           "images/fig2.png"),
                               style_files = "arxiv.sty") {
  tex_path <- file.path(dir, "paper.tex")
  if (is.null(tex_content)) {
    fig_lines <- vapply(figures,
      function(p) paste0("\\includegraphics[keepaspectratio]{", p, "}"),
      character(1))
    tex_content <- paste(c(
      "\\documentclass{article}",
      "\\usepackage{graphicx}",
      "\\usepackage{arxiv}",
      "\\begin{document}",
      "\\title{Test}",
      fig_lines,
      "\\end{document}"
    ), collapse = "\n")
  }
  writeLines(tex_content, tex_path)

  for (fig in figures) {
    full <- file.path(dir, fig)
    dir.create(dirname(full), showWarnings = FALSE, recursive = TRUE)
    writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), full)  # PNG magic header
  }

  for (sty in style_files) {
    writeLines(paste0("% dummy ", sty), file.path(dir, sty))
  }

  tex_path
}


# ══ Basic packaging ═════════════════════════════════════════════════════════

test_that("package_arxiv flattens figure paths and creates tar.gz", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  result <- package_arxiv(tex, verbose = FALSE)

  expect_true(file.exists(result$archive_path))
  expect_match(result$archive_path, "\\.tar\\.gz$")
  expect_true("paper.tex" %in% result$manifest)
  expect_true("fig1.png" %in% result$manifest)
  expect_true("fig2.png" %in% result$manifest)
  expect_true("arxiv.sty" %in% result$manifest)
  expect_equal(unname(result$rewrites[["images/fig1.png"]]), "fig1.png")
})

test_that("package_arxiv rewrites \\includegraphics to flat paths in staged .tex", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  result <- package_arxiv(tex, verbose = FALSE)

  # Extract the staged .tex from the archive and confirm rewrites
  extract <- tempfile("extract_"); dir.create(extract)
  utils::untar(result$archive_path, exdir = extract)
  staged <- readLines(file.path(extract, "paper.tex"))

  expect_true(any(grepl("\\\\includegraphics\\[.*\\]\\{fig1\\.png\\}", staged)))
  expect_false(any(grepl("images/fig1\\.png", staged)))
})

test_that("package_arxiv handles \\pandocbounded wrapper (Quarto/Pandoc output)", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\pandocbounded{\\includegraphics[keepaspectratio]{images/fig1.png}}",
    "\\end{document}"
  ), collapse = "\n")
  tex <- make_arxiv_fixture(td, tex_content = tex_content,
                            figures = "images/fig1.png")

  result <- package_arxiv(tex, verbose = FALSE)

  expect_true("fig1.png" %in% result$manifest)
  expect_equal(unname(result$rewrites[["images/fig1.png"]]), "fig1.png")
})


# ══ Error handling ══════════════════════════════════════════════════════════

test_that("package_arxiv errors when a referenced figure is missing", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  # Reference a figure that doesn't exist on disk
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\includegraphics{images/nonexistent.png}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))

  expect_error(
    package_arxiv(file.path(td, "paper.tex"), verbose = FALSE),
    "Figure.*not found"
  )
})

test_that("package_arxiv errors when tex_path does not exist", {
  expect_error(package_arxiv("does/not/exist.tex", verbose = FALSE),
               "TeX file not found")
})

test_that("package_arxiv warns on figure basename collisions after flatten", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(
    td,
    figures = c("images/fig.png", "appendix/fig.png")
  )

  result <- package_arxiv(tex, verbose = FALSE)

  expect_true(any(grepl("basename collision", result$warnings)))
})


# ══ flatten = FALSE ═════════════════════════════════════════════════════════

test_that("package_arxiv with flatten=FALSE preserves subdirectory structure", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  result <- package_arxiv(tex, flatten = FALSE, verbose = FALSE)

  expect_true("images/fig1.png" %in% result$manifest)
  expect_length(result$rewrites, 0)

  # Staged .tex should retain original paths
  extract <- tempfile("extract_"); dir.create(extract)
  utils::untar(result$archive_path, exdir = extract)
  staged <- readLines(file.path(extract, "paper.tex"))
  expect_true(any(grepl("images/fig1\\.png", staged)))
})


# ══ Archive format ══════════════════════════════════════════════════════════

test_that("package_arxiv produces a zip when requested", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  result <- package_arxiv(tex, archive_format = "zip", verbose = FALSE)

  expect_match(result$archive_path, "\\.zip$")
  expect_true(file.exists(result$archive_path))
})


# ══ Extra files ═════════════════════════════════════════════════════════════

test_that("package_arxiv includes extra_files in the archive", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)
  readme <- file.path(td, "README.txt")
  writeLines("Submission notes", readme)

  result <- package_arxiv(tex, extra_files = readme, verbose = FALSE)

  expect_true("README.txt" %in% result$manifest)
})


# ══ Bibliography handling (P1 gap) ══════════════════════════════════════════

test_that("package_arxiv auto-detects .bib from \\bibliography{refs}", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\usepackage{natbib}",
    "\\begin{document}",
    "\\bibliography{refs}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))
  writeLines("@article{a,title={t}}", file.path(td, "refs.bib"))

  result <- package_arxiv(file.path(td, "paper.tex"), verbose = FALSE)

  expect_true("refs.bib" %in% result$manifest)
})

test_that("package_arxiv auto-includes .bbl sibling of the .tex", {
  # biber/bibtex workflow: arXiv requires the .bbl because it doesn't run
  # bibtex itself.
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)
  writeLines("\\begin{thebibliography}{}\n\\end{thebibliography}",
             file.path(td, "paper.bbl"))

  result <- package_arxiv(tex, verbose = FALSE)

  expect_true("paper.bbl" %in% result$manifest)
})

test_that("package_arxiv warns on \\bibliography{a,b} with multiple entries", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\bibliography{refs,extra}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))
  writeLines("@article{a,title={t}}", file.path(td, "refs.bib"))

  result <- package_arxiv(file.path(td, "paper.tex"), verbose = FALSE)

  expect_true(any(grepl("multiple entries", result$warnings)))
  expect_true("refs.bib" %in% result$manifest)
})

test_that("package_arxiv warns when \\bibliography stem has no matching .bib", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\bibliography{refs}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))
  # deliberately no refs.bib on disk

  result <- package_arxiv(file.path(td, "paper.tex"), verbose = FALSE)

  expect_true(any(grepl("does not exist", result$warnings)))
})


# ══ Figure resolution (P2 gap) ══════════════════════════════════════════════

test_that("package_arxiv resolves \\includegraphics{fig1} without an extension", {
  # LaTeX permits the extension to be omitted; resolve_figure_paths() probes.
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\includegraphics{fig1}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), file.path(td, "fig1.png"))

  result <- package_arxiv(file.path(td, "paper.tex"), verbose = FALSE)

  expect_true("fig1.png" %in% result$manifest)
})

test_that("package_arxiv matches \\includegraphics* (star form)", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\includegraphics*[width=\\linewidth]{images/fig.png}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))
  dir.create(file.path(td, "images"))
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)),
           file.path(td, "images/fig.png"))

  result <- package_arxiv(file.path(td, "paper.tex"), verbose = FALSE)

  expect_true("fig.png" %in% result$manifest)
  expect_equal(unname(result$rewrites[["images/fig.png"]]), "fig.png")
})

test_that("package_arxiv warns on figure path using '../' parent reference", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  sibling <- file.path(td, "shared"); dir.create(sibling)
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), file.path(sibling, "fig.png"))
  render_dir <- file.path(td, "render"); dir.create(render_dir)
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\includegraphics{../shared/fig.png}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(render_dir, "paper.tex"))

  result <- package_arxiv(file.path(render_dir, "paper.tex"), verbose = FALSE)

  expect_true(any(grepl("'\\.\\./'", result$warnings) |
                  grepl("'\\.\\./'", result$warnings, fixed = TRUE) |
                  grepl("\\.\\./", result$warnings)))
})


# ══ Style file discovery (P3) ═══════════════════════════════════════════════

test_that("package_arxiv auto-discovers only \\usepackage'd style files", {
  # A stale `.sty` in the directory that the tex doesn't use must not ship.
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td, style_files = c("arxiv.sty", "stale.sty"))

  result <- package_arxiv(tex, verbose = FALSE)

  expect_true("arxiv.sty" %in% result$manifest)   # \usepackage{arxiv} in fixture
  expect_false("stale.sty" %in% result$manifest)  # never referenced
})

test_that("package_arxiv uses user-supplied style_files when provided", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)
  # Create an out-of-dir style file the user wants bundled explicitly
  custom <- tempfile("custom_", fileext = ".sty")
  writeLines("% custom style", custom); on.exit(unlink(custom), add = TRUE)

  result <- package_arxiv(tex, style_files = custom, verbose = FALSE)

  expect_true(basename(custom) %in% result$manifest)
  # auto-discovery is skipped — arxiv.sty from fixture should NOT be in manifest
  expect_false("arxiv.sty" %in% result$manifest)
})


# ══ Output path validation (P2) ═════════════════════════════════════════════

test_that("package_arxiv errors when output directory does not exist", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  expect_error(
    package_arxiv(tex,
                  output_path = file.path(td, "nonexistent", "out.tar.gz"),
                  verbose = FALSE),
    "Output directory does not exist"
  )
})


# ══ Archive integrity (P2) ══════════════════════════════════════════════════

test_that("package_arxiv zip archive has correct contents", {
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  result <- package_arxiv(tex, archive_format = "zip", verbose = FALSE)

  extract <- tempfile("extract_"); dir.create(extract)
  on.exit(unlink(extract, recursive = TRUE), add = TRUE)
  utils::unzip(result$archive_path, exdir = extract)

  extracted <- list.files(extract)
  expect_true("paper.tex" %in% extracted)
  expect_true("fig1.png" %in% extracted)
  expect_true("arxiv.sty" %in% extracted)
})

test_that("package_arxiv tar.gz contains no macOS AppleDouble ._* metadata", {
  # arXiv's AutoTeX rejects ._paper.tex; utils::tar(tar = 'internal') avoids
  # shelling out to system tar which can embed these on macOS.
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  tex <- make_arxiv_fixture(td)

  result <- package_arxiv(tex, verbose = FALSE)

  extract <- tempfile("extract_"); dir.create(extract)
  on.exit(unlink(extract, recursive = TRUE), add = TRUE)
  utils::untar(result$archive_path, exdir = extract)

  extracted <- list.files(extract, recursive = TRUE, all.files = TRUE)
  expect_false(any(grepl("^\\._", extracted)))
  expect_false(any(grepl("/\\._", extracted)))
})


# ══ Case-sensitivity (P3) ═══════════════════════════════════════════════════

test_that("package_arxiv warns on figure casing drift", {
  # On macOS APFS (default case-insensitive) this test exercises the warning.
  # On case-sensitive filesystems the figure wouldn't resolve at all and the
  # function would hard-error earlier — which is also fine.
  skip_on_os("linux")  # case-sensitive; no drift possible
  td <- tempfile("arxiv_"); dir.create(td); on.exit(unlink(td, recursive = TRUE))
  dir.create(file.path(td, "images"))
  # On-disk casing: lowercase. Tex references uppercase.
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)),
           file.path(td, "images/fig.png"))
  tex_content <- paste(c(
    "\\documentclass{article}",
    "\\begin{document}",
    "\\includegraphics{images/FIG.png}",
    "\\end{document}"
  ), collapse = "\n")
  writeLines(tex_content, file.path(td, "paper.tex"))

  result <- package_arxiv(file.path(td, "paper.tex"), verbose = FALSE)

  # Should still succeed (file resolves on case-insensitive fs) but warn
  expect_true(any(grepl("casing", result$warnings)))
})
