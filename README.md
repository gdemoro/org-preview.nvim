# org-preview.nvim

Live browser preview for [Org-mode](https://orgmode.org/) files in Neovim,
conceptually similar to [markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim),
but **pure Lua** and using **Pandoc** for the Org → HTML conversion.

- Preview the **current buffer contents**, including unsaved edits.
- Automatically re-render while you type, with a configurable debounce.
- The browser reloads itself over **Server-Sent Events** (no scroll sync).
- One local HTTP server per Neovim instance, bound to IPv4 loopback
  (`127.0.0.1`) only; it rejects Host headers other than `127.0.0.1:<port>`
  or `localhost:<port>`.
- Multiple Org buffers can be previewed at the same time.
- Relative links/images keep working: the local server can serve files under
  the Org file's source directory, not only assets referenced by the document.
- Pandoc is the only external runtime dependency. No Node.js, no npm.

## Requirements

- Neovim **0.10+** (uses `vim.system`, `vim.ui.open`, `vim.fs`).
- [Pandoc](https://pandoc.org/installing.html) available in `$PATH`.
  Pandoc 3.x recommended. Older versions are not currently tested.

Check that Neovim can see pandoc:

```vim
:echo executable('pandoc')
" => 1
```

## Installation

### lazy.nvim

```lua
{
  "gdemoro/org-preview.nvim",
  ft = "org",
  cmd = { "OrgPreview", "OrgPreviewStop", "OrgPreviewToggle" },
  opts = {
    debounce = 300,
    open_browser = true,
  },
  keys = {
    { "<leader>op", "<cmd>OrgPreview<cr>", desc = "Org preview" },
    { "<leader>oP", "<cmd>OrgPreviewToggle<cr>", desc = "Toggle Org preview" },
    { "<leader>oq", "<cmd>OrgPreviewStop<cr>", desc = "Stop Org preview" },
  },
}
```

`opts` is passed straight to `require("org-preview").setup()`.

### Manual

```lua
require("org-preview").setup({})
```

## Commands

| Command             | Description                                            |
| ------------------- | ------------------------------------------------------ |
| `:OrgPreview`       | Start (or re-open) a live preview for the current buffer |
| `:OrgPreviewStop`   | Stop the preview for the current buffer                |
| `:OrgPreviewToggle` | Toggle the preview for the current buffer              |

The preview URL is printed with `vim.notify`. When `open_browser` and
`auto_open` are enabled, the URL is opened with `vim.ui.open()`.

## Configuration

```lua
require("org-preview").setup({
  -- Open the browser automatically when a preview starts.
  auto_open = true,

  -- Milliseconds to wait after the last edit before re-rendering.
  debounce = 300,

  -- Port for the local preview server. 0 picks a free port automatically.
  port = 0,

  -- Master switch for launching a browser. Set to false on headless or
  -- remote machines; the URL is still printed so you can open it manually.
  open_browser = true,

  -- Stylesheet. nil uses the bundled assets/default.css. A path to a .css
  -- file or a raw CSS string replaces the bundled sheet. false or ""
  -- disables styling entirely (bare pandoc output).
  css = nil,

  -- Org TODO workflow, in pandoc's `#+TODO:` syntax. This is injected into
  -- the buffer fed to pandoc only when the document does not already
  -- declare its own #+TODO / #+SEQ_TODO / #+TYP_TODO line. Set to false to
  -- keep only pandoc's built-in TODO/DONE handling.
  todo_keywords = "TODO DOING WAITING | DONE CANCELLED",

  -- Render Org drawers as collapsible native <details>/<summary> blocks via
  -- a bundled Pandoc Lua filter. Set to false to keep pandoc's plain
  -- `<div class="NAME drawer">` output.
  drawers = true,

  -- Extra arguments appended to the pandoc command line.
  pandoc_args = {},
})
```

### TODO workflow states

Org TODO keywords are delegated to pandoc's own Org reader. By default
org-preview tells pandoc about a five-state workflow
(`TODO DOING WAITING | DONE CANCELLED`) so every state gets a semantic span:

```html
<span class="todo DOING">DOING</span>
<span class="done CANCELLED">CANCELLED</span>
```

If your Org file already contains a `#+TODO:`/`#+SEQ_TODO:`/`#+TYP_TODO:`
line, that declaration is used and nothing is injected. To match a custom
workflow, set `todo_keywords` to the same syntax, e.g.
`"TODO NEXT | DONE CANCELLED"`. Only keywords in the heading position are
recognized; the same words in paragraphs or code blocks are left alone.

