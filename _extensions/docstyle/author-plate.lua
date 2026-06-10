-- author-plate.lua
-- Pandoc Lua filter that generates a formatted author plate from YAML metadata
--
-- Usage in QMD:
--   ::: author-plate
--   :::
--
-- Configuration in _quarto.yml (under docstyle.author-plate):
--   corresponding-marker: "*"    # Symbol for corresponding author
--   equal-marker: "†"            # Symbol for equal contributors
--   show-orcid: false            # Show ORCID after author name
--   show-email: true             # Show corresponding author email
--   affiliation-style: numbered  # numbered (superscripts) or inline
--
-- Author metadata in QMD YAML front matter (Quarto manuscript format):
--   author:
--     - name:
--         given: "First"
--         family: "Last"
--       orcid: "0000-0000-0000-0000"
--       email: "author@example.com"
--       corresponding: true
--       equal-contributor: true
--       affiliations:
--         - ref: inst1
--   affiliations:
--     - id: inst1
--       name: "Institution Name"
--       department: "Department"
--       city: "City"
--       region: "Province"
--       country: "Country"

-- Load shared field code utilities
local fcu = require("field-code-utils")

local FORMAT = "openxml"

-- Store metadata
local authors = nil
local affiliations = nil
local config = {
  corresponding_marker = "*",
  equal_marker = "†",
  show_orcid = false,
  show_email = true,
  affiliation_style = "numbered"
}

-- Unicode superscript digits
local superscripts = {
  ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴",
  ["5"] = "⁵", ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹"
}

-- Use shared xml_escape from field-code-utils
local xml_escape = fcu.xml_escape

-- Convert number to superscript string
local function to_superscript(num)
  local s = tostring(num)
  local result = ""
  for i = 1, #s do
    local digit = s:sub(i, i)
    result = result .. (superscripts[digit] or digit)
  end
  return result
end

