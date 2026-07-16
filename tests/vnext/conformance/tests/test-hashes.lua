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
  { name = "CRLF, LF and lone CR line endings hash identically; different text does not", fn = function()
      local lf = { id = "p", type = "paragraph", text = "line one\nline two\nline three" }
      local crlf = { id = "p", type = "paragraph", text = "line one\r\nline two\r\nline three" }
      local cr = { id = "p", type = "paragraph", text = "line one\rline two\rline three" }
      local different = { id = "p", type = "paragraph", text = "line one\nline two\nline FOUR" }
      assert(h.content_hash(lf) == h.content_hash(crlf), "CRLF should hash the same as LF")
      assert(h.content_hash(lf) == h.content_hash(cr), "lone CR should hash the same as LF")
      assert(h.content_hash(lf) ~= h.content_hash(different), "genuinely different text must still change the hash")
    end },
  { name = "hash/source stripped at every depth, not just top level and one level of nesting", fn = function()
      -- Strip-at-every-depth: hash/source keys nested two levels down,
      -- inside a children array element's own nested attrs object and
      -- inside a doubly-nested children array, must strip the same as a
      -- top-level hash/source key does. (This closed what was an earlier
      -- test gap; it is not one of the six declared bounds in the README
      -- or audit (seven at last count) -- those enumerate genuine
      -- limitations, not tested cases.)
      local nested = {
        id = "sec", type = "section", hash = "sha256:top",
        children = {
          { id = "row1", type = "table-row", hash = "sha256:row",
            attrs = { align = "left", source = { file = "deep.qmd", start = 9 } },
            children = {
              { id = "cell1", type = "table-cell", text = "value",
                source = { file = "deep.qmd", start = 9 }, hash = "sha256:cell" },
            },
          },
        },
      }
      local stripped_twin = {
        id = "sec", type = "section",
        children = {
          { id = "row1", type = "table-row",
            attrs = { align = "left" },
            children = {
              { id = "cell1", type = "table-cell", text = "value" },
            },
          },
        },
      }
      assert(h.content_hash(nested) == h.content_hash(stripped_twin))
    end },
}
