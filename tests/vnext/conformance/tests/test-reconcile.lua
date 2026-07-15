local reconcile = require("lib.reconcile")

-- Table-driven cases for reconcile.decide(), covering all six reconciliation
-- rules from docs/superpowers/specs/2026-07-14-docstyle-vnext-wp1-schemas
-- -state-design.md ("Authority and reconciliation"), including every
-- blocking case and the unavailable-profile row. Each row names the rule it
-- exercises; the loop below turns the table itself into one named case per
-- row, so a failure points straight at the disagreement class that broke.
local ROWS = {
  { rule = "1", name = "authored, matching id and hash -> agree",
    entry = { authority = "authored",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = true },
    outcome = "agree", blocking = false },
  { rule = "1", name = "metadata, matching id and hash -> agree",
    entry = { authority = "metadata",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = true, kinds_agree = true },
    outcome = "agree", blocking = false },

  { rule = "2", name = "authored, differing hash -> proposed patch, never applied silently",
    entry = { authority = "authored",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = false },
    outcome = "propose-patch", blocking = false },
  { rule = "2", name = "generated, differing hash -> display edit ignored",
    entry = { authority = "generated",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = false },
    outcome = "ignore-display-edit", blocking = false },
  { rule = "2", name = "structural, differing hash -> reconciled, reported not discarded",
    entry = { authority = "structural",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = false },
    outcome = "reconcile-structural", blocking = false },
  { rule = "2", name = "external-managed, differing hash -> preserved, owner adapter reconciles",
    entry = { authority = "external-managed",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = false },
    outcome = "preserve-external", blocking = false },
  { rule = "2", name = "metadata, differing hash -> contradiction is a conflict (blocking)",
    entry = { authority = "metadata",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = false },
    outcome = "conflict", blocking = true },

  { rule = "3", name = "authored, present in source but absent from state -> unexplained loss (blocking)",
    entry = { authority = "authored",
      present = { source = true, field = true, catalogue = true, state = false } },
    outcome = "conflict", blocking = true },
  { rule = "3", name = "generated, presence mismatch -> same routing as rule 2 (non-blocking)",
    entry = { authority = "generated",
      present = { source = true, field = true, catalogue = false, state = true } },
    outcome = "ignore-display-edit", blocking = false },

  { rule = "4", name = "same id, different kind/role across representations -> conflict (blocking)",
    entry = { authority = "structural",
      present = { source = true, field = true, catalogue = true, state = true },
      hashes_agree = true, kinds_agree = false },
    outcome = "conflict", blocking = true },

  { rule = "5", name = "missing cache -> regenerated, not a conflict",
    entry = { authority = "structural", representation_missing = "cache" },
    outcome = "regenerate-cache", blocking = false },
  { rule = "5", name = "missing durable state -> cold reconstruction from the DOCX, not a conflict",
    entry = { authority = "authored", representation_missing = "durable-state" },
    outcome = "cold-reconstruct", blocking = false },

  { rule = "comments-and-revisions authority row", name = "annotation authority always normalizes fresh -> agree",
    entry = { authority = "annotation",
      present = { source = false, field = false, catalogue = false, state = true },
      hashes_agree = false },
    outcome = "agree", blocking = false },

  { rule = "profile mechanism", name = "metadata record with unavailable profile -> preserve-opaque with a warning",
    entry = { authority = "metadata",
      present = { source = true, field = false, catalogue = false, state = true },
      profile_available = false },
    outcome = "preserve-opaque", blocking = false, expect_warning = true },
}

local cases = {}
for _, row in ipairs(ROWS) do
  cases[#cases + 1] = { name = "rule " .. row.rule .. ": " .. row.name, fn = function()
    local result = reconcile.decide(row.entry)
    assert(result.outcome == row.outcome,
      "expected outcome " .. row.outcome .. ", got " .. tostring(result.outcome))
    assert(result.blocking == row.blocking,
      "expected blocking=" .. tostring(row.blocking) .. ", got " .. tostring(result.blocking))
    if row.expect_warning then
      assert(type(result.warning) == "string" and #result.warning > 0,
        "expected a reported warning for " .. row.name)
    end
  end }
end

-- Rule 6, fail-closed invariant: every "conflict" outcome above is blocking,
-- and nothing else is -- checked once, structurally, across every row
-- already defined, rather than as its own hand-picked entry.
cases[#cases + 1] = { name = "rule 6: blocking is exactly the conflict outcomes (fail closed)", fn = function()
  for _, row in ipairs(ROWS) do
    local result = reconcile.decide(row.entry)
    assert((result.outcome == "conflict") == result.blocking,
      row.name .. ": blocking must equal (outcome == 'conflict')")
  end
end }

-- Authority guard: an unrecognized authority string (e.g. a typo like
-- "strucural") must raise immediately rather than silently falling through
-- the routing logic to whatever outcome the missing branches happen to
-- produce (previously: a coincidental "conflict", indistinguishable from a
-- genuine blocking disagreement).
cases[#cases + 1] = { name = "authority guard: unrecognized authority raises rather than silently routing", fn = function()
  local okflag = pcall(reconcile.decide, { authority = "bogus-authority" })
  assert(not okflag, "expected reconcile.decide to raise for an unrecognized authority")
  local okflag2 = pcall(reconcile.decide, {})
  assert(not okflag2, "expected reconcile.decide to raise when authority is absent entirely")
end }

return cases
