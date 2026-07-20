local harness = require("lib.harness")
local fixture = require("lib.fixture")
local diagnostic = require("lib.diagnostic")

local function expect_error(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok, "expected function to fail")
  assert(tostring(err):match(pattern),
    "expected error matching " .. pattern .. ", got " .. tostring(err))
end

return {
  {
    name = "diagnostic capture preserves stable code and context",
    gate = "archive",
    stage = "archive",
    fn = function()
      local ok, err = diagnostic.capture(function()
        diagnostic.raise("zip.truncated", "short header", {
          entry = "word/document.xml",
          offset = 17,
        })
      end)
      assert(not ok)
      assert(err.docstyle_diagnostic == true)
      assert(err.code == "zip.truncated")
      assert(err.message == "short header")
      assert(err.context.entry == "word/document.xml")
      assert(err.context.offset == 17)
    end,
  },
  {
    name = "diagnostic capture wraps ordinary Lua errors",
    gate = "archive",
    stage = "archive",
    fn = function()
      local ok, err = diagnostic.capture(function()
        error("plain failure")
      end)
      assert(not ok)
      assert(err.docstyle_diagnostic == true)
      assert(err.code == "internal.lua-error")
      assert(err.message:match("plain failure"))
      assert(type(err.context) == "table")
    end,
  },
  {
    name = "registry runs cases in stable alphabetical order",
    gate = "archive",
    stage = "archive",
    fn = function()
      local registry = harness.new()
      local observed = {}
      registry:case("archive/order", "z-last", function()
        observed[#observed + 1] = "z"
      end, { gate = "archive", stage = "archive" })
      registry:case("archive/order", "a-first", function()
        observed[#observed + 1] = "a"
      end, { gate = "archive", stage = "archive" })

      local summary = registry:run("archive", { quiet = true })
      assert(table.concat(observed, ",") == "a,z")
      assert(summary.pass == 2 and summary.fail == 0 and summary.skip == 0)
    end,
  },
  {
    name = "runner options default to all stages without reference thresholds",
    gate = "archive",
    stage = "archive",
    fn = function()
      local stage, options = harness.runner_options(function() return nil end)
      assert(stage == "all")
      assert(options.reference_performance == false)
    end,
  },
  {
    name = "runner options read namespaced environment values",
    gate = "archive",
    stage = "archive",
    fn = function()
      local values = {
        DOCSTYLE_SPIKE_STAGE = "archive",
        DOCSTYLE_SPIKE_REFERENCE_PERFORMANCE = "1",
      }
      local stage, options = harness.runner_options(function(name)
        return values[name]
      end)
      assert(stage == "archive")
      assert(options.reference_performance == true)
    end,
  },
  {
    name = "registry rejects duplicate full case names",
    gate = "archive",
    stage = "archive",
    fn = function()
      local registry = harness.new()
      registry:case("archive/duplicate", "same", function() end,
        { gate = "archive", stage = "archive" })
      expect_error(function()
        registry:case("archive/duplicate", "same", function() end,
          { gate = "archive", stage = "archive" })
      end, "duplicate test case")
    end,
  },
  {
    name = "archive stage filters later work and reports skips",
    gate = "archive",
    stage = "archive",
    fn = function()
      local registry = harness.new()
      local observed = {}
      local function add(stage)
        registry:case(stage .. "/filter", "runs", function()
          observed[#observed + 1] = stage
        end, { gate = "functional", stage = stage })
      end
      add("archive")
      add("xml")
      add("package")
      add("performance")

      local summary = registry:run("archive", { quiet = true })
      assert(table.concat(observed, ",") == "archive")
      assert(summary.pass == 1 and summary.fail == 0 and summary.skip == 3)
      assert(summary.gates.functional.pass == 1)
      assert(summary.gates.functional.skip == 3)
    end,
  },
  {
    name = "all stage skips reference performance unless enabled",
    gate = "archive",
    stage = "archive",
    fn = function()
      local registry = harness.new()
      local count = 0
      registry:case("performance/reference", "threshold", function()
        count = count + 1
      end, {
        gate = "performance",
        stage = "performance",
        reference_only = true,
      })

      local ordinary = registry:run("all", { quiet = true })
      assert(count == 0)
      assert(ordinary.skip == 1)

      local reference = registry:run("all", {
        quiet = true,
        reference_performance = true,
      })
      assert(count == 1)
      assert(reference.pass == 1 and reference.skip == 0)
    end,
  },
  {
    name = "all six gate summaries are always present",
    gate = "archive",
    stage = "archive",
    fn = function()
      local summary = harness.new():run("archive", { quiet = true })
      local expected = {
        "archive", "functional", "preservation",
        "safety", "determinism", "performance",
      }
      for _, gate in ipairs(expected) do
        local row = assert(summary.gates[gate], "missing gate " .. gate)
        assert(row.pass == 0 and row.fail == 0 and row.skip == 0)
      end
    end,
  },
  {
    name = "registry returns machine-readable candidate evidence",
    gate = "archive",
    stage = "archive",
    fn = function()
      local registry = harness.new()
      registry:result("slaxml", {
        candidate = "SLAXML",
        dependency_count = 1,
      })
      local summary = registry:run("archive", { quiet = true })
      assert(summary.results.slaxml.candidate == "SLAXML")
      assert(summary.results.slaxml.dependency_count == 1)
    end,
  },
  {
    name = "failed case produces non-success summary and assertion",
    gate = "archive",
    stage = "archive",
    fn = function()
      local registry = harness.new()
      registry:case("archive/failure", "expected", function()
        error("deliberate")
      end, { gate = "safety", stage = "archive" })
      local summary = registry:run("archive", { quiet = true })
      assert(summary.fail == 1 and summary.pass == 0)
      assert(summary.gates.safety.fail == 1)
      expect_error(function()
        harness.assert_success(summary)
      end, "spike failures: 1")
    end,
  },
  {
    name = "zero discovery is a hard failure",
    gate = "archive",
    stage = "archive",
    fn = function()
      expect_error(function()
        harness.assert_discovery(0)
      end, "zero test cases discovered")
    end,
  },
  {
    name = "fixture helper preserves binary bytes and removes temporary directory",
    gate = "archive",
    stage = "archive",
    fn = function()
      local temp_path
      fixture.with_temp_dir("runner", function(dir)
        temp_path = dir
        local path = pandoc.path.join({ dir, "bytes.bin" })
        fixture.write_bytes(path, "a\0b\255")
        assert(fixture.read_bytes(path) == "a\0b\255")
        assert(fixture.exists(path))
      end)
      assert(not fixture.exists(temp_path))
    end,
  },
  {
    name = "provenance records the pinned runtime without unresolved markers",
    gate = "archive",
    stage = "archive",
    fn = function()
      local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
      local root = pandoc.path.normalize(pandoc.path.join({
        here, "..", "..", "..",
      }))
      local path = pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "provenance.json",
      })
      local bytes = fixture.read_bytes(path)
      assert(not bytes:match("TB[D]"))
      assert(not bytes:match("TO[D]"))
      assert(not bytes:match("PLACEHOLDE[R]"))

      local value = pandoc.json.decode(bytes, false)
      assert(value.runtime.quarto == "1.9.26")
      assert(value.runtime.pandoc == "3.8.3")
      assert(value.runtime.lua == "Lua 5.4")
      assert(value.runtime.os == pandoc.system.os)
      assert(value.runtime.arch == pandoc.system.arch,
        "expected " .. tostring(pandoc.system.arch) ..
        ", got " .. tostring(value.runtime.arch))
      assert(type(value.candidates) == "table")
      assert(type(value.fixtures) == "table")
      assert(type(value.local_modifications) == "table")
    end,
  },
  {
    name = "provenance hashes match the vendored source and licence",
    gate = "safety",
    stage = "archive",
    fn = function()
      local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
      local root = pandoc.path.normalize(pandoc.path.join({
        here, "..", "..", "..",
      }))
      local provenance_path = pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "provenance.json",
      })
      local provenance = pandoc.json.decode(
        fixture.read_bytes(provenance_path), false)
      local libdeflate
      for _, candidate in ipairs(provenance.candidates) do
        if candidate.name == "LibDeflate" then libdeflate = candidate end
      end
      assert(libdeflate, "LibDeflate provenance record is required")

      local sha256 = dofile(pandoc.path.join({
        root, "tests", "vnext", "conformance", "lib", "sha256.lua",
      }))
      local vendor_root = pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "archive", "vendor", "libdeflate",
      })
      local source_hash = sha256.hex(fixture.read_bytes(
        pandoc.path.join({ vendor_root, "LibDeflate.lua" })))
      local licence_hash = sha256.hex(fixture.read_bytes(
        pandoc.path.join({ vendor_root, "LICENSE.txt" })))

      assert(source_hash == libdeflate.vendored_source_sha256,
        "vendored LibDeflate source hash does not match provenance")
      assert(licence_hash == libdeflate.vendored_license_sha256,
        "vendored LibDeflate licence hash does not match provenance")
    end,
  },
}
