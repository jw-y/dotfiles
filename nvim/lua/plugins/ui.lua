return {
  {
    "nvim-tree/nvim-tree.lua",
    version = "*",
    lazy = true,
    cmd = { "NvimTreeToggle", "NvimTreeOpen", "NvimTreeFocus" },
    keys = { { "<C-n>", ":NvimTreeToggle<CR>", desc = "Toggle file tree" } },
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("nvim-tree").setup {
        disable_netrw = true,
        hijack_netrw = true,
      }
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    enabled = true,
    dependencies = { "catppuccin/nvim" },
    after = "catppuccin",
    config = function()
      require("lualine").setup({
        options = {
          --theme = "catppuccin-macchiato",
          --theme = "catppuccin",
          --theme = "catppuccin-mocha",
          theme = "palenight",
          --theme = "material",
          component_separators = "",
          section_separators = { left = '', right = '' }, -- slanted separators
          --section_separators = { left = "", right = "" }, -- round separators
          --component_separators = { left = '', right = ''},
        },
      })
    end
  }
}