-- Get author display name from by-author entry
-- Quarto's by-author has: name.literal (Inlines), name.given, name.family
local function get_author_name(author)
  -- Try name.literal first (Quarto's normalized format)
  if author["name"] and author["name"]["literal"] then
    return pandoc.utils.stringify(author["name"]["literal"])
  end

  -- Try given + family
  if author["name"] then
    local name = author["name"]
    local given = name["given"] and pandoc.utils.stringify(name["given"]) or ""
    local family = name["family"] and pandoc.utils.stringify(name["family"]) or ""
    if given ~= "" and family ~= "" then
      return given .. " " .. family
    end
    return family ~= "" and family or given
  end

  -- Fallback: stringify the whole author object
  local name_str = pandoc.utils.stringify(author)
  if name_str and name_str ~= "" then
    return name_str
  end

  return ""
end

-- Build affiliation lookup table from affiliations metadata
-- Works with both raw affiliations and Quarto's by-affiliation format
local function build_affiliation_map(affs)
  local map = {}
  local ordered = {}

  if not affs then return map, ordered end

  for i, aff in ipairs(affs) do
    local id = nil
    if aff["id"] then
      id = pandoc.utils.stringify(aff["id"])
    end

    local display = ""
    local parts = {}

    -- Build display string: Department, Name, City, Region, Country
    if aff["department"] then
      table.insert(parts, pandoc.utils.stringify(aff["department"]))
    end
    if aff["name"] then
      table.insert(parts, pandoc.utils.stringify(aff["name"]))
    end
    if aff["city"] then
      table.insert(parts, pandoc.utils.stringify(aff["city"]))
    end
    if aff["region"] then
      table.insert(parts, pandoc.utils.stringify(aff["region"]))
    end
    if aff["country"] then
      table.insert(parts, pandoc.utils.stringify(aff["country"]))
    end

    display = table.concat(parts, ", ")

    local entry = {
      id = id,
      number = i,
      display = display
    }

    if id then
      map[id] = entry
    end
    table.insert(ordered, entry)
  end

  return map, ordered
end

-- Get affiliation numbers for an author
-- In Quarto's by-author, affiliations are resolved objects with id, name, etc.
local function get_author_affiliations(author, aff_map)
  local numbers = {}

  if not author["affiliations"] then return numbers end

  for _, aff in ipairs(author["affiliations"]) do
    local aff_id = nil

    -- Quarto resolves affiliations, so we get full objects with id
    if type(aff) == "table" and aff["id"] then
      aff_id = pandoc.utils.stringify(aff["id"])
    elseif type(aff) == "table" and aff["ref"] then
      aff_id = pandoc.utils.stringify(aff["ref"])
    end

    if aff_id and aff_map[aff_id] then
      table.insert(numbers, aff_map[aff_id].number)
    end
  end

  return numbers
end

-- Check if author has attribute (Quarto stores these in attributes sub-object)
local function has_attribute(author, attr)
  -- Check in attributes sub-object first (Quarto's normalized location)
  if author["attributes"] and author["attributes"][attr] then
    local val = author["attributes"][attr]
    if type(val) == "boolean" then return val end
    local str_val = pandoc.utils.stringify(val)
    return str_val == "true" or str_val == "1"
  end

  -- Check top-level as fallback
  if author[attr] then
    local val = author[attr]
    if type(val) == "boolean" then return val end
    local str_val = pandoc.utils.stringify(val)
    return str_val == "true" or str_val == "1"
  end

  return false
end

-- Read configuration from metadata
function Meta(meta)
  -- Check whether author-plate is disabled before loading authors.
  -- When disabled, docstyle.authors in _quarto.yml is the correct pattern
  -- (it avoids Pandoc's native title block without triggering author-plate
  -- rendering). Suppress the deprecation warning in that case.
  local plate_enabled = true
  if meta.docstyle and meta.docstyle["author-plate"] then
    local ap = meta.docstyle["author-plate"]
    if ap["enabled"] ~= nil then
      local val = ap["enabled"]
      plate_enabled = (type(val) == "boolean" and val) or
                      (pandoc.utils.stringify(val) == "true")
    end
  end

  -- Priority 1: docstyle.authors (avoids Pandoc's native title block)
  -- Priority 2: by-author (Quarto's normalized format) — PREFERRED
  -- Priority 3: author (basic Pandoc format)
  --
  -- Multi-format note: define authors/affiliations once at the top level in
  -- _quarto.yml or QMD front matter. Quarto normalizes them into by-author and
  -- by-affiliation, which this filter reads. Unknown fields (e.g. roles: for
  -- CRediT) pass through to by-author entries unchanged for future use.
  if meta.docstyle and meta.docstyle["authors"] then
    authors = meta.docstyle["authors"]
    if plate_enabled then
      io.stderr:write("[author-plate] Warning: docstyle.authors is deprecated. " ..
        "Use standard Quarto author: metadata instead. " ..
        "See https://quarto.org/docs/journals/authors.html\n")
    end
    io.stderr:write("[author-plate] Found " .. #authors .. " authors (from docstyle.authors)\n")
  elseif meta["by-author"] then
    authors = meta["by-author"]
    io.stderr:write("[author-plate] Found " .. #authors .. " authors (from by-author)\n")
  elseif meta.author then
    authors = meta.author
    io.stderr:write("[author-plate] Found " .. #authors .. " authors (from author - basic)\n")
  end

  -- Get affiliations - priority order mirrors authors
  if meta.docstyle and meta.docstyle["affiliations"] then
    affiliations = meta.docstyle["affiliations"]
    if plate_enabled then
      io.stderr:write("[author-plate] Warning: docstyle.affiliations is deprecated. " ..
        "Use standard Quarto affiliations: metadata instead.\n")
    end
    io.stderr:write("[author-plate] Found " .. #affiliations .. " affiliations (from docstyle.affiliations)\n")
  elseif meta["by-affiliation"] then
    affiliations = meta["by-affiliation"]
    io.stderr:write("[author-plate] Found " .. #affiliations .. " affiliations (from by-affiliation)\n")
  elseif meta.affiliations then
    affiliations = meta.affiliations
    io.stderr:write("[author-plate] Found " .. #affiliations .. " affiliations\n")
  end

  -- Get config from docstyle.author-plate
  if meta.docstyle and meta.docstyle["author-plate"] then
    local ap_config = meta.docstyle["author-plate"]

    if ap_config["corresponding-marker"] then
      config.corresponding_marker = pandoc.utils.stringify(ap_config["corresponding-marker"])
    end
    if ap_config["equal-marker"] then
      config.equal_marker = pandoc.utils.stringify(ap_config["equal-marker"])
    end
    if ap_config["show-orcid"] ~= nil then
      local val = ap_config["show-orcid"]
      config.show_orcid = (type(val) == "boolean" and val) or (pandoc.utils.stringify(val) == "true")
    end
    if ap_config["show-email"] ~= nil then
      local val = ap_config["show-email"]
      config.show_email = (type(val) == "boolean" and val) or (pandoc.utils.stringify(val) == "true")
    end
    if ap_config["affiliation-style"] then
      config.affiliation_style = pandoc.utils.stringify(ap_config["affiliation-style"])
    end
  end

  return nil
end

-- Build the author plate XML
local function build_author_plate_xml()
  if not authors or #authors == 0 then
    return nil
  end

  local aff_map, aff_ordered = build_affiliation_map(affiliations)
  local blocks = {}

  -- Build author line with superscript affiliations
  local author_runs = {}
  local corresponding_email = nil
  local has_equal_contributors = false

  for i, author in ipairs(authors) do
    local name = get_author_name(author)
    local aff_nums = get_author_affiliations(author, aff_map)
    local is_corresponding = has_attribute(author, "corresponding")
    local is_equal = has_attribute(author, "equal-contributor")

    if is_equal then has_equal_contributors = true end

    -- Get email for corresponding author
    if is_corresponding and author.email then
      corresponding_email = pandoc.utils.stringify(author.email)
    end

    -- Build superscript string
    local superscript_parts = {}
    for _, num in ipairs(aff_nums) do
      table.insert(superscript_parts, to_superscript(num))
    end
    if is_corresponding then
      table.insert(superscript_parts, config.corresponding_marker)
    end
    if is_equal then
      table.insert(superscript_parts, config.equal_marker)
    end
    local superscript_str = table.concat(superscript_parts, ",")

    -- Add ORCID if configured
    local orcid_str = ""
    if config.show_orcid and author.orcid then
      orcid_str = " " .. pandoc.utils.stringify(author.orcid)
    end

    -- Build run XML for this author
    local author_xml = '<w:r><w:t xml:space="preserve">' .. xml_escape(name) .. '</w:t></w:r>'

    -- Add superscript
    if superscript_str ~= "" then
      author_xml = author_xml ..
        '<w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr>' ..
        '<w:t>' .. xml_escape(superscript_str) .. '</w:t></w:r>'
    end

    -- Add ORCID
    if orcid_str ~= "" then
      author_xml = author_xml .. '<w:r><w:t xml:space="preserve">' .. xml_escape(orcid_str) .. '</w:t></w:r>'
    end

    -- Add separator (comma) unless last author
    if i < #authors then
      author_xml = author_xml .. '<w:r><w:t xml:space="preserve">, </w:t></w:r>'
    end

    table.insert(author_runs, author_xml)
  end

  -- Author paragraph (centered, Author style)
  local author_para = '<w:p>' ..
    '<w:pPr><w:pStyle w:val="Author"/><w:jc w:val="center"/></w:pPr>' ..
    table.concat(author_runs) ..
    '</w:p>'
  table.insert(blocks, author_para)

  -- Empty paragraph for spacing
  table.insert(blocks, '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>')

  -- Affiliation lines (using Affiliation style)
  for _, aff in ipairs(aff_ordered) do
    local aff_line = to_superscript(aff.number) .. " " .. aff.display
    local aff_para = '<w:p>' ..
      '<w:pPr><w:pStyle w:val="Affiliation"/><w:jc w:val="center"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>' ..
      '<w:r><w:t xml:space="preserve">' .. xml_escape(aff_line) .. '</w:t></w:r>' ..
      '</w:p>'
    table.insert(blocks, aff_para)
  end

  -- Empty paragraph for spacing before footnotes
  table.insert(blocks, '<w:p><w:pPr><w:spacing w:after="120"/></w:pPr></w:p>')

  -- Corresponding author line (using Affiliation style for consistency)
  if config.show_email and corresponding_email then
    local corr_line = config.corresponding_marker .. "Corresponding author: " .. corresponding_email
    local corr_para = '<w:p>' ..
      '<w:pPr><w:pStyle w:val="Affiliation"/><w:jc w:val="center"/></w:pPr>' ..
      '<w:r><w:t xml:space="preserve">' .. xml_escape(corr_line) .. '</w:t></w:r>' ..
      '</w:p>'
    table.insert(blocks, corr_para)
  end

  -- Equal contributors line (using Affiliation style for consistency)
  if has_equal_contributors then
    local equal_line = config.equal_marker .. "These authors contributed equally to this work"
    local equal_para = '<w:p>' ..
      '<w:pPr><w:pStyle w:val="Affiliation"/><w:jc w:val="center"/></w:pPr>' ..
      '<w:r><w:t xml:space="preserve">' .. xml_escape(equal_line) .. '</w:t></w:r>' ..
      '</w:p>'
    table.insert(blocks, equal_para)
  end

  return table.concat(blocks)
end

-- Process Div elements looking for .author-plate class
function Div(div)
  -- Check if this div has the "author-plate" class
  if not div.classes:includes("author-plate") then
    return nil
  end

  -- Only process for docx output
  if FORMAT ~= "openxml" then
    io.stderr:write("[author-plate] Skipping (not docx output)\n")
    return nil
  end

  if not authors or #authors == 0 then
    io.stderr:write("[author-plate] No author metadata found\n")
    return {}  -- Remove the div entirely
  end

  io.stderr:write("[author-plate] Generating author plate with " .. #authors .. " authors\n")

  -- Build the author plate XML
  local plate_xml = build_author_plate_xml()
  if not plate_xml then
    return {}
  end

  -- Wrap in ADDIN DOCSTYLE field code (using shared utility)
  return {
    pandoc.RawBlock("openxml", fcu.build_div_field_start("author-plate")),
    pandoc.RawBlock("openxml", plate_xml),
    pandoc.RawBlock("openxml", fcu.build_block_field_end())
  }
end

-- Check output format
function Pandoc(doc)
  if FORMAT == "docx" or FORMAT == "openxml" then
    FORMAT = "openxml"
  end
  return nil
end

return {
  { Meta = Meta },
  { Div = Div }
}
