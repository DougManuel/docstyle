# vNext Conformance Runner

This directory is the conformance harness for Docstyle vNext work package 1
(WP1): the JSON Schema subset validator, the canonical-JSON/hashing/identifier
/manifest library modules, the legacy-to-vNext migration primitives, and the
schema and example files those modules validate against.

## Running the suite

From the repository root:

```bash
quarto run tests/vnext/conformance/run.lua
```

Quarto runs the file as a Pandoc Lua filter, which is what gives it access
to `pandoc.json`, `pandoc.path` and `pandoc.system` without an external Lua
JSON or filesystem library. There is also a `devtools::test()` bridge
(`tests/testthat/test-vnext-conformance.R`) that shells out to this same
command so the R test suite exercises the runner during the migration
period; it skips (rather than fails) when `quarto` is not on `PATH`.

## PASS/FAIL semantics

The runner does two things in one pass:

1. Loads every `tests/test-*.lua` file with `dofile` and runs each
   `{name, fn}` case it returns under `pcall`.
2. Loads every schema under `schemas/` and `schemas/profiles/`, then
   validates every file under `schemas/examples/<schema-name>/` against the
   schema of the same name. A file named `valid-*` must validate; a file
   named `invalid-*` must fail validation. Either outcome the wrong way
   round counts as a failure.

Output is one line per failed case (`FAIL <name>: <message>`) followed by a
summary line, `PASS n | FAIL n`. A non-zero exit means at least one case or
example failed; zero means every case passed and every example validated
as its name promised.

**A missing `require` target fails loudly.** `run.lua`'s `dofile` calls are
not wrapped in `pcall` -- only the cases a test file *returns* are. If a
test file's own top-level `require("lib.x")` fails (because `lib/x.lua`
does not exist yet, for example, during the red phase of test-driven
development), the whole runner aborts with a Lua stack traceback and a
non-zero exit, instead of one `FAIL` line per case in that file. This is
still a correct, unambiguous failure signal -- just a traceback instead of
a tally -- and it is deliberate: `run.lua` is a thin harness rather than a
full test framework, and swallowing a missing-module error into a
misleadingly specific `FAIL` line would hide the real problem.

## Test-file convention

Every `tests/test-*.lua` file `require`s the library module or modules it
exercises and returns an array of `{ name = "...", fn = function() ... end
}` tables. A case passes when its `fn` runs without raising; `assert()` is
the usual way to fail one.

Test files resolve the repository root two different ways:

- **The default idiom:** three `".."` steps up from `run.lua`'s own
  directory (`tests/vnext/conformance`), using
  `pandoc.path.directory(PANDOC_SCRIPT_FILE)`. This works because
  `PANDOC_SCRIPT_FILE` stays pinned to the top-level entry script
  (`run.lua`) for the whole process, even inside a file that `run.lua`
  loaded with `dofile` -- a `dofile`'d file does not get its own value.
  Every test file that needs the repository root uses this idiom
  (`test-envelope-size.lua`, `test-model-coverage.lua`,
  `test-model-roundtrip.lua`) with exactly three `".."` segments -- fewer
  than the four a naive read of the directory nesting might suggest.
- **The `test-migrate.lua` exception:** this file locates its own directory
  with `debug.getinfo(1, "S").source` instead, because its fixture data
  (`legacy/key-map.json`, `legacy/cases/*.json`) sits beside the
  `tests/` directory inside `tests/vnext/conformance` itself, not at the
  repository root. `PANDOC_SCRIPT_FILE`-based resolution would anchor to
  `run.lua`'s directory regardless of which file asked, which happens to
  be the right directory for this file's own needs by coincidence of
  nesting depth -- but `lib/migrate.lua` (which the same fixtures also
  feed) cannot rely on that coincidence, since library modules are
  `require`d, not `dofile`'d, and have no `PANDOC_SCRIPT_FILE`-relative
  frame of reference at all. `debug.getinfo(1, "S").source` returns the
  path of the currently executing chunk regardless of how it was loaded,
  so both the test file and `lib/migrate.lua` use it consistently for
  their shared, conformance-directory-local fixture path.

## Schemas and examples change together

A change to any file under `schemas/` must land in the same commit as the
matching additions or edits under `schemas/examples/<schema-name>/`. The
runner's example loop is the only thing that exercises a schema's actual
keyword behaviour end to end (`test-jsonschema.lua` tests the validator
engine in the abstract; it does not touch the WP1 schemas themselves) --
a schema edited without a corresponding example change can silently drift
from what it is meant to accept or reject, with nothing in this suite able
to catch it.

## Declared bounds

Six bounds accumulated over the course of building this harness. They
constrain what conformance here does and does not establish; see
`dev/vnext/wp1-legacy-coverage.md` for the fuller discussion of each.

1. **NFC assumption.** Canonicalization assumes input text is already
   Unicode NFC; Pandoc Lua exposes no normalizer. NFD-input normalization
   is a later work package's job (the WP3 production model builder or the
   WP2 text layer), not this harness's; LF line-ending normalization is
   implemented in the hash input preparation.
2. **Regex dialect subset.** Schema `pattern` strings use a documented
   dual-dialect subset -- bracket character classes, single-literal
   brackets for characters that are metacharacters in only one dialect
   (`[-]`, `[.]`), `^`/`$` anchors, and `{n}`/`{n,m}` brace repetition
   (expanded by `lib/jsonschema.lua`) -- so the same pattern string is valid
   under both this harness's Lua-pattern validator and a standard ECMA-regex
   engine. The validator itself still implements only that subset, not full
   ECMA regular expressions.
3. **`anchor` node-type addition.** The 17th node type, `anchor`, was
   added to the `document-model.v1` and `field-envelope.v4` enums beyond
   the approved specification's illustrative list, to give the legacy
   `float`/`anchor` field-code payloads a positioned-content kind. This is
   a spec revision, flagged for review.
4. **Acceptance-test-8 reading.** The six reconciliation rules are spec
   contracts for WP5 to execute, not something this harness runs. What
   this harness verifies is their data preconditions: that every schema
   the rules will operate over carries ids, hashes and policies.
5. **`source` payload-key rename.** The legacy `char` payload's `source`
   key is stored as `legacySource` in the migration record, because
   `hashes.content_hash()` strips any key literally named `hash` or
   `source` at every depth, which would otherwise silently exclude that
   key's content from the envelope hash.
6. **v1/v2 evidence gap.** The frozen WP0 baselines contain no v1 or v2
   field-code payloads -- only writer-v3. The v1/v2 cases under
   `legacy/cases/` come from `tests/testthat/` fixture strings instead,
   each cited by file and line.
