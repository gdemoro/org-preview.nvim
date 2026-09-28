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

--- Create an Org buffer backed by a real file. The directory is canonicalized
--- so path comparisons match `nvim_buf_get_name` on platforms where the temp
--- directory is a symlink (e.g. /var -> /private/var on macOS).
--- @param dir string
--- @param content string|nil
--- @return integer bufnr
local function open_org(dir, content)
  local file = vim.fs.joinpath(dir, "notes.org")
  local fd = io.open(file, "w")
  fd:write(content or "* Hello\n")
  fd:close()
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  return vim.api.nvim_get_current_buf()
end

--- Find the preview registered for a specific buffer.
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

test("hardening: a stale render cannot overwrite a newer one", function()
  local dir = H.temp_dir("race")
  local bufnr = open_org(dir, "* One\n")
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  with_fake_renderer(function(captures)
    op.start(bufnr)
    local url = preview_for(bufnr).url

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

test("hardening: a stopped preview ignores late renders and leaves no cache", function()
  local dir = H.temp_dir("stale-cache")
  local bufnr = open_org(dir)
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  with_fake_renderer(function(captures)
    op.start(bufnr)
    local id = preview_for(bufnr).id
    assert(#captures == 1, "expected the initial render")

    op.stop(bufnr)

    local cache_file = vim.fs.joinpath(vim.fn.stdpath("cache"), "org-preview", id, "index.html")
    captures[1](nil, "<html><body>STALE</body></html>")
    assert(not vim.uv.fs_stat(cache_file), "a late render must not recreate the cache")
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

  local p = preview_for(bufnr)
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
  local bufnr = open_org(dir_a, "* Hi\n")
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  local ok, err = pcall(function()
    op.start(bufnr)
    local p = preview_for(bufnr)
    assert(p and vim.uv.fs_realpath(p.source_dir) == dir_a, "expected the original directory")

    local file_b = vim.fs.joinpath(dir_b, "notes.org")
    vim.cmd("saveas! " .. vim.fn.fnameescape(file_b))

    assert(H.wait_for(function()
      local q = preview_for(bufnr)
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
  local bufnr = open_org(dir)
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })

  -- Uppercase standalone HTML: the script must be inserted before </BODY>.
  with_fake_renderer(function(captures)
    op.start(bufnr)
    local url = preview_for(bufnr).url
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
    local url = preview_for(bufnr).url
    captures[1](nil, "<p>fragment</p>")

    local res = H.curl(url)
    assert(res.stdout:match("EventSource"), "script missing for fragment HTML")
    assert(res.stdout:match("fragment"), "original content must be preserved")
  end)
  op.stop(bufnr)

  H.rm_rf(dir)
end)

test("hardening: stale cache cleanup only removes old, well-formed dirs", function()
  local preview = require("org-preview.preview")
  local root = vim.fs.joinpath(vim.fn.stdpath("cache"), "org-preview")
  vim.fn.mkdir(root, "p")

  local stale = vim.fs.joinpath(root, "99999-1", "index.html")
  local fresh = vim.fs.joinpath(root, "99999-2", "index.html")
  local foreign = vim.fs.joinpath(root, "not-a-preview", "keep.txt")
  vim.fn.mkdir(vim.fs.dirname(stale), "p")
  vim.fn.mkdir(vim.fs.dirname(fresh), "p")
  vim.fn.mkdir(vim.fs.dirname(foreign), "p")

  local function touch(path)
    local fd = io.open(path, "w")
    fd:write("x")
    fd:close()
  end
  touch(stale)
  touch(fresh)
  touch(foreign)

  local long_ago = os.time() - (48 * 60 * 60)
  vim.uv.fs_utime(vim.fs.dirname(stale), long_ago, long_ago)
  vim.uv.fs_utime(vim.fs.dirname(foreign), long_ago, long_ago)

  preview.cleanup_stale_cache(24 * 60 * 60)

  assert(not vim.uv.fs_stat(vim.fs.dirname(stale)), "old preview cache should be removed")
  assert(vim.uv.fs_stat(vim.fs.dirname(fresh)), "fresh preview cache should be kept")
  assert(vim.uv.fs_stat(vim.fs.dirname(foreign)), "unrelated cache dirs should be kept")

  H.rm_rf(vim.fs.dirname(stale))
  H.rm_rf(vim.fs.dirname(fresh))
  H.rm_rf(vim.fs.dirname(foreign))
end)