### Drawers

Arbitrary Org drawers — `:AI_OUTPUT:`, `:CUSTOM_NAME:`, `:NOTES:`, etc. —
are transformed by the bundled `assets/org-drawer.lua` Pandoc Lua filter into
native, JavaScript-free collapsible blocks:

```html
<details class="org-drawer" data-drawer-name="AI_OUTPUT">
  <summary>AI_OUTPUT</summary>
  …paragraphs, lists, tables, source blocks, quotes…
</details>
```

The filter works on Pandoc's AST (Pandoc already emits a `Div` with classes
`[NAME, drawer]` for every arbitrary drawer), so it is generic, preserves
the parsed content, and does not parse Org. Drawers are **closed by default**
to keep long notes compact. Set `drawers = false` to keep Pandoc's plain
`<div class="NAME drawer">` output.

`PROPERTIES` and `LOGBOOK` are left to Pandoc's built-in handling:
`PROPERTIES` is folded into heading attributes, and `LOGBOOK` is dropped by
the reader before the AST.

### Styling

A clean, compact default stylesheet (`assets/default.css`) is
injected automatically. It is self-contained and works offline, provides a
centered reading column (`max-width: 80ch`), a system sans-serif stack, a
compact line height, a readable heading hierarchy, styled
blockquotes/code/tables/lists/images, an inline-code style, horizontally
scrolling code blocks and tables, and automatic dark mode via
`@media (prefers-color-scheme: dark)`.

`css` is a **replace**, not an add-on:

| `css` value            | Result                                              |
| ---------------------- | --------------------------------------------------- |
| `nil` (default)        | bundled `assets/default.css`                        |
| path to a `.css` file  | that file replaces the bundled sheet                |
| raw CSS string         | the string replaces the bundled sheet               |
| `false` or `""`        | no injected styling (bare pandoc structural CSS)    |

The bundled sheet is layered after pandoc's structural CSS, and pandoc's own
opinionated theme is disabled (`document-css=false`), so the chosen
stylesheet is authoritative.

### Document title

No `title` is injected into pandoc. The filename is therefore **never**
rendered as a large document title. If the Org file declares `#+TITLE:`,
pandoc renders that as the document title block; otherwise no title block is
emitted. (The browser tab may show `-` for untitled documents, since pandoc
requires a non-empty `<title>` element.)

## Integration with nvim-orgmode

