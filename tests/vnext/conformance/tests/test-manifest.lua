local m = require("lib.manifest")
local json = require("lib.json")
return {
  { name = "commit writes manifest and typed files atomically", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local g1 = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(g1 == 1)
        local man = assert(m.read(dir))
        assert(man.generation == 1 and #man.stateId == 32 and man.files[1].name == "regions.json")
        local g2 = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(g2 == 2 and m.read(dir).stateId == man.stateId, "stateId must persist")
      end)
    end },
  { name = "interrupted commit leaves previous generation readable", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local okflag = pcall(m.commit, dir,
          { ["regions.json"] = { schemaVersion = 1, regions = { { id = "x" } } } },
          { fail_before_rename = true })
        assert(not okflag, "injected failure must raise")
        local man = assert(m.read(dir))
        assert(man.generation == 1, "old generation must survive")
      end)
    end },
  { name = "hash mismatch is reported on read", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local f = assert(io.open(dir .. "/regions.json", "wb"))
        f:write('{"schemaVersion":1,"regions":[{"tampered":true}]}'); f:close()
        local man, errs = m.read(dir)
        assert(man == nil and errs[1]:match("regions.json"), "expected stale-file error")
      end)
    end },
}
