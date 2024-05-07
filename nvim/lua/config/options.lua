-- numbers for left columns
vim.opt.number = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true
vim.opt.smartindent = true

vim.o.ignorecase = true
vim.o.smartcase = true

vim.opt.termguicolors = true

vim.opt.clipboard = "unnamedplus"

-- change indent behaviors
vim.api.nvim_create_augroup("filetype_indent", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "c", "cpp" },
    group = "filetype_indent",
    command = "setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab",
})
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "javascript", "typescript", "typescriptreact", "html", "css", "lua"},
    group = "filetype_indent",
    command = "setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab",
})
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "yaml", "pkl" },
    group = "filetype_indent",
    command = "setlocal tabstop=2 softtabstop=2 shiftwidth=2 expandtab",
})

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

-- open at the same line number
vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = {"*"},
    callback = function()
        if vim.fn.line("'\"") > 1 and vim.fn.line("'\"") <= vim.fn.line("$") then
            vim.api.nvim_exec("normal! g'\"",false)
        end
    end
})

-- temporary for mojo detection
vim.api.nvim_create_autocmd({"BufRead", "BufNewFile"}, {
    pattern = "*.mojo",
    callback = function()
        vim.bo.filetype = "mojo"
    end,
})
