local mg = require("lib.migrate")
local json = require("lib.json")

-- NOTE on path resolution (deviation from the task-8 brief's literal
-- `local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)`):
--
-- PANDOC_SCRIPT_FILE stays pinned to the *top-level* entry script
-- (tests/vnext/conformance/run.lua) for the lifetime of the process --
-- run.lua's `dofile(here .. "/tests/" .. f)` does not update it to the
-- dofile()'d file. Verified empirically with a standalone run.lua + dofile()
-- harness: a nested script's `pandoc.path.directory(PANDOC_SCRIPT_FILE)`
-- prints run.lua's own directory, not the nested script's directory, both
-- under `quarto run <absolute path>` and `quarto run <relative path>`.
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
-- The first four cases below (mapping-fixture coverage, unmapped-key,
-- future-version, and the synthetic-shape sidecar case) are verbatim from
-- the task-8 brief; every case after that was added in later review waves
-- (real-shape sidecars, unknown-payload-type, malformed input, marker-
-- preserving ids, determinism, dropped-key coverage, provisional-envelope
-- validation) and is not part of that original brief.
local this_file = debug.getinfo(1, "S").source:match("^@(.*)$")
local here = pandoc.path.directory(this_file)
local cases_dir = pandoc.path.join({ here, "..", "legacy", "cases" })
local cases = {
  { name = "every mapping case produces its expected envelope (provisional; hash unresolved)", fn = function()
      for _, f in ipairs(pandoc.system.list_directory(cases_dir)) do
        local case = json.read(pandoc.path.join({ cases_dir, f }))
        local out = mg.payload(case.legacy)
        local got, want = json.encode(out.envelope), json.encode(case.expected_envelope)
        assert(got == want, f .. ": " .. got)
        -- Wave 4 item 1: the envelope's hash is explicitly unresolved
        -- (pandoc.json.null, never a fake sha256:-shaped value), and the
        -- whole mapping is provisional -- both must hold for every fixture
        -- case, not just one hand-picked example.
        assert(out.provisional == true, f .. ": expected out.provisional == true")
        local found = false
        for _, fd in ipairs(out.findings) do
          if fd.code == "hash-unresolved" and fd.level == "warning" then found = true end
        end
        assert(found, f .. ": expected a hash-unresolved warning finding")
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
      assert(out.envelope == nil and out.findings[1].code == "unsupported-version"
        and out.provisional == true)
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
      -- These schemas must already be registered by the time this case
      -- runs -- run.lua registers schemas BEFORE the module self-test loop
      -- precisely so js.resolve() here sees a populated registry. Without
      -- that ordering, resolve() would return nil and js.validate(nil, ...)
      -- would either vacuously pass (pre-item-2 semantics) or raise
      -- (post-item-2 semantics); either way this assert catches a
      -- regression in the runner's ordering directly, rather than via a
      -- confusing downstream symptom.
      assert(js.resolve(base .. "state-citations.v1.json") ~= nil, "state-citations.v1 not registered -- runner ordering regression?")
      assert(js.resolve(base .. "state-annotations.v1.json") ~= nil, "state-annotations.v1 not registered -- runner ordering regression?")
      assert(js.resolve(base .. "report-envelope.v1.json") ~= nil, "report-envelope.v1 not registered -- runner ordering regression?")
      assert(js.validate(js.resolve(base .. "state-citations.v1.json"), res.citations))
      assert(js.validate(js.resolve(base .. "state-annotations.v1.json"), res.annotations))
      assert(js.validate(js.resolve(base .. "report-envelope.v1.json"), res.report))
      assert(res.report.result ~= "FAIL")
      -- Plain-array inputs keep their synthesized ids (Wave 4 item 4:
      -- marker-preserving ids only apply to object-keyed input).
      assert(res.annotations.comments[1].id == "c1", "plain-array comment input must keep synthesized id c1")
      assert(res.annotations.revisions[1].id == "r1", "plain-array revision input must keep synthesized id r1")
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
      -- See the resolve()-non-nil note in the previous case: this pins the
      -- runner-ordering precondition down for this case's own two ids too.
      assert(js.resolve(base .. "state-citations.v1.json") ~= nil, "state-citations.v1 not registered -- runner ordering regression?")
      assert(js.resolve(base .. "state-annotations.v1.json") ~= nil, "state-annotations.v1 not registered -- runner ordering regression?")
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

      -- Marker-preserving ids (Wave 4 item 4): object-keyed input carries
      -- its original key ("0", "1", "rev_12", "rev_del_3") into the
      -- migrated id instead of synthesizing c1/c2/r1/r2.
      local comment_ids = {}
      for _, c in ipairs(res.annotations.comments) do comment_ids[c.id] = true end
      assert(comment_ids["0"] and comment_ids["1"],
        "expected comment ids to be the original object-keyed markers '0'/'1', not synthesized c1/c2")
      local revision_ids = {}
      for _, r in ipairs(res.annotations.revisions) do revision_ids[r.id] = true end
      assert(revision_ids["rev_12"] and revision_ids["rev_del_3"],
        "expected revision ids to be the original object-keyed markers, not synthesized r1/r2")
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
  -- Wave 4 item 3 (migrate.payload malformed-input guards): a non-table
  -- legacy value or a non-numeric "version" must produce a finding, not a
  -- Lua runtime error from indexing a non-table or comparing a
  -- string/table against 1/3.
  { name = "malformed legacy payload input (non-table, non-numeric version) yields a finding, not a crash", fn = function()
      local out_nil = mg.payload(nil)
      assert(out_nil.envelope == nil, "expected nil envelope for nil legacy input")
      local found_nil = false
      for _, fd in ipairs(out_nil.findings) do
        if fd.code == "invalid-legacy-payload" and fd.level == "error" then found_nil = true end
      end
      assert(found_nil, "expected invalid-legacy-payload error finding for nil input")

      local out_str = mg.payload("not-a-table")
      assert(out_str.envelope == nil, "expected nil envelope for a string legacy input")
      local found_str = false
      for _, fd in ipairs(out_str.findings) do
        if fd.code == "invalid-legacy-payload" and fd.level == "error" then found_str = true end
      end
      assert(found_str, "expected invalid-legacy-payload error finding for a string input")

      local out_ver = mg.payload({ type = "div", name = "x", version = "three" })
      assert(out_ver.envelope == nil, "expected nil envelope for a non-numeric version")
      local found_ver = false
      for _, fd in ipairs(out_ver.findings) do
        if fd.code == "non-numeric-version" and fd.level == "error" then found_ver = true end
      end
      assert(found_ver, "expected non-numeric-version error finding")
    end },
  -- Wave 4 item 3 (migrate.sidecars malformed-input guard) + item 7
  -- (result="FAIL" reachability): a citation group with no usable
  -- keys/citekeys (missing entirely, or present but empty) must be
  -- skipped with a blocking finding rather than crashing on `keys[1]`,
  -- and enough of those blocking findings must make result="FAIL"
  -- reachable -- before this wave, migrate.sidecars's only findings were
  -- warning-level (anchor-unresolved), so FAIL was dead code.
  { name = "sidecars: malformed citation group (missing/empty keys) is skipped with an error finding, making result=FAIL reachable", fn = function()
      local res = mg.sidecars({
        field_codes = {
          citationGroups = {
            grp_missing = { instrText = "ADDIN ZOTERO_ITEM CSL_CITATION {}" }, -- no keys/citekeys at all
            grp_empty = { citekeys = {}, instrText = "ADDIN ZOTERO_ITEM CSL_CITATION {}" }, -- empty keys array
          },
        },
      })
      assert(#res.citations.citations == 0, "both malformed citation groups must be skipped, not migrated")
      local count = 0
      for _, fd in ipairs(res.report.findings) do
        if fd.code == "malformed-citation-group" and fd.level == "error" then count = count + 1 end
      end
      assert(count == 2, "expected 2 malformed-citation-group error findings, got " .. count)
      assert(res.report.result == "FAIL",
        "expected result=FAIL when a blocking finding is present, got " .. tostring(res.report.result))
    end },
  -- Wave 4 item 5 (determinism): migrate.sidecars must produce
  -- byte-identical output across repeated calls on the same object-keyed
  -- input -- the sorted-iteration contract that set-membership assertions
  -- (like the real-shape case above) cannot, by construction, detect,
  -- since they check "is this value present anywhere" rather than "is the
  -- output identical run to run". Building the input twice from separate
  -- table literals (rather than reusing one table reference) exercises
  -- the sort rather than relying on one Lua table's internal iteration
  -- order happening to repeat within a single process.
  { name = "sidecars: object-keyed input migrates deterministically across repeated runs", fn = function()
      local function build_input()
        return {
          field_codes = {
            citationGroups = {
              grp_b = { citationID = "b", instrText = "ADDIN ZOTERO_ITEM CSL_CITATION {}", citekeys = { "young2021" } },
              grp_a = { citationID = "a", instrText = "ADDIN ZOTERO_ITEM CSL_CITATION {}", citekeys = { "adams2019" } },
            },
            zotero_pref = "<data/>",
          },
          comments = {
            ["2"] = { author = "B", date = "2026-07-04", content = "second" },
            ["1"] = { author = "A", date = "2026-07-03", content = "first" },
          },
          revisions = {
            rev_z = { type = "insertion", author = "A", date = "2026-07-03", content = "z" },
            rev_a = { type = "deletion", author = "B", date = "2026-07-04", content = "a" },
          },
        }
      end
      local r1 = mg.sidecars(build_input())
      local r2 = mg.sidecars(build_input())
      assert(json.encode(r1) == json.encode(r2),
        "migrate.sidecars must be byte-identical across repeated runs on the same object-keyed input")
    end },
  -- Wave 4 item 6 (dropped-disposition coverage + direct record
  -- assertion): exercise the one "dropped" key ("adjacent") and assert
  -- out.record's contents directly, rather than only via the (now
  -- unresolved) envelope hash. Also covers item 2's typed migration
  -- record (id/recordType/schemaVersion).
  { name = "dropped key 'adjacent' is excluded from the record with an info finding; out.record asserted directly", fn = function()
      local out = mg.payload({ type = "anchor", version = 3, class = "column-margin",
        content_hint = "image", adjacent = "some-target-id" })
      assert(out.record.class == "column-margin", "expected 'class' to be carried into the record")
      assert(out.record.content_hint == "image", "expected 'content_hint' to be carried into the record")
      assert(out.record.adjacent == nil, "dropped key 'adjacent' must not appear in the record")
      assert(out.record.recordType == "migration-record" and out.record.schemaVersion == 1
        and out.record.id == out.envelope.id,
        "expected the typed migration-record shape (id/recordType/schemaVersion)")
      local found = false
      for _, fd in ipairs(out.findings) do
        if fd.code == "dropped-legacy-key" and fd.level == "info" and fd.message:match("adjacent") then
          found = true
        end
      end
      assert(found, "expected a dropped-legacy-key info finding naming 'adjacent'")
    end },
  -- Wave 4 item 7 (provisional envelope validation): the envelope's hash
  -- is deliberately unresolved, so validating it against field-envelope.v4
  -- must FAIL -- and fail specifically at /hash, not for some unrelated
  -- reason -- proving this really is a provisional mapping rather than an
  -- accidentally-passing final v4 envelope. The 1024-byte size bound still
  -- applies to the provisional shape.
  { name = "provisional envelope does not validate as a final field-envelope.v4 (hash unresolved), and stays under the size bound", fn = function()
      local js = require("lib.jsonschema")
      local out = mg.payload({ type = "div", version = 3, name = "abstract" })
      assert(out.provisional == true)
      local base = "https://dougmanuel.github.io/docstyle/schemas/"
      local schema = js.resolve(base .. "field-envelope.v4.json")
      assert(schema ~= nil, "field-envelope.v4 not registered -- runner ordering regression?")
      local ok, errs = js.validate(schema, out.envelope)
      assert(not ok, "a provisional envelope with an unresolved hash must NOT validate as a final field-envelope.v4")
      local hash_err = false
      for _, e in ipairs(errs) do
        if e.path == "/hash" then hash_err = true end
      end
      assert(hash_err, "expected the validation failure to be specifically about /hash, not an unrelated regression")
      local size = #json.encode(out.envelope)
      assert(size <= 1024, "provisional envelope exceeds the 1024-byte bound: " .. size)
    end },
}
return cases
