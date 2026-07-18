local M = {}

function M.read_bytes(path)
  local handle, err = io.open(path, "rb")
  assert(handle, err)
  local bytes = handle:read("a")
  handle:close()
  return bytes
end

function M.write_bytes(path, bytes)
  assert(type(bytes) == "string", "fixture bytes must be a string")
  local handle, err = io.open(path, "wb")
  assert(handle, err)
  local ok, write_err = handle:write(bytes)
  local close_ok, close_err = handle:close()
  assert(ok, write_err)
  assert(close_ok, close_err)
end

function M.exists(path)
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
    return true
  end
  return pcall(pandoc.system.list_directory, path)
end

function M.with_temp_dir(prefix, fn)
  assert(type(prefix) == "string" and prefix ~= "", "temporary prefix is required")
  assert(type(fn) == "function", "temporary callback is required")
  return pandoc.system.with_temporary_directory("docstyle-wp2-" .. prefix, fn)
end

return M
