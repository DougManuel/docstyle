-- Fresh-process Task 9 publication child.
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local spike_root = pandoc.path.normalize(pandoc.path.join({
  here, "..",
}))
local root = pandoc.path.normalize(pandoc.path.join({
  here, "..", "..", "..", "..",
}))

package.path = table.concat({
  spike_root .. "/?.lua",
  spike_root .. "/?/init.lua",
  root .. "/dev/vnext/xml-spike/?.lua",
  root .. "/dev/vnext/xml-spike/?/init.lua",
}, ";")

local adapter = require("candidates.luaxml.adapter")
local fixture = require("lib.fixture")
local opc = require("archive.opc")
local oracle = require("candidates.oracle")

local sha256 = dofile(pandoc.path.join({
  root, "tests", "vnext", "conformance", "lib", "sha256.lua",
}))

local W_NS =
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
local LIMITS = {
  max_archive_bytes = 128 * 1024 * 1024,
  max_entries = 10000,
  max_entry_uncompressed_bytes = 128 * 1024 * 1024,
  max_total_uncompressed_bytes = 512 * 1024 * 1024,
  max_compression_ratio = 1000,
  max_materialized_bytes = 256 * 1024 * 1024,
}

local function required_environment(name)
  local value = os.getenv(name)
  assert(type(value) == "string" and value ~= "",
    "missing required environment variable " .. name)
  return value
end

local function edit_first_text(source)
  local document = adapter.parse(source)
  local target, occurrence
  for index, node in ipairs(adapter.find_all(document, W_NS, "t")) do
    if not node.has_element_child and not node.has_cdata and
        #node.direct_text == 1 then
      target = node
      occurrence = index
      break
    end
  end
  assert(target, "office document needs one editable text element")

  local replacement = "Docstyle Task 9 fresh-process publication edit"
  local change = {
    operation = "text",
    element = {
      uri = W_NS,
      local_name = "t",
      occurrence = occurrence,
    },
  }
  local golden = oracle.find_edit_range(oracle.parse(source), change)
  adapter.replace_text(target, replacement)
  local edited, ranges = adapter.serialize(document)
  assert(#ranges == 1)
  local verification = oracle.verify_edit(source, edited, golden, {
    reported_range = ranges[1],
    operation = change.operation,
    element = change.element,
    value = replacement,
  })
  assert(verification.ok == true)
  return edited
end

local source_path =
  required_environment("DOCSTYLE_SPIKE_CHILD_SOURCE")
local output_path =
  required_environment("DOCSTYLE_SPIKE_CHILD_OUTPUT")
local pkg = opc.open_path(source_path, LIMITS)
local source = pkg:part(pkg.office_document_part)
local edited = edit_first_text(source)
pkg:replace_part(pkg.office_document_part, edited)
pkg:write_atomic(output_path)

local reopened = opc.open_path(output_path, LIMITS)
local entry_names = {}
for index, entry in ipairs(reopened.entries) do
  entry_names[index] = entry.name
end

print(pandoc.json.encode({
  edited_part_sha256 = sha256.hex(edited),
  entry_names = entry_names,
  archive_sha256 = sha256.hex(fixture.read_bytes(output_path)),
}))
