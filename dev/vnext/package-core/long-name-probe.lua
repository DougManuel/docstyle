-- Long-name CPU probe for the production package core (#55).
--
-- The vendored LuaXML backend's cost grows superlinearly with the length of
-- element and attribute names, namespace prefixes and processing-
-- instruction targets. Since #55 the backend parses a copy in which every
-- name is a short alias, and the strict layer matches plain-ASCII names
-- with one pattern instead of decoding them character by character. This
-- probe records the cost left for the shapes measured in #55, plus a
-- tag-dense part of short runs for contrast: per-token work and per-
-- character decoding, not names, now dominate.
--
-- Usage:
--   quarto run dev/vnext/package-core/long-name-probe.lua \
--     > dev/vnext/package-core/long-name-results.json
--
-- Stdout is exactly the JSON result; human-readable lines go to stderr.
-- Only pandoc.system.cputime is used, and the result carries no timestamp.

local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))
local core_dir = root .. "/_extensions/docstyle/vnext/package-core"

package.path = table.concat({
  core_dir .. "/?.lua",
  core_dir .. "/?/init.lua",
}, ";")

local xml = require("xml")
local strictness = require("xml.strictness")
local overlay = require("xml.token_overlay")
local luaxml = require("xml.vendor.luaxml-mod-xml")

local function cpu_seconds(fn)
  collectgarbage("collect")
  local started = pandoc.system.cputime()
  local result = fn()
  return (pandoc.system.cputime() - started) / 1e12, result
end

local function long(size) return string.rep("n", size) end

-- About 8 MiB of 256-byte self-closing elements under one root, either
-- repeating one name or giving each element its own name.
local function names_part(distinct)
  local limit = xml.MAX_INPUT_BYTES - 64
  local pieces, size, index = { "<r>" }, 3, 0
  while true do
    index = index + 1
    local name = long(256)
    if distinct then
      local suffix = tostring(index)
      name = long(256 - #suffix) .. suffix
    end
    local element = "<" .. name .. "/>"
    if size + #element + 4 > limit then break end
    pieces[#pieces + 1] = element
    size = size + #element
  end
  pieces[#pieces + 1] = "</r>"
  return table.concat(pieces)
end

-- About 8 MiB of short WordprocessingML-like runs: one element group, one
-- short attribute and four characters of text every 42 bytes.
local function short_runs_part()
  local limit = xml.MAX_INPUT_BYTES - 64
  local head = "<w:document xmlns:w='urn:w'>"
  local run = '<w:r w:rsidR="00A1"><w:t>text</w:t></w:r>'
  local pieces, size = { head }, #head
  while size + #run + 20 <= limit do
    pieces[#pieces + 1] = run
    size = size + #run
  end
  pieces[#pieces + 1] = "</w:document>"
  return table.concat(pieces)
end

local shapes = {
  { id = "element-name-10kb", part = "<" .. long(10000) .. "/>" },
  { id = "element-name-20kb", part = "<" .. long(20000) .. "/>" },
  { id = "attribute-name-10kb", part = "<r " .. long(10000) .. '="1"/>' },
  { id = "namespace-prefix-10kb",
    part = "<" .. long(10000) .. ":r xmlns:" .. long(10000) .. '="urn:p"/>' },
  { id = "pi-target-10kb", part = "<?" .. long(10000) .. " d?><r/>" },
  { id = "8mib-256-byte-names-repeated", part = names_part(false) },
  { id = "8mib-256-byte-names-distinct", part = names_part(true) },
  { id = "8mib-short-runs-contrast", part = short_runs_part() },
}

local results = {}
for _, shape in ipairs(shapes) do
  local seconds = cpu_seconds(function() return xml.parse(shape.part) end)
  results[#results + 1] = {
    id = shape.id,
    bytes = #shape.part,
    parse_cpu_seconds = tonumber(("%.6f"):format(seconds)),
  }
  io.stderr:write(("%-32s %10.3f s\n"):format(shape.id, seconds))
end

-- Where the time goes for the largest shape: the strict layer (which also
-- builds the backend copy) against the backend parsing that copy.
local split_part = shapes[6].part
local strict_seconds, inspected = cpu_seconds(function()
  return strictness.inspect(split_part)
end)
local backend_seconds = cpu_seconds(function()
  return overlay.luaxml_events(luaxml, inspected.semantic_xml,
    inspected.backend_names)
end)

local result = {
  protocol = {
    clock = "pandoc.system.cputime picoseconds converted to seconds",
    repetitions = 1,
    note = "single cold measurement per shape after a full collection",
  },
  shapes = results,
  split_8mib_repeated = {
    strict_layer_cpu_seconds = tonumber(("%.6f"):format(strict_seconds)),
    backend_cpu_seconds = tonumber(("%.6f"):format(backend_seconds)),
    part_bytes = #split_part,
    backend_copy_bytes = #inspected.semantic_xml,
  },
}

io.stderr:write(("split: strict layer %.3f s, backend %.3f s\n")
  :format(strict_seconds, backend_seconds))
print(pandoc.json.encode(result))
