local op = require("org-preview")

test("commands: OrgPreview commands are defined", function()
  assert(vim.fn.exists(":OrgPreview") == 2, ":OrgPreview missing")
  assert(vim.fn.exists(":OrgPreviewStop") == 2, ":OrgPreviewStop missing")
  assert(vim.fn.exists(":OrgPreviewToggle") == 2, ":OrgPreviewToggle missing")
end)

--- Fetch a URL until it contains `needle`, or give up.
local function wait_for_body(url, needle)
  local found = false
  H.wait_for(function()
    local res = H.curl(url)
    if res.code == 0 and res.stdout:match(needle) then
      found = true
      return true
    end
    return false
  end)
  return found
end

test("integration: start, live update, stop", function()
  local dir = H.temp_dir("e2e")
  local file = vim.fs.joinpath(dir, "notes.org")
  local fd = io.open(file, "w")
  fd:write("* First heading\n")
  fd:close()

  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()

  op.setup({ open_browser = false, auto_open = false, debounce = 50 })
  op.start(bufnr)

  local info = op.info()
  assert(info.server and info.server.port, "expected a running server")
  assert(#info.previews == 1, "expected one registered preview")
  local url = info.previews[1].url

  -- The initial render must expose the buffer contents.
  assert(wait_for_body(url, "First heading"), "initial render not served")

  -- The injected SSE client must be present.
  local res = H.curl(url)
  assert(res.stdout:match("EventSource"), "expected the SSE reload client to be injected")

  -- Unsaved edits must show up after the debounce.
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "Second heading" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  assert(wait_for_body(url, "Second heading"), "live update not served")

  -- The rendered document is generated under stdpath("cache")/org-preview/.
  local id = op.info().previews[1].id
  local cache_file = vim.fs.joinpath(vim.fn.stdpath("cache"), "org-preview", id, "index.html")
  assert(vim.uv.fs_stat(cache_file), "expected a cached index.html at " .. cache_file)

  -- Stopping tears everything down.
  op.stop(bufnr)
  assert(op.info().server == nil, "server should stop when the last preview stops")
  assert(#op.info().previews == 0, "no previews should remain")
  assert(not vim.uv.fs_stat(cache_file), "cache file should be removed on stop")

  H.rm_rf(dir)
end)
