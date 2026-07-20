local common = require("candidates.common")
local diagnostic = require("lib.diagnostic")
local fixture = require("lib.fixture")
local fixtures = require("fixtures.xml.cases")
local oracle = require("candidates.oracle")

local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
local root = pandoc.path.normalize(pandoc.path.join({
  here, "..", "..", "..",
}))

local adapter
local function subject()
  if not adapter then adapter = require("candidates.slaxml.adapter") end
  return adapter
end

local function expect_diagnostic(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected diagnostic " .. code)
  assert(err.code == code,
    "expected diagnostic " .. code .. ", got " .. tostring(err.code))
  return err
end

local function line_count(path)
  local bytes = fixture.read_bytes(path)
  local _, count = bytes:gsub("\n", "")
  if #bytes > 0 and bytes:sub(-1) ~= "\n" then count = count + 1 end
  return count
end

local function matching_node(document, selector)
  local nodes = subject().find_all(
    document, selector.uri, selector.local_name)
  return nodes[selector.occurrence or 1], nodes
end

local cases = {
  {
    name = "vendors the immutable parser and licence bytes",
    gate = "safety",
    stage = "xml",
    fn = function()
      local provenance = pandoc.json.decode(fixture.read_bytes(pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "provenance.json",
      })), false)
      local slaxml
      for _, candidate in ipairs(provenance.candidates) do
        if candidate.name == "SLAXML" then slaxml = candidate end
      end
      assert(slaxml, "SLAXML provenance record is required")
      assert(slaxml.commit ==
        "8a3e0c90325aa6d84ad23a7c13bf77247cb7f94e")

      local sha256 = dofile(pandoc.path.join({
        root, "tests", "vnext", "conformance", "lib", "sha256.lua",
      }))
      local vendor = pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "candidates", "slaxml", "vendor",
      })
      assert(sha256.hex(fixture.read_bytes(pandoc.path.join({
        vendor, "slaxml.lua",
      }))) == slaxml.vendored_source_sha256)
      assert(sha256.hex(fixture.read_bytes(pandoc.path.join({
        vendor, "LICENSE.txt",
      }))) == slaxml.vendored_license_sha256)
      assert(line_count(pandoc.path.join({ vendor, "slaxml.lua" })) == 259)
    end,
  },
  {
    name = "candidate does not import the independent oracle or DOM serializer",
    gate = "safety",
    stage = "xml",
    fn = function()
      local candidate_root = pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "candidates", "slaxml",
      })
      for _, filename in ipairs({
        "adapter.lua", "strictness.lua", "token_overlay.lua",
      }) do
        local source = fixture.read_bytes(pandoc.path.join({
          candidate_root, filename,
        })):lower()
        assert(not source:match("require%s*%(%s*[\"'].-oracle"))
        assert(not source:match("require%s*%(%s*[\"'].-slaxdom"))
      end
    end,
  },
}

