local function setup_lsp()
  local capabilities = require('blink.cmp').get_lsp_capabilities()

  vim.keymap.set('n', '<space>e', vim.diagnostic.open_float)
  vim.keymap.set('n', '[d', function() vim.diagnostic.jump({ count = -1 }) end)
  vim.keymap.set('n', ']d', function() vim.diagnostic.jump({ count = 1 }) end)

  vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup('UserLspConfig', {}),
    callback = function(ev)
      vim.bo[ev.buf].omnifunc = 'v:lua.vim.lsp.omnifunc'
      local opts = { buffer = ev.buf }
      vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
      vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
      vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
      vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, opts)
      vim.keymap.set('n', '<space>rn', vim.lsp.buf.rename, opts)
      vim.keymap.set({ 'n', 'v' }, '<space>ca', vim.lsp.buf.code_action, opts)
      vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
      vim.keymap.set('n', '<space>f', function()
        vim.lsp.buf.format { async = true }
      end, opts)
    end,
  })

  vim.lsp.config('pyright', { capabilities = capabilities })
  vim.lsp.enable('pyright')

  vim.lsp.config('lua_ls', {
    capabilities = capabilities,
    settings = {
      Lua = {
        runtime = { version = 'LuaJIT' },
        workspace = {
          checkThirdParty = false,
          library = { vim.env.VIMRUNTIME }
        }
      }
    }
  })
  vim.lsp.enable('lua_ls')

  vim.lsp.config('ts_ls', { capabilities = capabilities })
  vim.lsp.enable('ts_ls')

  vim.lsp.config('rust_analyzer', {
    capabilities = capabilities,
    settings = { ['rust-analyzer'] = {} },
  })
  vim.lsp.enable('rust_analyzer')
end

return {
  {
    "williamboman/mason.nvim",
    lazy = true,
    cmd = { "Mason", "MasonInstall", "MasonUninstall", "MasonUninstallAll", "MasonLog" },
    config = true,
  },
  {
    "williamboman/mason-lspconfig.nvim",
    lazy = true,
    event = "VeryLazy",
    opts = {
      ensure_installed = {
        "pyright",
        "lua_ls",
        "ts_ls",
        "rust_analyzer",
        "yamlls",
      }
    },
    config = setup_lsp
  },
  {
    'saghen/blink.cmp',
    version = '*',
    event = "InsertEnter",
    opts = {
      keymap = {
        preset = 'super-tab',
        ['<CR>'] = { 'accept', 'fallback' },
      },
      appearance = { nerd_font_variant = 'mono' },
      sources = {
        default = { 'lsp', 'path', 'snippets', 'buffer' },
      },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    lazy = true,
    event = { "BufReadPost", "BufNewFile" },
    config = function()
      require('nvim-treesitter').setup({
        ensure_installed = {
          'python', 'lua', 'yaml', 'bash', 'rust', 'typescript', 'javascript'
        },
        sync_install = false,
        auto_install = false,
        highlight = { enable = true },
        indent = { enable = true },
      })
    end
  },
  {
    "https://github.com/apple/pkl-neovim",
    lazy = true,
    event = "BufReadPre *.pkl",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    build = function()
      vim.cmd("TSInstall! pkl")
    end,
  }
}
