local op = require("org-preview")

local BADGE = '<span class="org-priority'

--- Render `content` through the live pipeline and return the served HTML.
--- @param content string
--- @return string
local function render(content)
  local dir = H.temp_dir("priority")
  local bufnr = H.open_org(dir, "notes.org", content)

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local p = H.preview_for(bufnr)
  assert(p, "expected a preview")
  local html
  assert(H.wait_for(function()
    local res = H.curl(p.url)
    html = res.stdout
    return html:find("EventSource", 1, true) ~= nil
  end), "preview did not render")

  op.stop(bufnr)
  H.rm_rf(dir)
  return H.body_only(html)
end

test("priorities: TODO [#A] heading becomes an A badge", function()
  local html = render("* TODO [#A] Example task\n")
  assert(html:find(BADGE .. " priority-a", 1, true), "expected an A badge")
  assert(html:find('title="Priority A"', 1, true), "expected the title attribute")
  assert(not html:find("[#A]", 1, true), "raw cookie should be replaced")
end)

test("priorities: DONE [#B] heading becomes a B badge", function()
  local html = render("* DONE [#B] Completed task\n")
  assert(html:find(BADGE .. " priority-b", 1, true), "expected a B badge")
  assert(html:find('title="Priority B"', 1, true), "expected the title attribute")
  assert(not html:find("[#B]", 1, true), "raw cookie should be replaced")
end)

test("priorities: [#C] heading without a keyword still becomes a C badge", function()
  local html = render("* [#C] Just a task\n")
  assert(html:find(BADGE .. " priority-c", 1, true), "expected a C badge")
  assert(not html:find("[#C]", 1, true), "raw cookie should be replaced")
end)

test("priorities: any single valid priority character is supported", function()
  local html = render("* [#D] Custom priority\n")
  assert(html:find(BADGE .. " priority-d", 1, true), "expected a generic priority badge")
  assert(html:find('title="Priority D"', 1, true), "expected the title attribute")
  assert(not html:find("[#D]", 1, true), "raw cookie should be replaced")
end)

test("priorities: cookies in a normal paragraph are not transformed", function()
  local html = render("* Heading\n\nThis mentions [#A] in prose.\n")
  assert(html:find("[#A]", 1, true), "paragraph cookie must be preserved verbatim")
  assert(not html:find(BADGE, 1, true), "paragraph cookie must not become a badge")
end)

test("priorities: cookies inside a code block are not transformed", function()
  local html = render("* Heading\n\n#+begin_src text\n[#A]\n#+end_src\n")
  assert(html:find("[#A]", 1, true), "code cookie must be preserved verbatim")
  assert(not html:find(BADGE, 1, true), "code cookie must not become a badge")
end)

test("priorities: a heading without a cookie is unchanged", function()
  local html = render("* Plain heading\n")
  assert(html:find("Plain heading", 1, true), "heading text missing")
  assert(not html:find(BADGE, 1, true), "no badge should be added")
end)
