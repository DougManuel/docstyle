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
  { name = "exhausted char source raises instead of hanging", fn = function()
      -- a finite source shorter than six chars returns "" past its end
      assert(not pcall(ids.generate, "table", {}, charsource("abc")))
    end },
}
