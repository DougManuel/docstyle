-- WP2 package core: deterministic, atomic OPC package publication.
local diagnostic = require("lib.diagnostic")

local M = {}
local MAX_RESERVATION_ATTEMPTS = 32
local ADDED_ENTRY_MODTIME = 315532800  -- 1980-01-01T00:00:00Z, the ZIP epoch
local FAILURE_POINTS = {
  after_archive = true,
  after_close = true,
  after_verification = true,
  before_rename = true,
}

local function raise(code, message, context)
  diagnostic.raise(code, message, context)
end

local function write_bytes(path, bytes)
  local handle, open_error = io.open(path, "wb")
  if not handle then
    raise("publication.write", "could not open temporary package", {
      path = path,
      detail = open_error,
    })
  end
  local wrote, write_error = handle:write(bytes)
  local closed, close_error = handle:close()
  if not wrote then
    raise("publication.write", "could not write temporary package", {
      path = path,
      detail = write_error,
      close_detail = closed and nil or close_error,
    })
  end
  if not closed then
    raise("publication.write", "could not close temporary package", {
      path = path,
      detail = close_error,
    })
  end
end

local function reservation_collision(err)
  local detail = tostring(err)
  return detail:find("File exists", 1, true) ~= nil or
    detail:find("already exists", 1, true) ~= nil
end

local function reserve_directory(destination_directory)
  for _ = 1, MAX_RESERVATION_ATTEMPTS do
    local temporary_name = os.tmpname()
    os.remove(temporary_name)
    local basename = pandoc.path.filename(temporary_name)
    local candidate = pandoc.path.join({
      destination_directory, ".docstyle-" .. basename,
    })
    local ok, err = pcall(
      pandoc.system.make_directory, candidate, false)
    if ok then return candidate end
    if not reservation_collision(err) then
      raise("publication.temp-directory",
        "could not reserve a sibling temporary directory", {
          path = candidate,
          detail = tostring(err),
        })
    end
  end
  raise("publication.temp-collision",
    "could not reserve a unique sibling temporary directory", {
      attempts = MAX_RESERVATION_ATTEMPTS,
    })
end

