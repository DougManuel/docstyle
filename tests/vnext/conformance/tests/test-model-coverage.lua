local json = require("lib.json")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local p = pandoc.path.join({ here, "..", "..", "..",
  "schemas", "examples", "document-model.v1", "valid-full-coverage.json" })
local ALL_TYPES = { "section", "heading", "paragraph", "list", "list-item",
  "table", "table-row", "table-cell", "figure", "caption", "equation",
  "code-block", "footnote", "citation", "span", "raw", "anchor" }
local ALL_POLICIES = { "authored-preserve", "generated-replace",
  "structural", "external-managed" }
local function walk(node, seen_t, seen_p, seen_g, seen_e)
  seen_t[node.type] = true; seen_p[node.policy] = true
  if node.id:match("^g%-") then seen_g.yes = true else seen_e.yes = true end
  for _, c in ipairs(node.children or {}) do walk(c, seen_t, seen_p, seen_g, seen_e) end
end
return {
  { name = "example exercises every node type, policy and both id forms", fn = function()
      local m = json.read(p)
      local t, pol, g, e = {}, {}, {}, {}
      for _, n in ipairs(m.content) do walk(n, t, pol, g, e) end
      for _, ty in ipairs(ALL_TYPES) do assert(t[ty], "missing node type " .. ty) end
      for _, po in ipairs(ALL_POLICIES) do assert(pol[po], "missing policy " .. po) end
      assert(g.yes and e.yes, "need both generated and explicit identifiers")
      assert(m.registries.metadata and m.registries.profiles
        and m.registries.relationships and m.registries.assets, "missing registry")
    end },
}
