# Reviewer

A beautiful, fast GitHub Pull Request picker for Neovim with rich previews, seamless checkout integration, and AI-powered PR creation using GitHub Copilot CLI.

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

- **Multi-Picker Support**: Auto-detects and uses fzf-lua or Telescope (configurable order)
- **Fast PR Browsing**: Quickly browse all PRs you're involved in
- **Flexible PR Filters**: Switch between predefined views with `Alt+F`
  - Awaiting My Review - default
  - My Open PRs
  - Recently Merged (all PRs, last 30 days with dynamic date filtering)
  - All Open PRs in repo
  - All Draft PRs in repo
  - Fully configurable default filter
  - Support for dynamic filters (e.g., automatic date calculations)
- **Rich Previews**: See PR details, status, reviewers, CI checks, comments, and more
  - **Relative Timestamps**: Human-readable time format ("2 hours ago", "3 days ago")
  - **Visual Age Indicators**: Red highlighting for timestamps 1 week or older
  - **Clean Metadata Display**: Minimal, focused information without clutter
- **Smart Caching with Auto-Refresh**: Intelligent cache management for optimal UX
  - Prefetches PR data in parallel for instant previews
  - Automatically detects PR updates in the background
  - Only reopens picker when necessary (status changes, currently viewing updated PR)
  - Silently updates cache when changes don't affect current view
- **Review Status Icons**: Visual indicators for approved, changes requested, and pending reviews
- **Configurable Comment Filtering**: Choose to show only unresolved comments or all comments
- **Browser Integration**: Open PRs in your browser with a single keypress
- **Git Checkout**: Checkout PR branches directly from the picker with `o`
- **PR Creation**: Create new PRs with `<leader>go` using clean input prompts
  - **AI-Powered Title/Body Generation** (Optional): Uses GitHub Copilot CLI to analyze your git diff and generate business-value focused PR titles and descriptions
    - Intelligently detects base branch from git reflog to show only relevant changes
    - Analyzes only unpushed commits (compares against upstream tracking branch or detected base branch)
    - Generates titles in imperative mood (format: "This commit will [YOUR_TITLE]")
    - Focuses on business value and user impact, not technical implementation details
    - Gracefully falls back to commit messages if Copilot is not available
    - Requires: `gh extension install github/gh-copilot` and active Copilot subscription
  - Prompts for title and body with smart defaults
  - Auto-assigns PR to you
  - Picker to select reviewer from collaborators (or skip)
  - Option to open in browser after creation
- **Smart Comment Filtering**: Automatically filters out bot comments and test results
- **Beautiful Formatting**: Syntax-highlighted previews with proper markdown rendering
  - Code blocks rendered in monospace with syntax highlighting
  - Suggestion blocks displayed cleanly without fence markers
  - Inline code highlighted for better readability

## Requirements

