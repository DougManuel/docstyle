local mg = require("lib.migrate")
local json = require("lib.json")

-- NOTE on path resolution (deviation from the task-8 brief's literal
-- `local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)`):
--
-- PANDOC_SCRIPT_FILE stays pinned to the *top-level* entry script
-- (tests/vnext/conformance/run.lua) for the lifetime of the process --
-- run.lua's `dofile(here .. "/tests/" .. f)` does not update it to the
-- dofile()'d file. Verified empirically with a standalone run.lua + dofile()
-- harness (see task-8-report.md): a nested script's
-- `pandoc.path.directory(PANDOC_SCRIPT_FILE)` prints run.lua's own
-- directory, not the nested script's directory, both under `quarto run
-- <absolute path>` and `quarto run <relative path>`.
--
-- Using PANDOC_SCRIPT_FILE here would make `here` resolve to
-- tests/vnext/conformance (run.lua's directory) rather than
-- tests/vnext/conformance/tests (this file's own directory), so
-- `join(here, "..", "legacy", "cases")` would land one level too high, on a
-- "legacy" sibling of conformance/ itself, instead of tests/vnext/conformance
-- /legacy/cases as required by the task-8 brief's Files list. Resolving
-- `here` from this chunk's own debug info (which does reflect wherever it
-- was loaded from) makes the `..`-relative join land correctly regardless of
-- how this file is invoked (dofile()'d from run.lua, or run directly).
--
-- The four test cases below are otherwise verbatim from the task-8 brief.
local this_file = debug.getinfo(1, "S").source:match("^@(.*)$")
local here = pandoc.path.directory(this_file)
local cases_dir = pandoc.path.join({ here, "..", "legacy", "cases" })
local cases = {
  { name = "every mapping case produces its expected envelope", fn = function()
      for _, f in ipairs(pandoc.system.list_directory(cases_dir)) do
        local case = json.read(pandoc.path.join({ cases_dir, f }))
        local out = mg.payload(case.legacy)
        local got, want = json.encode(out.envelope), json.encode(case.expected_envelope)
        assert(got == want, f .. ": " .. got)
      end
    end },
  { name = "unknown legacy key is a blocking finding, not a guess", fn = function()
      local out = mg.payload({ version = 2, type = "div", name = "x",
        mystery = "value" })
      local found = false
      for _, fd in ipairs(out.findings) do
        if fd.code == "unmapped-legacy-key" and fd.level == "error" then found = true end
      end
      assert(found, "expected unmapped-legacy-key error finding")
    end },
  { name = "future version is rejected", fn = function()
      local out = mg.payload({ version = 9, type = "div", name = "x" })
      assert(out.envelope == nil and out.findings[1].code == "unsupported-version")
    end },
  { name = "sidecar migration emits schema-valid outputs and a report", fn = function()
      local js = require("lib.jsonschema")
      local res = mg.sidecars({
        field_codes = { citations = { { keys = { "smith2024" },
          instruction = "ADDIN ZOTERO_ITEM CSL_CITATION {}" } },
          zotero_pref = "<data/>" },
        comments = { { author = "A", date = "2026-07-01",
          text = "note", anchor_text = "the abstract" } },
        revisions = { { author = "A", date = "2026-07-01",
          type = "insert", text = "added" } } })
      local base = "https://dougmanuel.github.io/docstyle/schemas/"
      assert(js.validate(js.resolve(base .. "state-citations.v1.json"), res.citations))
      assert(js.validate(js.resolve(base .. "state-annotations.v1.json"), res.annotations))
      assert(js.validate(js.resolve(base .. "report-envelope.v1.json"), res.report))
      assert(res.report.result ~= "FAIL")
    end },
  -- Real-shape sidecars: comments.json/revisions.json are id-keyed JSON
  -- OBJECTS whose entries carry "content" (R/comments.R:87-92,169;
  -- R/revisions.R:61-66,144), and field-codes.json's citation data is an
  -- object-of-groups carrying "citekeys"/"instrText"
  -- (R/extract_citations.R:306-312) -- not the {keys, instruction} array
  -- the case above uses. This case feeds those real shapes straight through
  -- (no field renaming by the caller) and checks migrate.sidecars performs
  -- the container normalization and content->text / citekeys->keys /
  -- instrText->instruction renames itself.
  { name = "real-shape sidecars (object-keyed, content/citekeys/instrText) migrate and validate", fn = function()
      local js = require("lib.jsonschema")
      local res = mg.sidecars({
        field_codes = {
          citationGroups = {
            grp_abc123 = { citationID = "abc123",
              instrText = "ADDIN ZOTERO_ITEM CSL_CITATION {\"citationItems\":[]}",
              citekeys = { "jones2020" } },
          },
          zotero_pref = "<data/>",
        },
        comments = {
          ["0"] = { id = "0", author = "R", date = "2026-07-02",
            content = "please clarify", initials = "R",
            para_id = "00AA11BB", done = false },
          ["1"] = { id = "1", author = "S", date = "2026-07-03",
            content = "looks good", initials = "S",
            para_id = "00AA22CC", done = true },
        },
        revisions = {
          rev_12 = { id = "rev_12", type = "insertion", author = "R",
            date = "2026-07-02", content = "new text", initials = "R" },
          rev_del_3 = { id = "rev_del_3", type = "deletion", author = "S",
            date = "2026-07-03", content = "old text", initials = "S" },
        },
      })
      local base = "https://dougmanuel.github.io/docstyle/schemas/"
      local cit_ok, cit_err = js.validate(js.resolve(base .. "state-citations.v1.json"), res.citations)
      assert(cit_ok, cit_err and cit_err[1] and (cit_err[1].path .. " " .. cit_err[1].message))
      local ann_ok, ann_err = js.validate(js.resolve(base .. "state-annotations.v1.json"), res.annotations)
      assert(ann_ok, ann_err and ann_err[1] and (ann_err[1].path .. " " .. ann_err[1].message))

      -- every entry preserved: assert counts...
      assert(#res.citations.citations == 1, "expected 1 migrated citation group")
      assert(#res.annotations.comments == 2, "expected 2 migrated comments")
      assert(#res.annotations.revisions == 2, "expected 2 migrated revisions")

      -- ...and one field value per type, proving the real-shape key
      -- renames actually ran (citekeys->keys, instrText->instruction,
      -- content->text) rather than silently producing empty/nil fields.
      assert(res.citations.citations[1].keys[1] == "jones2020")
      assert(res.citations.citations[1].instruction:match("^ADDIN ZOTERO_ITEM"))
      local comment_texts = {}
      for _, c in ipairs(res.annotations.comments) do comment_texts[c.text] = true end
      assert(comment_texts["please clarify"] and comment_texts["looks good"])
      local revision_texts, revision_ops = {}, {}
      for _, r in ipairs(res.annotations.revisions) do
        revision_texts[r.text] = true
        revision_ops[r.op] = true
      end
      assert(revision_texts["new text"] and revision_texts["old text"])
      assert(revision_ops.insert and revision_ops.delete)
    end },
  { name = "unknown payload type yields nil envelope and an error finding", fn = function()
      local out = mg.payload({ version = 2, type = "bogus-payload-type" })
      assert(out.envelope == nil, "expected nil envelope for unknown payload type")
      local found = false
      for _, fd in ipairs(out.findings) do
        if fd.code == "unknown-payload-type" and fd.level == "error" then found = true end
      end
      assert(found, "expected unknown-payload-type error finding")
    end },
}
return cases
