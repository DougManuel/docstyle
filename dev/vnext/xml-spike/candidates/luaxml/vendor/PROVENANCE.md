# LuaXML provenance

## Selected revision

- Repository: <https://github.com/michal-h21/LuaXML>
- Commit: `c919471be63d0c770d82200261c5682dee39c9d1`
- Commit date: May 12, 2026
- Retrieval date: July 21, 2026
- Selected source: `luaxml-mod-xml.lua`

The spike pins the immutable commit instead of the mutable `master` branch. The
selected commit was the upstream head when this audit was performed. The
latest tag, `v0.2` (`be48a3ded15b0690bd5e417c058b3b757503e0e3`), predates the
repository's composite licence file and the restored generated entity module.
The selected minimum path does not use the entity module, but the later commit
makes the upstream licence boundaries explicit.

## Minimum dependency closure

The candidate loads `luaxml-mod-xml.lua` directly and supplies its own event
handler. The selected file contains no `require` call. An executable probe
under `quarto run` loaded the file and parsed a start tag, text token and end
tag while both LuaTeX globals (`kpse` and `unicode`) were absent.

The vendored closure is therefore:

- `luaxml-mod-xml.lua` -- Lua License
- `LICENSE` -- upstream composite licence notice

No LuaRocks package, native module, system Lua interpreter or LuaTeX global is
required by this path.

## Compatibility code

The upstream parser checks element structure and emits lexical events. It does
not retain the information required by the adapter contract for namespaces,
case-sensitive attributes, source encodings or byte-exact edits. The
candidate therefore has separate Docstyle-owned strictness and byte-span
modules. The strictness module begins from the reviewed SLAXML candidate's
strictness implementation and is copied into this candidate so the dependency
and line-count evidence remains explicit. The LuaXML overlay is backend-
specific. Neither module imports SLAXML or the independent oracle. All 1,305
Docstyle-owned lines count toward the maintenance comparison.

## Excluded dependency paths

The public DOM entry point, `luaxml-domobject.lua`, eagerly imports XML-handler,
CSS-query, HTML and XPath modules. Those modules are outside the bounded XML
parse path and the Task 6 scope. In particular:

- `luaxml-parse-query.lua` is MIT-licensed and depends on LPeg
- `luaxml-lxpath.lua` is covered by the modified-BSD notice for the upstream
  XPath component; the notice names `luaxml-xpath.lua`, while the current source
  path is `luaxml-lxpath.lua`
- `luaxml-cssquery.lua`, `luaxml-mod-html.lua`, `luaxml-domobject.lua`,
  `luaxml-mod-handler.lua`, `luaxml-entities.lua`, `luaxml-namedentities.lua`
  and `luaxml-stack.lua` are not vendored

The LuaXML rockspec describes the package as MIT, but the repository README,
per-file headers and composite `LICENSE` assign the main project to the Lua
License and identify the two third-party boundaries above. This spike records
the more specific file-level notices.

## Local changes

There are no local changes to either vendored file. The source retains upstream
trailing spaces so its bytes and hash remain exact. The scoped `.gitattributes`
file suppresses Git's trailing-space warning for that source only. The
repository tests pin both SHA-256 hashes and the 570-line source count.
