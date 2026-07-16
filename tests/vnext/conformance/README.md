# vNext Conformance Runner

This directory is the conformance harness for Docstyle vNext work package 1
(WP1): the JSON Schema subset validator, the canonical-JSON/hashing/identifier
/manifest library modules, the legacy-to-vNext migration primitives, the
reconciliation decision table, and the schema and example files those
modules validate against.

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

Run the full R suite with `devtools::test(stop_on_failure = TRUE)`, not
bare `devtools::test()`:

```bash
env R_PROFILE_USER=/dev/null Rscript -e 'devtools::test(stop_on_failure = TRUE)'
```

`devtools::test()`'s default `stop_on_failure = FALSE` means
`Rscript -e 'devtools::test()'` exits `0` even when this bridge (or any
other test) fails -- a broken runner would pass silently in CI or a
pre-commit check. `stop_on_failure = TRUE` makes a test failure raise a
condition that propagates to a non-zero process exit.

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

## Metadata-profile validation: two layers

Profile-typed metadata records are validated in two layers that compose
rather than duplicate each other:

- **Structural gate -- `state-metadata.v1.json`'s `records[]` `anyOf`.**
  Branch 1 validates a core `metadata-core.v1` record; branch 2 accepts any
  object that merely carries `id`/`recordType`/`schemaVersion`/`profile`,
  because state-metadata.v1 has no way to know what any given profile's
  record shape actually requires. This is deliberately permissive -- a
  record can satisfy branch 2 while still violating its own profile's real
  schema (for example, a `docstyle:fixture` record missing the profile's
  required `label`). Left unchecked, this is the "anyOf branch-2 bypass".
- **Semantic gate -- `lib/profile.lua`'s `validate_metadata()`.** For every
  record naming an active, available profile, this composes that profile's
  own schema (`schemas/profiles/<name>.v1.json`) and validates the record
  against it, closing the gap branch 2 leaves open. A record whose profile
  is inactive or unavailable is preserved as opaque data with a `warning`
  finding, never blocking; activating a profile whose schema is
  unavailable is its own blocking `error` finding, independent of whether
  any record currently references it.

See `lib/profile.lua`'s header comment for the full dispatch table and the
profile-id-to-schema mapping convention, and `tests/test-profile.lua` for
the adversarial cases, including the missing-`label` bypass case.

## Declared bounds

Seven bounds accumulated over the course of building this harness. They
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
   a spec revision, ratified in the spec's content-node type table at the
   WP1 pre-merge review.
4. **Acceptance-test-8 reading.** The six reconciliation rules are now
   backed by an executable decision table, `lib/reconcile.lua`'s
   `reconcile.decide()`, covered end to end by `tests/test-reconcile.lua`
   against every rule, every blocking case and the unavailable-profile
   row. WP1 does not apply these outcomes during a real render or return
   -- that remains WP5's job, which is expected to call
   `reconcile.decide()` directly rather than re-derive the routing from
   spec prose.
5. **`source` payload-key rename.** The legacy `char` payload's `source`
   key is stored as `legacySource` in the migration record, because
   `hashes.content_hash()` strips any key literally named `hash` or
   `source` at every depth, which would otherwise silently exclude that
   key's content from the envelope hash.
6. **v1/v2 evidence gap.** The frozen WP0 baselines contain no v1 or v2
   field-code payloads -- only writer-v3. The v1/v2 cases under
   `legacy/cases/` come from `tests/testthat/` fixture strings instead,
   each cited by file and line.
7. **Atomic state publication (acceptance test 6) -- a design description,
   not a limitation.** `lib/manifest.lua`'s commit protocol publishes typed
   state files under generation-qualified immutable physical names
   (`<logical-base>.<generation>.json`, e.g. `regions.2.json`), never a
   name any existing manifest already references. A manifest entry carries
   both the logical name (`regions.json`, stable across generations) and
   the physical name (generation-specific). Every typed-file rename during
   a commit lands on a name the current manifest does not yet reference;
   the rename of `manifest.json.tmp` over `manifest.json` is the sole
   commit point. `test-manifest.lua` injects failure both before any
   rename and -- the window a shared-filename design's own test could
   miss -- after the typed-file renames but before the manifest rename,
   and asserts `read()` still returns the prior generation cleanly in both
   cases. This is recorded here, alongside the other bounds, as the
   mechanism by which acceptance test 6 is met, not as a deferral.
