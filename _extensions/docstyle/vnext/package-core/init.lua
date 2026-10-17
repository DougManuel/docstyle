-- Docstyle vNext package core: the only public surface.
-- Feature modules and the machine interface require this file, never internals.
local opc = require("opc")
return {
  open = opc.open_path,
  xml = require("xml"),
  diagnostic = require("lib.diagnostic"),
}