`org-preview.nvim` is designed to sit next to
[nvim-orgmode](https://github.com/nvim-orgmode/orgmode). It does **not** import,
patch or otherwise depend on nvim-orgmode internals. It only relies on the
buffer being an Org buffer (`filetype=org` or a `*.org` filename).

Suggested lazy.nvim setup that loads both plugins for `org` files:

```lua
{
  "nvim-orgmode/orgmode",
  ft = "org",
  config = function()
    require("orgmode").setup({})
  end,
},
{
  "gdemoro/org-preview.nvim",
  ft = "org",
  cmd = { "OrgPreview", "OrgPreviewStop", "OrgPreviewToggle" },
  opts = {},
  keys = {
    { "<leader>op", "<cmd>OrgPreview<cr>", desc = "Org preview" },
    { "<leader>oP", "<cmd>OrgPreviewToggle<cr>", desc = "Toggle Org preview" },
    { "<leader>oq", "<cmd>OrgPreviewStop<cr>", desc = "Stop Org preview" },
  },
},
```

Because rendering reads the buffer directly, it works regardless of whether
nvim-orgmode has folded, narrowed or modified the buffer's display — the
preview always shows the underlying text.

## How it works

```
 assets/
   default.css   bundled, offline default stylesheet
 lua/org-preview/
   init.lua      setup(), commands, single shared server lifecycle
   renderer.lua  buffer text --(pandoc)--> standalone HTML
   server.lua    libuv HTTP server, SSE reload stream, static assets
   preview.lua   per-buffer autocmds, debounce timers, pandoc jobs
```

1. `:OrgPreview` starts one shared HTTP server (`server.lua`) bound only to
   `127.0.0.1` (IPv4 loopback), choosing a free port when `port = 0`.
   Requests must carry a `Host` header with that port and either `127.0.0.1`
   or `localhost`; IPv6 `::1` is not served.
2. `preview.lua` registers the buffer, hooks `TextChanged`/`TextChangedI`/
   `InsertLeave`/`BufWritePost`/`BufFilePost`, and debounces re-renders.
3. `renderer.lua` pipes the **current buffer text** to `pandoc` (run with the
   Org file's directory as the working directory) and returns HTML.
4. The HTML is cached under `stdpath("cache")/org-preview/<id>/index.html`
   and served from `http://127.0.0.1:<port>/preview/<id>/`.
5. A tiny injected script opens an `EventSource` on `/preview/<id>/__events`.
   After each render the server pushes a `reload` event and the browser
   refreshes. The chosen stylesheet is injected before `</head>`.
6. Relative assets resolve against `/preview/<id>/`. The local preview
   server can serve **any file within the Org source directory**, not only
   files referenced in the rendered document; do not treat that directory
   as private while a preview is running. Unnamed buffers use Neovim's
   current working directory instead.

`stdpath("cache")` is cleaned up per preview when the preview is stopped, and
everything is torn down on `VimLeavePre`.

### Edge-case behavior

- **Unsaved buffers**: everything is rendered from buffer text, so unsaved
  edits always appear. A buffer with **no filename** is still previewed; its
  relative assets resolve from the current working directory (`uv.cwd()`),
  and a notification tells you so. Saving the buffer to a path updates the
  asset root automatically.
- **Renames**: `BufFilePost`/`BufWritePost` detect when the buffer is saved
  or `:saveas`-ed elsewhere and update the asset source directory and
  re-render, without restarting the preview.
- **Rendering order**: each preview carries a monotonically increasing
  generation token. If two pandoc renders overlap and finish out of order,
  the older result is discarded, so it can never overwrite the newer one.
  Stopping a preview invalidates the token, so a late callback cannot
  re-create the cache directory or touch the server.
- **Asset security**: asset URLs are percent-decoded, backslashes are treated
  as separators, `..` components are rejected, and the final path is
  canonicalized with `fs_realpath` and checked to remain inside the source
  directory. **Symlinks are followed, but a symlink whose real target
  escapes the source directory is refused.**
- **Injection robustness**: the reload script is injected before a
  case-insensitive `</body>` (allowing whitespace); if there is no closing
  body it is appended. Unusual or fragment-only HTML still previews and
  reloads.
- **Cache hygiene**: cache directories matching our `<bufnr>-<counter>` id
  pattern that are older than 24 hours are removed once per Neovim session,
  cleaning up after crashed sessions. Active previews serve HTML from memory,
  so this can never break a running preview.

## Troubleshooting

- **"pandoc was not found in $PATH"** — install pandoc and make sure the
  executable Neovim sees is the one on your `$PATH`. GUI/AppImage installs
  sometimes have a different environment than your shell.
- **Blank page / nothing renders** — check `:messages`; the error output from
  pandoc is shown in the page and logged as a notification.
- **Port already in use** — leave `port = 0`, or pick another port.
- **Browser does not open** — set `open_browser = false` and open the printed
  URL manually. `vim.ui.open` needs a working opener (`xdg-open`, `open`,
  `wslview`, ...).

## Tests

The suite uses a small home-grown runner (no test framework required):

```sh
make test
# or
nvim --headless -u tests/minimal_init.lua -l tests/run.lua
```

The full suite requires Pandoc and `curl` on `$PATH`; `curl` is a test-only
dependency. Without Pandoc, the renderer tests are bypassed but integration
tests fail. Without `curl`, tests that use it fail rather than skip.

The suite includes regression tests for:

- overlapping renders completing out of order;
- late callbacks after `:OrgPreviewStop`;
- encoded path-traversal attempts and symlink escapes;
- unnamed buffers and buffer renames;
- reload-script injection into non-default HTML shapes;
- default/custom CSS injection, dark mode, and the absence of a filename title.

## Limitations (v1)

- No scroll synchronization (intentionally out of scope).
- No built-in Org parser; pandoc does all of the conversion.
- HTML is served from memory; the on-disk copy in the cache directory is for
  inspection only.

## License

MIT
