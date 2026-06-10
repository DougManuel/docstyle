#' Match Citations
#'
#' Matches extracted Word citations against a canonical CSL/BibTeX library.
#'
#' @param source_items List of CSL-JSON items from Word (Source).
#' @param target_items List of CSL-JSON items from BibTeX (Target).
#' @return A list containing:
#'   - `matches`: Data frame of matched pairs.
#'   - `orphans`: Data frame of source items not found in target.
#'   - `unused`: Data frame of target items not used in source.
#' @keywords internal
#' @export
match_citations <- function(source_items, target_items) {
  
  # Normalize
  df_source <- normalize_items(source_items, source = "word")
  df_target <- normalize_items(target_items, source = "bib")
  
  matched_pairs <- data.frame(
    word_id = character(), 
    bib_id = character(), 
    method = character(),
    stringsAsFactors = FALSE
  )
  
  # Helper to track matched IDs
  matched_source_ids <- c()
  matched_target_ids <- c()
  
  # 1. DOI Match (Exact)
  # Filter out items without DOI first to save time
  s_doi <- df_source[!is.na(df_source$doi) & df_source$doi != "", ]
  t_doi <- df_target[!is.na(df_target$doi) & df_target$doi != "", ]
  
  if (nrow(s_doi) > 0 && nrow(t_doi) > 0) {
    # Merge on DOI
    m <- merge(s_doi, t_doi, by = "doi")
    if (nrow(m) > 0) {
      matched_pairs <- rbind(matched_pairs, data.frame(
        word_id = m$id.x,
        bib_id = m$id.y,
        method = "doi",
        stringsAsFactors = FALSE
      ))
      matched_source_ids <- c(matched_source_ids, m$id.x)
      matched_target_ids <- c(matched_target_ids, m$id.y)
    }
  }
  
  # 2. Title + Year Match (Strong)
  # Filter remaining
  s_rem <- df_source[!df_source$id %in% matched_source_ids, ]
  t_rem <- df_target # Target can be matched multiple times? No, ideally 1:1. 
  # Actually, bib items are unique entities. If Word cites the same paper twice (different Zotero IDs), 
  # they should both map to the same Bib ID.
  # So we filter Source, but keep Target available? 
  # Usually Zotero uses one Item ID per paper. But if user inserted duplicates...
  
  if (nrow(s_rem) > 0) {
    m <- merge(s_rem, df_target, by = c("title_norm", "year"))
    if (nrow(m) > 0) {
      new_matches <- data.frame(
        word_id = m$id.x,
        bib_id = m$id.y,
        method = "title_year",
        stringsAsFactors = FALSE
      )
      matched_pairs <- rbind(matched_pairs, new_matches)
      matched_source_ids <- c(matched_source_ids, m$id.x)
    }
  }
  
  # 3. Fuzzy Match (Title only)
  s_rem <- df_source[!df_source$id %in% matched_source_ids, ]
  if (nrow(s_rem) > 0 && nrow(df_target) > 0) {
    # Simple levenshtein on titles
    for (i in 1:nrow(s_rem)) {
      s_title <- s_rem$title_norm[i]
      if (nchar(s_title) < 10) next # Skip short titles
      
      dists <- utils::adist(s_title, df_target$title_norm)
      min_dist <- min(dists)
      which_min <- which.min(dists)
      
      # Threshold: e.g. < 5 edits or < 10% length
      if (min_dist < (nchar(s_title) * 0.2)) {
        matched_pairs <- rbind(matched_pairs, data.frame(
          word_id = s_rem$id[i],
          bib_id = df_target$id[which_min],
          method = "fuzzy_title",
          stringsAsFactors = FALSE
        ))
        matched_source_ids <- c(matched_source_ids, s_rem$id[i])
      }
    }
  }
  
  # Orphans
  orphans <- df_source[!df_source$id %in% matched_source_ids, ]
  
  # Unused (Targets not in matched pairs)
  unused <- df_target[!df_target$id %in% matched_pairs$bib_id, ]
  
  list(
    matches = matched_pairs,
    orphans = orphans,
    unused = unused
  )
}

#' Normalize Citation Items
#'
#' Converts a list of CSL items to a data frame for comparison.
#'
#' @param items List of CSL items.
#' @param source Label ("word" or "bib").
#' @return Data frame.
#' @keywords internal
normalize_items <- function(items, source) {
  ids <- sapply(items, function(x) as.character(x$id))
  titles <- sapply(items, function(x) {
    t <- x$title
    if (is.null(t)) return("")
    # Normalize: lowercase, remove punctuation/spaces
    t <- tolower(t)
    t <- gsub("[^a-z0-9]", "", t)
    t
  })
  
  dois <- sapply(items, function(x) {
    d <- x$DOI
    if (is.null(d)) return("")
    # Clean DOI
    d <- tolower(d)
    d <- gsub("https?://(dx\\.)?doi\\.org/", "", d)
    d
  })
  
  years <- sapply(items, function(x) {
    # Extract year logic
    y <- ""
    if (!is.null(x$issued$`date-parts`) && length(x$issued$`date-parts`) > 0) {
      y <- as.character(x$issued$`date-parts`[[1]][[1]])
    } else if (!is.null(x$accessed$`date-parts`) && length(x$accessed$`date-parts`) > 0) {
      y <- as.character(x$accessed$`date-parts`[[1]][[1]])
    }
    y
  })
  
  data.frame(
    id = ids,
    title_norm = titles,
    doi = dois,
    year = years,
    stringsAsFactors = FALSE
  )
}