-- The writer consumes ONLY the effective view (single-view invariant): it
-- never inspects pkg._additions directly. Each original entry carries its
-- archive index, which stays aligned with metadata_archive.entries even
-- when ignored entries (#54) are skipped.
local function archive_entries(pkg)
  local metadata_archive = pandoc.zip.Archive(pkg._archive_bytes)
  -- Backend agreement is still checked against the ORIGINAL entries; the
  -- backend archive cannot know about additions.
  if #metadata_archive.entries ~= #pkg.entries then
    raise("publication.backend-mismatch",
      "ZIP backend entry count differs from validated preflight", {
        validated = #pkg.entries,
        backend = #metadata_archive.entries,
      })
  end

  local entries = {}
  for _, effective in ipairs(pkg:_effective_entries()) do
    if effective.kind == "original" then
      local index = effective.archive_index
      local metadata = metadata_archive.entries[index]
      if metadata.path ~= effective.name then
        raise("publication.backend-mismatch",
          "ZIP backend entry order differs from validated preflight", {
            index = index,
            validated = effective.name,
            backend = metadata.path,
          })
      end
      entries[#entries + 1] = pandoc.zip.Entry(
        effective.name, pkg:_effective_bytes(effective.name),
        metadata.modtime)
    else
      entries[#entries + 1] = pandoc.zip.Entry(
        effective.name, pkg:_effective_bytes(effective.name),
        ADDED_ENTRY_MODTIME)
    end
  end
  return entries
end

local function maybe_fail(options, point)
  if options and options.fail_at == point then
    raise("publication.injected-failure",
      "injected publication failure", {
        point = point,
      })
  end
end

local function validate_output_sizes(pkg)
  local total = 0
  for _, effective in ipairs(pkg:_effective_entries()) do
    local size
    if effective.kind == "original" and
        pkg._replacements[effective.name] == nil then
      size = pkg._entries_by_name[effective.name].uncompressed_size
    else
      size = #pkg:_effective_bytes(effective.name)
    end
    if size > pkg._limits.max_entry_uncompressed_bytes then
      raise("publication.entry-limit",
        "output entry exceeds the uncompressed-size limit", {
          entry = effective.name,
          actual = size,
          limit = pkg._limits.max_entry_uncompressed_bytes,
        })
    end
    local remaining = pkg._limits.max_total_uncompressed_bytes - total
    if size > remaining then
      raise("publication.total-limit",
        "output package exceeds the total uncompressed-size limit", {
          entry = effective.name,
          actual = total + size,
          limit = pkg._limits.max_total_uncompressed_bytes,
        })
    end
    total = total + size
  end
end

local function publish(pkg, output_path, options)
  local destination_directory = pandoc.path.directory(output_path)
  if destination_directory == "" then destination_directory = "." end
  local reserved = reserve_directory(destination_directory)
  local temporary_path = pandoc.path.join({
    reserved, pandoc.path.filename(output_path),
  })

  local ok, result = pcall(function()
    local archive = pandoc.zip.Archive(archive_entries(pkg))
    maybe_fail(options, "after_archive")
    local archive_bytes = archive:bytestring()
    if #archive_bytes > pkg._limits.max_archive_bytes then
      raise("publication.archive-limit",
        "completed archive exceeds the archive-size limit", {
          actual = #archive_bytes,
          limit = pkg._limits.max_archive_bytes,
        })
    end
    write_bytes(temporary_path, archive_bytes)
    maybe_fail(options, "after_close")
    local verified = require("opc").open_path(
      temporary_path, pkg._limits)
    local expected_names = pkg:_effective_names()
    if #verified.entries ~= #expected_names then
      raise("publication.verification",
        "completed package entry count changed", {
          expected = #expected_names,
          actual = #verified.entries,
        })
    end
    for index, expected in ipairs(expected_names) do
      if verified.entries[index].name ~= expected then
        raise("publication.verification",
          "completed package entry sequence changed", {
            index = index,
            expected = expected,
            actual = verified.entries[index].name,
          })
      end
    end
    maybe_fail(options, "after_verification")
    maybe_fail(options, "before_rename")
    local renamed, rename_error = os.rename(
      temporary_path, output_path)
    if not renamed then
      raise("publication.rename",
        "could not atomically replace the destination package", {
          source = temporary_path,
          destination = output_path,
          detail = rename_error,
        })
    end
    return {
      output_path = output_path,
      entry_count = #verified.entries,
      -- Archive entries that are not parts are dropped, never silently.
      dropped_entries = pkg:ignored_entries(),
    }
  end)

  local cleaned, cleanup_error = pcall(
    pandoc.system.remove_directory, reserved, true)
  if not ok then
    if not cleaned then
      if type(result) == "table" and
          result.docstyle_diagnostic == true then
        result.context.cleanup_path = reserved
        result.context.cleanup_detail = tostring(cleanup_error)
      else
        raise("internal.lua-error", tostring(result), {
          cleanup_path = reserved,
          cleanup_detail = tostring(cleanup_error),
        })
      end
    end
    error(result, 0)
  end
  if not cleaned then
    raise("publication.cleanup",
      "could not remove reserved temporary directory", {
        path = reserved,
        detail = tostring(cleanup_error),
      })
  end
  return result
end

function M.write_atomic(pkg, output_path, options)
  if type(pkg) ~= "table" or type(pkg.entries) ~= "table" or
      type(pkg._archive_bytes) ~= "string" then
    raise("publication.invalid-package",
      "validated OPC package handle is required", {})
  end
  if type(output_path) ~= "string" or output_path == "" or
      pandoc.path.filename(output_path) == "" then
    raise("publication.invalid-path",
      "destination package path is required", {
        output_path = output_path,
      })
  end
  if options ~= nil and type(options) ~= "table" then
    raise("publication.invalid-options",
      "publication options must be a table", {})
  end
  for name in pairs(options or {}) do
    if name ~= "fail_at" then
      raise("publication.invalid-options",
        "unknown publication option", {
          option = name,
        })
    end
  end
  if options and options.fail_at ~= nil and
      not FAILURE_POINTS[options.fail_at] then
    raise("publication.invalid-options",
      "unknown publication failure-injection point", {
        fail_at = options.fail_at,
      })
  end
  validate_output_sizes(pkg)
  return publish(pkg, output_path, options)
end

return M
