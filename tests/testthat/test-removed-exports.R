# Regression guard: functions removed in 0.11.0 must not reappear.
#
# These three Zotero Web-API functions were removed because Zotero library
# management is out of scope for a document-styling package. If a future merge,
# rebase, or revert accidentally re-introduces them, this test fails loudly.
# See NEWS.md entry for 0.11.0 and ai-infrastructure issue #4.

test_that("Zotero Web-API management functions are not exported (0.11.0)", {
  removed <- c("add_zotero_item", "update_zotero_item", "update_zotero_doi")
  for (fn in removed) {
    expect_false(
      fn %in% getNamespaceExports("docstyle"),
      info = sprintf(
        "`%s` was removed in 0.11.0 but is exported again; see NEWS.md.",
        fn
      )
    )
  }
})
