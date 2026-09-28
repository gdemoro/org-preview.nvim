-- org-drawer.lua: Pandoc Lua filter for org-preview.nvim.
--
-- Pandoc's Org reader already emits a semantic Div for every arbitrary
-- drawer, e.g. `Div ("", ["AI_OUTPUT", "drawer"], []) [...]`. This filter
-- rewrites each such Div into native, JS-free <details>/<summary> markup so
-- the drawer is labelled and collapsible while its content (paragraphs,
-- lists, tables, source blocks, quotes, images, links, ...) is preserved
-- exactly as Pandoc parsed it.
--
-- It is deliberately generic: no drawer name is hard-coded, and it performs
-- no Org parsing.

local function escape_html(text)
  return (text:gsub("[&<>\"']", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#39;",
  }))
end

--- Return the drawer name for a Div that has the `drawer` class, or nil.
--- @param el table
--- @return string|nil
local function drawer_name(el)
  if not el.classes:includes("drawer") then
    return nil
  end
  for _, class in ipairs(el.classes) do
    if class ~= "drawer" then
      return class
    end
  end
  return nil
end

function Div(el)
  local name = drawer_name(el)
  if not name then
    return nil
  end

  local safe = escape_html(name)
  local out = {
    pandoc.RawBlock("html", '<details class="org-drawer" data-drawer-name="' .. safe .. '">'),
    pandoc.RawBlock("html", "<summary>" .. safe .. "</summary>"),
  }
  for _, block in ipairs(el.content) do
    out[#out + 1] = block
  end
  out[#out + 1] = pandoc.RawBlock("html", "</details>")
  return out
end
