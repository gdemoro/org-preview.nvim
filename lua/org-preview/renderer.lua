--- Pandoc-backed Org -> HTML renderer.
---
--- This module knows nothing about servers, buffers or autocmds. It only
--- turns an Org source string into a standalone HTML document by shelling
--- out to pandoc. Rendering is asynchronous: `render` returns immediately
--- and invokes `callback(err, html)` when pandoc exits.
local M = {}

--- Check whether pandoc can be found in `$PATH`.
--- @return boolean
function M.is_available()
  return vim.fn.executable("pandoc") == 1
end

--- Absolute path to the pandoc executable (or nil when unavailable).
--- @return string|nil
function M.pandoc_path()
  local path = vim.fn.exepath("pandoc")
  if path == "" then
    return nil
  end
  return path
end

--- Build the pandoc argument list.
--- @return string[]
local function build_args()
  return {
    M.pandoc_path() or "pandoc",
    "--from=org",
    "--to=html5",
    "--standalone",
    -- Keep only pandoc's structural CSS; org-preview provides the visual
    -- theme (assets/default.css or the user's `css`).
    "--metadata=document-css=false",
  }
end

--- Does the Org source already declare its own TODO keywords?
--- Pandoc understands `#+TODO:`, `#+SEQ_TODO:` and `#+TYP_TODO:`; when one
--- is present we must not inject our own.
--- @param content string
--- @return boolean
local function has_todo_keywords(content)
  for line in content:gmatch("[^\n]*") do
    if line:lower():match("^#%+[%w_]*todo:") then
      return true
    end
  end
  return false
end

--- Prepend a `#+TODO:` declaration when the document has none, so the Org
--- reader assigns semantic classes to custom workflow states (DOING,
--- WAITING, CANCELLED, ...). This is pandoc's own configuration mechanism,
--- not a re-implementation of Org parsing.
--- @param content string
--- @param todo_keywords string|nil
--- @return string
local function prepare_content(content, todo_keywords)
  if not todo_keywords or todo_keywords == "" then
    return content
  end
  if has_todo_keywords(content) then
    return content
  end
  return "#+TODO: " .. todo_keywords .. "\n\n" .. content
end

--- Render `opts.content` (a string of Org source) to HTML.
---
--- opts:
---   content       (string)  Org source, e.g. the current buffer contents
---   source_dir    (string)  directory the document lives in; pandoc is run
---                           with this as cwd so relative resources/links
---                           are kept relative to the source Org file
---   todo_keywords (string)  Org TODO workflow in pandoc `#+TODO:` syntax
---   drawer_filter (string)  path to the bundled org-drawer Lua filter
---   pandoc_args   (string[]) extra arguments appended to the pandoc call
---
--- No `title` metadata is injected: if the Org document declares a
--- `#+TITLE`, pandoc renders it as the document title; otherwise no title
--- block is emitted (so the filename never becomes a title by accident).
---
--- @param opts table
--- @param callback fun(err: string|nil, html: string|nil)
--- @return table|nil handle A job handle that can be `:kill()`ed.
function M.render(opts, callback)
  if not M.is_available() then
    callback(
      "pandoc was not found in $PATH. Install it from https://pandoc.org/installing.html "
        .. "and make sure it is available to Neovim.",
      nil
    )
    return nil
  end

  local args = build_args()
  if opts.drawer_filter then
    args[#args + 1] = "--lua-filter"
    args[#args + 1] = opts.drawer_filter
  end
  for _, arg in ipairs(opts.pandoc_args or {}) do
    args[#args + 1] = arg
  end

  local content = prepare_content(opts.content or "", opts.todo_keywords)

  -- vim.system's on_exit runs in a libuv fast-event context, where most Vim
  -- APIs (notify, fn.*, buffer access) are off limits. Marshal the result
  -- back to the main loop before invoking the user callback.
  local function dispatch(err, html)
    vim.schedule(function()
      callback(err, html)
    end)
  end

  local ok, handle = pcall(vim.system, args, {
    stdin = content,
    cwd = opts.source_dir,
    text = true,
  }, function(obj)
    if obj.code ~= 0 then
      local stderr = obj.stderr or ""
      if stderr == "" then
        stderr = "pandoc exited with code " .. tostring(obj.code)
      end
      dispatch("org-preview: pandoc failed: " .. stderr, nil)
      return
    end
    dispatch(nil, obj.stdout or "")
  end)

  if not ok then
    dispatch("org-preview: failed to run pandoc: " .. tostring(handle), nil)
    return nil
  end

  return handle
end

return M
