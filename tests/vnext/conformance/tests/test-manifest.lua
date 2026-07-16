local m = require("lib.manifest")
local json = require("lib.json")

-- Helper: find the physical filename manifest.json records for a given
-- logical name, e.g. physical_of(man, "regions.json") == "regions.2.json".
local function physical_of(man, logical_name)
  for _, entry in ipairs(man.files) do
    if entry.name == logical_name then return entry.file, entry end
  end
  error("no manifest entry named " .. logical_name)
end

return {
  { name = "commit writes manifest and generation-qualified typed files atomically", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local g1 = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(g1 == 1)
        local man = assert(m.read(dir))
        assert(man.generation == 1 and #man.stateId == 32 and man.files[1].name == "regions.json")
        local phys1 = physical_of(man, "regions.json")
        assert(phys1 == "regions.1.json", "expected a generation-qualified physical name, got " .. tostring(phys1))

        local g2 = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(g2 == 2 and m.read(dir).stateId == man.stateId, "stateId must persist")
        local man2 = assert(m.read(dir))
        local phys2 = physical_of(man2, "regions.json")
        assert(phys2 == "regions.2.json", "expected the new generation's own physical file, got " .. tostring(phys2))
      end)
    end },

  { name = "interrupted commit before any rename leaves previous generation readable", fn = function()
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

  -- The interruption window this generation-qualified design actually
  -- creates, and which a shared-physical-filename design's test could miss
  -- entirely: the new generation's typed files are already renamed to their
  -- final physical names on disk (harmless orphans -- no manifest points at
  -- them yet) when the crash happens, strictly before the manifest itself
  -- is repointed. read() must still cleanly return the PRIOR generation.
  { name = "interrupted commit after typed-file renames but before manifest rename leaves previous generation readable", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local okflag = pcall(m.commit, dir,
          { ["regions.json"] = { schemaVersion = 1, regions = { { id = "x" } } } },
          { fail_before_manifest_rename = true })
        assert(not okflag, "injected failure must raise")

        -- the new generation's physical file DOES exist on disk (orphaned,
        -- not yet referenced by any manifest)...
        local f = io.open(dir .. "/regions.2.json", "rb")
        assert(f ~= nil, "expected the orphaned gen-2 typed file to exist on disk")
        f:close()

        -- ...but manifest.json was never repointed, so read() must return
        -- the prior generation cleanly, not the orphan.
        local man = assert(m.read(dir))
        assert(man.generation == 1, "old generation must survive")
        assert(physical_of(man, "regions.json") == "regions.1.json")
      end)
    end },

  { name = "resume after an interrupted commit succeeds, preserves stateId, advances generation", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local man0 = assert(m.read(dir))
        pcall(m.commit, dir,
          { ["regions.json"] = { schemaVersion = 1, regions = { { id = "x" } } } },
          { fail_before_manifest_rename = true })

        local g = m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = { { id = "y" } } } })
        assert(g == 2, "generation must advance from the last COMMITTED generation (1), not the orphaned attempt")
        local man = assert(m.read(dir))
        assert(man.stateId == man0.stateId, "stateId must persist across the interrupted attempt")
        assert(man.generation == 2)
        assert(physical_of(man, "regions.json") == "regions.2.json")
      end)
    end },

  { name = "multi-file commit references the right generation-qualified files across generations", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, {
          ["regions.json"] = { schemaVersion = 1, regions = {} },
          ["citations.json"] = { schemaVersion = 1, citations = {} },
        })
        local man1 = assert(m.read(dir))
        assert(physical_of(man1, "regions.json") == "regions.1.json")
        assert(physical_of(man1, "citations.json") == "citations.1.json")

        -- second generation drops citations.json and changes regions.json
        m.commit(dir, {
          ["regions.json"] = { schemaVersion = 1, regions = { { id = "z" } } },
        })
        local man2 = assert(m.read(dir))
        assert(#man2.files == 1 and man2.files[1].name == "regions.json",
          "citations.json must no longer be part of the manifest once it drops out of a commit")
        assert(physical_of(man2, "regions.json") == "regions.2.json")
        assert(man2.generation == 2)
      end)
    end },

  { name = "hash mismatch is reported on read", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local man = assert(m.read(dir))
        local phys = physical_of(man, "regions.json")
        local f = assert(io.open(dir .. "/" .. phys, "wb"))
        f:write('{"schemaVersion":1,"regions":[{"tampered":true}]}'); f:close()
        local man2, errs = m.read(dir)
        assert(man2 == nil and errs[1]:match("regions.json"), "expected stale-file error")
      end)
    end },

  { name = "corrupt manifest.json (present but unparseable) fails closed rather than starting a fresh lineage", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local f = assert(io.open(dir .. "/manifest.json", "wb"))
        f:write("{not valid json"); f:close()
        local okflag = pcall(m.read, dir)
        assert(not okflag, "expected m.read to raise on an unparseable manifest.json")
        local okflag2 = pcall(m.commit, dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(not okflag2, "expected m.commit to raise rather than silently start a fresh lineage")
      end)
    end },

  { name = "manifest.json present but missing stateId/generation fails closed", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local f = assert(io.open(dir .. "/manifest.json", "wb"))
        f:write('{"schemaVersion":1,"files":[]}'); f:close()
        local okflag = pcall(m.commit, dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        assert(not okflag, "expected m.commit to raise on a manifest missing stateId/generation")
      end)
    end },

  { name = "commit rejects a logical file name outside the path-containment allowlist", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local okflag = pcall(m.commit, dir, { ["../evil.json"] = { schemaVersion = 1 } })
        assert(not okflag, "expected commit to reject a name containing ..")
        local okflag2 = pcall(m.commit, dir, { ["sub/dir.json"] = { schemaVersion = 1 } })
        assert(not okflag2, "expected commit to reject a name containing a path separator")
        local okflag3 = pcall(m.commit, dir, { ["/etc/passwd.json"] = { schemaVersion = 1 } })
        assert(not okflag3, "expected commit to reject an absolute-path name")
      end)
    end },

  { name = "read rejects a manifest entry whose physical file fails the containment allowlist", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local raw = assert(io.open(dir .. "/manifest.json", "rb"))
        local bytes = raw:read("a"); raw:close()
        local manifest = json.decode(bytes)
        manifest.files[1].file = "../../etc/passwd"
        local out = assert(io.open(dir .. "/manifest.json", "wb"))
        out:write(json.encode(manifest)); out:close()
        -- A traversal path in an entry is manifest-structure corruption:
        -- since full contract validation, corrupt structure RAISES (the
        -- nil+errors channel is reserved for a well-formed manifest whose
        -- referenced files are missing or stale on disk).
        assert(not pcall(m.read, dir),
          "expected read to raise on a manifest entry with a path-traversal file name")
      end)
    end },

  -- Full manifest-contract validation at BOTH boundaries (read and the
  -- read_raw commit() uses to establish lineage): a structurally invalid
  -- manifest must raise, not be partially accepted.
  { name = "manifest with its files collection removed fails closed on read and commit", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local raw = assert(io.open(dir .. "/manifest.json", "rb"))
        local manifest = json.decode(raw:read("a")); raw:close()
        manifest.files = nil
        local out = assert(io.open(dir .. "/manifest.json", "wb"))
        out:write(json.encode(manifest)); out:close()
        assert(not pcall(m.read, dir), "read must raise on a manifest missing its files collection")
        assert(not pcall(m.commit, dir, { ["regions.json"] = { schemaVersion = 1 } }),
          "commit must raise rather than build a new lineage on a files-less manifest")
      end)
    end },
  { name = "manifest whose generation disagrees with its entries' physical files fails closed", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local raw = assert(io.open(dir .. "/manifest.json", "rb"))
        local manifest = json.decode(raw:read("a")); raw:close()
        manifest.generation = 2 -- entries still point at regions.1.json
        local out = assert(io.open(dir .. "/manifest.json", "wb"))
        out:write(json.encode(manifest)); out:close()
        assert(not pcall(m.read, dir),
          "read must raise when entry.file does not equal physical_name(entry.name, generation)")
        assert(not pcall(m.commit, dir, { ["regions.json"] = { schemaVersion = 1 } }),
          "commit must raise on the same generation/file mismatch")
      end)
    end },
  { name = "manifest with duplicate logical names fails closed", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local raw = assert(io.open(dir .. "/manifest.json", "rb"))
        local manifest = json.decode(raw:read("a")); raw:close()
        manifest.files[2] = manifest.files[1]
        local out = assert(io.open(dir .. "/manifest.json", "wb"))
        out:write(json.encode(manifest)); out:close()
        assert(not pcall(m.read, dir), "read must raise on duplicate logical names")
      end)
    end },
  { name = "manifest entry whose schema id disagrees with its logical store fails closed", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        m.commit(dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        local raw = assert(io.open(dir .. "/manifest.json", "rb"))
        local manifest = json.decode(raw:read("a")); raw:close()
        manifest.files[1].schema = "https://dougmanuel.github.io/docstyle/schemas/state-citations.v1.json"
        local out = assert(io.open(dir .. "/manifest.json", "wb"))
        out:write(json.encode(manifest)); out:close()
        assert(not pcall(m.read, dir), "read must raise when an entry's schema id does not match its logical store")
      end)
    end },
  { name = "commit rejects an empty files batch", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        assert(not pcall(m.commit, dir, {}),
          "a commit with nothing to commit is a caller bug and must raise")
      end)
    end },

  { name = "commit raises when a typed-file write fails (checked writes)", fn = function()
      pandoc.system.with_temporary_directory("wp1state", function(dir)
        local real_open = io.open
        io.open = function(path, mode)
          if mode == "wb" and path:match("regions%.%d+%.json%.tmp$") then
            local stub = {}
            function stub:write(_) return nil, "simulated disk full" end
            function stub:close() return true end
            return stub
          end
          return real_open(path, mode)
        end
        local okflag = pcall(m.commit, dir, { ["regions.json"] = { schemaVersion = 1, regions = {} } })
        io.open = real_open
        assert(not okflag, "expected commit to raise when a typed-file write fails")
        local man = m.read(dir)
        assert(man == nil, "no manifest should have been committed after a failed typed-file write")
      end)
    end },
}
