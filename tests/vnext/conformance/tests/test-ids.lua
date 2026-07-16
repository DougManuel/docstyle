local ids = require("lib.ids")
local function charsource(s)
  local i = 0
  return function() i = i + 1; return s:sub(i, i) end
end
return {
  { name = "format g-<kind>-<6 base32>", fn = function()
      local id = ids.generate("table", {}, charsource("k3m7ap"))
      assert(id == "g-table-k3m7ap", id)
    end },
  { name = "collision redraws until unused", fn = function()
      local used = { ["g-table-aaaaaa"] = true }
      local id = ids.generate("table", used, charsource("aaaaaabbbbbb"))
      assert(id == "g-table-bbbbbb", id)
    end },
  { name = "explicit ids may not use reserved prefixes or collide", fn = function()
      assert(ids.check_explicit("abstract", {}))
      local ok1 = ids.check_explicit("g-abstract", {})
      local ok2 = ids.check_explicit("docstyle-x", {})
      local ok3 = ids.check_explicit("abstract", { abstract = true })
      assert(not ok1 and not ok2 and not ok3)
    end },
  { name = "reuse(): persisted ids survive a simulated re-render (explicit, moved, edited, brand-new)", fn = function()
      -- Render 1: durable state persisted from the previous commit
      -- (regions.json-shaped: id, source, hash per generated region).
      local loc_abstract = { file = "protocol.qmd", start = 1, ["end"] = 5 }
      local loc_x = { file = "protocol.qmd", start = 10, ["end"] = 15 }
      local loc_y = { file = "protocol.qmd", start = 20, ["end"] = 25 }
      local durable = {
        { id = "abstract", source = loc_abstract, hash = "H0" },
        { id = "g-table-k3m7ap", source = loc_x, hash = "H1" },
        { id = "g-figure-qqqqqq", source = loc_y, hash = "H2" },
      }

      -- Render 2, #abstract: explicit id wins regardless of source/hash.
      local abstract_id, abstract_origin = ids.reuse({ explicit_id = "abstract" }, durable)
      assert(abstract_id == "abstract" and abstract_origin == "explicit",
        "expected abstract/explicit, got " .. tostring(abstract_id) .. "/" .. tostring(abstract_origin))

      -- Render 2, table MOVED to a new source location but with the same
      -- content hash (H1) -> reused via hash match.
      local loc_x2 = { file = "protocol.qmd", start = 40, ["end"] = 45 }
      local table_id, table_origin = ids.reuse({ type = "table", source = loc_x2, hash = "H1" }, durable)
      assert(table_id == "g-table-k3m7ap" and table_origin == "hash",
        "expected g-table-k3m7ap/hash, got " .. tostring(table_id) .. "/" .. tostring(table_origin))

      -- Render 2, figure stayed at the same source location but its
      -- content changed (H2 -> H3) -> reused via source match, checked
      -- before hash.
      local figure_id, figure_origin = ids.reuse({ type = "figure", source = loc_y, hash = "H3" }, durable)
      assert(figure_id == "g-figure-qqqqqq" and figure_origin == "source",
        "expected g-figure-qqqqqq/source, got " .. tostring(figure_id) .. "/" .. tostring(figure_origin))

      -- Render 2, a genuinely new region (new source, new hash) matches
      -- nothing durable and must be minted fresh.
      local loc_z = { file = "protocol.qmd", start = 60, ["end"] = 66 }
      local new_id, new_origin = ids.reuse({ type = "list", source = loc_z, hash = "H4" }, durable)
      assert(new_origin == "minted", "expected origin minted, got " .. tostring(new_origin))
      assert(new_id:match("^g%-list%-[a-z2-7][a-z2-7][a-z2-7][a-z2-7][a-z2-7][a-z2-7]$"),
        "expected format g-list-<6 base32>, got " .. tostring(new_id))
    end },
  { name = "reuse(): source match wins over a competing hash match on a different region", fn = function()
      -- A candidate whose source location matches one durable region AND
      -- whose content hash matches a DIFFERENT durable region must reuse
      -- the source-matched id: source is checked before hash. If the two
      -- tiers were swapped, this returns the hash-matched id instead, so
      -- the ordering is load-bearing here, not merely incidental as in the
      -- single-tier moved/edited cases above.
      local durable = {
        { id = "g-table-source1", source = { file = "d.qmd", start = 10, ["end"] = 15 }, hash = "HA" },
        { id = "g-table-hash1",   source = { file = "d.qmd", start = 90, ["end"] = 95 }, hash = "HB" },
      }
      local candidate = { type = "table", source = { file = "d.qmd", start = 10, ["end"] = 15 }, hash = "HB" }
      local id, origin = ids.reuse(candidate, durable)
      assert(id == "g-table-source1" and origin == "source",
        "source tier must win over a competing hash match; got "
          .. tostring(id) .. "/" .. tostring(origin))
    end },
  { name = "exhausted char source raises instead of hanging", fn = function()
      -- a finite source shorter than six chars returns "" past its end
      assert(not pcall(ids.generate, "table", {}, charsource("abc")))
    end },
  -- Document-scoped allocation (spec collision rule: an id must be unused
  -- within the DOCUMENT and its durable state). allocator() shares
  -- claimed/assigned sets across claims in one render; reuse() is a
  -- one-shot wrapper over a fresh allocator and cannot see other regions.
  { name = "allocator: two same-hash candidates cannot both claim one durable id", fn = function()
      -- The reproduced defect: one durable entry, two distinct current
      -- regions at different locations with the same content hash. The
      -- first claim reuses the durable id; the second must NOT receive the
      -- same id again -- it mints.
      local durable = {
        { id = "g-paragraph-aaaaaa", source = { file = "d.qmd", start = 1, ["end"] = 2 }, hash = "H" },
      }
      local alloc = ids.allocator(durable, { next_char = charsource("mmmmmm") })
      local id1, o1 = alloc:claim({ type = "paragraph", source = { file = "d.qmd", start = 8, ["end"] = 9 }, hash = "H" })
      local id2, o2 = alloc:claim({ type = "paragraph", source = { file = "d.qmd", start = 20, ["end"] = 21 }, hash = "H" })
      assert(id1 == "g-paragraph-aaaaaa" and o1 == "hash", id1 .. "/" .. o1)
      assert(id2 ~= id1 and o2 == "minted", "second claim must mint, got " .. id2 .. "/" .. o2)
    end },
  { name = "allocator: ambiguous durable hash matches mint rather than pick arbitrarily", fn = function()
      -- Two durable entries share a hash; a single moved candidate matches
      -- both. Identity is not inferable, so the claim mints instead of
      -- selecting either entry.
      local durable = {
        { id = "g-table-first2", source = { file = "d.qmd", start = 1, ["end"] = 2 }, hash = "H" },
        { id = "g-table-second", source = { file = "d.qmd", start = 5, ["end"] = 6 }, hash = "H" },
      }
      local alloc = ids.allocator(durable, { next_char = charsource("nnnnnn") })
      local id, origin = alloc:claim({ type = "table", source = { file = "d.qmd", start = 30, ["end"] = 31 }, hash = "H" })
      assert(origin == "minted", "ambiguous hash match must mint, got " .. id .. "/" .. origin)
    end },
  { name = "allocator: freshly minted ids reserve against one another", fn = function()
      -- The injected source offers "aaaaaa" twice; the second mint must
      -- redraw past the collision with the first mint's id.
      local alloc = ids.allocator({}, { next_char = charsource("aaaaaaaaaaaabbbbbb") })
      local id1 = alloc:claim({ type = "list", hash = "H1" })
      local id2 = alloc:claim({ type = "list", hash = "H2" })
      assert(id1 == "g-list-aaaaaa", id1)
      assert(id2 == "g-list-bbbbbb", "second mint must redraw, got " .. id2)
    end },
  { name = "allocator: duplicate explicit ids in one document raise", fn = function()
      local alloc = ids.allocator({})
      local id = alloc:claim({ explicit_id = "abstract" })
      assert(id == "abstract")
      assert(not pcall(function() alloc:claim({ explicit_id = "abstract" }) end),
        "second claim of the same explicit id must raise")
    end },
}
