-- jats-fixups.lua — JATS-only post-processing for docstyle
--
-- Runs only when the output format is JATS. Returns nil for all other
-- formats so it has zero effect on Word, Typst, HTML, etc. — matching
-- the established docstyle filter pattern.
--
-- Two transformations:
--
-- 1. Structured abstract. Pandoc emits abstract paragraphs that start
--    with a bold label (e.g. "**Background:** ...") as a single <p>
--    with <bold>Background:</bold> ... — flat structure. JATS consumers
--    (PMC, scite) parse the structured form (<sec><title>Background
--    </title><p>...</p></sec>) more reliably. We rewrite the abstract
--    Meta block so each labelled paragraph becomes a Div-wrapped
--    Header+Para pair, which Pandoc's JATS writer then emits as a
--    proper <sec> with nested <title> and <p>.
--
-- 2. CRediT term canonicalization. CRediT canonical terms use en-dashes
--    (Writing – original draft). Authors often type hyphens
--    (writing - original draft). Pandoc's JATS writer adds the
--    vocab-term-identifier URI only when the term matches canonically.
--    We rewrite non-canonical role strings to the canonical spelling
--    so the writer attaches the URI.

local KNOWN_JATS_FORMATS = {
  jats = true,
  jats_archiving = true,
  jats_publishing = true,
  jats_articleauthoring = true
}

if not KNOWN_JATS_FORMATS[FORMAT] then
  -- Warn if FORMAT looks JATS-ish but doesn't match. A future Quarto
  -- adding a new JATS variant would otherwise silently regress
  -- structured abstracts and CRediT URIs — exactly the failure mode
  -- this filter exists to prevent. Constitution principle 7
  -- (epistemic honesty: say what you do not know).
  if type(FORMAT) == "string" and FORMAT:match("jats") then
    io.stderr:write("[jats-fixups] Unrecognized JATS variant: '"
                    .. FORMAT .. "'. Fixups skipped. "
                    .. "Add to KNOWN_JATS_FORMATS in jats-fixups.lua.\n")
  end
  return {}
end

-- ── CRediT canonical term list ───────────────────────────────────────────
-- From https://credit.niso.org/. Lookup yields the URI slug used for
-- vocab-term-identifier construction. Canonical spelling uses en-dash
-- (U+2013) where Writing terms include a dash; canonical display is
-- lowercased to match Quarto's emission convention.

local CREDIT_BASE_URI = "https://credit.niso.org"
local CREDIT_TERM_BASE = CREDIT_BASE_URI .. "/contributor-roles/"

-- Map canonical-display → slug. Slug is the path segment in the URI.
local credit_terms_to_slug = {
  ["conceptualization"]        = "conceptualization",
  ["data curation"]            = "data-curation",
  ["formal analysis"]          = "formal-analysis",
  ["funding acquisition"]      = "funding-acquisition",
  ["investigation"]            = "investigation",
  ["methodology"]              = "methodology",
  ["project administration"]   = "project-administration",
  ["resources"]                = "resources",
  ["software"]                 = "software",
  ["supervision"]              = "supervision",
  ["validation"]               = "validation",
  ["visualization"]            = "visualization",
  ["writing – original draft"] = "writing-original-draft",
  ["writing – review & editing"] = "writing-review-editing"
}

-- Lookup keyed by a normalized form (lowercased, all dashes folded to
-- '-') so input variants find their canonical match.
local function normalize_for_match(s)
  if type(s) ~= "string" then return "" end
  s = s:lower()
  s = s:gsub("\xe2\x80\x93", "-")  -- en-dash U+2013 → '-'
  s = s:gsub("\xe2\x80\x94", "-")  -- em-dash U+2014 → '-'
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- Build lookup keyed by normalized form (lowercase, dash-folded) so
-- input variants like "writing - original draft" find their canonical
-- display "writing – original draft" and the URI slug.
local credit_lookup = {}
for canonical, slug in pairs(credit_terms_to_slug) do
  credit_lookup[normalize_for_match(canonical)] = {
    canonical = canonical,
    slug = slug
  }
end

-- Look up a role string. Returns {canonical, slug} or nil if not a
-- known CRediT term.
local function credit_lookup_match(s)
  if type(s) ~= "string" then return nil end
  return credit_lookup[normalize_for_match(s)]
end

-- Build a CRediT role MetaMap with all four fields populated.
-- Quarto's normalized author roles are MetaMaps with role/vocab-term/
-- vocab-identifier/vocab-term-identifier. Pandoc's JATS writer drops
-- the URI attributes from the emitted <role> element if any of these
-- four fields is missing, so we always populate all four.
local function build_credit_role_metamap(canonical, slug)
  return {
    ["role"] = pandoc.MetaString(canonical),
    ["vocab-term"] = pandoc.MetaString(canonical),
    ["vocab-identifier"] = pandoc.MetaString(CREDIT_BASE_URI),
    ["vocab-term-identifier"] = pandoc.MetaString(
      CREDIT_TERM_BASE .. slug .. "/")
  }
end


-- ── Abstract restructuring ───────────────────────────────────────────────

-- Detect a paragraph that starts with a bolded section label like
-- "Background:". The detection is deliberately strict to avoid
-- over-matching prose paragraphs that happen to start with a bold word
-- followed by a colon (e.g. "**emphasis:** the introduction begins...").
-- Heuristics: the label must be a short prefix (at most 4 words), must
-- end with ':' inside the Strong (not in following inlines), and the
-- paragraph must have content beyond the label so we're not promoting
-- a one-bold-line paragraph into an empty section.
local MAX_LABEL_WORDS = 4

