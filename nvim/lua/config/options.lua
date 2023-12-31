-- numbers for left columns
vim.opt.number = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smartindent = true

vim.opt.termguicolors = true

vim.api.nvim_create_autocmd("FocusGained", {
    pattern = "*",
    callback = function()
        vim.o.relativenumber = true -- Switch to relative numbers on focus
    end,
})

vim.api.nvim_create_autocmd("FocusLost", {
    pattern = "*",
    callback = function()
        vim.o.relativenumber = false -- Switch to absolute numbers when focus is lost
    end,
})