- Neovim >= 0.9.0
- One of the following pickers (auto-detected):
  - [ibhagwan/fzf-lua](https://github.com/ibhagwan/fzf-lua) (recommended, fastest)
  - [nvim-telescope/telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [GitHub CLI (`gh`)](https://cli.github.com/) - Must be installed and authenticated

### Optional

- **GitHub Copilot in the CLI** - For AI-powered PR title/body generation
  - Install with: `gh extension install github/gh-copilot`
  - Requires active GitHub Copilot subscription
  - Makes the `copilot` command available in your PATH
  - Can be disabled with `use_copilot_suggestions = false` in config

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "peterdanulf/reviewer.nvim",
  -- Optional: specify your preferred picker (will auto-detect if not specified)
  dependencies = {
    -- Pick ONE (or install both and Reviewer will auto-detect):
    "ibhagwan/fzf-lua",      -- Recommended
    -- "nvim-telescope/telescope.nvim",
  },
  config = function()
    require('reviewer').setup({
      -- All options are optional, showing defaults here:
      picker_order = { "fzf", "telescope" },
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
  requires = { 'ibhagwan/fzf-lua' }, -- or telescope
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
- `o` - Checkout the PR branch locally (Telescope) or `Alt+O` (fzf-lua)
- `Alt+F` - Change filter (Open PRs, Merged PRs, Drafts, etc.)
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
  -- Default: { "fzf", "telescope" }
  picker_order = { "fzf", "telescope" },

  -- Automatically use Copilot for PR title/body suggestions if available
  -- Default: true
  use_copilot_suggestions = true,

  -- GitHub PR search filter (see gh pr list --help for options)
  -- Default: "involves:@me state:open sort:updated-desc"
  -- Note: This is overridden by the default filter in pr_filters
  pr_search_filter = "involves:@me state:open sort:updated-desc",

  -- Predefined PR filters (switch with Alt+F in picker)
  -- Each filter has: name, filter (gh pr list search), description, default (boolean)
  -- The filter marked as default=true will be used when opening the picker
  -- Default: 5 predefined filters (see below)
  pr_filters = {
    {
      name = "Awaiting My Review",
      filter = "review-requested:@me state:open sort:updated-desc",
      description = "PRs where you're requested as a reviewer",
      default = true,
    },
    {
      name = "My Open PRs",
      filter = "author:@me state:open sort:updated-desc",
      description = "PRs you authored that are still open",
      default = false,
    },
    {
      name = "Recently Merged (30 days)",
      filter = "state:merged sort:updated-desc",
      description = "All PRs that were merged in the last 30 days",
      default = false,
      -- Dynamic filter that calculates date 30 days ago
      dynamic_filter = function()
        local days_ago = 30
        local seconds_ago = days_ago * 24 * 60 * 60
        local date = os.date("%Y-%m-%d", os.time() - seconds_ago)
        return "state:merged merged:>=" .. date .. " sort:updated-desc"
      end,
    },
    {
      name = "All Open PRs",
      filter = "state:open -is:draft sort:updated-desc",
      description = "All open PRs in the repository (excluding drafts)",
      default = false,
    },
    {
      name = "Draft PRs",
      filter = "is:draft sort:updated-desc",
      description = "All draft PRs in the repository",
      default = false,
    },
  },

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

#### PR Filters

Customize the predefined filters or add your own:

```lua
-- Add a custom filter for urgent PRs
pr_filters = {
  {
    name = "Urgent PRs",
    filter = "involves:@me state:open label:urgent sort:updated-desc",
    description = "Open PRs with urgent label",
    default = true,  -- Make this the default view
  },
  {
    name = "Recently Merged (7 days)",
    filter = "involves:@me state:merged sort:updated-desc merged:>7-days-ago",
    description = "PRs merged in the last week",
    default = false,
  },
  -- Add more custom filters as needed
}

-- Or keep the defaults and just change which one is default
pr_filters = {
  -- ... copy default filters from setup() docs above ...
  -- Just change default = true on the filter you want as default
}
```

#### Legacy PR Search Filter

If you prefer the old single-filter approach, you can still use `pr_search_filter`:

```lua
-- Note: This is overridden by pr_filters if both are specified
pr_search_filter = "author:@me state:open sort:updated-desc"
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
  picker_order = { "fzf", "telescope" },
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
  picker_order = { "fzf", "telescope" },
  pr_limit = 30,
  auto_assign_to_me = false,
})
```

#### `pick_pr()`

Opens the PR picker with your configured picker (fzf-lua, telescope,). Shows PRs matching your search filter with rich previews.

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

### Basic Flow

1. **Fetching**: Uses `gh pr list` to fetch PRs you're involved in
2. **Prefetching**: Immediately prefetches detailed PR data in parallel for instant previews
3. **Caching**: Caches PR data during picker session to avoid redundant API calls
4. **Preview**: Shows rich PR details including metadata, status checks, comments, and description
5. **Filtering**: Automatically filters out bot comments and automated test results

### Smart Cache Refresh

The plugin intelligently manages cache updates to provide the best user experience:

#### When You Open the Picker

- **First Time**: Shows "Loading PRs..." and fetches all data
- **Subsequent Opens**: Shows cached PRs instantly while checking for updates in the background

#### Background Update Detection

When the picker is open, it automatically checks for PR updates by comparing timestamps:

- **Left Window Changes** (PR list icons/titles):
  - Review status changes (✗ → ✓)
  - PR title changes
  - Author changes
  - **Action**: Picker reopens to show fresh data

- **Right Window Changes** (preview details only):
  - New review comments added
  - PR description edited
  - New commits pushed
  - **Action**: Cache updated silently, no disruption

#### Intelligent Reopen Logic

The picker only reopens when necessary:

1. **Currently viewing updated PR**: If you're looking at PR #3 and it gets new comments → reopens to show fresh preview
2. **Left window data changed**: If any PR's status icon changes → reopens to show fresh icons
3. **Other PR updated**: If you're viewing PR #3 and PR #5 gets updated → stays open, no disruption

This ensures you always see fresh data without unnecessary interruptions.

## Troubleshooting

### "Reviewer not loaded" error

Make sure the plugin is loaded before trying to use it. If integrating with a dashboard, ensure proper plugin load order.

### "No compatible picker found" error

Install at least one of the supported pickers: fzf-lua, telescope.nvim,.nvim.

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

- Supports multiple pickers: [fzf-lua](https://github.com/ibhagwan/fzf-lua), [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- Powered by [GitHub CLI](https://cli.github.com/)
- Inspired by modern PR workflows and developer productivity
