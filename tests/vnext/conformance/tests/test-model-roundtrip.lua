local json = require("lib.json")
local c = require("lib.canonical")
local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local p = pandoc.path.join({ here, "..", "..", "..",
  "schemas", "examples", "document-model.v1", "valid-full-coverage.json" })
return {
  { name = "model round-trips decode-encode-decode without loss", fn = function()
      local m1 = json.read(p)
      local m2 = json.decode(json.encode(m1))
      assert(c.encode(m1) == c.encode(m2), "canonical forms differ after round trip")
    end },
}
