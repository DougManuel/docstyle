local h = require("lib.hashes")
return {
  { name = "format and determinism", fn = function()
      local node = { id = "abstract", type = "section", hash = "sha256:stale",
        children = { { id = "g-paragraph-aaaaaa", type = "paragraph",
          source = { file = "x.qmd", start = 3 }, text = "Résumé ✓" } } }
      local a = h.content_hash(node)
      assert(a:match("^sha256:[0-9a-f]+$") and #a == 71, a)
      assert(a == h.content_hash(node))
    end },
  { name = "hash and source excluded; text changes hash", fn = function()
      local base = { id = "r", type = "paragraph", text = "t" }
      local with_meta = { id = "r", type = "paragraph", text = "t",
        hash = "sha256:x", source = { file = "a.qmd" } }
      assert(h.content_hash(base) == h.content_hash(with_meta))
      local edited = { id = "r", type = "paragraph", text = "u" }
      assert(h.content_hash(base) ~= h.content_hash(edited))
    end },
}
