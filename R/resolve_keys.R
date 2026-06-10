#' Resolve Citation Keys
#'
#' Generates unique citation keys for a list of items, handling collisions.
#'
#' @param all_items Named list of CSL-JSON items.
#' @return Named list of citation keys (names match item IDs).
#' @keywords internal
resolve_cite_keys <- function(all_items) {
  cite_keys <- list()
  generated_keys_counter <- list() # To track base keys and their counts
  
  for (i in seq_along(all_items)) {
    item_id <- names(all_items)[i]
    item <- all_items[[i]]
    
    base_key <- generate_base_key(item)
    
    # Handle collisions
    if (is.null(generated_keys_counter[[base_key]])) {
      generated_keys_counter[[base_key]] <- 0
      final_key <- base_key
    } else {
      count <- generated_keys_counter[[base_key]] + 1
      generated_keys_counter[[base_key]] <- count
      final_key <- paste0(base_key, letters[count]) # a, b, c... 
      # Handling > 26 collisions: wrap around or use double letters?
      # Simple fallback if > 26: just use number? 
      if (count > 26) {
        final_key <- paste0(base_key, count)
      }
    }
    
    # Ensure we mark base key as seen if we used it directly
    if (final_key == base_key) {
       generated_keys_counter[[base_key]] <- 0
    }
    
    cite_keys[[item_id]] <- final_key
  }
  return(cite_keys)
}