for _, row in ipairs(fixtures.valid) do
  cases[#cases + 1] = {
    name = "accepts shared fixture " .. row.name,
    gate = "functional",
    stage = "xml",
    fn = function()
      local document = subject().parse(row.bytes)
      assert(document.slaxml_version == "0.8")
      local roots = subject().find_all(
        document, row.root.uri, row.root.local_name)
      assert(#roots == 1, "expected exactly one fixture root")

      for _, expected in ipairs(row.elements or {}) do
        local nodes = subject().find_all(
          document, expected.uri, expected.local_name)
        assert(#nodes == expected.count)
      end
      for _, expected in ipairs(row.attributes or {}) do
        local owner = assert(matching_node(document, expected.owner),
          "missing attribute owner")
        local value = subject().get_attribute(
          owner, expected.uri, expected.local_name)
        assert(value == expected.value,
          "wrong attribute value for " .. expected.local_name)
      end
    end,
  }
end

for _, row in ipairs(fixtures.invalid) do
  cases[#cases + 1] = {
    name = "rejects shared fixture " .. row.name,
    gate = "functional",
    stage = "xml",
    fn = function()
      expect_diagnostic(row.code, function()
        subject().parse(row.bytes)
      end)
    end,
  }
end

for _, row in ipairs(fixtures.limit_boundaries) do
  cases[#cases + 1] = {
    name = "enforces shared boundary " .. row.name,
    gate = "safety",
    stage = "xml",
    fn = function()
      subject().parse(row.bytes, { [row.option] = row.exact })
      expect_diagnostic(row.code, function()
        subject().parse(row.bytes, { [row.option] = row.exact - 1 })
      end)
    end,
  }
end

for _, row in ipairs(fixtures.invalid_limits) do
  cases[#cases + 1] = {
    name = "rejects shared parse limit " .. row.name,
    gate = "safety",
    stage = "xml",
    fn = function()
      expect_diagnostic("xml.invalid-limit", function()
        subject().parse("<root/>", row.options)
      end)
    end,
  }
end

for _, row in ipairs(fixtures.mutations) do
  cases[#cases + 1] = {
    name = "edits and independently verifies " .. row.name,
    gate = "preservation",
    stage = "xml",
    fn = function()
      local document = subject().parse(row.bytes)
      local node = assert(matching_node(document, row.element),
        "missing mutation target")
      if row.operation == "attribute" then
        assert(subject().get_attribute(
          node, row.attribute.uri, row.attribute.local_name) ==
          row.expected_source)
        subject().set_attribute(
          node, row.attribute.uri, row.attribute.local_name,
          row.replacement_value)
        assert(subject().get_attribute(
          node, row.attribute.uri, row.attribute.local_name) ==
          row.replacement_value)
      else
        subject().replace_text(node, row.replacement_value)
      end

      local edited, edit_ranges = subject().serialize(document)
      assert(#edit_ranges == 1)
      assert(common.same_range(edit_ranges[1], row.golden_range))
      assert(edited == fixtures.edited_bytes(row),
        "candidate emitted unexpected replacement bytes")
      local verification = oracle.verify_edit(
        row.bytes, edited, row.golden_range, {
          reported_range = edit_ranges[1],
          operation = row.operation,
          element = row.element,
          attribute = row.attribute,
          value = row.replacement_value,
        })
      assert(verification.ok == true)

      local second_bytes, second_ranges = subject().serialize(document)
      assert(second_bytes == edited)
      assert(common.same_range(second_ranges[1], edit_ranges[1]))
    end,
  }
end

cases[#cases + 1] = {
  name = "escapes all normalized attribute whitespace deterministically",
  gate = "preservation",
  stage = "xml",
  fn = function()
    local source = "<root a='old'/>"
    local start_at, finish_at = source:find("old", 1, true)
    local golden = common.range(start_at - 1, finish_at)
    local replacement = "x\t\n\r&<'\""
    local document = subject().parse(source)
    local node = assert(subject().find_all(document, "", "root")[1])
    subject().set_attribute(node, "", "a", replacement)
    local edited, ranges = subject().serialize(document)
    assert(edited ==
      "<root a='x&#x9;&#xA;&#xD;&amp;&lt;&apos;\"'/>")
    assert(common.same_range(ranges[1], golden))
    local verified = oracle.verify_edit(source, edited, golden, {
      reported_range = ranges[1],
      operation = "attribute",
      element = { uri = "", local_name = "root" },
      attribute = { uri = "", local_name = "a" },
      value = replacement,
    })
    assert(verified.ok == true)
  end,
}

cases[#cases + 1] = {
  name = "rejects text replacement on mixed content",
  gate = "preservation",
  stage = "xml",
  fn = function()
    local document = subject().parse("<root>a<child/>b</root>")
    local node = assert(subject().find_all(document, "", "root")[1])
    expect_diagnostic("xml.edit-target", function()
      subject().replace_text(node, "replacement")
    end)
  end,
}

cases[#cases + 1] = {
  name = "accepts long leading zeros in valid numeric references",
  gate = "safety",
  stage = "xml",
  fn = function()
    local zeros = string.rep("0", 128)
    local document = subject().parse(
      "<root a='&#" .. zeros .. "65;'>&#x" .. zeros .. "41;</root>")
    local node = assert(subject().find_all(document, "", "root")[1])
    assert(subject().get_attribute(node, "", "a") == "A")
  end,
}

cases[#cases + 1] = {
  name = "reports machine-readable maintenance evidence",
  gate = "safety",
  stage = "xml",
  fn = function()
    local evidence = subject().result
    assert(type(evidence) == "table")
    assert(evidence.candidate == "SLAXML")
    assert(evidence.version == "0.8")
    assert(evidence.dependency_count == 1)
    assert(evidence.vendored_lines == 259)
    assert(type(evidence.docstyle_owned_lines) == "number")
    assert(evidence.docstyle_owned_lines ==
      line_count(pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "candidates", "slaxml",
        "adapter.lua",
      })) + line_count(pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "candidates", "slaxml",
        "strictness.lua",
      })) + line_count(pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "candidates", "slaxml",
        "token_overlay.lua",
      })))
    assert(type(evidence.unsupported_constructs) == "table")
    assert(type(evidence.rejected_fixture_rows) == "table")

    local provenance = pandoc.json.decode(fixture.read_bytes(pandoc.path.join({
      root, "dev", "vnext", "xml-spike", "provenance.json",
    })), false)
    local recorded
    for _, candidate in ipairs(provenance.candidates) do
      if candidate.name == "SLAXML" then
        recorded = candidate.maintenance_evidence
      end
    end
    assert(recorded, "SLAXML maintenance evidence must be durable")
    assert(recorded.vendored_lines == evidence.vendored_lines)
    assert(recorded.docstyle_owned_lines == evidence.docstyle_owned_lines)
    assert(recorded.dependency_count == evidence.dependency_count)
    assert(#recorded.unsupported_constructs ==
      #evidence.unsupported_constructs)
    assert(#recorded.rejected_fixture_rows ==
      #evidence.rejected_fixture_rows)
  end,
}

cases.result = function()
  return subject().result
end

return cases
