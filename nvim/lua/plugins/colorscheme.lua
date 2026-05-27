return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    config = function()
      require("catppuccin").setup({
        flavour = "mocha",
        transparent_background = false,
        integrations = {
          telescope = true,
          gitsigns = true,
          mason = true,
          treesitter = true,
          which_key = true,
          mini = { enabled = true },
          nvim_tree = true,
          blink_cmp = true,
          native_lsp = { enabled = true },
        },
        color_overrides = {
          mocha = {
            base = "#101016",
            mantle = "#000000",
          },
        },
      })
    end
  },
}
