-- abstract.lua
-- Emits a DOCSTYLE_ABSTRACT position marker (wrapped in an ADDIN DOCSTYLE
-- div field code) at a :::docstyle-abstract::: placeholder div, so the R
-- post-render relocate_abstract() step can MOVE Pandoc's hoisted
-- AbstractTitle+Abstract paragraphs to that position (#149). docx only;
-- returns nil for typst/jats/latex (Quarto renders the abstract natively
-- there). The placeholder class is docstyle-namespaced, NOT Pandoc's
-- special `.abstract` div.

local fcu = require("field-code-utils")

local function is_word_format()
  return FORMAT == "docx" or FORMAT == "openxml"
end

function Div(div)
  if not div.classes:includes("docstyle-abstract") then
    return nil
  end
  if not is_word_format() then
    return nil  -- Quarto handles the abstract natively for non-docx formats
  end

  -- field_start | DOCSTYLE_ABSTRACT marker paragraph | field_end
  -- No content: the abstract paragraphs are relocated from the document
  -- top by relocate_abstract() in post-render.
  local marker = '<w:p><w:r><w:t xml:space="preserve">DOCSTYLE_ABSTRACT</w:t></w:r></w:p>'
  return pandoc.Blocks({
    pandoc.RawBlock("openxml", fcu.build_div_field_start("abstract")),
    pandoc.RawBlock("openxml", marker),
    pandoc.RawBlock("openxml", fcu.build_block_field_end())
  })
end
