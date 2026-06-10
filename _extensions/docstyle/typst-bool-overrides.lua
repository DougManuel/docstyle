-- typst-bool-overrides.lua — sentinel emission for boolean YAML keys
--
-- Pandoc template syntax `$if(x)$` cannot distinguish "x is unset" from
-- "x is explicitly false". For boolean keys whose template branch falls
-- through to an `$elseif(flag)$` default (e.g., `medrxiv`), a user's
-- explicit `false` is silently ignored and the flag default fires.
-- See #140 for the analysis.
--
-- This filter inspects the AST-level metadata, where the user's intent
-- is preserved as a real Lua boolean, and emits a sentinel
-- `<key>-explicit-false: true` for any affected key the user has set
-- to false. Templates consult the sentinel ahead of the elseif branch.
--
-- Active for the `typst` writer only; returns nil for other formats.

local AFFECTED_BOOLEAN_KEYS = { "line-number" }

-- A YAML `false` reaches this filter in one of two representations,
-- depending on the stack: bare `pandoc` surfaces it as a MetaBool tagged
-- table (`{t="MetaBool", c=false}`), while Quarto's metadata-normalization
-- layer hands the filter a raw Lua boolean. Both branches below are
-- load-bearing — each is the live path on one of the two stacks — so
-- neither can be removed. (Verified empirically against pandoc 3.1.2 and
-- Quarto; see tests/testthat/test-medrxiv-flag.R.)
local function is_explicit_false(value)
  if value == nil then return false end
  if type(value) == "boolean" then return value == false end
  if type(value) == "table" and value.t == "MetaBool" then
    return value.c == false
  end
  return false
end

function Meta(meta)
  if FORMAT ~= "typst" then return nil end
  for _, key in ipairs(AFFECTED_BOOLEAN_KEYS) do
    if is_explicit_false(meta[key]) then
      meta[key .. "-explicit-false"] = true
    end
  end
  return meta
end
