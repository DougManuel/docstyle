#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Pick Zotero Citation
# @raycast.mode silent
# @raycast.packageName DocStyle

# Optional parameters:
# @raycast.icon 📝

# Documentation:
# @raycast.description Opens Zotero picker and copies Pandoc citation to clipboard
# @raycast.author Douglas Manuel

# Call Better BibTeX API
# format=pandoc returns [@key]
# minimize=true keeps Zotero in background after
CITATION=$(curl -s "http://127.0.0.1:23119/better-bibtex/cayw?format=pandoc&minimize=true")

if [ -n "$CITATION" ]; then
  # Sanitize the output using sed (similar to our R logic)
  # 1. Trim whitespace
  # 2. Remove brackets
  # 3. Remove leading @
  # 4. Reconstruct [@key]
  
  # Remove all brackets and all @ symbols, then trim whitespace
  # This makes the sanitization much more aggressive and less prone to unexpected BBT outputs.
  CLEANED=$(echo "$CITATION" | sed -E 's/\[|\]|@//g' | tr -d '\n\r' | sed 's/^ *//;s/ *$//')
  FINAL="[@$CLEANED]"

  # Copy to clipboard
  echo "$FINAL" | pbcopy
  
  # Notify user
  echo "Copied: $FINAL"
else
  echo "Canceled"
fi
