return {
  "folke/snacks.nvim",
  opts = {
    picker = {
      -- your picker configuration comes here
      -- or leave it empty to use the default settings
      -- refer to the configuration section below
      hidden = true,
      sources = {
        files = {
          hidden = true,
          ignored = true,
          exclude = {
            "**/.git/*",
            "**/node_modules/*",
            "**/.turbo/cache/*",
            "**/dist/*",
            "**/build/*",
            "**/.husky/_/*",
          },
        },
        explorer = {
          layout = {
            layout = {
            width = 30,
            },
          },
        },
      },
    },
    quickfile = { enabled = true },
    terminal = { enabled = true },
    dashboard = { enabled = true },
  },
}
