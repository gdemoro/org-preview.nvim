local op = require("org-preview")
local renderer = require("org-preview.renderer")

local real_render = renderer.render

--- Swap in a renderer that hands control of completion back to the test.
--- `fn(captures)` receives a list of `callback(err, html)` functions, one per
--- call, in call order.
--- @param fn fun(captures: function[])
local function with_fake_renderer(fn)
  local captures = {}
  renderer.render = function(_, callback)
    captures[#captures + 1] = callback
    return {
      kill = function() end,
    }
  end

  local ok, err = pcall(fn, captures)
  renderer.render = real_render
  if not ok then
    error(err)
  end
end

test("hardening: a stale render cannot overwrite a newer one", function()
  local dir = H.temp_dir("race")
  local bufnr = H.open_org(dir, "notes.org", "* One\n")
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  with_fake_renderer(function(captures)
    op.start(bufnr)
    local url = H.preview_for(bufnr).url

    -- Kick off a second render while the first is still in flight.
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "Second" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
    assert(H.wait_for(function()
      return #captures >= 2
    end), "expected two overlapping render jobs")

    -- The newer render completes first; the older one completes afterwards.
    captures[2](nil, "<html><body>NEW</body></html>")
    captures[1](nil, "<html><body>OLD</body></html>")

    local res = H.curl(url)
    assert(res.stdout:match("NEW"), "the newest render should be served")
    assert(not res.stdout:match("OLD"), "a stale render overwrote the newer one")
  end)

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("hardening: a stopped preview ignores late renders", function()
  local dir = H.temp_dir("stale-callback")
  local bufnr = H.open_org(dir, "notes.org")
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  with_fake_renderer(function(captures)
    op.start(bufnr)
    local url = H.preview_for(bufnr).url

    op.stop(bufnr)

    -- The late callback must be ignored without raising an error, and the
    -- stopped preview must no longer serve anything.
    captures[1](nil, "<html><body>STALE</body></html>")
    local res = H.curl(url)
    assert(res.code ~= 0, "a stopped preview must not serve HTML")
  end)

  H.rm_rf(dir)
end)

test("hardening: unnamed Org buffer previews from cwd", function()
  vim.cmd("enew!")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "org"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "* Unnamed heading" })

  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local p = H.preview_for(bufnr)
  assert(p, "expected a preview")
  assert(p.source_dir == vim.uv.cwd(), "expected the cwd fallback")

  assert(H.wait_for(function()
    local res = H.curl(p.url)
    return res.code == 0 and res.stdout:match("Unnamed heading")
  end), "unnamed buffer did not render")

  op.stop(bufnr)
end)

test("hardening: renaming the buffer updates the asset source directory", function()
  local dir_a = vim.uv.fs_realpath(H.temp_dir("rename-a"))
  local dir_b = vim.uv.fs_realpath(H.temp_dir("rename-b"))
  local bufnr = H.open_org(dir_a, "notes.org", "* Hi\n")
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  local ok, err = pcall(function()
    op.start(bufnr)
    local p = H.preview_for(bufnr)
    assert(p and vim.uv.fs_realpath(p.source_dir) == dir_a, "expected the original directory")

    local file_b = vim.fs.joinpath(dir_b, "notes.org")
    vim.cmd("saveas! " .. vim.fn.fnameescape(file_b))

    assert(H.wait_for(function()
      local q = H.preview_for(bufnr)
      return q and vim.uv.fs_realpath(q.source_dir) == dir_b
    end), "the source directory should follow the rename")
  end)

  pcall(op.stop, bufnr)
  H.rm_rf(dir_a)
  H.rm_rf(dir_b)
  if not ok then
    error(err)
  end
end)

test("hardening: reload script survives non-default HTML shapes", function()
  local dir = H.temp_dir("inject")
  local bufnr = H.open_org(dir, "notes.org")
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  -- Uppercase standalone HTML: the script must be inserted before </BODY>.
  with_fake_renderer(function(captures)
    op.start(bufnr)
    local url = H.preview_for(bufnr).url
    captures[1](nil, "<HTML><HEAD></HEAD><BODY>upper</BODY></HTML>")

    local res = H.curl(url)
    assert(res.stdout:match("EventSource"), "script missing for uppercase HTML")
    local script_pos = res.stdout:find("EventSource", 1, true)
    local body_pos = res.stdout:lower():find("</body>", 1, true)
    assert(script_pos and body_pos and script_pos < body_pos, "script should precede </BODY>")
  end)
  op.stop(bufnr)

  -- Fragment with no closing body: the script is appended and still works.
  with_fake_renderer(function(captures)
    op.start(bufnr)
    local url = H.preview_for(bufnr).url
    captures[1](nil, "<p>fragment</p>")

    local res = H.curl(url)
    assert(res.stdout:match("EventSource"), "script missing for fragment HTML")
    assert(res.stdout:match("fragment"), "original content must be preserved")
  end)
  op.stop(bufnr)

  H.rm_rf(dir)
end)
