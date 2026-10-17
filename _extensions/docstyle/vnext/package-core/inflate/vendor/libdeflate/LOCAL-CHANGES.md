# Local changes to LibDeflate 1.0.2

## Purpose

Docstyle needs to inspect untrusted DOCX packages without allowing a small
compressed entry to allocate an unbounded expanded string. Upstream
`DecompressDeflate` returns a complete string, so the WP2 feasibility spike adds
a separate raw-DEFLATE decoder path with a mandatory byte limit and bounded
sink. The upstream public decoder remains unchanged and is not called by the
selected path.

## Changed routines and evidence

All changes are in the block labelled `Docstyle bounded raw-DEFLATE adaptation`
inside `LibDeflate.lua`.

| Local routine | Change | Primary acceptance evidence |
|---|---|---|
| `CreateLimitedDecompressState` | Adds exact produced-byte accounting, a 32 KiB circular history window, an 8 KiB pending-output bound and optional sink collection. | `emitter receives only bounded chunks and exact produced count`; `circular history wraps beyond 32 KiB without collecting full output` |
| `LimitedHasBudget` | Checks the next chunk against the remaining integer budget before construction or emission. Flushes only output already admitted to the budget. | Stored, fixed and dynamic cases at limits 0, expected minus 1, expected and expected plus 1; `high-ratio stream stops before cap without retaining expanded output` |
| `LimitedWriteLiteral` | Checks one output byte before adding it to history or the sink. | Fixed and dynamic boundary-limit cases |
| `LimitedWriteBackReference` | Rejects a distance beyond produced history, copies against the moving 32 KiB ring and bounds temporary chunks to 8 KiB. | `impossible history distance has a stable diagnostic`; `circular history wraps beyond 32 KiB without collecting full output` |
| `LimitedWriteStored` | Checks each bounded stored chunk before allocating its temporary table or reading bytes. | Stored boundary-limit cases; `truncated stream has a stable diagnostic` |
| `LimitedDecodeUntilEndOfBlock` | Reuses upstream Huffman tables while directing literals and matches only to the bounded sink. Checks reader exhaustion after each variable-length read. | Fixed and dynamic vectors; malformed-tree, impossible-distance and truncated-stream cases |
| `LimitedDecompressDynamicBlock` | Adapts upstream dynamic-tree construction and rejects incomplete, over-subscribed or otherwise invalid descriptions. | `malformed dynamic Huffman tree has a stable diagnostic` |
| `InflateLimited` | Supports stored, fixed-Huffman and dynamic-Huffman blocks; rejects the reserved block type, truncation and trailing bytes. | All three valid block vectors; invalid-block-type, truncated-stream and trailing-data cases |
| `DecompressDeflateLimited` | Exposes the bounded decoder without calling the upstream full-string decoder. Returns exact produced bytes and a local status. | All tests in `test-inflate-limit.lua`; source review that the method invokes only `InflateLimited` |

The Docstyle-owned `archive.inflate_limited` module translates local statuses to
stable diagnostics. `archive.entry_reader` then combines the decoder with
preflighted offsets and declarations, chooses the smaller of entry and package
budgets, reasserts stored-size equality before slicing, checks actual output
length and verifies CRC-32 incrementally.

## Fixture provenance

Stored, fixed-Huffman, dynamic-Huffman and high-ratio raw-DEFLATE streams are
checked in as hexadecimal bytes in `test-inflate-limit.lua`. They were generated
with Python 3.14.5 linked to zlib 1.2.12 using raw-DEFLATE mode (`wbits = -15`).
The fixed stream used `Z_FIXED`; the stored stream used compression level 0.
Expected plaintext and CRC-32 values are declared independently in the test.
As supplementary compatibility evidence, a deterministic multi-block corpus is
encoded at test time with LibDeflate's unchanged compressor routines in stored,
fixed-Huffman and dynamic-Huffman modes and decoded through the bounded path.

The live Quarto probe also records that `pandoc.zip.Entry:contents()` returns all
6,225 expanded bytes when called with the numeric value `16`; that argument is
not an enforceable output cap. Pandoc's backend is therefore evidence-only for
this gate.
