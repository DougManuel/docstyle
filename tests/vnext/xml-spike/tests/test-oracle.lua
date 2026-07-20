local common = require("candidates.common")
local oracle = require("candidates.oracle")
local diagnostic = require("lib.diagnostic")
local fixtures = require("fixtures.xml.cases")
local file_fixture = require("lib.fixture")

local function expect_diagnostic(code, fn)
  local ok, err = diagnostic.capture(fn)
  assert(not ok, "expected diagnostic " .. code)
  assert(err.code == code,
    "expected diagnostic " .. code .. ", got " .. tostring(err.code))
  return err
end

local function matching_elements(document, expected)
  local matches = {}
  for _, event in ipairs(document.events) do
    if event.kind == "start" and event.name.uri == expected.uri and
        event.name.local_name == expected.local_name then
      matches[#matches + 1] = event
    end
  end
  return matches
end

local function find_attribute(document, expected)
  for _, element in ipairs(matching_elements(document, expected.owner)) do
    for _, attribute in ipairs(element.attributes) do
      if attribute.name.uri == expected.uri and
          attribute.name.local_name == expected.local_name then
        return attribute
      end
    end
  end
  return nil
end

local function assert_valid_case(row)
  local document = oracle.parse(row.bytes)
  assert(document.encoding == row.encoding)
  assert(document.root.name.uri == row.root.uri)
  assert(document.root.name.local_name == row.root.local_name)

  for _, expected in ipairs(row.elements or {}) do
    assert(#matching_elements(document, expected) == expected.count)
  end
  for _, expected in ipairs(row.attributes or {}) do
    local attribute = assert(find_attribute(document, expected),
      "missing attribute " .. expected.local_name)
    assert(attribute.value == expected.value)
    if expected.quote then assert(attribute.quote == expected.quote) end
  end

  local text_index = 0
  local token_matches = {}
  for _, expected in ipairs(row.token_values or {}) do
    token_matches[expected.kind] = token_matches[expected.kind] or {}
    token_matches[expected.kind][#token_matches[expected.kind] + 1] = expected
  end
  for _, event in ipairs(document.events) do
    if event.kind == "text" and row.text then
      text_index = text_index + 1
      assert(event.value == row.text[text_index])
    end
    for _, expected in ipairs(token_matches[event.kind] or {}) do
      if event.value == expected.value and
          (expected.target == nil or event.target == expected.target) then
        expected.found = true
      end
    end
  end
  if row.text then assert(text_index == #row.text) end
  for _, expected in ipairs(row.token_values or {}) do
    assert(expected.found, "missing lexical token " .. expected.kind)
    expected.found = nil
  end
end

local cases = {
  {
    name = "common result types enforce half-open byte ranges",
    gate = "functional",
    stage = "xml",
    fn = function()
      local range = common.range(2, 5)
      assert(range.start == 2 and range.finish == 5)
      expect_diagnostic("xml.invalid-range", function()
        common.range(5, 2)
      end)
    end,
  },
  {
    name = "oracle source is independent of both candidate parsers",
    gate = "safety",
    stage = "xml",
    fn = function()
      local here = pandoc.path.directory(PANDOC_SCRIPT_FILE)
      local root = pandoc.path.normalize(pandoc.path.join({
        here, "..", "..", "..",
      }))
      local source = file_fixture.read_bytes(pandoc.path.join({
        root, "dev", "vnext", "xml-spike", "candidates", "oracle.lua",
      }))
      assert(not source:lower():match("require%s*%(%s*[\"'].-slaxml"))
      assert(not source:lower():match("require%s*%(%s*[\"'].-luaxml"))
    end,
  },
  {
    name = "one MiB UTF-8 text retains exact identity byte coordinates",
    gate = "safety",
    stage = "xml",
    fn = function()
      local payload = string.rep("a", 1024 * 1024)
      local bytes = "<root>" .. payload .. "</root>"
      local document = oracle.parse(bytes, { max_input_bytes = #bytes })
      assert(document.token_count == 3)
      local text_event = document.events[2]
      assert(text_event.kind == "text")
      assert(text_event.range.start == 6)
      assert(text_event.range.finish == 6 + #payload)
      assert(#text_event.value == #payload)
    end,
  },
}

for _, row in ipairs(fixtures.valid) do
  cases[#cases + 1] = {
    name = "accepts " .. row.name,
    gate = "functional",
    stage = "xml",
    fn = function() assert_valid_case(row) end,
  }
end

for _, row in ipairs(fixtures.invalid) do
  cases[#cases + 1] = {
    name = "rejects " .. row.name,
    gate = "functional",
    stage = "xml",
    fn = function()
      expect_diagnostic(row.code, function() oracle.parse(row.bytes) end)
    end,
  }
end

for _, row in ipairs(fixtures.limit_boundaries) do
  cases[#cases + 1] = {
    name = "accepts exact " .. row.name .. " limit and rejects one below",
    gate = "safety",
    stage = "xml",
    fn = function()
      oracle.parse(row.bytes, { [row.option] = row.exact })
      expect_diagnostic(row.code, function()
        oracle.parse(row.bytes, { [row.option] = row.exact - 1 })
      end)
    end,
  }
end

for _, row in ipairs(fixtures.invalid_limits) do
  cases[#cases + 1] = {
    name = "rejects " .. row.name .. " parse limit",
    gate = "safety",
    stage = "xml",
    fn = function()
      expect_diagnostic("xml.invalid-limit", function()
        oracle.parse("<root/>", row.options)
      end)
    end,
  }
end

for _, row in ipairs(fixtures.mutations) do
  cases[#cases + 1] = {
    name = "reports literal golden range for " .. row.name,
    gate = "preservation",
    stage = "xml",
    fn = function()
      local source_bytes = row.expected_source_bytes or row.expected_source
      local actual = row.bytes:sub(
        row.golden_range.start + 1, row.golden_range.finish)
      assert(actual == source_bytes, "fixture golden range is not literal")

      local document = oracle.parse(row.bytes)
      local range = oracle.find_edit_range(document, row)
      assert(range.start == row.golden_range.start)
      assert(range.finish == row.golden_range.finish)
    end,
  }
  cases[#cases + 1] = {
    name = "verifies full-part semantics for " .. row.name,
    gate = "preservation",
    stage = "xml",
    fn = function()
      local edited = fixtures.edited_bytes(row)
      local result = oracle.verify_edit(
        row.bytes,
        edited,
        row.golden_range,
        {
          reported_range = common.range(
            row.golden_range.start, row.golden_range.finish),
          operation = row.operation,
          element = row.element,
          attribute = row.attribute,
          value = row.replacement_value,
        })
      assert(result.ok == true)
    end,
  }
end

cases[#cases + 1] = {
  name = "rejects wider and narrower reported edit ranges first",
  gate = "preservation",
  stage = "xml",
  fn = function()
    local row = fixtures.mutations[1]
    local edited = fixtures.edited_bytes(row)
    for _, range in ipairs({
      common.range(row.golden_range.start - 1, row.golden_range.finish),
      common.range(row.golden_range.start + 1, row.golden_range.finish),
      common.range(row.golden_range.start, row.golden_range.finish + 1),
      common.range(row.golden_range.start, row.golden_range.finish - 1),
    }) do
      expect_diagnostic("xml.edit-range", function()
        oracle.verify_edit(row.bytes, edited, row.golden_range, {
          reported_range = range,
          operation = row.operation,
          element = row.element,
          attribute = row.attribute,
          value = row.replacement_value,
        })
      end)
    end
  end,
}

cases[#cases + 1] = {
  name = "rejects an undeclared semantic change outside the owned range",
  gate = "preservation",
  stage = "xml",
  fn = function()
    local row = fixtures.mutations[1]
    local edited = fixtures.edited_bytes(row):gsub("before", "altered", 1)
    expect_diagnostic("xml.outside-bytes", function()
      oracle.verify_edit(row.bytes, edited, row.golden_range, {
        reported_range = common.range(
          row.golden_range.start, row.golden_range.finish),
        operation = row.operation,
        element = row.element,
        attribute = row.attribute,
        value = row.replacement_value,
      })
    end)
  end,
}

return cases
