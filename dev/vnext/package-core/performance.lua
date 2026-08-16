-- WP2 package-core reference performance benchmark (Task 8).
--
-- Ports the reference-measurement mechanics from the frozen spike
-- (tests/vnext/xml-spike/tests/test-performance.lua's measure_reference,
-- read-only reference -- do not edit that file or anything else under
-- tests/vnext/xml-spike/ or dev/vnext/xml-spike/): 1 warm-up + 5
-- repetitions per size, median of combined CPU seconds via
-- pandoc.system.cputime, retained heap sampled as
-- max(0, collectgarbage("count") - init) * 1024 after a collection at each
-- phase boundary, and golden-coordinate WordprocessingML-shaped fixtures at
-- 1/5/10 MiB. This script measures the PRODUCTION xml module
-- (_extensions/docstyle/vnext/package-core/xml), not the spike candidate.
--
-- Usage:
--   quarto run dev/vnext/package-core/performance.lua \
--     > dev/vnext/package-core/performance-results.json
--
-- Stdout is exactly the JSON result (print(pandoc.json.encode(result))).
-- All human-readable output -- the advisory CPU line, an approved-limit
-- latency warning if unmet, and the known-limitations note -- goes to
-- stderr, so redirecting stdout produces a clean JSON file. No wall-clock
-- calls are used for measurement (only pandoc.system.cputime), and the
-- result carries no timestamp, so re-runs on the same machine produce
-- comparable files.

local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({ here, "..", "..", ".." }))
local core_dir = root .. "/_extensions/docstyle/vnext/package-core"

-- Mirror part-size-survey.lua's package.path pattern: point straight at the
-- production core so this benchmark measures the real seam, not a copy.
package.path = table.concat({
  core_dir .. "/?.lua",
  core_dir .. "/?/init.lua",
}, ";")

local xml = require("xml")

local MIB = 1024 * 1024
local W_NS =
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
local TARGET_ATTRIBUTE_VALUE = "00000001"
local REPLACEMENT_ATTRIBUTE_VALUE = "0000000A"
local WARMUPS = 1
local REPETITIONS = 5
-- Every xml.parse call in this benchmark passes this override. The Task 5
-- production default (xml.MAX_INPUT_BYTES) is 1,048,576 bytes and would
-- reject the 5 MiB and 10 MiB scaling cases before they could be measured.
local PARSE_LIMIT_OVERRIDE = 16 * MIB

local PREFIX = table.concat({
  '<?xml version="1.0" encoding="UTF-8"?>',
  '<w:document xmlns:w="',
  W_NS,
  '" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"',
  ' xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"',
  ' mc:Ignorable="w14"><w:body>',
})
local TARGET_OPEN_PREFIX = '<w:p w:rsidR="'
local TARGET_OPEN_SUFFIX =
  '" w14:paraId="00000001">' ..
  '<w:r w:rsidRPr="00000001"><w:t xml:space="preserve">'
local TARGET_TEXT = "Docstyle Task 8 reference-performance target"
local TARGET_CLOSE = '</w:t></w:r></w:p>'
local FILLER_OPEN =
  '<w:p w:rsidR="00000002" w14:paraId="00000002">' ..
  '<w:r w:rsidRPr="00000002"><w:t xml:space="preserve">'
local FILLER_CLOSE = '</w:t></w:r></w:p>'
local SUFFIX = '</w:body></w:document>'

