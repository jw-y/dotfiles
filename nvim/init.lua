local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Set <space> as the leader key
vim.g.mapleader = " " -- Make sure to set `mapleader` before lazy so your mappings are correct

-- packages
require("lazy").setup("plugins")

require("config.options")
require("config.keymaps")

-- require("lsp_config")

vim.cmd.colorscheme "catppuccin"

-- highlight cursor number
vim.opt.cursorline = true
vim.opt.cursorlineopt = "number"
