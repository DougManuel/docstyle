# SDD ledger — plan: docs/superpowers/plans/2026-08-14-docstyle-vnext-wp2-package-core.md
Task 1: complete (commits 1c3fb75..92dee9d, review clean)
Task 1: minor (deferred): empty leftover dirs from git mv in dev/vnext/xml-spike + tests/vnext/xml-spike (cosmetic, untracked)
Task 2: review approved diff; binding R-suite expectation unmet (Task 1 side-effect: EXTENSION_SOURCE_FILES lacks vnext handling)
Task 2: fix round 1/5 IN PROGRESS — ruling: exclude vnext/ from legacy extension inventory (spec isolation principle); resumed implementer a8435832302f1505a
Task 2: minor (deferred): SKIP 8 vs 4 in R suite is Zotero-not-running environmental variance, not a regression
Task 2: fix round 1/5 (1 addressed via f511abc — inventory/walk exclusion + pinning test, R suite FAIL 0; 1 open — init-copy path still ships vnext/ into new projects; commits fd60d66..f511abc)
Task 2: fix round 2/5 IN PROGRESS — init-copy exclusion + non-vacuous pinning test; resumed implementer a8435832302f1505a
Task 2: fix round 2/5 (2 addressed, 0 open — inventory+walk exclusion f511abc, init-copy exclusion e02045a; single-sourced EXTENSION_LEGACY_EXCLUDED; re-review verified tests load-bearing by revert)
Task 2: minor (deferred): new init-copy path drops top-level dotfiles the old whole-dir copy would carry (no live effect; no dotfiles exist in _extensions/docstyle/)
Task 2: complete (commits 92dee9d..e02045a, review clean after 2 fix rounds)
Task 3: complete (commits e02045a..4af0aca, review clean)
Task 3: minor (deferred): _require_effective return-arity asymmetry (1 vs 2 values) — normalize when a second-value consumer appears (Tasks 6/7)
Task 3: minor (deferred): _effective_bytes banner comment says "the writer" consults the helpers — becomes true in Task 6, verify then
Task 3: note for Task 6: addition branches in the effective helpers are unexercised until add_part exists — Task 6 tests must cover them
Task 4: implementer crashed once on API error (no commits lost, clean tree), resumed successfully; DONE at 33ada31 (suite 334/0/0)
Task 4: review Needs fixes — Medium: oracle verify_edits comparator lacks (start,seq) tie-break (reviewer reproduced false negative); Low: no self-closing-parent rejection test
Task 4: fix round 1/5 IN PROGRESS — resumed implementer a01fa15e175fd830a; FIX_BASE 33ada31
Task 4: fix round 1/5 (2 addressed, 0 open — oracle (start,seq) comparator + pinning test, self-closing rejection test; commit 54f9150; re-review verified by revert)
Task 4: complete (commits 4af0aca..54f9150, review clean after 1 fix round; suite 336/0/0)
Task 5: DONE at f7034ad (suite 340/0/0; survey max 23,278 bytes, no BLOCKED); review Approved BUT controller overruled the reviewer's provenance ruling
Task 5: adjudication — provenance.json edits (Task 4: 1305->1440, Task 5: 1440->1459) violate the frozen-record constraint (decision-report still says 1305); defect = promoted test couples live counts to frozen evidence; fix round 1/5 IN PROGRESS (restore provenance to merge-base, decouple test); FIX_BASE f7034ad; reviewer dissent recorded for the final review
Task 5: minor (deferred): vendored LuaXML O(n^2) on single large attribute values — verified quadratic; a <1 MiB adversarial part can exhaust CPU below the byte limit; file a tracked issue at branch finish + surface in Task 8 evidence
Task 5: minor (deferred): xml.invalid-limit context shape differs between adapter.lua and common.lua raisers; max_input_bytes=0 accepted by adapter, rejected by common.lua (unreachable for non-empty parts)
Task 5: minor (deferred): Task 5 survey corpus (vnext fixtures) is narrower than the WP0 six-fixture set; headroom claim anchors on the frozen 654,301-byte WP0 maximum
Task 5: fix round 1/5 (1 addressed, 0 open — provenance restored to 1305 byte-exact, test decoupled from frozen record, live recount kept; commit 85069f8; re-review ran suites independently)
Task 5: complete (commits 54f9150..85069f8, review clean after adjudicated fix round; suite 340/0/0)
Task 6: DONE at 684b827 (suite 350/0/0); review Needs fixes — High: Override tests vacuous (Default Extension=xml shadows Override; reviewer proved by neutering the mechanism, suite stayed green); production code independently confirmed correct
Task 6: fix round 1/5 IN PROGRESS — non-colliding content types + neuter-proof protocol + same-name-collision test + original-type post-mutation assertion; FIX_BASE 684b827; resumed implementer a149e5a9dbd52ec89
Task 6: minor (deferred): _register_content_type_override re-parses [Content_Types].xml per add_part call (quadratic-ish for many additions; fine at current scale)
Task 6: minor (deferred): no fresh-process determinism harness specifically for add_part (in-process double-publish + existing 10-process gate cover current scope)
Task 6: fix round 1/5 (3 addressed, 0 open — non-colliding content types with neuter-proof protocol, same-name collision test, original-type post-mutation assertion; commit 7768dca; re-reviewer repeated the neuter probe independently)
Task 6: complete (commits 85069f8..7768dca, review clean after 1 fix round; suite 351/0/0)
Task 7: complete (commits 7768dca..3ea2be8, review clean; suite 359/0/0; mutation probes confirmed tests load-bearing)
Task 7: minor (deferred, final-review triage): coverage gaps in probed-correct code — (a) two add_relationship calls on one source through publish+reopen; (b) missing-rels-part branch (add_relationship on a just-added part); (c) gapped/non-numeric rId minting; (d) opc.invalid-target-mode dual context shapes (suggest distinct code opc.invalid-relationship-mode); (e) unexercised opc.invalid-relationship/invalid-target-mode arg validations
Task 8: DONE at 4aeae95 (decision=pass on hard gates; advisory 5s not met at 5.203238s; approved-limit latency met 0.5596<=0.75; sweep all green)
Task 8: review Needs fixes — Medium: known_limitations note cites "~40KB attr ≈ 21s, verified in Task 5's review", a figure absent from the repo record. PROVENANCE RESOLUTION (controller): the figure is REAL — it is the Task 5 reviewer's independent probe (agent a8ab365dbf0dabaa2), whose table measured single-large-attribute parse times: 5,000B=0.34s; 10,000B=1.35s; 20,000B=5.41s; 40,000B=21.64s (each doubling ~4x, confirming O(n^2)); the Task 5 implementer separately recorded 80,000B≈71s in task-5-report.md. Reviewer reports are not persisted to the repo, hence the apparent fabrication. This ledger entry is now the persistent provenance for the reviewer's table.
Task 8: fix round 1/5 IN PROGRESS — re-source the known_limitations note to repo-recorded figures and regenerate the results JSON by re-running the benchmark; FIX_BASE 4aeae95
Task 8: fix round 1/5 (1 addressed, 0 open — note re-sourced to traceable evidence, JSON regenerated by genuine re-run; commit ef6f4fd)
Task 8: complete (commits 3ea2be8..ef6f4fd, review clean after 1 fix round; decision=pass, advisory 5s not met 5.196473s, approved-limit met)
ALL 8 TASKS COMPLETE — dispatching final whole-branch review
FINAL REVIEW (whole branch, most capable model): all 5 acceptance criteria PASS (re-derived + live runs); adjudication audit clean (frozen record byte-identical to merge-base, dissent moot); cross-task coherence holds (single effective view, append_element-only insertion, gsub sweep clean); verdict NEEDS FIX WAVE (no defects) — publish-level tests for T7(a)/(b) required; tracked issues (LuaXML O(n^2), diagnostics cleanup pre-WP4) to file at finish; stale spike headers optional
FINAL FIX WAVE 1/1 IN PROGRESS — resumed T7 implementer a2d638ebe512af6a4; FIX_BASE ef6f4fd
FINAL FIX WAVE 1/1 (all items ADDRESSED — publish-level rels tests load-bearing-verified, headers refreshed; commit 7b26e10; suite 364/0/0)
BRANCH COMPLETE — 15 commits, all 8 tasks + final review + fix wave; ledger archived to dev/vnext/package-core/implementation-ledger.md
