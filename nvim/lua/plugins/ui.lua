return {
  {
    "nvim-tree/nvim-tree.lua",
    version = "*",
    lazy = false,
    dependencies = {
      "nvim-tree/nvim-web-devicons",
    },
    config = function()
      require("nvim-tree").setup {
        disable_netrw = true,
      }
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    enabled = false,
    opts = {
      theme = "catppuccin",
      options = {
        component_separators = " ",
        section_separators = { left = "", right = "" },
      },
    }
  }
}
