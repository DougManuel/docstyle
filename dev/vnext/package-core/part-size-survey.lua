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
--
-- Folder mode (#53): set DOCSTYLE_SURVEY_DIR to survey any directory tree
-- of .docx files, such as a collaborator's own documents:
--
--   DOCSTYLE_SURVEY_DIR=~/Documents \
--     quarto run dev/vnext/package-core/part-size-survey.lua
--
-- DOCSTYLE_SURVEY_FILES names a file listing one .docx path per line
-- instead, for trees too slow to walk (cloud-synced folders); build it
-- with Spotlight, e.g. `mdfind -onlyin <dir> 'kMDItemFSName == "*.docx"'`.
--
-- Folder mode prints one aggregate JSON object and never a file name, part
-- name or content, so its output is safe to share or commit. Sizes come
-- from pandoc.zip, independently of the package core, so documents the
-- core refuses to open are still measured; the core's verdict is reported
-- separately by diagnostic code.
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

local SKIPPED_DIRECTORIES = { node_modules = true, renv = true }

local function collect_docx(dir, found)
  found = found or {}
  local ok, entries = pcall(pandoc.system.list_directory, dir)
  if not ok then return found end
  for _, name in ipairs(entries) do
    local full = pandoc.path.join({ dir, name })
    if is_directory(full) then
      if name:sub(1, 1) ~= "." and not SKIPPED_DIRECTORIES[name] then
        collect_docx(full, found)
      end
    elseif name:match("%.docx$") and name:sub(1, 2) ~= "~$" then
      found[#found + 1] = full
    end
  end
  return found
end

local MIB = 1024 * 1024
local THRESHOLDS_MIB = { 1, 2, 4, 8, 16 }

local function largest_xml_part(bytes)
  local ok, archive = pcall(pandoc.zip.Archive, bytes)
  if not ok then return nil end
  local largest = 0
  for _, entry in ipairs(archive.entries) do
    if entry.path:match("%.xml$") or entry.path:match("%.rels$") then
      largest = math.max(largest, #entry:contents())
    end
  end
  return largest
end

local function survey_files(found)
  table.sort(found)
  local result = {
    files_found = #found,
    documents = 0,
    unreadable_archives = 0,
    largest_xml_part_bytes = 0,
    documents_with_largest_xml_part_above_mib = {},
    core_open = { opened = 0, refused_by_code = {} },
  }
  for _, threshold in ipairs(THRESHOLDS_MIB) do
    result.documents_with_largest_xml_part_above_mib[tostring(threshold)] = 0
  end
  -- Streams one document at a time; byte-identical copies (checkouts,
  -- worktrees, backups) count once.
  local seen = {}
  for index, path in ipairs(found) do
    if index % 100 == 0 then
      io.stderr:write(("[survey] %d of %d files\n"):format(index, #found))
    end
    local handle = io.open(path, "rb")
    local bytes = handle and handle:read("a")
    if handle then handle:close() end
    local digest = bytes and pandoc.utils.sha1(bytes)
    if bytes == nil then
      result.unreadable_archives = result.unreadable_archives + 1
    elseif not seen[digest] then
      seen[digest] = true
      result.documents = result.documents + 1
      local largest = largest_xml_part(bytes)
      bytes = nil
      if largest == nil then
        result.unreadable_archives = result.unreadable_archives + 1
      else
        result.largest_xml_part_bytes =
          math.max(result.largest_xml_part_bytes, largest)
        for _, threshold in ipairs(THRESHOLDS_MIB) do
          if largest > threshold * MIB then
            local key = tostring(threshold)
            result.documents_with_largest_xml_part_above_mib[key] =
              result.documents_with_largest_xml_part_above_mib[key] + 1
          end
        end
      end
      local ok, err = pcall(core.open, path, LIMITS)
      if ok then
        result.core_open.opened = result.core_open.opened + 1
      else
        local code = type(err) == "table" and err.code or "internal.lua-error"
        result.core_open.refused_by_code[code] =
          (result.core_open.refused_by_code[code] or 0) + 1
      end
      collectgarbage()
    end
  end
  return result
end

local survey_list = os.getenv("DOCSTYLE_SURVEY_FILES")
if survey_list and survey_list ~= "" then
  local found = {}
  for line in io.lines(survey_list) do
    if line:match("%.docx$") and not line:match("/~%$[^/]*$") then
      found[#found + 1] = line
    end
  end
  print(pandoc.json.encode(survey_files(found)))
  return
end
local survey_dir = os.getenv("DOCSTYLE_SURVEY_DIR")
if survey_dir and survey_dir ~= "" then
  print(pandoc.json.encode(survey_files(collect_docx(survey_dir))))
  return
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
