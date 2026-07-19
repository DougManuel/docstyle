# LibDeflate provenance

## Upstream identity

- Project: [LibDeflate](https://github.com/SafeteeWoW/LibDeflate)
- Release tag: `1.0.2-release`
- Tag object: `650e91c8000b38a3659c78e871c6d8647e6ac297`
- Commit: `6831edcaa915154e7769d622e0de72ee5d25a882`
- Commit date: 2020-06-26T23:12:35+08:00
- Retrieved: 2026-07-18
- Licence: zlib licence

The source and licence were retrieved from a depth-one checkout of the
immutable release tag. The upstream files had these SHA-256 values before any
local adaptation:

| File | Upstream SHA-256 |
|---|---|
| `LibDeflate.lua` | `76f2114e527c2be1ac5cf768a68084946a3e19f63592834640020b7c9b5a450f` |
| `LICENSE.txt` | `acbecf8578f4febb766a1dd0217336e2e7ec19e66d13c907e38b01b1b727d7df` |

The initial vendored copies matched those hashes byte for byte. The licence
remains unchanged. The source was then plainly marked and adapted locally for
bounded output; its post-adaptation SHA-256 is
`910ce3f61f32bc5114085f30175128d64284c4ea49d02d53b97ce6388fe4c0c0`.

## Selection boundary

The upstream `DecompressDeflate` function is retained for provenance and
comparison, but it materializes the complete expanded string. It is not part of
the selected untrusted-package read path. Docstyle calls only the local
`DecompressDeflateLimited` extension through `archive.inflate_limited`; the
wrapper never calls `DecompressDeflate`.

The local changes and their acceptance tests are enumerated in
`LOCAL-CHANGES.md`. Vendoring records origin and reproducibility; it does not
make an independent claim that the upstream or adapted code is free of defects.
