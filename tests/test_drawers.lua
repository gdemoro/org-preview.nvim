local op = require("org-preview")

--- @param bufnr integer
--- @return table|nil
local function preview_for(bufnr)
  for _, p in ipairs(op.info().previews) do
    if p.bufnr == bufnr then
      return p
    end
  end
  return nil
end

--- Strip <style>/<script> blocks so assertions only see markup.
--- @param html string
--- @return string
local function body_only(html)
  html = html:gsub("<style>.-</style>", "")
  html = html:gsub("<script>.-</script>", "")
  return html
end

--- Render `content` through the live pipeline and return the served body.
--- @param content string
--- @param opts table|nil
--- @return string
local function render(content, opts)
  local dir = H.temp_dir("drawer")
  local file = vim.fs.joinpath(dir, "notes.org")
  local fd = io.open(file, "w")
  fd:write(content)
  fd:close()
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()

  -- Reset module state so tests are order-independent.
  op.config.css = nil
  op.config.drawers = true
  op.setup(vim.tbl_extend("force", {
    open_browser = false,
    auto_open = false,
    debounce = 10,
  }, opts or {}))
  op.start(bufnr)

  local p = preview_for(bufnr)
  assert(p, "expected a preview")
  local html
  assert(H.wait_for(function()
    local res = H.curl(p.url)
    html = res.stdout
    return html:find("EventSource", 1, true) ~= nil
  end), "preview did not render")

  op.stop(bufnr)
  H.rm_rf(dir)
  return body_only(html)
end

test("drawers: arbitrary drawer becomes a details/summary block", function()
  local body = render("* Heading\n\n:AI_OUTPUT:\nSome text.\n:END:\n")
  assert(body:find('<details class="org-drawer"', 1, true), "expected a <details> drawer")
  assert(body:find("<summary>AI_OUTPUT</summary>", 1, true), "expected a summary")
  assert(body:find("</details>", 1, true), "expected the drawer to close")
end)

test("drawers: the drawer name is preserved", function()
  local body = render("* Heading\n\n:CUSTOM_NAME:\ncontent\n:END:\n")
  assert(body:find('data-drawer-name="CUSTOM_NAME"', 1, true), "data-drawer-name missing")
  assert(body:find("<summary>CUSTOM_NAME</summary>", 1, true), "summary name missing")
end)

test("drawers: drawers are closed by default", function()
  local body = render("* Heading\n\n:AI_OUTPUT:\ncontent\n:END:\n")
  local tag = body:match("<details[^>]*>")
  assert(tag, "expected a <details> tag")
  assert(not tag:find("open", 1, true), "drawer must not be open by default")
end)

test("drawers: paragraph content survives", function()
  local body = render("* Heading\n\n:AI_OUTPUT:\nA generated paragraph.\n:END:\n")
  assert(body:find("<p>A generated paragraph.</p>", 1, true), "paragraph lost inside drawer")
end)

test("drawers: list content survives", function()
  local body = render("* Heading\n\n:DATA:\n- first item\n- second item\n:END:\n")
  assert(body:find("<li>first item</li>", 1, true), "list item lost inside drawer")
  assert(body:find("<li>second item</li>", 1, true), "second list item lost inside drawer")
end)

test("drawers: source block content survives", function()
  local body = render("* Heading\n\n:DATA:\n#+begin_src python\nprint(\"hi\")\n#+end_src\n:END:\n")
  assert(body:find("sourceCode python", 1, true), "source block lost inside drawer")
  assert(body:find("print", 1, true), "source code text lost inside drawer")
end)

test("drawers: two differently named drawers both render", function()
  local body = render("* Heading\n\n:A_ONE:\nfirst\n:END:\n\n:B_TWO:\nsecond\n:END:\n")
  assert(body:find('data-drawer-name="A_ONE"', 1, true), "first drawer missing")
  assert(body:find('data-drawer-name="B_TWO"', 1, true), "second drawer missing")
  assert(body:find("<summary>A_ONE</summary>", 1, true), "first summary missing")
  assert(body:find("<summary>B_TWO</summary>", 1, true), "second summary missing")
end)

test("drawers: drawers = false keeps the previous plain div behavior", function()
  local body = render("* Heading\n\n:AI_OUTPUT:\ncontent\n:END:\n", { drawers = false })
  assert(body:find('<div class="AI_OUTPUT drawer">', 1, true), "expected the plain drawer div")
  assert(not body:find("<details", 1, true), "no details should be produced")
  assert(not body:find("org-drawer", 1, true), "no drawer class should be produced")
end)

test("drawers: non-drawer rendering is unaffected", function()
  local body = render("* Heading\n\nText.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n")
  assert(body:find("<h1", 1, true), "heading missing")
  assert(body:find("<p>Text.</p>", 1, true), "paragraph missing")
  assert(body:find("<table>", 1, true), "table missing")
  assert(not body:find("org-drawer", 1, true), "no drawer markup expected")
end)
