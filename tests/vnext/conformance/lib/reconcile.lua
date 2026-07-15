-- tests/vnext/conformance/lib/reconcile.lua
-- Executable decision table for the WP1 spec's "Authority and
-- reconciliation" section (docs/superpowers/specs/2026-07-14-docstyle
-- -vnext-wp1-schemas-state-design.md): the six-row authority table plus
-- reconciliation rules 1-6. Declared bound 4 previously read acceptance
-- test 8 as "WP5 executes these rules, WP1 only verifies their data
-- preconditions"; this module makes the rules themselves executable, so
-- WP5 can call reconcile.decide() rather than re-deriving the routing
-- logic from the spec prose each time.
--
-- reconcile.decide(entry) -> { outcome, blocking, warning? }
--
-- entry fields:
--   authority   "authored" | "generated" | "structural"
--               | "external-managed" | "annotation" | "metadata"
--   present     { source=bool, field=bool, catalogue=bool, state=bool }
--   hashes_agree            bool | nil  -- nil: not compared / not applicable
--   kinds_agree             bool | nil  -- same id's kind/role across reps
--   representation_missing  "cache" | "durable-state" | nil
--   profile_available       bool | nil  -- see note below; metadata rows only
--
-- `profile_available` is not part of the literal entry shape named in the
-- task brief (authority/present/hashes_agree/kinds_agree/
-- representation_missing); it is added here because the spec's
-- unavailable-profile case ("activation of an unavailable profile is a
-- validation failure, while profile-typed data for an inactive profile is
-- preserved as opaque data with a warning") is a distinct axis -- whether
-- the record's declared profile is registered -- that none of the other
-- fields can express. It is only read when authority == "metadata" and is
-- nil/absent for every other row.
--
-- outcome is one of: agree, propose-patch, ignore-display-edit,
-- reconcile-structural, preserve-external, conflict, regenerate-cache,
-- cold-reconstruct, preserve-opaque.
--
-- blocking is always exactly (outcome == "conflict"): rule 6 ("Blocking
-- conflicts fail closed: no QMD patch is applied and no durable state is
-- overwritten until a person resolves them") is enforced structurally by
-- that equivalence, through the single `finish()` exit point, rather than
-- by a separate branch that could drift out of sync with the outcome.

local M = {}

local function finish(outcome, warning)
  return { outcome = outcome, blocking = (outcome == "conflict"), warning = warning }
end

-- Rule 2's ("Route by authority row above") and rule 3's ("additions and
-- deletions follow the same authority routing") shared lookup: what a
-- genuine disagreement resolves to for each non-annotation authority,
-- mirroring the spec's "On disagreement" column verbatim:
--   authored          -> a returned DOCX difference becomes a proposed
--                        patch; it is never applied silently
--   generated         -> display edits are ignored unless the field type
--                        declares reverse editing (no such flag on this
--                        entry shape, so the default is to ignore)
--   structural        -> recovered structure is reconciled; unsupported
--                        edits are reported, not discarded silently
--   external-managed  -> preserve exact field data; reconcile through the
--                        owner's adapter
--   metadata          -> embedded catalogue and state are synchronized
--                        views; contradiction is a conflict
local DISAGREEMENT_OUTCOME = {
  authored = "propose-patch",
  generated = "ignore-display-edit",
  structural = "reconcile-structural",
  ["external-managed"] = "preserve-external",
  metadata = "conflict",
}

-- Rule 3: "Identifier present in one representation and absent in
-- another." True when `present`'s booleans are not all the same value.
local function presence_mismatch(present)
  if present == nil then return false end
  local seen_true, seen_false = false, false
  for _, v in pairs(present) do
    if v then seen_true = true else seen_false = true end
  end
  return seen_true and seen_false
end

function M.decide(entry)
  entry = entry or {}

  -- Unavailable-profile case (metadata-profile mechanism section): preserved
  -- as opaque data with a warning, never a conflict -- checked first because
  -- it is a distinct axis from the four disagreement signals below.
  if entry.authority == "metadata" and entry.profile_available == false then
    return finish("preserve-opaque",
      "profile-typed metadata record references a profile that is not " ..
      "active/available; preserved as opaque data rather than validated")
  end

  -- Rule 4: same identifier, different kind or role -- a blocking conflict
  -- regardless of authority. Checked before hash/presence so a kind clash
  -- can't be masked by, say, a coincidentally matching hash.
  if entry.kinds_agree == false then
    return finish("conflict")
  end

  -- Rule 5: missing representations are rebuilt, never a conflict.
  if entry.representation_missing == "cache" then
    return finish("regenerate-cache")
  end
  if entry.representation_missing == "durable-state" then
    return finish("cold-reconstruct")
  end

  -- Comments and revisions are captured fresh from the returned DOCX on
  -- every return ("Normalized into annotation state with stable anchors");
  -- there is no second representation for them to disagree with, so they
  -- always resolve to agreement rather than routing through rule 2 or 3.
  if entry.authority == "annotation" then
    return finish("agree")
  end

  -- Rule 3: identifier present in one representation, absent in another.
  if presence_mismatch(entry.present) then
    if entry.authority == "authored" then
      -- "an unexplained loss of authored content is a blocking conflict" --
      -- this entry shape carries no signal that a deletion was intentional,
      -- so every authored presence mismatch is treated as unexplained.
      return finish("conflict")
    end
    return finish(DISAGREEMENT_OUTCOME[entry.authority] or "conflict")
  end

  -- Rule 2: matching identifier, differing hash -- route by authority row.
  if entry.hashes_agree == false then
    return finish(DISAGREEMENT_OUTCOME[entry.authority] or "conflict")
  end

  -- Rule 1: matching identifier and matching hash (or nothing disagreed).
  return finish("agree")
end

return M
