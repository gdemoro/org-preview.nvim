local op = require("org-preview")

local DEFAULT_TODO = "TODO DOING WAITING | DONE CANCELLED"

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
  local dir = H.temp_dir("workflow")
  local file = vim.fs.joinpath(dir, "notes.org")
  local fd = io.open(file, "w")
  fd:write(content)
  fd:close()
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()

  -- Reset module state so tests are order-independent.
  op.config.css = nil
  op.config.todo_keywords = DEFAULT_TODO
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

test("workflow: TODO gets a semantic span and priority", function()
  local body = render("* TODO [#A] TODO example :test:\n")
  assert(body:find('class="todo TODO"', 1, true), "expected the TODO state span")
  assert(body:find('class="org-priority priority-a"', 1, true), "expected the A priority badge")
end)

test("workflow: DOING gets a semantic span and priority", function()
  local body = render("* DOING [#B] DOING example :test:\n")
  assert(body:find('class="todo DOING"', 1, true), "expected the DOING state span")
  assert(body:find('class="org-priority priority-b"', 1, true), "expected the B priority badge")
end)

test("workflow: WAITING gets a semantic span and priority", function()
  local body = render("* WAITING [#B] WAITING example :test:\n")
  assert(body:find('class="todo WAITING"', 1, true), "expected the WAITING state span")
  assert(body:find('class="org-priority priority-b"', 1, true), "expected the B priority badge")
end)

test("workflow: DONE gets a semantic span and priority", function()
  local body = render("* DONE [#C] DONE example :test:\n")
  assert(body:find('class="done DONE"', 1, true), "expected the DONE state span")
  assert(body:find('class="org-priority priority-c"', 1, true), "expected the C priority badge")
end)

test("workflow: CANCELLED gets a semantic span and priority", function()
  local body = render("* CANCELLED [#C] CANCELLED example :test:\n")
  assert(body:find('class="done CANCELLED"', 1, true), "expected the CANCELLED state span")
  assert(body:find('class="org-priority priority-c"', 1, true), "expected the C priority badge")
end)

test("workflow: ordinary words in a paragraph are not treated as states", function()
  local body = render("* Heading\n\nWe are DOING this while WAITING for review.\n")
  assert(not body:find('class="todo DOING"', 1, true), "paragraph DOING must not be a state")
  assert(not body:find('class="todo WAITING"', 1, true), "paragraph WAITING must not be a state")
end)

test("workflow: keywords inside a code block are not treated as states", function()
  local body = render("* Heading\n\n#+begin_src text\nDOING\nWAITING\nCANCELLED\n#+end_src\n")
  assert(not body:find('class="todo DOING"', 1, true), "code DOING must not be a state")
  assert(not body:find('class="todo WAITING"', 1, true), "code WAITING must not be a state")
  assert(not body:find('class="done CANCELLED"', 1, true), "code CANCELLED must not be a state")
end)

test("workflow: a document's own #+TODO declaration is respected", function()
  local body = render("#+TODO: BACKLOG | FINISHED\n\n* BACKLOG Task\n* FINISHED Task\n")
  assert(body:find('class="todo BACKLOG"', 1, true), "document TODO keywords should be used")
  assert(body:find('class="done FINISHED"', 1, true), "document done keyword should be used")
  assert(not body:find('class="todo TODO"', 1, true), "default TODO must not be injected")
end)

test("workflow: todo_keywords = false disables injection", function()
  local body = render("* DOING Task\n", { todo_keywords = false })
  assert(not body:find("class=\"todo DOING\"", 1, true), "DOING should stay plain text")
end)
