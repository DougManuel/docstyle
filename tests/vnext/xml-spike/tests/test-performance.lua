local adapter = require("candidates.luaxml.adapter")
local fixture = require("lib.fixture")
local oracle = require("candidates.oracle")

local MIB = 1024 * 1024
local W_NS =
  "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
local TARGET_ATTRIBUTE_VALUE = "00000001"
local REPLACEMENT_ATTRIBUTE_VALUE = "0000000A"
local WARMUPS = 1
local REPETITIONS = 5
local runner_here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  runner_here, "..", "..", "..",
}))
local RESULTS = pandoc.path.join({
  root, "dev", "vnext", "xml-spike", "performance-results.json",
})
local PROVENANCE = pandoc.path.join({
  root, "dev", "vnext", "xml-spike", "provenance.json",
})

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
local TARGET_TEXT = "Docstyle Task 9 attribute-edit target"
local TARGET_CLOSE = '</w:t></w:r></w:p>'
local FILLER_OPEN =
  '<w:p w:rsidR="00000002" w14:paraId="00000002">' ..
  '<w:r w:rsidRPr="00000002"><w:t xml:space="preserve">'
local FILLER_CLOSE = '</w:t></w:r></w:p>'
local SUFFIX = '</w:body></w:document>'

local function pipe_trim(command, arguments)
  local output = pandoc.pipe(command, arguments, "")
  return output:match("^%s*(.-)%s*$")
end

local function query_reference_environment()
  assert(pandoc.system.os == "darwin",
    "reference environment validation requires macOS")
  local profile = pandoc.json.decode(pandoc.pipe(
    "/usr/sbin/system_profiler",
    { "SPHardwareDataType", "-json" }, ""), false)
  local hardware = assert(profile.SPHardwareDataType[1],
    "system_profiler did not return hardware data")
  local processor_cores_text = assert(
    hardware.number_processors:match("^proc%s+(%d+):"),
    "system_profiler processor count has an unexpected form")
  local memory_gib_text = assert(
    hardware.physical_memory:match("^(%d+)%s+GB$"),
    "system_profiler memory has an unexpected form")
  local processor_cores = tonumber(processor_cores_text)
  local memory_gib = tonumber(memory_gib_text)

  return {
    operating_system =
      pipe_trim("/usr/bin/sw_vers", { "-productName" }) .. " " ..
      pipe_trim("/usr/bin/sw_vers", { "-productVersion" }),
    architecture = pipe_trim("/usr/bin/uname", { "-m" }),
    model_name = hardware.machine_name,
    model_identifier = hardware.machine_model,
    processor = hardware.chip_type,
    processor_cores = processor_cores,
    installed_memory_bytes = memory_gib * 1024 * 1024 * 1024,
  }
end

local function assert_reference_environment_matches_recorded(recorded)
  local queried = query_reference_environment()
  for _, key in ipairs({
    "operating_system",
    "architecture",
    "model_name",
    "model_identifier",
    "processor",
    "processor_cores",
    "installed_memory_bytes",
  }) do
    assert(recorded[key] == queried[key],
      ("recorded reference environment differs for %s: %s ~= %s")
        :format(key, tostring(recorded[key]), tostring(queried[key])))
  end
end

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
    "adapter edit range differs from generator coordinates")
end

local function attribute_change()
  return {
    operation = "attribute",
    element = {
      uri = W_NS,
      local_name = "p",
      occurrence = 1,
    },
    attribute = {
      uri = W_NS,
      local_name = "rsidR",
    },
  }
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
  local document = adapter.parse(generated.bytes)
  local parse_picoseconds =
    pandoc.system.cputime() - parse_started
  observe_retained_heap()

  local edit_started = pandoc.system.cputime()
  local targets = adapter.find_all(document, W_NS, "p")
  adapter.set_attribute(assert(targets[1]),
    W_NS, "rsidR", REPLACEMENT_ATTRIBUTE_VALUE)
  local edit_picoseconds =
    pandoc.system.cputime() - edit_started
  observe_retained_heap()

  local serialization_started = pandoc.system.cputime()
  local edited, ranges = adapter.serialize(document)
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
  for index = 1, REPETITIONS do
    local row = measure_once(generated)
    repetitions[index] = row
    combined[index] = row.combined_cpu_seconds
    maximum_retained = math.max(
      maximum_retained, row.retained_lua_heap_delta_bytes)
  end
  return {
    input_mib = size_mib,
    input_bytes = generated.size_bytes,
    golden_range = generated.golden_range,
    warmups = WARMUPS,
    repetitions = repetitions,
    median_combined_cpu_seconds = median(combined),
    maximum_retained_lua_heap_delta_bytes = maximum_retained,
  }
