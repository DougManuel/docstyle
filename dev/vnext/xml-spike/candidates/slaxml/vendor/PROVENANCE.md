# SLAXML provenance

## Upstream source

- Project: [SLAXML](https://github.com/Phrogz/SLAXML)
- Version: 0.8
- Tag: `v0.8`
- Commit: `8a3e0c90325aa6d84ad23a7c13bf77247cb7f94e`
- Licence: MIT
- Retrieved: July 20, 2026

The vendored `slaxml.lua` is byte-for-byte identical to the upstream streaming
parser. The upstream DOM builder and serializer (`slaxdom.lua`), tests and
documentation are not vendored. Docstyle does not modify the parser. The
licence uses LF rather than the upstream CRLF line endings; its text is
unchanged.

## Integrity

| File | Upstream Git blob | Upstream SHA-256 | Vendored SHA-256 |
|---|---|---|---|
| `slaxml.lua` | `98e9819543a5967e6ad15fa024bc9af4be86035e` | `4e736768c061407609741baea1ebbe15e6b53cab5920defea5d7ed3b3c16c35e` | `4e736768c061407609741baea1ebbe15e6b53cab5920defea5d7ed3b3c16c35e` |
| `LICENSE.txt` | `6f1dc915f9ed90b48d907216a0a6cfc2584e1c43` | `21b7b0c90e51ff9111744b02e734f37b4e093ae55ebf5eb1f8abbf380bf3803d` | `24c9af86e5a9ecc484c7e4afcdc277ec3fbe2a95c465e7afb3c8bced74b930de` |

## Documented limitations

The upstream v0.8 documentation states these limitations:

- accepts some XML that is not well formed
- reports XML declarations as processing instructions
- does not support Unicode characters in element or attribute names
- does not support character-set decoding
- does not support DTDs or custom entities
- does not fully enforce reserved XML namespace rules
- can serialize invalid namespace combinations through its separate DOM module

The Docstyle candidate uses SLAXML only for semantic events. A separate
Docstyle-owned strictness and byte-span overlay enforces the spike contract.
Serialization replaces one owned source span and does not use the upstream DOM
serializer.
