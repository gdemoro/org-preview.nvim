local op = require("org-preview")

--- Fetch the served HTML for a buffer.
--- @param bufnr integer
--- @return string
local function serve(bufnr)
  local p = H.preview_for(bufnr)
  assert(p, "expected an active preview")
  return H.curl(p.url).stdout
end

--- Start a preview and wait until `predicate(html)` is satisfied.
--- @param bufnr integer
--- @param predicate fun(html: string): boolean
--- @return string html
local function wait_for_html(bufnr, predicate)
  local html
  assert(H.wait_for(function()
    html = serve(bufnr)
    return predicate(html)
  end), "preview HTML did not satisfy the predicate")
  return html
end

test("styles: built-in stylesheet is injected by default", function()
  local dir = H.temp_dir("styles-default")
  local bufnr = H.open_org(dir, "notes.org", "* Heading\n\nBody text.\n")

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("org-preview.nvim: default stylesheet", 1, true) ~= nil
  end)
  assert(html:find("--op-max-width", 1, true), "expected the max-width variable")
  assert(html:find("--op-max-width: 80ch", 1, true), "expected an 80ch reading width")
  assert(html:find("max-width: var(--op-max-width)", 1, true), "expected centered max width")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: outline headings are compact and the title stays dominant", function()
  local dir = H.temp_dir("styles-hierarchy")
  local bufnr = H.open_org(dir, "notes.org", "#+TITLE: Doc\n\n* TODO Example task\n** Sub\n*** Deeper\n")

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("org-preview.nvim: default stylesheet", 1, true) ~= nil
  end)

  -- Document title is styled separately from outline headings.
  assert(html:find("#title-block-header h1.title", 1, true), "title selector missing")
  assert(html:find("font-size: 1.7rem", 1, true), "document title size missing")
  assert(html:find("font-weight: 700", 1, true), "document title weight missing")

  -- Outline depth sizes.
  assert(html:find("font-size: 1.3rem", 1, true), "h1 outline size missing")
  assert(html:find("font-size: 1.15rem", 1, true), "h2 outline size missing")
  assert(html:find("font-size: 1.05rem", 1, true), "h3 outline size missing")

  -- TODO / DONE badges.
  assert(html:find(".todo", 1, true), "TODO badge selector missing")
  assert(html:find(".done", 1, true), "DONE badge selector missing")
  assert(html:find("border-radius: 999px", 1, true), "badge rounding missing")
  assert(html:find("--op-todo-bg", 1, true), "TODO badge colour token missing")
  assert(html:find("--op-done-bg", 1, true), "DONE badge colour token missing")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: dark-mode block is present", function()
  local dir = H.temp_dir("styles-dark")
  local bufnr = H.open_org(dir, "notes.org", "* Heading\n")

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("prefers-color-scheme: dark", 1, true) ~= nil
  end)
  assert(html:find("prefers-color-scheme: dark", 1, true), "dark-mode media query missing")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: custom css replaces the built-in stylesheet", function()
  local dir = H.temp_dir("styles-custom")
  local bufnr = H.open_org(dir, "notes.org", "* Heading\n")

  op.setup({
    css = "CUSTOM_STYLE_MARKER { color: rgb(1, 2, 3); }",
    open_browser = false,
    auto_open = false,
    debounce = 10,
  })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("CUSTOM_STYLE_MARKER", 1, true) ~= nil
  end)
  assert(not html:find("org-preview.nvim: default stylesheet", 1, true), "default CSS should be replaced")
  assert(not html:find("--op-max-width", 1, true), "default CSS should be replaced")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: custom css can be loaded from a file", function()
  local dir = H.temp_dir("styles-file")
  local css_file = vim.fs.joinpath(dir, "my.css")
  local fd = io.open(css_file, "w")
  fd:write("FILE_STYLE_MARKER { color: rgb(4, 5, 6); }")
  fd:close()

  local bufnr = H.open_org(dir, "notes.org", "* Heading\n")
  op.setup({ css = css_file, open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("FILE_STYLE_MARKER", 1, true) ~= nil
  end)
  assert(not html:find("org-preview.nvim: default stylesheet", 1, true), "file CSS should replace the default")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: css = false disables all injected styling", function()
  local dir = H.temp_dir("styles-off")
  local bufnr = H.open_org(dir, "notes.org", "* Heading\n")

  op.setup({ css = false, open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("Heading", 1, true) ~= nil
  end)
  assert(not html:find("org-preview.nvim: default stylesheet", 1, true), "default CSS should be disabled")
  assert(not html:find("--op-max-width", 1, true), "default CSS should be disabled")
  assert(html:find("CUSTOM_STYLE_MARKER", 1, true) == nil, "unexpected leftover CSS")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: filename is not used as the document title", function()
  local dir = H.temp_dir("title-none")
  local bufnr = H.open_org(dir, "toxicology.org", "* Section\n\nBody text.\n")

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("Section", 1, true) ~= nil
  end)

  assert(not html:find('class="title"', 1, true), "a title block should not be emitted")
  assert(not html:find(">toxicology<", 1, true), "the filename must not become a title")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: an explicit #+TITLE is rendered", function()
  local dir = H.temp_dir("title-explicit")
  local bufnr = H.open_org(dir, "notes.org", "#+TITLE: Real Title\n\n* Section\n")

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("Real Title", 1, true) ~= nil
  end)
  assert(html:find('class="title"', 1, true), "explicit title should render a title block")
  assert(html:find("Real Title", 1, true), "explicit title text missing")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("styles: Org tags are quiet pills with smallcaps neutralised", function()
  local dir = H.temp_dir("styles-tags")
  local bufnr = H.open_org(dir, "notes.org", "* Heading :toxicology:review:\n")

  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("org-preview.nvim: default stylesheet", 1, true) ~= nil
  end)

  assert(html:find(".tag {", 1, true), "tag selector missing")
  assert(html:find("--op-tag-fg", 1, true), "tag colour token missing")
  assert(html:find("--op-tag-bg", 1, true), "tag background token missing")
  assert(html:find("font-size: 0.55em", 1, true), "tag font size missing")
  assert(html:find(".tag .smallcaps", 1, true), "smallcaps override missing")
  assert(html:find("font-variant: normal", 1, true), "smallcaps neutralisation missing")
  assert(html:find(".tag + .tag", 1, true), "adjacent tag spacing missing")

  op.stop(bufnr)
  H.rm_rf(dir)
end)