end

local function measure_reference()
  local rows = {
    measure_size(1),
    measure_size(5),
    measure_size(10),
  }
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
    },
    sizes = rows,
    gates = {
      ten_mib_cpu_seconds_at_most = 5,
      ten_mib_retained_heap_multiple_at_most = 12,
      ten_to_one_mib_cpu_ratio_at_most = 15,
      ten_to_one_mib_retained_heap_ratio_at_most = 15,
    },
  }
end

local function evaluate_reference_gates(result, options)
  options = options or {}
  local one = result.sizes[1]
  local ten = result.sizes[3]
  assert(ten.input_bytes == 10 * MIB)
  local results = {
    ten_mib_cpu = {
      actual = ten.median_combined_cpu_seconds,
      limit = 5,
      pass = ten.median_combined_cpu_seconds <= 5,
    },
    ten_mib_retained_heap = {
      actual = ten.maximum_retained_lua_heap_delta_bytes,
      limit = 12 * ten.input_bytes,
      pass = ten.maximum_retained_lua_heap_delta_bytes <=
        12 * ten.input_bytes,
    },
    ten_to_one_mib_cpu = {
      one_mib = one.median_combined_cpu_seconds,
      ten_mib = ten.median_combined_cpu_seconds,
      limit_multiple = 15,
      pass = ten.median_combined_cpu_seconds <=
        15 * one.median_combined_cpu_seconds,
    },
    ten_to_one_mib_retained_heap = {
      one_mib = one.maximum_retained_lua_heap_delta_bytes,
      ten_mib = ten.maximum_retained_lua_heap_delta_bytes,
      limit_multiple = 15,
      pass = ten.maximum_retained_lua_heap_delta_bytes <=
        15 * one.maximum_retained_lua_heap_delta_bytes,
    },
  }
  local rows
  if options.absolute_cpu_is_advisory then
    result.advisory_results = {
      ten_mib_cpu = results.ten_mib_cpu,
    }
    result.binding_gate_results = {
      ten_mib_retained_heap = results.ten_mib_retained_heap,
      ten_to_one_mib_cpu = results.ten_to_one_mib_cpu,
      ten_to_one_mib_retained_heap =
        results.ten_to_one_mib_retained_heap,
    }
    rows = result.binding_gate_results
  else
    result.gate_results = results
    rows = result.gate_results
  end
  local all_pass = true
  for _, row in pairs(rows) do
    if not row.pass then all_pass = false end
  end
  result.decision = all_pass and "pass" or "fail"
  return all_pass
end

