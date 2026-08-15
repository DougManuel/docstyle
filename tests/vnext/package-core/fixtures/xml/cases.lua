local M = {}

local XML_NS = "http://www.w3.org/XML/1998/namespace"
local MC_NS = "http://schemas.openxmlformats.org/markup-compatibility/2006"
local W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
local W14_NS = "http://schemas.microsoft.com/office/word/2010/wordml"

local function append_u16(parts, value, endian)
  local high = (value >> 8) & 0xff
  local low = value & 0xff
  if endian == "utf-16le" then
    parts[#parts + 1] = string.char(low, high)
  else
    parts[#parts + 1] = string.char(high, low)
  end
end

local function encode_utf16(text, endian, bom)
  local parts = {}
  if bom then
    parts[#parts + 1] = endian == "utf-16le" and "\255\254" or "\254\255"
  end
  for _, codepoint in utf8.codes(text) do
    if codepoint <= 0xffff then
      append_u16(parts, codepoint, endian)
    else
      local value = codepoint - 0x10000
      append_u16(parts, 0xd800 + (value >> 10), endian)
      append_u16(parts, 0xdc00 + (value & 0x3ff), endian)
    end
  end
  return table.concat(parts)
end

local function encode(text, encoding, bom)
  if encoding == "utf-8" then
    return (bom and "\239\187\191" or "") .. text
  end
  return encode_utf16(text, encoding, bom)
end

local function range_of(bytes, needle)
  local start_at, finish_at = bytes:find(needle, 1, true)
  assert(start_at, "golden fixture token not found")
  assert(not bytes:find(needle, finish_at + 1, true),
    "golden fixture token must be unique")
  return { start = start_at - 1, finish = finish_at }
end

local function replace_range(bytes, range, replacement)
  return bytes:sub(1, range.start) .. replacement ..
    bytes:sub(range.finish + 1)
end

local function valid(name, xml, fields)
  fields = fields or {}
  fields.name = name
  fields.encoding = fields.encoding or "utf-8"
  fields.bytes = encode(xml, fields.encoding, fields.bom == true)
  fields.root = fields.root or { uri = "", local_name = "root" }
  return fields
end

M.namespaces = {
  xml = XML_NS,
  mc = MC_NS,
  word = W_NS,
  word_2010 = W14_NS,
}

M.valid = {
  valid("utf8-minimal", [[<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="urn:w"><w:p w:rsidR='01'>Text</w:p></w:document>]], {
    root = { uri = "urn:w", local_name = "document" },
    attributes = {
      { owner = { uri = "urn:w", local_name = "p" },
        uri = "urn:w", local_name = "rsidR", value = "01" },
    },
    text = { "Text" },
  }),
  valid("utf8-bom", "<root>bom</root>", {
    bom = true,
    text = { "bom" },
  }),
  valid("utf16le-bom-surrogate", [[<?xml version="1.0" encoding="UTF-16"?>
<root>face 😀</root>]], {
    encoding = "utf-16le",
    bom = true,
    text = { "face 😀" },
  }),
  valid("utf16be-bom-surrogate", [[<?xml version="1.0" encoding="UTF-16"?>
<root>face 😀</root>]], {
    encoding = "utf-16be",
    bom = true,
    text = { "face 😀" },
  }),
  valid("utf16le-declaration-no-bom",
    [[<?xml version="1.0" encoding="UTF-16LE"?><root>le</root>]], {
      encoding = "utf-16le",
      text = { "le" },
    }),
  valid("utf16be-declaration-no-bom",
    [[<?xml version="1.0" encoding="UTF-16BE"?><root>be</root>]], {
      encoding = "utf-16be",
      text = { "be" },
    }),
  valid("namespace-shadowing", [[<root xmlns="urn:outer" xmlns:p="urn:p1">
<p:item p:a="one"><child xmlns="urn:inner" xmlns:p="urn:p2"
p:a="two" plain="none"/></p:item></root>]], {
    root = { uri = "urn:outer", local_name = "root" },
    elements = {
      { uri = "urn:p1", local_name = "item", count = 1 },
      { uri = "urn:inner", local_name = "child", count = 1 },
    },
    attributes = {
      { owner = { uri = "urn:p1", local_name = "item" },
        uri = "urn:p1", local_name = "a", value = "one" },
      { owner = { uri = "urn:inner", local_name = "child" },
        uri = "urn:p2", local_name = "a", value = "two" },
      { owner = { uri = "urn:inner", local_name = "child" },
        uri = "", local_name = "plain", value = "none" },
    },
  }),
  valid("predefined-and-numeric-entities", [[<root
a="&amp;&lt;&gt;&quot;&apos;&#65;&#x1F600;">&amp;&lt;&gt;&quot;&apos;&#65;&#x1F600;</root>]], {
    attributes = {
      { owner = { uri = "", local_name = "root" }, uri = "",
        local_name = "a", value = "&<>\"'A😀" },
    },
    text = { "&<>\"'A😀" },
  }),
  valid("numeric-reference-leading-zeros",
    [[<root>&#00000000000065;&#x00000000000041;</root>]], {
      text = { "AA" },
    }),
  valid("quote-styles", [[<root single='one' double="two"/>]], {
    attributes = {
      { owner = { uri = "", local_name = "root" }, uri = "",
        local_name = "single", value = "one", quote = "'" },
      { owner = { uri = "", local_name = "root" }, uri = "",
        local_name = "double", value = "two", quote = "\"" },
    },
  }),
  valid("raw-greater-than-single-quoted-empty-attribute",
    "<root a='1>2'/>", {
      attributes = {
        { owner = { uri = "", local_name = "root" }, uri = "",
          local_name = "a", value = "1>2", quote = "'" },
      },
    }),
  valid("raw-greater-than-double-quoted-empty-attribute",
    [[<root a="1>2"/>]], {
      attributes = {
        { owner = { uri = "", local_name = "root" }, uri = "",
          local_name = "a", value = "1>2", quote = "\"" },
      },
    }),
  valid("cdata-close-marker-inside-attribute", "<root a=']]>'/>", {
    attributes = {
      { owner = { uri = "", local_name = "root" }, uri = "",
        local_name = "a", value = "]]>", quote = "'" },
    },
  }),
  valid("pi-close-marker-inside-attribute", "<root a='x?>y'/>", {
    attributes = {
      { owner = { uri = "", local_name = "root" }, uri = "",
        local_name = "a", value = "x?>y", quote = "'" },
    },
  }),
  valid("empty-element-marker-inside-attribute",
    "<root a='x/>y'>text</root>", {
      attributes = {
        { owner = { uri = "", local_name = "root" }, uri = "",
          local_name = "a", value = "x/>y", quote = "'" },
      },
      text = { "text" },
    }),
  valid("lexical-content", "<root xml:space=\"preserve\"> \n" ..
    "<!--keep--><?target data?><![CDATA[raw <&>]]><child/>  </root>", {
    attributes = {
      { owner = { uri = "", local_name = "root" }, uri = XML_NS,
        local_name = "space", value = "preserve" },
    },
    token_values = {
      { kind = "comment", value = "keep" },
      { kind = "pi", target = "target", value = "data" },
      { kind = "cdata", value = "raw <&>" },
    },
    text = { " \n", "  " },
  }),
  valid("pi-target-begins-with-xml",
    [[<?xml-stylesheet type="text/xsl" href="style.xsl"?><root/>]], {
      token_values = {
        { kind = "pi", target = "xml-stylesheet",
          value = [[type="text/xsl" href="style.xsl"]] },
      },
    }),
  valid("pi-multiple-space-separator", "<?target  data?><root/>", {
    token_values = {
      { kind = "pi", target = "target", value = "data" },
    },
  }),
  valid("pi-tab-separator", "<?target\tdata?><root/>", {
    token_values = {
      { kind = "pi", target = "target", value = "data" },
    },
  }),
  valid("pi-line-feed-separator", "<?target\ndata?><root/>", {
    token_values = {
      { kind = "pi", target = "target", value = "data" },
    },
  }),
  valid("pi-empty-data-after-separator", "<?target  ?><root/>", {
    token_values = {
      { kind = "pi", target = "target", value = "" },
    },
  }),
  valid("namespace-declaration-follows-use",
    [[<p:root p:a='x' xmlns:p='urn:p'/>]], {
      root = { uri = "urn:p", local_name = "root" },
      attributes = {
        { owner = { uri = "urn:p", local_name = "root" }, uri = "urn:p",
          local_name = "a", value = "x" },
      },
    }),
  valid("default-namespace-undeclaration",
    [[<root xmlns="urn:outer"><child xmlns=""/></root>]], {
      root = { uri = "urn:outer", local_name = "root" },
      elements = {
        { uri = "", local_name = "child", count = 1 },
      },
    }),
  valid("attribute-line-and-reference-normalization",
    "<root a=\"x\t\r\ny&#x9;&#xA;&#xD;\"/>", {
      attributes = {
        { owner = { uri = "", local_name = "root" }, uri = "",
          local_name = "a", value = "x  y\t\n\r" },
      },
    }),
  valid("compatibility-and-unknown-content", [[<w:document
xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
mc:Ignorable="w14" w14:paraId="00A1"><w:body><w14:unknown
w14:value="kept"/></w:body></w:document>]], {
    root = { uri = W_NS, local_name = "document" },
    elements = {
      { uri = W14_NS, local_name = "unknown", count = 1 },
    },
    attributes = {
      { owner = { uri = W_NS, local_name = "document" }, uri = MC_NS,
        local_name = "Ignorable", value = "w14" },
      { owner = { uri = W_NS, local_name = "document" }, uri = W14_NS,
        local_name = "paraId", value = "00A1" },
    },
  }),
  valid("line-end-normalization", "<root>a\r\nb\rc</root>", {
    text = { "a\nb\nc" },
  }),
}

local function invalid(name, bytes, code, fields)
  fields = fields or {}
  fields.name = name
  fields.bytes = bytes
  fields.code = code
  return fields
end

M.invalid = {
  invalid("unsupported-version", [[<?xml version="1.1"?><root/>]],
    "xml.unsupported-version"),
  invalid("multiple-roots", "<a/><b/>", "xml.multiple-roots"),
  invalid("mismatched-elements", "<a><b></a>", "xml.mismatched-element"),
  invalid("missing-root-end", "<a><b/>", "xml.unclosed-element"),
  invalid("unclosed-element", "<a><b/></a", "xml.malformed-token"),
  invalid("unclosed-root", "<a><b/></a><!--", "xml.malformed-comment"),
  invalid("invalid-name-start", "<1root/>", "xml.invalid-name"),
  invalid("invalid-qualified-name", "<a:b:c/>", "xml.invalid-name"),
  invalid("invalid-qualified-element-local-start",
    "<a:1bc xmlns:a='urn:x'/>", "xml.invalid-name"),
  invalid("invalid-qualified-attribute-local-start-digit",
    "<root xmlns:a='urn:x' a:1bc='v'/>", "xml.invalid-name"),
  invalid("invalid-qualified-attribute-local-start-hyphen",
    "<root xmlns:a='urn:x' a:-bc='v'/>", "xml.invalid-name"),
  invalid("invalid-namespace-prefix-start",
    "<root xmlns:1p='urn:p'/>", "xml.invalid-name"),
  invalid("invalid-control-character", "<root>\1</root>",
    "xml.invalid-character"),
  invalid("text-outside-root", "text<root/>", "xml.text-outside-root"),
  invalid("unbound-element-prefix", "<p:root/>", "xml.unbound-prefix"),
  invalid("unbound-attribute-prefix", "<root p:a='x'/>",
    "xml.unbound-prefix"),
  invalid("illegal-xml-rebinding", "<root xmlns:xml='urn:not-xml'/>",
    "xml.illegal-namespace"),
  invalid("illegal-xmlns-rebinding", "<root xmlns:xmlns='urn:x'/>",
    "xml.illegal-namespace"),
  invalid("default-xmlns-uri", [[<root xmlns="http://www.w3.org/2000/xmlns/"/>]],
    "xml.illegal-namespace"),
  invalid("xml-namespace-uri-on-non-xml-prefix",
    [[<root xmlns:p="http://www.w3.org/XML/1998/namespace"/>]],
    "xml.illegal-namespace"),
  invalid("empty-prefixed-namespace", [[<root xmlns:p=""/>]],
    "xml.illegal-namespace"),
  invalid("xmlns-element-prefix", [[<xmlns:root/>]],
    "xml.illegal-namespace"),
  invalid("duplicate-expanded-attribute", [[<root xmlns:a="urn:x"
xmlns:b="urn:x" a:id="1" b:id="2"/>]], "xml.duplicate-attribute"),
  invalid("duplicate-lexical-attribute", "<root a='1' a='2'/>",
    "xml.duplicate-attribute"),
  invalid("malformed-declaration", "<?xml version='1.0' encoding=UTF-8?><root/>",
    "xml.malformed-declaration"),
  invalid("invalid-standalone", "<?xml version='1.0' standalone='maybe'?><root/>",
    "xml.malformed-declaration"),
  invalid("misplaced-declaration", "<!--x--><?xml version='1.0'?><root/>",
    "xml.misplaced-declaration"),
  invalid("comment-double-hyphen", "<root><!--a--b--></root>",
    "xml.malformed-comment"),
  invalid("comment-ending-hyphen", "<root><!--a---></root>",
    "xml.malformed-comment"),
  invalid("unclosed-cdata", "<root><![CDATA[x</root>",
    "xml.malformed-cdata"),
  invalid("cdata-outside-root", "<![CDATA[x]]><root/>",
    "xml.cdata-outside-root"),
  invalid("declaration-with-pi-data", "<?xml data?><root/>",
    "xml.malformed-declaration"),
  invalid("pi-target-xml-mixed", "<root><?XmL data?></root>",
    "xml.reserved-pi-target"),
  invalid("pi-target-colon", "<?a:b data?><root/>", "xml.invalid-name"),
  invalid("unclosed-pi", "<root><?target data</root>", "xml.malformed-pi"),
  invalid("unknown-entity", "<root>&custom;</root>",
    "xml.malformed-reference"),
  invalid("unterminated-reference", "<root>&amp</root>",
    "xml.malformed-reference"),
  invalid("invalid-numeric-reference", "<root>&#x110000;</root>",
    "xml.invalid-character"),
  invalid("overflowing-decimal-reference",
    "<root>&#18446744073709551681;</root>", "xml.invalid-character"),
  invalid("overflowing-hexadecimal-reference",
    "<root>&#x10000000000000041;</root>", "xml.invalid-character"),
  invalid("uppercase-hex-reference-marker", "<root>&#X41;</root>",
    "xml.malformed-reference"),
  invalid("empty-numeric-reference", "<root>&#;</root>",
    "xml.malformed-reference"),
  invalid("doctype", "<!DOCTYPE root><root/>", "xml.doctype-forbidden"),
  invalid("custom-entity", [[<!DOCTYPE root [<!ENTITY x "value">]><root>&x;</root>]],
    "xml.doctype-forbidden"),
  invalid("external-entity", [[<!DOCTYPE root [<!ENTITY x SYSTEM "file:///x">]>
<root>&x;</root>]], "xml.doctype-forbidden"),
  invalid("utf8-declares-utf16",
    [[<?xml version="1.0" encoding="UTF-16"?><root/>]],
    "xml.encoding-mismatch"),
  invalid("utf8-unregistered-utf8-alias",
    [[<?xml version="1.0" encoding="utf8"?><root/>]],
    "xml.encoding-mismatch"),
  invalid("utf16le-unregistered-utf16-alias", encode(
    [[<?xml version="1.0" encoding="utf16"?><root/>]],
    "utf-16le", true), "xml.encoding-mismatch"),
  invalid("utf16be-underscore-encoding-label", encode(
    [[<?xml version="1.0" encoding="UTF_16"?><root/>]],
    "utf-16be", true), "xml.encoding-mismatch"),
  invalid("utf16le-bom-declares-utf8", encode(
    [[<?xml version="1.0" encoding="UTF-8"?><root/>]],
    "utf-16le", true), "xml.encoding-mismatch"),
  invalid("utf16le-no-bom-no-declaration",
    encode("<root>le</root>", "utf-16le", false),
    "xml.encoding-mismatch"),
  invalid("utf16be-no-bom-declaration-without-encoding",
    encode([[<?xml version="1.0"?><root>be</root>]], "utf-16be", false),
    "xml.encoding-mismatch"),
  invalid("utf16le-generic-declaration-no-bom", encode(
    [[<?xml version="1.0" encoding="UTF-16"?><root>le</root>]],
    "utf-16le", false), "xml.encoding-mismatch"),
  invalid("utf16be-generic-declaration-no-bom", encode(
    [[<?xml version="1.0" encoding="UTF-16"?><root>be</root>]],
    "utf-16be", false), "xml.encoding-mismatch"),
  invalid("invalid-utf8", "<root>\240\040\140\188</root>",
    "xml.invalid-encoding"),
  invalid("utf16le-lone-high-surrogate",
    "\255\254\060\000\114\000\062\000\000\216\060\000\047\000\114\000\062\000",
    "xml.invalid-encoding"),
  invalid("utf16be-truncated-code-unit", "\254\255\000\060\000",
    "xml.invalid-encoding"),
}

M.capability_boundaries = {
  valid("unicode-greek-element-name", "<λroot>x</λroot>", {
    root = { uri = "", local_name = "λroot" },
    text = { "x" },
    slaxml_diagnostic = "xml.backend-rejected",
  }),
  valid("unicode-cjk-element-name", "<中文>x</中文>", {
    root = { uri = "", local_name = "中文" },
    text = { "x" },
    slaxml_diagnostic = "xml.backend-rejected",
  }),
  valid("unicode-greek-attribute-name", "<root λattr='x'/>", {
    attributes = {
      { owner = { uri = "", local_name = "root" }, uri = "",
        local_name = "λattr", value = "x" },
    },
    slaxml_diagnostic = "xml.backend-rejected",
  }),
  valid("unicode-greek-pi-target", "<?λpi data?><root/>", {
    token_values = {
      { kind = "pi", target = "λpi", value = "data" },
    },
    slaxml_diagnostic = "xml.backend-mismatch",
  }),
}

local limit_bytes = "<root xmlns:p='urn:p' xmlns:q='urn:q'>" ..
  "<p:child a='1' b='2'>t</p:child></root>"
M.limit_boundaries = {
  { name = "input-bytes", bytes = limit_bytes, option = "max_input_bytes",
    exact = #limit_bytes, code = "xml.input-limit" },
  { name = "element-depth", bytes = limit_bytes, option = "max_depth",
    exact = 2, code = "xml.depth-limit" },
  { name = "total-tokens", bytes = limit_bytes, option = "max_tokens",
    exact = 5, code = "xml.token-limit" },
  { name = "attributes-per-element", bytes = limit_bytes,
    option = "max_attributes", exact = 2, code = "xml.attribute-limit" },
  { name = "namespace-declarations-per-element", bytes = limit_bytes,
    option = "max_namespaces", exact = 2, code = "xml.namespace-limit" },
}

M.invalid_limits = {
  { name = "zero", options = { max_depth = 0 } },
  { name = "negative", options = { max_tokens = -1 } },
  { name = "non-integral", options = { max_attributes = 1.5 } },
  { name = "non-numeric", options = { max_input_bytes = "10" } },
  { name = "infinite", options = { max_namespaces = math.huge } },
}

local mutation_source = [[<w:document xmlns:w="urn:w"><w:p w:rsidR='old'>before 😀</w:p></w:document>]]
local attr_bytes = encode(mutation_source, "utf-8", false)
local attr_range = range_of(attr_bytes, "old")
local text_range = range_of(attr_bytes, "before 😀")

local utf16_source = [[<?xml version="1.0" encoding="UTF-16"?><root>😀old</root>]]
local utf16_bytes = encode(utf16_source, "utf-16be", true)
local utf16_text = encode("😀old", "utf-16be", false)
local utf16_range = range_of(utf16_bytes, utf16_text)

M.mutations = {
  {
    name = "attribute-carriage-return-and-quote",
    encoding = "utf-8",
    bytes = attr_bytes,
    operation = "attribute",
    element = { uri = "urn:w", local_name = "p", occurrence = 1 },
    attribute = { uri = "urn:w", local_name = "rsidR" },
    expected_source = "old",
    replacement_value = "new&\r'",
    replacement_lexical = "new&amp;&#xD;&apos;",
    golden_range = attr_range,
  },
  {
    name = "ordinary-text-carriage-return-and-cdata-guard",
    encoding = "utf-8",
    bytes = attr_bytes,
    operation = "text",
    element = { uri = "urn:w", local_name = "p", occurrence = 1 },
    expected_source = "before 😀",
    replacement_value = "after\r]]>tail",
    replacement_lexical = "after&#xD;]]&gt;tail",
    golden_range = text_range,
  },
  {
    name = "utf16be-surrogate-byte-range",
    encoding = "utf-16be",
    bytes = utf16_bytes,
    operation = "text",
    element = { uri = "", local_name = "root", occurrence = 1 },
    expected_source = "😀old",
    expected_source_bytes = utf16_text,
    replacement_value = "x😀\ry",
    replacement_lexical = "x😀&#xD;y",
    golden_range = utf16_range,
  },
}

function M.encode(text, encoding, bom)
  return encode(text, encoding, bom == true)
end

function M.replacement_bytes(row)
  return encode(row.replacement_lexical, row.encoding, false)
end

function M.edited_bytes(row)
  return replace_range(row.bytes, row.golden_range, M.replacement_bytes(row))
end

return M
