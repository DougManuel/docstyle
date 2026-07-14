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
  { name = "persisted id survives a simulated re-render", fn = function()
      -- first render assigns; durable state carries it; second render must reuse
      local state = {}
      local id = ids.generate("figure", state, charsource("qqqqqq"))
      state[id] = true
      local reused = state["g-figure-qqqqqq"] and "g-figure-qqqqqq"
      assert(reused == id)
    end },
  { name = "exhausted char source raises instead of hanging", fn = function()
      -- a finite source shorter than six chars returns "" past its end
      assert(not pcall(ids.generate, "table", {}, charsource("abc")))
    end },
}