return {
  {
    name = "generator emits exact independent scaling fixtures",
    gate = "functional",
    stage = "performance",
    fn = function()
      for _, size_mib in ipairs({ 1, 5, 10 }) do
        local generated = generate_scaling_fixture(size_mib)
        assert(#generated.bytes == size_mib * MIB)
        assert(generated.bytes:sub(
          generated.golden_range.start + 1,
          generated.golden_range.finish) == TARGET_ATTRIBUTE_VALUE)
        local oracle_range = oracle.find_edit_range(
          oracle.parse(generated.bytes), attribute_change())
        assert_range(oracle_range, generated.golden_range)
      end
    end,
  },
  {
    name = "attribute edit preserves generator coordinates at every size",
    gate = "preservation",
    stage = "performance",
    fn = function()
      for _, size_mib in ipairs({ 1, 5, 10 }) do
        local generated = generate_scaling_fixture(size_mib)
        local document = adapter.parse(generated.bytes)
        local target =
          assert(adapter.find_all(document, W_NS, "p")[1])
        adapter.set_attribute(
          target, W_NS, "rsidR", REPLACEMENT_ATTRIBUTE_VALUE)
        local edited, ranges = adapter.serialize(document)
        assert(#ranges == 1)
        assert_range(ranges[1], generated.golden_range)
        local change = attribute_change()
        change.reported_range = ranges[1]
        change.value = REPLACEMENT_ATTRIBUTE_VALUE
        local verification = oracle.verify_edit(
          generated.bytes, edited, generated.golden_range, change)
        assert(verification.ok == true)
      end
    end,
  },
  {
    name = "recorded reference evidence matches the measurement protocol",
    gate = "performance",
    stage = "performance",
    fn = function()
      local evidence = pandoc.json.decode(
        fixture.read_bytes(RESULTS), false)
      assert(evidence.decision == "fail")
      assert(evidence.runtime.quarto == "1.9.26")
      assert(evidence.runtime.pandoc == tostring(PANDOC_VERSION))
      assert(evidence.runtime.lua == _VERSION)
      assert(evidence.runtime.os == pandoc.system.os)
      assert(evidence.runtime.arch == pandoc.system.arch)
      assert(type(evidence.reference_environment.model_name) == "string")
      assert(type(evidence.reference_environment.processor) == "string")
      assert(evidence.reference_environment.installed_memory_bytes > 0)
      assert(evidence.protocol.warmups_per_size == WARMUPS)
      assert(evidence.protocol.repetitions_per_size == REPETITIONS)
      assert(#evidence.sizes == 3)
      for index, size_mib in ipairs({ 1, 5, 10 }) do
        local generated = generate_scaling_fixture(size_mib)
        local row = evidence.sizes[index]
        assert(row.input_bytes == generated.size_bytes)
        assert_range(row.golden_range, generated.golden_range)
        assert(row.warmups == WARMUPS)
        assert(#row.repetitions == REPETITIONS)
        local combined = {}
        local maximum_retained = 0
        for _, repetition in ipairs(row.repetitions) do
          assert_range(
            repetition.reported_range, generated.golden_range)
          assert(repetition.edited_bytes == generated.size_bytes)
          assert(math.abs(
            repetition.parse_cpu_seconds +
            repetition.edit_cpu_seconds +
            repetition.serialization_cpu_seconds -
            repetition.combined_cpu_seconds) < 1e-12)
          combined[#combined + 1] =
            repetition.combined_cpu_seconds
          maximum_retained = math.max(maximum_retained,
            repetition.retained_lua_heap_delta_bytes)
        end
        assert(row.median_combined_cpu_seconds == median(combined))
        assert(row.maximum_retained_lua_heap_delta_bytes ==
          maximum_retained)
      end
      local one, ten = evidence.sizes[1], evidence.sizes[3]
      assert(evidence.gate_results.ten_mib_cpu.pass ==
        (ten.median_combined_cpu_seconds <= 5))
      assert(evidence.gate_results.ten_mib_retained_heap.pass ==
        (ten.maximum_retained_lua_heap_delta_bytes <=
          12 * ten.input_bytes))
      assert(evidence.gate_results.ten_to_one_mib_cpu.pass ==
        (ten.median_combined_cpu_seconds <=
          15 * one.median_combined_cpu_seconds))
      assert(evidence.gate_results
        .ten_to_one_mib_retained_heap.pass ==
        (ten.maximum_retained_lua_heap_delta_bytes <=
          15 * one.maximum_retained_lua_heap_delta_bytes))
      assert(evidence.decision ==
        (evidence.gate_results.ten_mib_cpu.pass and
         evidence.gate_results.ten_mib_retained_heap.pass and
         evidence.gate_results.ten_to_one_mib_cpu.pass and
         evidence.gate_results
           .ten_to_one_mib_retained_heap.pass and "pass" or "fail"))
    end,
  },
  {
    name = "provenance records the resolved Task 9 gate outcomes",
    gate = "performance",
    stage = "performance",
    fn = function()
      local provenance = pandoc.json.decode(
        fixture.read_bytes(PROVENANCE), false)
      local evidence = pandoc.json.decode(
        fixture.read_bytes(RESULTS), false)
      local gate = assert(provenance.task_9_gate)
      assert(gate.decision == "fail")
      assert(gate.determinism.decision == "pass")
      assert(gate.determinism.process_count == 10)
      assert(gate.performance.decision == "fail")
      assert(gate.performance.ten_mib_median_cpu_seconds ==
        evidence.sizes[3].median_combined_cpu_seconds)
      assert(gate.performance
        .maximum_retained_lua_heap_delta_bytes ==
        evidence.sizes[3].maximum_retained_lua_heap_delta_bytes)
      assert(gate.criteria.fresh_process_determinism == true)
      assert(gate.criteria.existing_attribute_edit_measured == true)
      assert(gate.criteria
        .oracle_verified_all_scaling_ranges == true)
      assert(gate.criteria.ten_mib_cpu_gate == false)
      assert(gate.criteria.ten_mib_retained_heap_gate == true)
      assert(gate.criteria.cpu_scaling_gate == true)
      assert(gate.criteria.retained_heap_scaling_gate == true)
    end,
  },
  {
    name = "Task 10 amendment preserves the original failure and separates the advisory target",
    gate = "performance",
    stage = "performance",
    fn = function()
      local evidence = pandoc.json.decode(
        fixture.read_bytes(RESULTS), false)
      assert(evidence.decision == "fail")
      local binding_gates_pass = evaluate_reference_gates(evidence, {
        absolute_cpu_is_advisory = true,
      })
      assert(binding_gates_pass == true)
      assert(evidence.advisory_results.ten_mib_cpu.pass == false)
      assert(evidence.binding_gate_results.ten_mib_retained_heap.pass == true)
      assert(evidence.binding_gate_results.ten_to_one_mib_cpu.pass == true)
      assert(evidence.binding_gate_results
        .ten_to_one_mib_retained_heap.pass == true)
      assert(evidence.decision == "pass")
    end,
  },
  {
    name = "provenance records the conditional go without rewriting Task 9",
    gate = "performance",
    stage = "performance",
    fn = function()
      local provenance = pandoc.json.decode(
        fixture.read_bytes(PROVENANCE), false)
      local task_9 = assert(provenance.task_9_gate)
      local task_10 = assert(provenance.task_10_decision)
      assert(task_9.decision == "fail")
      assert(task_9.performance.ten_mib_cpu_limit_seconds == 5)
      assert(task_9.performance.ten_mib_median_cpu_seconds == 5.274299)
      assert(task_10.decision == "conditional-go")
      assert(task_10.post_result_amendment.original_decision == "fail")
      assert(task_10.post_result_amendment
        .absolute_cpu_target_seconds == 5)
      assert(task_10.post_result_amendment
        .observed_cpu_seconds == 5.274299)
      assert(task_10.post_result_amendment
        .absolute_cpu_target_met == false)
      assert(task_10.reference_verification.decision == "pass")
      assert(task_10.reference_verification
        .absolute_cpu_target_met == false)
      assert(task_10.reference_verification
        .observed_cpu_seconds == 5.117641)
      assert(task_10.binding_performance_gates
        .ten_mib_retained_heap == true)
      assert(task_10.binding_performance_gates
        .cpu_scaling == true)
      assert(task_10.binding_performance_gates
        .retained_heap_scaling == true)
      assert(task_10.production_prerequisite.status ==
        "required-before-production")
      assert(task_10.restrictions.case_sensitive_part_lookup == true)
      assert(task_10.restrictions
        .office_uri_encoded_relationship_targets_observed == false)
    end,
  },
  {
    name = "reference Mac meets binding performance gates and reports the advisory CPU target",
    gate = "performance",
    stage = "performance",
    reference_only = true,
    fn = function()
      local evidence = pandoc.json.decode(
        fixture.read_bytes(RESULTS), false)
      assert_reference_environment_matches_recorded(
        evidence.reference_environment)
      local result = measure_reference()
      local gates_pass = evaluate_reference_gates(result, {
        absolute_cpu_is_advisory = true,
      })
      local output_path =
        os.getenv("DOCSTYLE_SPIKE_REFERENCE_RESULT_OUTPUT")
      if output_path and output_path ~= "" then
        fixture.write_bytes(output_path, pandoc.json.encode(result))
      end
      assert(gates_pass,
        "reference binding performance gates failed: " ..
        pandoc.json.encode(result.binding_gate_results))
    end,
  },
}
