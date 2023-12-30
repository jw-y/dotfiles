-- numbers for left columns
vim.o.number = true
vim.o.relativenumber = true

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