local function extract_abstract_label(para)
  if not para or para.t ~= "Para" then return nil end
  local content = para.content
  if not content or #content == 0 then return nil end

  local first = content[1]
  if first.t ~= "Strong" then return nil end

  local bold_text = pandoc.utils.stringify(first)
  if not bold_text:match(":%s*$") then return nil end

  local label = bold_text:gsub(":%s*$", "")
  if #label == 0 then return nil end

  -- Reject long labels — they're prose, not section markers.
  local word_count = 0
  for _ in label:gmatch("%S+") do word_count = word_count + 1 end
  if word_count > MAX_LABEL_WORDS then return nil end

  -- Drop the bold label (and a leading Space immediately after it).
  local remaining = {}
  for i = 2, #content do
    local inline = content[i]
    if i == 2 and inline.t == "Space" then
      -- skip
    else
      table.insert(remaining, inline)
    end
  end

  -- Require non-empty remaining content so a paragraph that's just
  -- "**Background:**" doesn't become a section with no body.
  if #remaining == 0 then return nil end

  return label, remaining
end

-- Convert each labelled Para to a Div wrapping Header + Para. The Div
-- wrapper is necessary because, without it, Pandoc's JATS writer
-- creates an empty <sec> for the Header and emits the following Para
-- as a sibling of the section rather than nested inside.
-- Use plain Lua tables and Pandoc constructors that accept them
-- (pandoc.Header, pandoc.Para, pandoc.Div, pandoc.Inlines-via-list).
-- The pandoc.Inlines{...} / pandoc.List{...} constructors are
-- Pandoc 2.17+ — older Quarto bundles can throw "attempt to call a nil
-- value" on those forms. Plain tables work on all supported versions
-- because Pandoc's element constructors coerce them.
local function restructure_abstract_blocks(blocks)
  if not blocks then return blocks end
  local out = {}
  for _, block in ipairs(blocks) do
    local label, remaining = extract_abstract_label(block)
    if label then
      local sec_blocks = {
        pandoc.Header(4, {pandoc.Str(label)})
      }
      if #remaining > 0 then
        table.insert(sec_blocks, pandoc.Para(remaining))
      end
      table.insert(out,
        pandoc.Div(sec_blocks, pandoc.Attr("", {"section"}, {})))
    else
      table.insert(out, block)
    end
  end
  return out
end


-- ── Meta filter ─────────────────────────────────────────────────────────

-- Track unrecognized CRediT terms so we don't spam stderr if the same
-- role appears on multiple authors. Reset per render via the local.
local warned_credit_terms = {}

function Meta(meta)
  -- Abstract restructuring. meta.abstract is MetaBlocks when written
  -- as `abstract: |` in YAML. Wrap the result in pandoc.MetaBlocks so
  -- the assignment round-trips through Pandoc's metadata coercion
  -- without nesting MetaList(MetaBlocks(...)) — that nested form is
  -- accepted on some Pandoc versions and silently ignored on others.
  if meta.abstract then
    local blocks = meta.abstract
    if type(blocks) == "table" and #blocks > 0 then
      meta.abstract = pandoc.MetaBlocks(restructure_abstract_blocks(blocks))
    end
  end

  -- CRediT role canonicalization. Quarto pre-processes recognized
  -- CRediT terms into a MetaMap with four fields (role, vocab-term,
  -- vocab-identifier, vocab-term-identifier). For unrecognized roles
  -- (typed with the wrong dash, capitalization, etc.) only the
  -- `role` field is populated, and the JATS writer emits an
  -- un-enriched <role>...</role> with no URI.
  --
  -- We detect roles missing `vocab-term-identifier`, look them up
  -- against the canonical CRediT vocabulary, and rebuild the full
  -- MetaMap. Update both `meta.authors` (Quarto) and `meta.by-author`
  -- (Pandoc's normalized form that the JATS writer actually reads).
  for _, key in ipairs({"authors", "by-author"}) do
    local authors = meta[key]
    if type(authors) == "table" then
      for _, author in ipairs(authors) do
        if type(author) == "table" and author.roles then
          local roles = author.roles
          if type(roles) == "table" then
            for i, role in ipairs(roles) do
              -- Only fix up roles that don't already have a URI.
              if type(role) ~= "table" or
                 not role["vocab-term-identifier"] then
                local s = pandoc.utils.stringify(role)
                local match = credit_lookup_match(s)
                if match then
                  roles[i] = build_credit_role_metamap(
                    match.canonical, match.slug)
                elseif s ~= "" and not warned_credit_terms[s] then
                  -- Unknown role string. Emit a one-time warning so
                  -- typos surface during render rather than at PMC
                  -- ingest time. We dedupe per-string so multiple
                  -- authors with the same typo don't spam stderr.
                  warned_credit_terms[s] = true
                  io.stderr:write("[jats-fixups] Unrecognized CRediT "
                    .. "role '" .. s .. "'. Emitted as <role> without "
                    .. "vocab URI. Check spelling against "
                    .. "https://credit.niso.org/.\n")
                end
              end
            end
          end
        end
      end
    end
  end

  return meta
end
