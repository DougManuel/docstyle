local diagnostic = require("lib.diagnostic")
local libdeflate = require("archive.vendor.libdeflate.LibDeflate")

local M = {}

local STATUS = {
  [-1] = {
    code = "deflate.invalid-block-type",
    message = "raw DEFLATE stream uses the reserved block type",
  },
  [-2] = {
    code = "deflate.invalid-stored-block",
    message = "stored DEFLATE block length complement is invalid",
  },
  [-11] = {
    code = "deflate.invalid-distance",
    message = "DEFLATE back-reference exceeds produced history",
  },
  [-101] = {
    code = "deflate.trailing-data",
    message = "raw DEFLATE stream has trailing bytes",
  },
  [2] = {
    code = "deflate.truncated",
    message = "raw DEFLATE stream ended before the final block completed",
  },
}

local function raise_status(status, limit, produced)
  if status == -100 then
    diagnostic.raise("zip.output-limit",
      "expanded entry would exceed its output byte limit", {
        limit = limit,
        produced = produced,
      })
  end
  local row = STATUS[status]
  if not row and status <= -3 and status >= -10 then
    row = {
      code = "deflate.invalid-huffman",
      message = "DEFLATE Huffman description or code is invalid",
    }
  end
  row = row or {
    code = "deflate.invalid-stream",
    message = "raw DEFLATE stream is invalid",
  }
  diagnostic.raise(row.code, row.message, {
    status = status,
    produced = produced,
  })
end

function M.inflate_raw(compressed, limit, emit)
  if type(compressed) ~= "string" then
    diagnostic.raise("deflate.invalid-input",
      "compressed input must be a byte string", {})
  end
  if math.type(limit) ~= "integer" or limit < 0 then
    diagnostic.raise("zip.invalid-limits",
      "DEFLATE output limit must be a non-negative integer", {
        limit = limit,
      })
  end
  if emit ~= nil and type(emit) ~= "function" then
    diagnostic.raise("deflate.invalid-sink",
      "DEFLATE output sink must be a function", {})
  end

  local output, status, produced =
    libdeflate:DecompressDeflateLimited(compressed, limit, emit)
  if status ~= 0 then raise_status(status, limit, produced) end
  return output, produced
end

return M
