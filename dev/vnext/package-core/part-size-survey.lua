-- WP0 corpus part-size survey (Task 5, WP2 package-core).
--
-- Measures every real WordprocessingML part reachable from the WP0
-- characterization fixtures and the office-interop fixture, to confirm the
-- candidate 1,048,576-byte (1 MiB) XML-part input-byte limit has headroom
-- against real documents before the limit is enforced fail-closed in
-- xml/adapter.lua. This is advisory measurement, not a test: it prints a
-- report for a human to read and record in the Task 5 commit message.
--
-- Usage: quarto run dev/vnext/package-core/part-size-survey.lua
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))
local core_dir = root .. "/_extensions/docstyle/vnext/package-core"

-- Mirror run.lua's package.path pattern: point straight at the production
-- core so this script measures the real seam, not a copy.
package.path = table.concat({
  core_dir .. "/?.lua",
  core_dir .. "/?/init.lua",
}, ";")

local core = require("init")

-- Generous, fixed limits for a read-only survey. These bound the archive
-- open itself (content-types and root relationships are read during
-- opc.open_path's own manifest validation, which consumes the
-- materialization budget before this script ever inspects an entry) -- not
-- the measurement, which never materializes part bytes at all.
local LIMITS = {
  max_archive_bytes = 128 * 1024 * 1024,
  max_entries = 10000,
  max_entry_uncompressed_bytes = 128 * 1024 * 1024,
  max_total_uncompressed_bytes = 512 * 1024 * 1024,
  max_compression_ratio = 1000,
  max_materialized_bytes = 128 * 1024 * 1024,
}

local function is_directory(path)
  return (pcall(pandoc.system.list_directory, path))
end

local function collect_docx(dir, found)
  found = found or {}
  local ok, entries = pcall(pandoc.system.list_directory, dir)
  if not ok then return found end
  for _, name in ipairs(entries) do
    local full = pandoc.path.join({ dir, name })
    if is_directory(full) then
      collect_docx(full, found)
    elseif name:match("%.docx$") then
      found[#found + 1] = full
    end
  end
  return found
end

local targets = {}
for _, path in ipairs(collect_docx(
    pandoc.path.join({ root, "tests", "vnext", "fixtures" }))) do
  targets[#targets + 1] = path
end
for _, path in ipairs(collect_docx(pandoc.path.join({
    root, "tests", "vnext", "package-core", "fixtures", "office" }))) do
  targets[#targets + 1] = path
end
table.sort(targets)

assert(#targets > 0, "part-size survey found no .docx fixtures to inspect")

local overall_max_bytes = -1
local overall_max_part = nil
local overall_max_docx = nil

for _, path in ipairs(targets) do
  -- A fresh handle per docx: opc.open_path consumes the per-handle
  -- materialization budget while validating [Content_Types].xml and the
  -- root relationships, so reusing one handle across files would starve
  -- later opens. Sizes below come from the validated zip central-directory
  -- entries (uncompressed_size), never from materializing a part's bytes.
  local pkg = core.open(path, LIMITS)
  print("== " .. path .. " ==")
  for _, entry in ipairs(pkg.entries) do
    print(entry.name .. "\t" .. entry.uncompressed_size)
    if entry.uncompressed_size > overall_max_bytes then
      overall_max_bytes = entry.uncompressed_size
      overall_max_part = entry.name
      overall_max_docx = path
    end
  end
end

print(("MAXIMUM\t%d\t%s\t%s"):format(
  overall_max_bytes, overall_max_part or "", overall_max_docx or ""))
