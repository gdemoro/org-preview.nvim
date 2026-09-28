-- Minimal init for the test suite. Run from the repository root:
--   nvim --headless -u tests/minimal_init.lua -l tests/run.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
