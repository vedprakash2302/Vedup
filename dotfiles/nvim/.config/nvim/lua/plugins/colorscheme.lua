return {
  -- add gruvbox
  { "ellisonleao/gruvbox.nvim", opts = {
    transparent_mode = true,
  } },

  -- Configure LazyVim to load gruvbox
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
    },
  },
}
--
-- return {
--   -- add gruvbox
--   {
--     "catppuccin/nvim",
--     name = "catppuccin",
--     priority = 1000,
--     opts = {
--       flavour = "mocha", -- latte, frappe, macchiato, mocha
--       transparent_background = true,
--   solarized_light    float = {
--         transparent = true, -- enable transparent floating windows
--         solid = false, -- use solid styling for floating windows, see |winborder|
--       },
--       auto_integrations = true,
--       term_colors = true,
--       styles = {
--         comments = { "italic" },
--         conditionals = { "italic" },
--         loops = { "italic" },
--         functions = { "italic" },
--         keywords = { "italic" },
--       },
--     },
--   },
--   -- Configure LazyVim to load gruvbox
--   {
--     "LazyVim/LazyVim",
--     opts = {
--       colorscheme = "catppuccin",
--     },
--   },
-- }