-- Generates a WordprocessingML-shaped part scaled by element/attribute
-- count (many ordinary-size elements and attributes), never by a single
-- large attribute value. See the known_limitations entry below: the
-- vendored LuaXML backend is O(n^2) on one large attribute value, so a
-- benchmark fixture built that way would measure a pre-existing backend
-- pathology unrelated to ordinary WordprocessingML shape or to the
-- input-byte limit this benchmark exists to characterize.
local function generate_scaling_fixture(size_mib)
  assert(size_mib == 1 or size_mib == 5 or size_mib == 10,
    "scaling size must be one, five or 10 MiB")
  local target_bytes = size_mib * MIB
  local parts, length = {}, 0
  local function append(bytes)
    parts[#parts + 1] = bytes
    length = length + #bytes
  end

  append(PREFIX)
  append(TARGET_OPEN_PREFIX)
  local golden_range = { start = length }
  append(TARGET_ATTRIBUTE_VALUE)
  golden_range.finish = length
  append(TARGET_OPEN_SUFFIX)
  append(TARGET_TEXT)
  append(TARGET_CLOSE)

  local fragment_count = size_mib * 64
  local remaining = target_bytes - length - #SUFFIX
  local markup_bytes =
    fragment_count * (#FILLER_OPEN + #FILLER_CLOSE)
  local payload_bytes = remaining - markup_bytes
  assert(payload_bytes >= fragment_count,
    "scaling fixture lacks room for representative fragments")
  local base_payload = payload_bytes // fragment_count
  local extra_payload = payload_bytes % fragment_count
  for index = 1, fragment_count do
    append(FILLER_OPEN)
    append(string.rep("x",
      base_payload + (index <= extra_payload and 1 or 0)))
    append(FILLER_CLOSE)
  end
  append(SUFFIX)
  assert(length == target_bytes,
    "scaling fixture size differs from its byte budget")

  return {
    bytes = table.concat(parts),
    size_mib = size_mib,
    size_bytes = target_bytes,
    golden_range = golden_range,
  }
end

local function assert_range(actual, expected)
  assert(type(actual) == "table" and
    actual.start == expected.start and
    actual.finish == expected.finish,
    "production adapter edit range differs from generator coordinates")
end

local function measure_once(generated)
  collectgarbage("collect")
  local initial_kib = collectgarbage("count")
  local maximum_kib = initial_kib
  local function observe_retained_heap()
    collectgarbage("collect")
    maximum_kib = math.max(maximum_kib, collectgarbage("count"))
  end

  local parse_started = pandoc.system.cputime()
  local document = xml.parse(generated.bytes,
    { max_input_bytes = PARSE_LIMIT_OVERRIDE })
  local parse_picoseconds =
    pandoc.system.cputime() - parse_started
  observe_retained_heap()

  local edit_started = pandoc.system.cputime()
  local targets = xml.find_all(document, W_NS, "p")
  xml.set_attribute(assert(targets[1]),
    W_NS, "rsidR", REPLACEMENT_ATTRIBUTE_VALUE)
  local edit_picoseconds =
    pandoc.system.cputime() - edit_started
  observe_retained_heap()

  local serialization_started = pandoc.system.cputime()
  local edited, ranges = xml.serialize(document)
  local serialization_picoseconds =
    pandoc.system.cputime() - serialization_started
  assert(#ranges == 1)
  assert_range(ranges[1], generated.golden_range)
  observe_retained_heap()

  return {
    parse_cpu_seconds = parse_picoseconds / 1e12,
    edit_cpu_seconds = edit_picoseconds / 1e12,
    serialization_cpu_seconds = serialization_picoseconds / 1e12,
    combined_cpu_seconds = (
      parse_picoseconds +
      edit_picoseconds +
      serialization_picoseconds
    ) / 1e12,
    retained_lua_heap_delta_bytes =
      math.max(0, maximum_kib - initial_kib) * 1024,
    edited_bytes = #edited,
    reported_range = ranges[1],
  }
end

local function median(values)
  local ordered = {}
  for index, value in ipairs(values) do ordered[index] = value end
  table.sort(ordered)
  return ordered[(#ordered + 1) // 2]
end

local function measure_size(size_mib)
  local generated = generate_scaling_fixture(size_mib)
  for _ = 1, WARMUPS do measure_once(generated) end

  local repetitions = {}
  local combined = {}
  local maximum_retained = 0
  local maximum_combined = 0
  for index = 1, REPETITIONS do
    local row = measure_once(generated)
    repetitions[index] = row
    combined[index] = row.combined_cpu_seconds
    maximum_retained = math.max(
      maximum_retained, row.retained_lua_heap_delta_bytes)
    maximum_combined = math.max(maximum_combined, row.combined_cpu_seconds)
  end
  return {
    input_mib = size_mib,
    input_bytes = generated.size_bytes,
    golden_range = generated.golden_range,
    warmups = WARMUPS,
    repetitions = repetitions,
    median_combined_cpu_seconds = median(combined),
    maximum_combined_cpu_seconds = maximum_combined,
    maximum_retained_lua_heap_delta_bytes = maximum_retained,
  }
end

local function measure_reference()
  local rows = {
    measure_size(1),
    measure_size(5),
    measure_size(10),
  }
  local one, ten = rows[1], rows[3]
  assert(one.input_bytes == MIB,
    "the 1 MiB fixture must be exactly the approved 1,048,576-byte limit")
  assert(ten.input_bytes == 10 * MIB)

  local ten_mib_cpu = {
    actual = ten.median_combined_cpu_seconds,
    limit = 5,
    pass = ten.median_combined_cpu_seconds <= 5,
  }
  local ten_mib_retained_heap = {
    actual = ten.maximum_retained_lua_heap_delta_bytes,
    limit = 12 * ten.input_bytes,
    pass = ten.maximum_retained_lua_heap_delta_bytes <=
      12 * ten.input_bytes,
  }
  local ten_to_one_mib_cpu = {
    one_mib = one.median_combined_cpu_seconds,
    ten_mib = ten.median_combined_cpu_seconds,
    limit_multiple = 15,
    pass = ten.median_combined_cpu_seconds <=
      15 * one.median_combined_cpu_seconds,
  }
  local ten_to_one_mib_retained_heap = {
    one_mib = one.maximum_retained_lua_heap_delta_bytes,
    ten_mib = ten.maximum_retained_lua_heap_delta_bytes,
    limit_multiple = 15,
    pass = ten.maximum_retained_lua_heap_delta_bytes <=
      15 * one.maximum_retained_lua_heap_delta_bytes,
  }

  -- decision reflects the hard gates only: the 5-second absolute CPU line
  -- is advisory and is reported (below, and on stderr) but never asserted.
  local decision =
    (ten_mib_retained_heap.pass and ten_to_one_mib_cpu.pass and
     ten_to_one_mib_retained_heap.pass) and "pass" or "fail"

  return {
    schema_version = 1,
    runtime = {
      quarto = "1.9.26",
      pandoc = tostring(PANDOC_VERSION),
      lua = _VERSION,
      os = pandoc.system.os,
      arch = pandoc.system.arch,
    },
    protocol = {
      fixture_sizes_mib = { 1, 5, 10 },
      warmups_per_size = WARMUPS,
      repetitions_per_size = REPETITIONS,
      clock =
        "pandoc.system.cputime picoseconds converted to seconds",
      phases = {
        "parse",
        "one existing-attribute edit",
        "serialization",
      },
      memory_metric =
        "retained Lua heap after collection, not peak memory",
      parse_limit_override_bytes = PARSE_LIMIT_OVERRIDE,
      subject = "production xml module " ..
        "(_extensions/docstyle/vnext/package-core/xml), not the spike " ..
        "candidate",
    },
    sizes = rows,
    gates = {
      hard = {
        ten_mib_retained_heap_multiple_at_most = 12,
        ten_to_one_mib_cpu_ratio_at_most = 15,
        ten_to_one_mib_retained_heap_ratio_at_most = 15,
      },
      advisory = {
        ten_mib_cpu_seconds_at_most = 5,
      },
    },
    advisory_results = {
      ten_mib_cpu = ten_mib_cpu,
    },
    binding_gate_results = {
      ten_mib_retained_heap = ten_mib_retained_heap,
      ten_to_one_mib_cpu = ten_to_one_mib_cpu,
      ten_to_one_mib_retained_heap = ten_to_one_mib_retained_heap,
    },
    decision = decision,
    approved_limit_latency = {
      limit_bytes = 1048576,
      observed_median_seconds = one.median_combined_cpu_seconds,
      observed_maximum_seconds = one.maximum_combined_cpu_seconds,
      expectation_seconds = 0.75,
      met = one.maximum_combined_cpu_seconds <= 0.75,
    },
    known_limitations = {
      {
        id = "luaxml-quadratic-single-attribute-value",
        note = "The vendored LuaXML backend parses a single large " ..
          "attribute value in quadratic time (recorded during Task 5: " ..
          "an 80,000-byte attribute value took ~71 seconds, scaling as " ..
          "size^2; independent review probes at 5k-40k confirmed the " ..
          "quadratic shape -- see the WP2 plan ledger). The XML-part " ..
          "input-byte limit bounds bytes, not CPU: an adversarial " ..
          "sub-limit part with one large attribute value remains a " ..
          "CPU-exhaustion risk. Tracked follow-up planned.",
      },
    },
  }
end

local result = measure_reference()

io.stderr:write(
  ("ADVISORY reference 10 MiB combined CPU: actual=%.6f s | target=5 s | met=%s\n")
    :format(result.advisory_results.ten_mib_cpu.actual,
      tostring(result.advisory_results.ten_mib_cpu.pass)))

if not result.approved_limit_latency.met then
  io.stderr:write(
    ("WARNING approved-limit latency target unmet: " ..
      "observed_maximum=%.6f s > expectation=%.3f s at %d bytes\n")
      :format(result.approved_limit_latency.observed_maximum_seconds,
        result.approved_limit_latency.expectation_seconds,
        result.approved_limit_latency.limit_bytes))
end

for _, limitation in ipairs(result.known_limitations) do
  io.stderr:write(
    ("NOTE known limitation recorded: %s\n"):format(limitation.id))
end

print(pandoc.json.encode(result))
