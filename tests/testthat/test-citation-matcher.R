test_that("match_citations identifies exact and fuzzy matches", {
  # Mock Data
  source_items <- list(
    list(id = "word1", title = "A Study of Everything", DOI = "10.1000/xyz", issued = list(`date-parts` = list(list(2023)))),
    list(id = "word2", title = "Fuzzy Title Match Example", issued = list(`date-parts` = list(list(2020)))),
    list(id = "word3", title = "Orphan Paper", issued = list(`date-parts` = list(list(2021))))
  )
  
  target_items <- list(
    list(id = "bib1", title = "A study of everything", DOI = "10.1000/xyz", issued = list(`date-parts` = list(list(2023)))), # Exact DOI
    list(id = "bib2", title = "Fuzzy Title Match Exampl", issued = list(`date-parts` = list(list(2020)))) # Fuzzy (typo)
  )
  
  res <- match_citations(source_items, target_items)
  
  # Check DOI match
  m1 <- res$matches[res$matches$word_id == "word1", ]
  expect_equal(m1$bib_id, "bib1")
  expect_equal(m1$method, "doi")
  
  # Check Fuzzy/Title match
  m2 <- res$matches[res$matches$word_id == "word2", ]
  expect_equal(m2$bib_id, "bib2")
  
  # Check Orphan
  expect_true("word3" %in% res$orphans$id)
})
