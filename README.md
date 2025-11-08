# Reviewer

A beautiful, fast GitHub Pull Request picker for Neovim with rich previews and seamless checkout integration.

![License](https://img.shields.io/badge/license-MIT-blue.svg)

## ⚠️ Alpha Software Warning

**This plugin is in early alpha development and under active development.**

- Breaking changes may occur without notice
- Features may be incomplete or contain bugs
- Use at your own risk and responsibility
- Always commit your work before testing new features
- Report issues at [GitHub Issues](https://github.com/peterdanulf/reviewer.nvim/issues)

**Not recommended for production workflows yet.** Please test thoroughly in non-critical environments.

## Features

- **Multi-Picker Support**: Auto-detects and uses fzf-lua, Telescope, or Snacks (configurable order)
- **Fast PR Browsing**: Quickly browse all PRs you're involved in
- **Rich Previews**: See PR details, status, reviewers, CI checks, comments, and more
  - **Relative Timestamps**: Human-readable time format ("2 hours ago", "3 days ago")
  - **Visual Age Indicators**: Red highlighting for timestamps 1 week or older
  - **Clean Metadata Display**: Minimal, focused information without clutter
- **Smart Caching**: Prefetches PR data in parallel for instant previews
- **Review Status Icons**: Visual indicators for approved, changes requested, and pending reviews
- **Configurable Comment Filtering**: Choose to show only unresolved comments or all comments
- **Browser Integration**: Open PRs in your browser with a single keypress
- **Git Checkout**: Checkout PR branches directly from the picker with `o`
- **PR Creation**: Create new PRs with `<leader>go` using clean input prompts
  - **Copilot Integration**: Automatically pre-fills title and body from git context when Copilot is available
    - Titles are formatted as actions (imagine "This commit will " before them for consistency)
  - Prompts for title and body (with smart defaults from commits)
  - Auto-assigns PR to you
  - Picker to select reviewer from collaborators (or skip)
  - Option to open in browser after creation
- **Smart Comment Filtering**: Automatically filters out bot comments and test results
- **Beautiful Formatting**: Syntax-highlighted previews with proper markdown rendering

## Requirements

- Neovim >= 0.9.0
- One of the following pickers (auto-detected):
  - [ibhagwan/fzf-lua](https://github.com/ibhagwan/fzf-lua) (recommended, fastest)
  - [nvim-telescope/telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (most popular)
  - [folke/snacks.nvim](https://github.com/folke/snacks.nvim) (modern)
- [GitHub CLI (`gh`)](https://cli.github.com/) - Must be installed and authenticated

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "peterdanulf/reviewer.nvim",
  -- Optional: specify your preferred picker (will auto-detect if not specified)
  dependencies = {
    -- Pick ONE (or install multiple and Reviewer will auto-detect):
    "ibhagwan/fzf-lua",      -- Recommended
    -- "nvim-telescope/telescope.nvim",
    -- "folke/snacks.nvim",
  },
  config = function()
    require('reviewer').setup({
      -- All options are optional, showing defaults here:
      picker_order = { "fzf", "telescope", "snacks" },
      pr_search_filter = "involves:@me state:open sort:updated-desc",
      pr_limit = 20,
      auto_assign_to_me = true,
      auto_open_browser = "ask", -- "always", "never", or "ask"
      show_resolved_comments = false, -- Show resolved comments in preview
      default_reviewers = {}, -- e.g., {"teammate1", "tech-lead"}
      exclude_reviewers = {}, -- e.g., {"dependabot[bot]"}
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'peterdanulf/reviewer.nvim',
  requires = { 'ibhagwan/fzf-lua' }, -- or telescope or snacks
  config = function()
    require('reviewer').setup({
      -- Configure as needed (all optional)
      auto_assign_to_me = true,
      auto_open_browser = "ask",
    })
  end
}
```

## Usage

### Default Keymaps

The plugin sets up the following keymaps:

- `<leader>gr` - Open the PR picker (review existing PRs)
- `<leader>go` - Create a new PR

### Picker Controls

Once the picker is open:

- `Enter` - Open selected PR(s) in browser
- `o` - Checkout the PR branch locally (Snacks/Telescope) or `Alt+O` (fzf-lua)
- `/` or `i` - Filter PRs by typing
- `j/k` or `↓/↑` - Navigate through PRs
- `Esc` or `q` - Close picker

### Status Icons

- `✓` - PR is approved
- `✗` - Changes requested
- `○` - Review required
- `•` - No review decision

## Configuration

The plugin works out of the box with sensible defaults:

```lua
require('reviewer').setup({
  -- Customize picker detection order
  -- Default: { "snacks", "fzf", "telescope" }
  picker_order = { "fzf", "telescope", "snacks" },

  -- Automatically use Copilot for PR title/body suggestions if available
  -- Default: true
  use_copilot_suggestions = true,

  -- GitHub PR search filter (see gh pr list --help for options)
  -- Default: "involves:@me state:open sort:updated-desc"
  pr_search_filter = "involves:@me state:open sort:updated-desc",

  -- Limit number of PRs to fetch
  -- Default: 20
  pr_limit = 20,

  -- Automatically assign PR to yourself when created
  -- Default: true
  auto_assign_to_me = true,

  -- Auto-open PR in browser after creation
  -- Options: "always", "never", "ask"
  -- Default: "ask"
  auto_open_browser = "ask",

  -- Show resolved comments in PR preview
  -- Default: false (only shows unresolved comments)
  show_resolved_comments = false,

  -- Default reviewers to always include in the list
  -- These appear first in the reviewer selection
  -- Default: {}
  default_reviewers = { "teammate1", "lead-dev" },

  -- Reviewers to exclude from the list
  -- Useful for bots or inactive users
  -- Default: {}
  exclude_reviewers = { "dependabot[bot]", "renovate[bot]" },
})
```

### Configuration Examples

#### PR Search Filters

```lua
-- Show only PRs you authored
pr_search_filter = "author:@me state:open sort:updated-desc"

-- Show PRs where you're requested as reviewer
pr_search_filter = "review-requested:@me state:open sort:updated-desc"

-- Show all open PRs in the repo
pr_search_filter = "state:open sort:updated-desc"

-- Show PRs with specific labels
pr_search_filter = "involves:@me state:open label:bug,urgent sort:updated-desc"

-- Show draft PRs you're involved in
pr_search_filter = "involves:@me draft:true sort:updated-desc"
```

#### Reviewer Management

```lua
-- Team workflow: Always include team leads
default_reviewers = { "tech-lead", "team-lead" }

-- Filter out bots and inactive users
exclude_reviewers = { "dependabot[bot]", "renovate[bot]", "ex-employee" }

-- Solo developer: Skip reviewer selection entirely
default_reviewers = {}
auto_assign_to_me = true

-- Fast workflow: Auto-open PRs and skip prompts
auto_open_browser = "always"
auto_assign_to_me = true
```

### Custom Keymaps

```lua
-- Custom keymap example (default is <leader>gr)
vim.keymap.set("n", "<leader>pr", function()
  _G.Reviewer.pick_pr()
end, { desc = "Browse GitHub PRs" })
```

## API

The plugin can be accessed either through the module or globally after setup:

### Module API

```lua
local reviewer = require('reviewer')

-- Setup with configuration
reviewer.setup({
  picker_order = { "fzf", "telescope", "snacks" },
  auto_assign_to_me = true,
  -- ... other options
})

-- Open the PR picker
reviewer.pick_pr()

-- Create a new PR with guided flow
reviewer.create_pr()

-- Access current configuration
local config = reviewer.config
```

### Global API

After setup, the plugin is also available globally via `_G.Reviewer`:

```lua
-- Open PR picker
_G.Reviewer.pick_pr()

-- Create new PR
_G.Reviewer.create_pr()

-- Access configuration
local config = _G.Reviewer.config
```

### Functions

#### `setup(opts)`

Configure the plugin with custom options. All options are optional and will be merged with defaults.

```lua
require('reviewer').setup({
  picker_order = { "fzf", "telescope", "snacks" },
  pr_limit = 30,
  auto_assign_to_me = false,
})
```

#### `pick_pr()`

Opens the PR picker with your configured picker (fzf-lua, telescope, or snacks). Shows PRs matching your search filter with rich previews.

```lua
require('reviewer').pick_pr()
```

#### `create_pr()`

Starts the PR creation flow:

1. Prompts for PR title (with smart defaults from git commits)
2. Prompts for PR body
3. Creates the PR
4. Optionally assigns to you (based on config)
5. Prompts for reviewer selection
6. Optionally opens in browser (based on config)

```lua
require('reviewer').create_pr()
```

### Configuration Access

You can access and modify the configuration at runtime:

```lua
-- View current config
print(vim.inspect(require('reviewer').config))

-- Modify config (not recommended, use setup() instead)
require('reviewer').config.pr_limit = 50
```

## How It Works

1. **Fetching**: Uses `gh pr list` to fetch PRs you're involved in
2. **Prefetching**: Immediately prefetches detailed PR data in parallel for instant previews
3. **Caching**: Caches PR data during picker session to avoid redundant API calls
4. **Preview**: Shows rich PR details including metadata, status checks, comments, and description
5. **Filtering**: Automatically filters out bot comments and automated test results

## Troubleshooting

### "Reviewer not loaded" error

Make sure the plugin is loaded before trying to use it. If integrating with a dashboard, ensure proper plugin load order.

### "No compatible picker found" error

Install at least one of the supported pickers: fzf-lua, telescope.nvim, or snacks.nvim.

### No PRs showing up

1. Ensure `gh` CLI is installed: `gh --version`
2. Authenticate with GitHub: `gh auth login`
3. Check you have PRs: `gh pr list --search "involves:@me state:open"`

### Checkout not working

Make sure you have the GitHub CLI authenticated and the repository is a git repository with a valid remote.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see LICENSE file for details

## Credits

- Supports multiple pickers: [fzf-lua](https://github.com/ibhagwan/fzf-lua), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), [snacks.nvim](https://github.com/folke/snacks.nvim)
- Powered by [GitHub CLI](https://cli.github.com/)
- Inspired by modern PR workflows and developer productivity
