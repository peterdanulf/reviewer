-- Reviewer - GitHub PR Picker for Neovim
-- A beautiful, fast PR picker with rich previews
-- Supports: fzf-lua or telescope.nvim (auto-detected, configurable)

---@class ReviewerConfig
---@field picker_order string[] Order to detect pickers: "fzf", "telescope"
---@field use_copilot_suggestions boolean Automatically use Copilot for PR title/body suggestions if available
---@field pr_search_filter string GitHub PR search filter (see gh pr list --help for options)
---@field pr_limit number Limit number of PRs to fetch
---@field auto_assign_to_me boolean Automatically assign PR to yourself when creating
---@field auto_open_browser "always"|"never"|"ask" Browser behavior
---@field default_reviewers string[] Always include these reviewers in the selection list
---@field exclude_reviewers string[] Never show these reviewers in the selection list

---@class PullRequest
---@field number number PR number
---@field title string PR title
---@field author {login: string} Author information
---@field reviewDecision? "APPROVED"|"CHANGES_REQUESTED"|"REVIEW_REQUIRED" Review decision
---@field body? string PR body/description
---@field state string PR state (OPEN, CLOSED, MERGED)
---@field url string PR URL
---@field createdAt string Creation date
---@field updatedAt string Last update date

---@class Reviewer
local M = {}

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

---@type ReviewerConfig
M.config = {
  picker_order = { "fzf", "telescope" },
  use_copilot_suggestions = true,
  pr_search_filter = "involves:@me state:open sort:updated-desc",
  pr_limit = 20,
  auto_assign_to_me = true,
  auto_open_browser = "ask",
  default_reviewers = {},
  exclude_reviewers = {},
  -- Show only unresolved review comments (default: true)
  show_only_unresolved_review_comments = true,
  -- Delay before showing reviewer selection (milliseconds)
  reviewer_selection_delay = 100,
  -- Maximum concurrent PR fetches for prefetching
  max_concurrent_fetches = 3,
  -- Timeout for git/gh operations (milliseconds)
  operation_timeout = 30000,
  -- Network retry configuration
  max_retries = 3,
  retry_delay = 1000,
  -- Rate limit delay (milliseconds)
  rate_limit_delay = 5000,
}

-- Helper function to validate a single config option
local function validate_opt(opts, key, validator, err_msg)
  if opts[key] and not validator(opts[key]) then
    vim.notify("reviewer: " .. err_msg, vim.log.levels.ERROR)
    opts[key] = nil
  end
end

---Setup the plugin with user configuration
---@param opts? ReviewerConfig User configuration
function M.setup(opts)
  opts = opts or {}

  -- ========== Validate Configuration ==========

  -- Validate picker_order
  if opts.picker_order then
    if type(opts.picker_order) ~= "table" then
      vim.notify("reviewer: picker_order must be a table", vim.log.levels.ERROR)
      opts.picker_order = nil
    else
      for _, picker in ipairs(opts.picker_order) do
        if not vim.tbl_contains({"fzf", "telescope"}, picker) then
          vim.notify("reviewer: Invalid picker in picker_order: " .. tostring(picker), vim.log.levels.ERROR)
          opts.picker_order = nil
          break
        end
      end
    end
  end

  -- Validate numeric options
  validate_opt(opts, "pr_limit",
    function(v) return type(v) == "number" and v >= 1 end,
    "pr_limit must be a positive number")

  validate_opt(opts, "reviewer_selection_delay",
    function(v) return type(v) == "number" and v >= 0 end,
    "reviewer_selection_delay must be a non-negative number")

  validate_opt(opts, "max_concurrent_fetches",
    function(v) return type(v) == "number" and v >= 1 end,
    "max_concurrent_fetches must be a positive number")

  validate_opt(opts, "operation_timeout",
    function(v) return type(v) == "number" and v >= 1000 end,
    "operation_timeout must be >= 1000 milliseconds")

  validate_opt(opts, "max_retries",
    function(v) return type(v) == "number" and v >= 0 end,
    "max_retries must be a non-negative number")

  validate_opt(opts, "retry_delay",
    function(v) return type(v) == "number" and v >= 0 end,
    "retry_delay must be a non-negative number")

  validate_opt(opts, "rate_limit_delay",
    function(v) return type(v) == "number" and v >= 0 end,
    "rate_limit_delay must be a non-negative number")

  -- Validate enum options
  validate_opt(opts, "auto_open_browser",
    function(v) return vim.tbl_contains({"always", "never", "ask"}, v) end,
    "auto_open_browser must be 'always', 'never', or 'ask'")

  -- Validate table options
  validate_opt(opts, "default_reviewers",
    function(v) return type(v) == "table" end,
    "default_reviewers must be a table")

  validate_opt(opts, "exclude_reviewers",
    function(v) return type(v) == "table" end,
    "exclude_reviewers must be a table")

  -- Validate boolean options
  validate_opt(opts, "show_only_unresolved_review_comments",
    function(v) return type(v) == "boolean" end,
    "show_only_unresolved_review_comments must be a boolean")

  M.config = vim.tbl_deep_extend("force", M.config, opts)
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

---Safely close a window
---@param win number Window ID
---@param force? boolean Force close
local function safe_win_close(win, force)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, force or false)
  end
end

---Safely get buffer lines
---@param buf number Buffer ID
---@param start_line number Starting line (0-indexed)
---@param end_line number Ending line (0-indexed, -1 for end)
---@return table|nil Lines or nil on error
local function safe_buf_get_lines(buf, start_line, end_line)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_line, end_line, false)
  return ok and lines or nil
end

---Safely set buffer lines
---@param buf number Buffer ID
---@param start_line number Starting line (0-indexed)
---@param end_line number Ending line (0-indexed, -1 for end)
---@param lines table Lines to set
---@return boolean Success
local function safe_buf_set_lines(buf, start_line, end_line, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, start_line, end_line, false, lines)
  return ok
end

-- Track all created buffers for cleanup
local created_buffers = {}

---Safely delete a buffer
---@param buf number Buffer ID
---@param opts? table Options (e.g., {force = true})
local function safe_buf_delete(buf, opts)
  opts = opts or {}
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- Remove from tracked buffers
    created_buffers[buf] = nil
    -- Try to delete the buffer
    local ok, err = pcall(vim.api.nvim_buf_delete, buf, opts)
    if not ok and opts.force then
      -- Force delete by detaching from all windows first
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      -- Try again
      pcall(vim.api.nvim_buf_delete, buf, opts)
    end
  end
end

-- Clean up all tracked buffers on VimLeavePre
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for buf, _ in pairs(created_buffers) do
      safe_buf_delete(buf, { force = true })
    end
    created_buffers = {}
  end,
})

---Safely set buffer option
---@param buf number Buffer ID
---@param name string Option name
---@param value any Option value
---@return boolean Success
local function safe_buf_set_option(buf, name, value)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ok = pcall(vim.api.nvim_set_option_value, name, value, { buf = buf })
  return ok
end

---Helper: Get latest review per author from reviews array
---@param reviews table Array of review objects
---@return table latest_reviews Map of author to their latest review
local function get_latest_reviews(reviews)
  local latest_reviews = {}
  if not reviews or type(reviews) ~= "table" then
    return latest_reviews
  end

  for _, review in ipairs(reviews) do
    if review.author and review.author.login and review.state then
      if review.state == "APPROVED" or review.state == "CHANGES_REQUESTED" then
        local author = review.author.login
        local submitted_at = review.submittedAt or ""
        if not latest_reviews[author] or submitted_at > (latest_reviews[author].submittedAt or "") then
          latest_reviews[author] = review
        end
      end
    end
  end

  return latest_reviews
end

---Helper: Determine status from latest reviews
---@param latest_reviews table Map of author to latest review
---@return string icon, string hl_group, string status_text
local function status_from_reviews(latest_reviews)
  local status_text = "Pending Review"
  local icon = "○"
  local hl_group = "DiagnosticWarn"

  for _, review in pairs(latest_reviews) do
    if review.state == "CHANGES_REQUESTED" then
      return "✗", "DiagnosticError", "Changes Requested"
    elseif review.state == "APPROVED" then
      status_text = "Approved"
      icon = "✓"
      hl_group = "DiagnosticOk"
    end
  end

  if vim.tbl_isempty(latest_reviews) then
    return "○", "DiagnosticWarn", "Review Required"
  end

  return icon, hl_group, status_text
end

---Determine review status from PR data
---@param pr_data table PR data with reviewDecision, reviews, and review_comments
---@return string icon, string hl_group, string status_text
local function get_review_status(pr_data)
  if not pr_data then
    return "•", "Comment", "Unknown"
  end

  -- Primary: Use GitHub's reviewDecision (most reliable)
  if pr_data.reviewDecision and pr_data.reviewDecision ~= vim.NIL then
    if pr_data.reviewDecision == "CHANGES_REQUESTED" then
      return "✗", "DiagnosticError", "Changes Requested"
    elseif pr_data.reviewDecision == "APPROVED" then
      return "✓", "DiagnosticOk", "Approved"
    elseif pr_data.reviewDecision == "REVIEW_REQUIRED" then
      -- Only do detailed analysis if we have enriched data (reviews/review_comments)
      -- Otherwise trust the reviewDecision field
      if pr_data.reviews or pr_data.review_comments then
        -- Check for unresolved comment threads (indicates changes requested)
        if pr_data.review_comments and type(pr_data.review_comments) == "table" then
          for _, comment in ipairs(pr_data.review_comments) do
            if comment.in_reply_to_id == vim.NIL or not comment.in_reply_to_id then
              return "✗", "DiagnosticError", "Changes Requested"
            end
          end
        end

        -- No unresolved comments, check individual reviews
        local latest_reviews = get_latest_reviews(pr_data.reviews)
        return status_from_reviews(latest_reviews)
      else
        -- Basic data only - trust reviewDecision
        return "○", "DiagnosticWarn", "Review Required"
      end
    end
  end

  -- Fallback: Check individual reviews if reviewDecision not available
  local latest_reviews = get_latest_reviews(pr_data.reviews)
  return status_from_reviews(latest_reviews)
end

---Get author initials from GitHub login
---@param login string GitHub username
---@return string initials
local function get_author_initials(login)
  return login:gsub("-", " "):gsub("%w+", function(w)
    return w:sub(1, 1):upper()
  end):gsub(" ", "")
end

---Pad PR number with zeros
---@param number number PR number
---@param width number Desired width
---@return string padded_number
local function pad_pr_number(number, width)
  return string.format("%0" .. width .. "d", number)
end

---Execute shell command and get output
---@param cmd string Command to execute
---@return string output
local function shell_exec(cmd)
  local handle = io.popen(cmd .. " 2>/dev/null")
  if not handle then
    return ""
  end

  -- Safely read output
  local ok, output = pcall(function()
    return handle:read("*a") or ""
  end)

  -- Safe close even if already closed
  pcall(handle.close, handle)

  return ok and vim.trim(output) or ""
end

-- ========== Job and Timer Tracking ==========
local active_jobs = {}
local active_timers = {}

-- Helper: Check if error is retryable
local function is_retryable_error(stderr)
  if not stderr then return false end
  return stderr:match("network") or
         stderr:match("connection") or
         stderr:match("timeout") or
         stderr:match("refused") or
         stderr:match("rate limit")
end

-- Forward declaration for exec_async (defined later)
local exec_async

-- Helper: Schedule retry with exponential backoff
local function schedule_retry(cmd, on_success, on_error, retry_count, delay)
  local retry_timer
  retry_timer = vim.defer_fn(function()
    active_timers[retry_timer] = nil
    exec_async(cmd, on_success, on_error, retry_count + 1)
  end, delay)
  active_timers[retry_timer] = true
end

-- Helper: Kill job and remove from tracking
local function kill_job(job_obj)
  pcall(function()
    if job_obj and job_obj.kill then
      job_obj:kill(9)
    end
  end)

  for i, j in ipairs(active_jobs) do
    if j == job_obj then
      table.remove(active_jobs, i)
      break
    end
  end
end

-- Helper: Handle command result (success or error with retry logic)
local function handle_result(result, cmd, on_success, on_error, retry_count, timeout_timer)
  -- ========== Cleanup Timeout Timer ==========
  if timeout_timer then
    active_timers[timeout_timer] = nil
    pcall(function()
      vim.fn.timer_stop(timeout_timer)
    end)
  end

  -- ========== Check for Rate Limiting ==========
  if result.code == 1 and result.stderr and result.stderr:match("rate limit") then
    if retry_count < M.config.max_retries then
      vim.defer_fn(function()
        exec_async(cmd, on_success, on_error, retry_count + 1)
      end, M.config.rate_limit_delay)
      return
    end
  end

  -- ========== Handle Success ==========
  if result.code == 0 then
    on_success(result)
    return
  end

  -- ========== Handle Error with Retry ==========
  if not on_error then
    return
  end

  -- Check for retryable network errors
  if is_retryable_error(result.stderr) and retry_count < M.config.max_retries then
    schedule_retry(cmd, on_success, on_error, retry_count,
                  M.config.retry_delay * (2 ^ retry_count))
  else
    on_error(vim.trim(tostring(result.stderr or "Unknown error")))
  end
end

---Execute async command with callback, timeout and retry support
---@param cmd string[] Command array
---@param on_success function Success callback with result
---@param on_error? function Error callback with error message
---@param retry_count? number Current retry attempt (internal use)
function exec_async(cmd, on_success, on_error, retry_count)
  retry_count = retry_count or 0

  local timeout_timer = nil
  local job_obj = nil
  local job_completed = false

  -- ========== Validate Command ==========
  for i, v in ipairs(cmd) do
    if type(v) ~= "string" then
      local err_msg = string.format("Command array element %d is not a string: %s (type: %s)",
                                     i, tostring(v), type(v))
      vim.schedule(function()
        vim.notify("ERROR: " .. err_msg, vim.log.levels.ERROR)
        if on_error then on_error(err_msg) end
      end)
      return
    end
  end

  -- ========== Setup Timeout Timer ==========
  if M.config.operation_timeout > 0 then
    timeout_timer = vim.defer_fn(function()
      active_timers[timeout_timer] = nil

      if not job_completed and job_obj then
        kill_job(job_obj)

        -- Retry if attempts remaining
        if retry_count < M.config.max_retries then
          schedule_retry(cmd, on_success, on_error, retry_count,
                        M.config.retry_delay * (2 ^ retry_count))
        elseif on_error then
          on_error(string.format("Operation timed out after %dms and %d retries",
                                M.config.operation_timeout, M.config.max_retries))
        end
      end
    end, M.config.operation_timeout)
    active_timers[timeout_timer] = true
  end

  -- ========== Execute Command via libuv ==========
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local stdout_chunks = {}
  local stderr_chunks = {}

  local handle, pid
  handle, pid = vim.loop.spawn(cmd[1], {
    args = vim.list_slice(cmd, 2),
    stdio = {nil, stdout, stderr},
  }, function(exit_code, signal)
    -- ========== Cleanup Pipes and Handle ==========
    stdout:close()
    stderr:close()
    handle:close()

    -- ========== Build Result Object ==========
    local result = {
      code = exit_code,
      stdout = table.concat(stdout_chunks),
      stderr = table.concat(stderr_chunks)
    }

    job_completed = true

    -- ========== Process Result ==========
    handle_result(result, cmd, on_success, on_error, retry_count, timeout_timer)
  end)

  -- ========== Handle Spawn Failure ==========
  if not handle then
    if on_error then
      on_error("Failed to spawn process: " .. tostring(pid))
    end
    return
  end

  job_obj = handle

  -- ========== Setup Output Pipes ==========
  stdout:read_start(function(err, data)
    if data then
      table.insert(stdout_chunks, data)
    end
  end)

  stderr:read_start(function(err, data)
    if data then
      table.insert(stderr_chunks, data)
    end
  end)

  -- ========== Track Active Job ==========
  table.insert(active_jobs, job_obj)
end

-- Clean up active jobs and timers on VimLeavePre
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    -- Clean up jobs
    for _, job in ipairs(active_jobs) do
      pcall(function()
        if job and job.kill then
          job:kill(9)
        end
      end)
    end
    active_jobs = {}

    -- Clean up timers
    for timer, _ in pairs(active_timers) do
      pcall(function()
        vim.fn.timer_stop(timer)
      end)
    end
    active_timers = {}
  end,
})

-- ============================================================================
-- DEPENDENCY CHECKS
-- ============================================================================

---Check if GitHub CLI is installed
---@return boolean is_installed
local function check_gh_cli()
  local result = vim.fn.system("which gh 2>/dev/null")
  return vim.v.shell_error == 0 and result ~= ""
end

-- ============================================================================
-- GIT OPERATIONS
-- ============================================================================

---Check if we're in a git repository with GitHub remote
---@return boolean is_valid, string? error_message
local function validate_git_repo()
  -- Check if we're in a git repository
  local git_dir = shell_exec("git rev-parse --git-dir 2>/dev/null")
  if not git_dir or git_dir == "" then
    return false, "Not in a git repository"
  end

  -- Check if we have a GitHub remote
  local remote_url = shell_exec("git remote get-url origin 2>/dev/null") or ""
  -- Check for github.com or ghe.com (GitHub Enterprise)
  if not remote_url:match("github%.com") and not remote_url:match("ghe%.com") then
    -- Try upstream if origin doesn't exist
    remote_url = shell_exec("git remote get-url upstream 2>/dev/null") or ""
    if not remote_url:match("github%.com") and not remote_url:match("ghe%.com") then
      return false, "No GitHub remote found. Please add a GitHub remote (origin or upstream)"
    end
  end

  return true
end

---Get git context for PR suggestions
---@return string context
local function get_pr_context()
  local diff = shell_exec("git diff --cached --stat || git diff HEAD~1..HEAD --stat") or ""
  local last_commit = shell_exec("git log -1 --pretty=%s") or ""
  return vim.trim(diff .. "\n" .. last_commit)
end

---Get changed files from git
---@param limit? number Maximum number of files to return
---@return string[] files List of changed file names
local function get_changed_files(limit)
  limit = limit or 999
  local cmd = "git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff --cached --name-only 2>/dev/null"
  if limit < 999 then
    cmd = cmd .. " | head -" .. limit
  end

  local files_output = shell_exec(cmd)
  if not files_output or files_output == "" then
    return {}
  end

  local files = {}
  for file in files_output:gmatch("[^\n]+") do
    table.insert(files, file)
  end
  return files
end

-- Simple shell escape function that doesn't rely on vim.fn (safe for async)
local function shell_escape(str)
  -- Escape single quotes by replacing ' with '\''
  return "'" .. str:gsub("'", "'\\''") .. "'"
end

---Use GitHub Copilot to generate PR title and body from diff
---@param callback function(title: string, body: string) Callback with generated content
local function generate_with_copilot(callback)
  -- Get the diff of unpushed commits only by comparing against upstream
  -- This ensures we only see changes that haven't been pushed yet
  -- Try to intelligently detect the base branch
  local diff_cmd = [[
    # First try to get unpushed commits from upstream tracking branch
    if git rev-parse @{upstream} >/dev/null 2>&1; then
      git diff @{upstream}...HEAD 2>/dev/null
    # Try origin/current-branch if it exists
    elif git rev-parse origin/$(git rev-parse --abbrev-ref HEAD) >/dev/null 2>&1; then
      git diff origin/$(git rev-parse --abbrev-ref HEAD)...HEAD 2>/dev/null
    # Try to detect the actual base branch by checking common remote branches
    else
      # Try to find which remote branch this was branched from by checking reflog
      BASE_BRANCH=$(git reflog show --all --date=raw --format='%gd %gs' | grep -E 'branch: Created from|checkout: moving from' | head -1 | sed -n 's/.*from \([^ ]*\).*/\1/p')

      # If we found a base branch in reflog, use it
      if [ -n "$BASE_BRANCH" ] && git rev-parse "origin/$BASE_BRANCH" >/dev/null 2>&1; then
        git diff origin/$BASE_BRANCH...HEAD 2>/dev/null
      # Fall back to trying common base branches
      else
        BASE=$(git merge-base origin/main HEAD 2>/dev/null || git merge-base origin/master HEAD 2>/dev/null || git merge-base origin/develop HEAD 2>/dev/null || git merge-base main HEAD 2>/dev/null || git merge-base master HEAD 2>/dev/null || echo "HEAD~1")
        git diff $BASE...HEAD 2>/dev/null
      fi
    fi
  ]]

  -- First, execute the diff command to get the actual diff content
  exec_async({ "sh", "-c", diff_cmd }, function(diff_result)
    if diff_result.code ~= 0 or not diff_result.stdout or diff_result.stdout == "" then
      vim.notify("Failed to get git diff. Using commit message.", vim.log.levels.WARN)
      local last_commit = shell_exec("git log -1 --pretty=%s") or ""
      callback(last_commit, "")
      return
    end

    local diff_content = diff_result.stdout

    local prompt = string.format([[Based on this git diff, generate a PR title and detailed body.

Format your response EXACTLY as:
TITLE: [your title here]
BODY: [your body here - write 3-10 complete sentences]

REQUIREMENTS:

TITLE:
- Use imperative mood (e.g., "Add feature" not "Added feature")
- Focus on business value, not technical details
- Be under 72 characters

BODY (MUST BE 3-10 SENTENCES):
- Write AT LEAST 3 sentences, preferably 5-10 sentences
- First 2-3 sentences: Explain WHAT changed and WHY
- Middle sentences: Explain the PROBLEM this solves
- Final sentences: Describe the IMPACT and VALUE
- Focus on user/business benefits, not technical implementation
- Write in paragraph form with proper sentence structure

Example of a good body:
"This change improves the PR creation workflow by integrating AI-powered suggestions. Previously, users had to manually write PR titles and descriptions, which was time-consuming and often resulted in unclear descriptions. The new Copilot integration analyzes the complete git diff and generates business-focused content automatically. This saves developers time and ensures PR descriptions are clear and valuable. Teams will benefit from more consistent and professional PR documentation."

Here's the diff:
%s]], diff_content)

    -- Show loading indicator
    vim.notify("Generating PR title and body with Copilot...", vim.log.levels.INFO)

    -- Call GitHub Copilot CLI
    -- Set COPILOT_ALLOW_ALL to auto-approve tool usage without prompts
    -- Provide stdin to prevent any interactive prompts
    local copilot_cmd = string.format(
      [[echo "" | COPILOT_ALLOW_ALL=true copilot -p %s --allow-all-tools 2>&1]],
      shell_escape(prompt)
    )

  exec_async({ "sh", "-c", copilot_cmd }, function(result)
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      local output = result.stdout

      -- Parse the response - look for TITLE: and BODY: markers
      local title = output:match("TITLE:%s*(.-)%s*\n") or output:match("TITLE:%s*(.-)%s*$") or ""
      -- Match BODY but stop at usage stats or end of meaningful content
      local body = output:match("BODY:%s*(.-)%s*\n\n") or output:match("BODY:%s*(.-)%s*Total usage") or output:match("BODY:%s*(.+)") or ""

      -- Clean up
      title = vim.trim(title)
      body = vim.trim(body)

      -- Remove markdown formatting
      title = title:gsub("^%*%*", ""):gsub("%*%*$", ""):gsub("^`", ""):gsub("`$", "")

      -- Post-process body: ensure line breaks between sentences
      -- Split on sentence boundaries (. ! ?) followed by space/capital letter
      -- and rejoin with double newlines
      if body ~= "" then
        -- First, normalize any existing multiple newlines to single spaces
        body = body:gsub("\n+", " ")
        -- Then add double newlines after sentence endings (. ! ?) followed by space
        -- This catches most sentence boundaries
        body = body:gsub("([.!?])%s+", "%1\n\n")
        -- Clean up any trailing newlines
        body = vim.trim(body)
      end

      -- Fallback if parsing failed
      if title == "" then
        vim.notify("Copilot response didn't match expected format. Using commit message.", vim.log.levels.WARN)
        local last_commit = shell_exec("git log -1 --pretty=%s") or ""
        callback(last_commit, "")
      else
        callback(title, body)
      end
    else
      -- Fallback if Copilot fails
      if result.code == 127 then
        vim.notify(
          "GitHub Copilot CLI not found. Disable with: use_copilot_suggestions = false",
          vim.log.levels.WARN
        )
      else
        vim.notify("Copilot failed (exit " .. result.code .. "). Using commit message.", vim.log.levels.WARN)
      end
      local last_commit = shell_exec("git log -1 --pretty=%s") or ""
      callback(last_commit, "")
    end
  end, function(err)
    vim.notify("Error calling Copilot: " .. tostring(err), vim.log.levels.WARN)
    local last_commit = shell_exec("git log -1 --pretty=%s") or ""
    callback(last_commit, "")
  end)
  end, function(err)
    vim.notify("Error getting git diff: " .. tostring(err), vim.log.levels.WARN)
    local last_commit = shell_exec("git log -1 --pretty=%s") or ""
    callback(last_commit, "")
  end)
end

---Generate smart PR title and body from git commits
---@param with_copilot boolean Whether to use Copilot for generation
---@param callback function(title: string, body: string) Callback with generated content
local function generate_pr_defaults(with_copilot, callback)
  if with_copilot and M.config.use_copilot_suggestions then
    generate_with_copilot(callback)
  else
    -- Simple title from last commit
    local last_commit_full = shell_exec("git log -1 --pretty=%B") or ""
    local title = (last_commit_full:match("^([^\n]+)") or ""):gsub("^%l", string.upper)
    callback(title, "")
  end
end

-- ============================================================================
-- REVIEWER SELECTION
-- ============================================================================

---Get list of available reviewers
---@param pr_number string PR number
---@param callback function Callback with reviewers list
local function get_reviewers_list(pr_number, callback)
  -- Get current user
  exec_async({ "gh", "api", "user", "--jq", ".login" }, function(user_result)
    local current_user = vim.trim(user_result.stdout or "")

    -- Get collaborators
    exec_async({ "gh", "api", "repos/:owner/:repo/collaborators", "--jq", ".[].login" }, function(collab_result)
      local reviewers = {}
      local reviewer_set = {}

      -- Add default reviewers first
      for _, reviewer in ipairs(M.config.default_reviewers or {}) do
        if reviewer ~= current_user then
          table.insert(reviewers, reviewer)
          reviewer_set[reviewer] = true
        end
      end

      -- Add collaborators from API with validation
      if collab_result.stdout and type(collab_result.stdout) == "string" then
        for reviewer in collab_result.stdout:gmatch("[^\r\n]+") do
          -- Validate reviewer name
          reviewer = vim.trim(reviewer)
          if type(reviewer) == "string" and reviewer ~= "" and not reviewer:match("^%s*$") then
            -- Validate it's a valid GitHub username (alphanumeric, hyphens, max 39 chars)
            if reviewer:match("^[%w%-]+$") and #reviewer <= 39 then
              -- Check exclusions
              local is_excluded = vim.tbl_contains(M.config.exclude_reviewers or {}, reviewer)

              if reviewer ~= current_user and not is_excluded and not reviewer_set[reviewer] then
                table.insert(reviewers, reviewer)
                reviewer_set[reviewer] = true
              end
            else
              vim.notify("Invalid GitHub username format: " .. tostring(reviewer), vim.log.levels.WARN)
            end
          end
        end
      end

      -- Check for Copilot availability
      exec_async({ "gh", "api", "/repos/:owner/:repo", "--jq", ".owner.type" }, function(owner_result)
        local owner_type = vim.trim(owner_result.stdout or "User")

        local function add_copilot_if_available()
          if owner_type == "Organization" then
            exec_async({ "gh", "api", "/repos/:owner/:repo", "--jq", ".owner.login" }, function(org_result)
              local org = vim.trim(org_result.stdout or "")
              exec_async({ "gh", "api", "/orgs/" .. tostring(org) .. "/copilot/billing", "--silent" }, function(copilot_result)
                if copilot_result.code == 0 then
                  table.insert(reviewers, "Copilot")
                end
                callback(reviewers)
              end, function(err)
                -- Error getting Copilot billing info, continue without Copilot
                callback(reviewers)
              end)
            end, function(err)
              -- Error getting org name, continue without Copilot
              callback(reviewers)
            end)
          else
            -- For personal repos, assume Copilot is available
            table.insert(reviewers, "Copilot")
            callback(reviewers)
          end
        end

        add_copilot_if_available()
      end, function(err)
        -- Error getting owner type, continue with reviewers we have
        callback(reviewers)
      end)
    end, function(err)
      -- Error getting collaborators, continue with default reviewers only
      local reviewers = {}
      -- Add default reviewers even on error
      for _, reviewer in ipairs(M.config.default_reviewers or {}) do
        if reviewer ~= current_user then
          table.insert(reviewers, reviewer)
        end
      end
      vim.notify("Failed to fetch collaborators: " .. vim.trim(tostring(err or "")), vim.log.levels.WARN)
      callback(reviewers)
    end)
  end, function(err)
    -- Error getting current user, return empty list
    vim.notify("Failed to get current user: " .. vim.trim(tostring(err or "")), vim.log.levels.WARN)
    callback({})
  end)
end

---Add reviewer to PR
---@param pr_number string PR number
---@param reviewer string Reviewer username
---@param callback function Success callback
local function add_reviewer(pr_number, reviewer, callback)
  if reviewer == "Copilot" then
    -- Use correct API endpoint for Copilot
    exec_async({
      "gh", "api", "--method", "POST",
      "/repos/:owner/:repo/pulls/" .. tostring(pr_number) .. "/requested_reviewers",
      "-f", "reviewers[]=copilot-pull-request-reviewer[bot]",
    }, function()
      vim.notify("✓ Added Copilot as reviewer", vim.log.levels.INFO)
      callback()
    end, function(err)
      vim.notify("✗ Failed to add Copilot: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      callback()
    end)
  else
    exec_async({ "gh", "pr", "edit", tostring(pr_number), "--add-reviewer", tostring(reviewer) }, function()
      vim.notify("✓ Added " .. tostring(reviewer or "unknown") .. " as reviewer", vim.log.levels.INFO)
      callback()
    end, function(err)
      vim.notify("✗ Failed to add reviewer: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      callback()
    end)
  end
end

-- ============================================================================
-- PR CREATION FLOW
-- ============================================================================

-- State management for PR creation flow
local pr_creation_active = false
local pr_title_buf = nil  -- Buffer for the title dialog
local pr_title_win = nil  -- Window for the title dialog
local pr_suggested_body = nil  -- Store suggested body for later use
local pr_copilot_loading = false  -- Track if Copilot is currently loading
local pr_loading_timer = nil  -- Timer for loading animation

-- ============================================================================
-- BROWSER OPERATIONS
-- ============================================================================

---Handle browser opening based on config
---@param pr_number? string Optional PR number for specific PR
---@param check_state? boolean Whether to check pr_creation_state (default false)
local function handle_browser_open(pr_number, check_state)
  -- If checking state and flow is not active, don't proceed
  if check_state and not pr_creation_active then
    return
  end

  local function open_browser()
    local cmd = pr_number and { "gh", "pr", "view", tostring(pr_number), "--web" } or { "gh", "pr", "view", "--web" }
    vim.fn.jobstart(cmd, { detach = true })
  end

  if M.config.auto_open_browser == "always" then
    open_browser()
  elseif M.config.auto_open_browser == "ask" then
    vim.defer_fn(function()
      -- Check state again if requested
      if check_state and not pr_creation_active then
        return
      end

      -- Use custom floating window to match title/body/reviewer style
      vim.schedule(function()
        local buf = vim.api.nvim_create_buf(false, true)
        created_buffers[buf] = true

        local options = { "Yes", "No" }
        safe_buf_set_lines(buf, 0, -1, options)

        -- Buffer options
        vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
        vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

        -- Match title/body positioning
        local width = math.floor(vim.o.columns * 0.4)
        local height = #options + 2
        local row = math.floor(vim.o.lines * 0.2)
        local col = math.floor((vim.o.columns - width) / 2)

        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = width,
          height = height,
          row = row,
          col = col,
          border = "rounded",
          title = " Open PR in browser? (Enter=select, ESC/q=no) ",
          title_pos = "center"
        })

        -- Set current line highlight
        vim.wo[win].cursorline = true

        -- Keymaps
        local opts = { buffer = buf, silent = true }

        vim.keymap.set("n", "<ESC>", function()
          safe_win_close(win, true)
          if check_state then
            pr_creation_active = false
          end
        end, opts)

        vim.keymap.set("n", "<CR>", function()
          local line_num = vim.api.nvim_win_get_cursor(win)[1]
          local choice = options[line_num]
          safe_win_close(win, true)

          if choice == "Yes" then
            open_browser()
          end

          -- Mark flow as complete after browser prompt
          if check_state then
            pr_creation_active = false
          end
        end, opts)

        vim.keymap.set("n", "q", function()
          safe_win_close(win, true)
          if check_state then
            pr_creation_active = false
          end
        end, opts)
      end)
    end, 100)
  else
    -- "never" - mark flow as complete
    if check_state then
      pr_creation_active = false
    end
  end
end

---Cancel any pending PR creation operations
local function cancel_pr_creation()
  -- Clean up command abbreviations and augroups for any active buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("%[PR Body") or name:match("%[PR Title") then
        -- Clean up command abbreviations
        pcall(vim.cmd, string.format([[
          silent! cunabbrev <buffer=%d> w
          silent! cunabbrev <buffer=%d> wq
          silent! cunabbrev <buffer=%d> x
          silent! cunabbrev <buffer=%d> q
        ]], buf, buf, buf, buf))
        -- Clean up augroup
        pcall(vim.cmd, "silent! augroup! ReviewerPRBody_" .. buf)
      end
    end
  end

  -- Stop loading animation timer if running
  if pr_loading_timer then
    pcall(function() pr_loading_timer:stop() end)
    pcall(function() pr_loading_timer:close() end)
    pr_loading_timer = nil
  end

  -- Clear state variables
  pr_title_buf = nil
  pr_title_win = nil
  pr_suggested_body = nil
  pr_copilot_loading = false

  -- Mark as inactive
  pr_creation_active = false
end

---Select and add reviewer to PR
---@param pr_number string PR number
local function select_reviewer(pr_number)
  -- Check if flow is still active
  if not pr_creation_active then
    return
  end

  -- Use vim.defer_fn instead of timer_start to avoid serialization issues
  vim.defer_fn(function()
    -- Double-check flow is still active
    if not pr_creation_active then
      return
    end

    get_reviewers_list(pr_number, function(reviewers)
      -- Check again after async operation
      if not pr_creation_active then
        return
      end

      -- Add "Skip" option at the beginning
      table.insert(reviewers, 1, "Skip")

      -- Schedule to avoid fast event context issues
      vim.schedule(function()
        -- Create custom floating window to match title/body style
        local buf = vim.api.nvim_create_buf(false, true)
        created_buffers[buf] = true

        -- Set buffer content
        safe_buf_set_lines(buf, 0, -1, reviewers)

        -- Buffer options
        vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
        vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

        -- Match title/body positioning
        local width = math.floor(vim.o.columns * 0.4)
        local height = math.min(#reviewers + 2, math.floor(vim.o.lines * 0.5))
        local row = math.floor(vim.o.lines * 0.2)
        local col = math.floor((vim.o.columns - width) / 2)

        local win = vim.api.nvim_open_win(buf, true, {
          relative = "editor",
          width = width,
          height = height,
          row = row,
          col = col,
          border = "rounded",
          title = " Select Reviewer (Enter=select, ESC/q=cancel) ",
          title_pos = "center"
        })

        -- Set current line highlight
        vim.wo[win].cursorline = true

        -- Keymaps
        local opts = { buffer = buf, silent = true }

        vim.keymap.set("n", "<ESC>", function()
          safe_win_close(win, true)
          vim.notify("Reviewer selection cancelled", vim.log.levels.INFO)
          pr_creation_active = false
        end, opts)

        vim.keymap.set("n", "<CR>", function()
          local line_num = vim.api.nvim_win_get_cursor(win)[1]
          local reviewer = reviewers[line_num]
          safe_win_close(win, true)

          if reviewer == "Skip" then
            handle_browser_open(pr_number, true)
          else
            add_reviewer(pr_number, reviewer, function()
              handle_browser_open(pr_number, true)
            end)
          end
        end, opts)

        vim.keymap.set("n", "q", function()
          safe_win_close(win, true)
          vim.notify("Reviewer selection cancelled", vim.log.levels.INFO)
          pr_creation_active = false
        end, opts)
      end)
    end)
  end, M.config.reviewer_selection_delay or 100)
end

---Handle PR assignment
---@param pr_number string PR number
local function handle_pr_assignment(pr_number)
  -- Check if flow is still active
  if not pr_creation_active then
    return
  end

  vim.notify("✓ PR #" .. tostring(pr_number or "?") .. " created", vim.log.levels.INFO)

  if M.config.auto_assign_to_me then
    exec_async({ "gh", "pr", "edit", tostring(pr_number), "--add-assignee", "@me" }, function()
      vim.notify("✓ Assigned to you", vim.log.levels.INFO)
      select_reviewer(pr_number)
    end, function(err)
      vim.notify("✗ Failed to assign: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
      select_reviewer(pr_number)
    end)
  else
    select_reviewer(pr_number)
  end
end

---Create GitHub pull request
---@param title string PR title
---@param body string PR body
local function create_github_pr(title, body)
  -- Check if flow is still active
  if not pr_creation_active then
    return
  end

  -- Check if branch needs to be pushed
  exec_async({ "sh", "-c", "git rev-parse --abbrev-ref HEAD" }, function(branch_result)
    local current_branch = vim.trim(branch_result.stdout)

    -- Check if branch exists on remote by trying to get its remote ref
    exec_async({ "sh", "-c", "git ls-remote --heads origin " .. current_branch .. " 2>/dev/null | wc -l" }, function(remote_check)
        local branch_on_remote = vim.trim(remote_check.stdout) ~= "0"

        -- Helper function to actually create the PR
        local function do_create_pr()
          exec_async({ "gh", "pr", "create", "--title", tostring(title), "--body", tostring(body) }, function(result)
    -- Extract PR number from output
    local pr_number = result.stdout:match("https://github%.com/[^%s]+/pull/(%d+)")
        or result.stdout:match("#(%d+)")

    if pr_number then
      handle_pr_assignment(pr_number)
    else
      -- Try to get current PR number as fallback
      exec_async({ "gh", "pr", "view", "--json", "number", "--jq", ".number" }, function(pr_result)
        local number = vim.trim(pr_result.stdout)
        handle_pr_assignment(number)
      end, function()
        vim.notify("✗ Could not determine PR number", vim.log.levels.ERROR)
        pr_creation_active = false
      end)
    end
          end, function(err)
            vim.notify("✗ Failed to create PR: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
            pr_creation_active = false
          end)
        end

        -- Check if we need to push
        if not branch_on_remote then
          -- Ask user if they want to push
          vim.schedule(function()
            vim.ui.select(
              { "Yes", "No" },
              {
                prompt = "Branch '" .. current_branch .. "' needs to be pushed. Push now?",
              },
              function(choice)
                if not choice or choice == "No" then
                  vim.notify("PR creation cancelled.", vim.log.levels.WARN)
                  pr_creation_active = false
                  return
                end

                if choice == "Yes" then
                  vim.notify("Pushing branch...", vim.log.levels.INFO)
                  exec_async({ "sh", "-c", "git push -u origin " .. current_branch }, function()
                    do_create_pr()
                  end, function(err)
                    vim.notify("✗ Failed to push: " .. tostring(err), vim.log.levels.ERROR)
                    pr_creation_active = false
                  end)
                end
              end
            )
          end)
        else
          -- Branch already pushed, create PR directly
          do_create_pr()
        end
      end)
    end)
end

---Create a multiline input buffer for PR body
---@param title string PR title
---@param default_body string Default body text
local function create_body_input(title, default_body)
  -- Create a new buffer for body input
  local buf = vim.api.nvim_create_buf(false, true)
  -- Track buffer for cleanup
  created_buffers[buf] = true

  -- Set the default content if provided
  if default_body and default_body ~= "" then
    local lines = vim.split(default_body, "\n")
    safe_buf_set_lines(buf, 0, -1, lines)
  end

  -- Set buffer options
  safe_buf_set_option(buf, "buftype", "nofile")
  safe_buf_set_option(buf, "bufhidden", "wipe")
  safe_buf_set_option(buf, "swapfile", false)
  safe_buf_set_option(buf, "filetype", "markdown")

  -- Set a unique filename so :wq works (include buffer ID for uniqueness)
  local ok = pcall(vim.api.nvim_buf_set_name, buf, "[PR Body " .. buf .. "]")
  if not ok then
    -- If naming fails, try with a timestamp
    pcall(vim.api.nvim_buf_set_name, buf, "[PR Body " .. os.time() .. "]")
  end

  -- Create a floating window for the body input
  local width = math.floor(vim.o.columns * 0.4)
  local height = math.floor(vim.o.lines * 0.3)
  local row = math.floor(vim.o.lines * 0.2)  -- 20% from top, same as title
  local col = math.floor((vim.o.columns - width) / 2)

  -- Use vim.ui.input as fallback for better compatibility
  local function use_input_fallback()
    vim.ui.input({
      prompt = "PR Body (optional, press Enter to skip): ",
      default = default_body or "",
    }, function(input)
      -- Check if user canceled (input is nil) vs empty input (input is "")
      if input == nil then
        vim.notify("PR creation cancelled", vim.log.levels.WARN)
        cancel_pr_creation()
        return
      end

      if pr_creation_active then
        create_github_pr(title, input)
      else
        vim.notify("PR creation cancelled", vim.log.levels.WARN)
        cancel_pr_creation()
      end
    end)
  end

  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = " PR Body (i=edit, ESC/:q!=cancel, :wq/:q/ZZ=submit) ",
    title_pos = "center"
  })

  if not ok_win then
    -- Fall back to vim.ui.input if floating window fails
    safe_buf_delete(buf, { force = true })
    use_input_fallback()
    return
  end

  -- Ensure window has focus and enable soft wrap
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      -- Enable soft wrap to avoid horizontal scrolling
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true
    end
  end)

  -- Add cleanup autocmd for unexpected window closes
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- Clean up if window closed unexpectedly
      if pr_creation_active then
        cancel_pr_creation()
      end
    end,
  })

  -- Set up keymaps for the buffer
  local opts = { buffer = buf, silent = true }

  -- ESC cancels
  vim.keymap.set("n", "<ESC>", function()
    -- Delete the autocmd before closing to prevent double cancel
    pcall(vim.api.nvim_clear_autocmds, { event = "WinClosed", pattern = tostring(win) })
    safe_win_close(win, true)
    vim.notify("PR creation cancelled", vim.log.levels.WARN)
    cancel_pr_creation()
  end, opts)

  -- ZZ to confirm and submit
  vim.keymap.set("n", "ZZ", function()
    if pr_creation_active then
      local lines = safe_buf_get_lines(buf, 0, -1)
      if not lines then return end
      local body = table.concat(lines, "\n")
      -- Delete the autocmd before closing
      pcall(vim.api.nvim_clear_autocmds, { event = "WinClosed", pattern = tostring(win) })
      safe_win_close(win, true)
      create_github_pr(title, body)
    end
  end, opts)

  -- Create custom commands to handle :w, :wq, and :x
  vim.api.nvim_buf_create_user_command(buf, "W", function()
    vim.bo[buf].modified = false
    vim.notify("Ready to submit (use :q)", vim.log.levels.INFO)
  end, { bang = true })

  vim.api.nvim_buf_create_user_command(buf, "Wq", function()
    if pr_creation_active then
      local lines = safe_buf_get_lines(buf, 0, -1)
      if not lines then return end
      local body = table.concat(lines, "\n")
      vim.api.nvim_clear_autocmds({ event = "WinClosed", pattern = tostring(win) })
      safe_win_close(win, true)
      create_github_pr(title, body)
    end
  end, { bang = true })

  vim.api.nvim_buf_create_user_command(buf, "X", function()
    if pr_creation_active then
      local lines = safe_buf_get_lines(buf, 0, -1)
      if not lines then return end
      local body = table.concat(lines, "\n")
      vim.api.nvim_clear_autocmds({ event = "WinClosed", pattern = tostring(win) })
      safe_win_close(win, true)
      create_github_pr(title, body)
    end
  end, { bang = true })

  -- Create :q command to also submit (but :q! cancels)
  vim.api.nvim_buf_create_user_command(buf, "Q", function(opts)
    if opts.bang then
      -- :q! cancels
      vim.api.nvim_clear_autocmds({ event = "WinClosed", pattern = tostring(win) })
      safe_win_close(win, true)
      vim.notify("PR creation cancelled", vim.log.levels.WARN)
      cancel_pr_creation()
    else
      -- :q submits
      if pr_creation_active then
        local lines = safe_buf_get_lines(buf, 0, -1)
        if lines then
          local body = table.concat(lines, "\n")
          vim.api.nvim_clear_autocmds({ event = "WinClosed", pattern = tostring(win) })
          safe_win_close(win, true)
          create_github_pr(title, body)
        end
      end
    end
  end, { bang = true })

  -- Map the standard commands to our custom ones
  local augroup_name = "ReviewerPRBody_" .. buf
  vim.cmd(string.format([[
    augroup %s
      autocmd!
      autocmd BufEnter <buffer=%d> cnoreabbrev <buffer> w W
      autocmd BufEnter <buffer=%d> cnoreabbrev <buffer> wq Wq
      autocmd BufEnter <buffer=%d> cnoreabbrev <buffer> x X
      autocmd BufEnter <buffer=%d> cnoreabbrev <buffer> q Q
    augroup END
  ]], augroup_name, buf, buf, buf, buf))

  -- Clean up augroup when buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.cmd, "augroup! " .. augroup_name)
    end,
  })
end

---Start animated loading indicator in title dialog
local function start_loading_animation()
  local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local frame_idx = 1

  -- Stop any existing timer
  if pr_loading_timer then
    pcall(function() pr_loading_timer:stop() end)
    pcall(function() pr_loading_timer:close() end)
  end

  -- Create new timer that updates every 80ms
  pr_loading_timer = vim.loop.new_timer()
  pr_loading_timer:start(0, 80, vim.schedule_wrap(function()
    -- Check if still loading and dialog is valid
    if not pr_copilot_loading or not pr_title_buf or not vim.api.nvim_buf_is_valid(pr_title_buf) then
      if pr_loading_timer then
        pr_loading_timer:stop()
        pr_loading_timer:close()
        pr_loading_timer = nil
      end
      return
    end

    -- Update buffer with current spinner frame
    local spinner = spinner_frames[frame_idx]
    safe_buf_set_lines(pr_title_buf, 0, -1, { spinner .. " Loading suggestions from Copilot..." })

    -- Advance to next frame
    frame_idx = (frame_idx % #spinner_frames) + 1
  end))
end

---Create a floating input for PR title
---@param suggested_title string Default title
---@param suggested_body string Default body
local function create_title_input(suggested_title, suggested_body, is_loading)
  -- Create a new buffer for title input
  local buf = vim.api.nvim_create_buf(false, true)
  -- Track buffer for cleanup
  created_buffers[buf] = true

  -- Set the default content if provided
  if is_loading then
    safe_buf_set_lines(buf, 0, -1, { "⠋ Loading suggestions from Copilot..." })
  elseif suggested_title and suggested_title ~= "" then
    safe_buf_set_lines(buf, 0, -1, { suggested_title })
  end

  -- Set buffer options
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

  -- Set a unique buffer name for identification
  local ok = pcall(vim.api.nvim_buf_set_name, buf, "[PR Title " .. buf .. "]")
  if not ok then
    -- If naming fails, try with a timestamp
    pcall(vim.api.nvim_buf_set_name, buf, "[PR Title " .. os.time() .. "]")
  end

  -- Create a floating window for the title input (single line)
  local width = math.floor(vim.o.columns * 0.4)
  local height = 1
  local row = math.floor(vim.o.lines * 0.2)  -- 20% from top
  local col = math.floor((vim.o.columns - width) / 2)

  -- Use vim.ui.input as fallback for better compatibility
  local function use_input_fallback()
    vim.ui.input({
      prompt = "PR Title: ",
      default = suggested_title or "",
    }, function(input)
      if input and input ~= "" then
        if pr_creation_active then
          vim.schedule(function()
            if pr_creation_active then
              create_body_input(input, suggested_body or "")
            end
          end)
        end
      else
        vim.notify("PR creation cancelled", vim.log.levels.WARN)
        cancel_pr_creation()
      end
    end)
  end

  -- Set window title based on loading state
  local window_title = is_loading
    and " PR Title - Loading from Copilot... (ESC=cancel) "
    or " PR Title (i=edit, Enter=continue, ESC=cancel) "

  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    title = window_title,
    title_pos = "center"
  })

  if not ok_win then
    -- Fall back to vim.ui.input if floating window fails
    safe_buf_delete(buf, { force = true })
    use_input_fallback()
    return
  end

  -- Store buffer and window references for later updates
  pr_title_buf = buf
  pr_title_win = win
  pr_suggested_body = suggested_body

  -- Start loading animation if in loading state
  if is_loading then
    start_loading_animation()
  end

  -- Ensure window has focus and enable soft wrap
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      -- Enable soft wrap to avoid horizontal scrolling
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true
    end
  end)

  -- Add cleanup autocmd for unexpected window closes
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      -- Clean up if window closed unexpectedly
      if pr_creation_active then
        cancel_pr_creation()
      end
    end,
  })

  -- Set up keymaps
  local opts = { buffer = buf, silent = true }

  -- ESC in normal mode cancels (let ESC in insert mode work normally to go to normal mode)
  vim.keymap.set("n", "<ESC>", function()
    -- Delete the autocmd before closing to prevent double cancel
    pcall(vim.api.nvim_clear_autocmds, { event = "WinClosed", pattern = tostring(win) })
    safe_win_close(win, true)
    vim.notify("PR creation cancelled", vim.log.levels.WARN)
    cancel_pr_creation()
  end, opts)

  -- Enter continues to body
  vim.keymap.set({"n", "i"}, "<CR>", function()
    local lines = safe_buf_get_lines(buf, 0, -1)
    if not lines then
      vim.notify("Failed to read title", vim.log.levels.ERROR)
      return
    end
    local title = vim.trim(table.concat(lines, " "))

    -- Prevent submission while loading (check state variable, not parameter)
    if pr_copilot_loading or title:match("Loading suggestions from Copilot") then
      vim.notify("Please wait for Copilot to finish loading...", vim.log.levels.WARN)
      return
    end

    if title == "" then
      vim.notify("Title cannot be empty", vim.log.levels.WARN)
      return
    end

    -- Delete the autocmd before closing to prevent cancellation
    pcall(vim.api.nvim_clear_autocmds, { event = "WinClosed", pattern = tostring(win) })
    safe_win_close(win, true)

    if pr_creation_active then
      -- Continue to body input
      vim.schedule(function()
        -- Re-check state inside scheduled callback
        if pr_creation_active then
          -- Use pr_suggested_body from state if available, otherwise use the passed parameter
          create_body_input(title, pr_suggested_body or suggested_body or "")
        end
      end)
    end
  end, opts)

  -- Start in normal mode (user can press 'i' to edit)
end

---Update the title dialog with Copilot suggestions
---@param suggested_title string Suggested PR title from Copilot
---@param suggested_body string Suggested PR body from Copilot
local function update_title_with_suggestions(suggested_title, suggested_body)
  -- Mark loading as complete
  pr_copilot_loading = false

  -- Stop loading animation
  if pr_loading_timer then
    pcall(function() pr_loading_timer:stop() end)
    pcall(function() pr_loading_timer:close() end)
    pr_loading_timer = nil
  end

  -- Check if dialog is still open and valid
  if not pr_title_buf or not vim.api.nvim_buf_is_valid(pr_title_buf) then
    return
  end

  if not pr_title_win or not vim.api.nvim_win_is_valid(pr_title_win) then
    return
  end

  -- Update the buffer content with the suggestion
  safe_buf_set_lines(pr_title_buf, 0, -1, { suggested_title })

  -- Store the suggested body for later use
  pr_suggested_body = suggested_body

  -- Update the window title to remove loading indicator
  pcall(vim.api.nvim_win_set_config, pr_title_win, {
    title = " PR Title (i=edit, Enter=continue, ESC=cancel) ",
  })

  -- Notify the user that suggestions are ready
  vim.notify("Copilot suggestions loaded!", vim.log.levels.INFO)
end

---Prompt for PR details and create
---@param suggested_title? string Suggested PR title
---@param suggested_body? string Suggested PR body
---@param is_loading? boolean Whether copilot is still loading
local function prompt_for_pr_details(suggested_title, suggested_body, is_loading)
  -- Set flow as active
  pr_creation_active = true

  -- Use custom floating input for title
  create_title_input(suggested_title or "", suggested_body or "", is_loading)
end

---Create a new pull request
function M.create_pr()
  -- Check for GitHub CLI
  if not check_gh_cli() then
    vim.notify("reviewer: GitHub CLI (gh) is not installed. Please install it from https://cli.github.com/", vim.log.levels.ERROR)
    return
  end

  -- Validate git repository
  local is_valid, err_msg = validate_git_repo()
  if not is_valid then
    vim.notify("reviewer: " .. err_msg, vim.log.levels.ERROR)
    return
  end

  -- Check for uncommitted changes BEFORE calling Copilot
  local git_status = shell_exec("git status --porcelain")
  if git_status and git_status ~= "" then
    vim.notify("reviewer: You have uncommitted changes. Please commit or stash them before creating a PR.", vim.log.levels.ERROR)
    return
  end

  -- Check if a PR creation is already in progress
  if pr_creation_active then
    vim.notify("PR creation already in progress", vim.log.levels.WARN)
    return
  end

  -- Cancel any leftover state (shouldn't happen but be safe)
  cancel_pr_creation()

  -- Close all picker windows and PR creation windows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = buf })
    if ok and (ft == "snacks_picker" or ft == "snacks_picker_list" or ft == "snacks_picker_input") then
      safe_win_close(win, true)
    end
    -- Also close any PR title/body windows
    local ok_name, buf_name = pcall(vim.api.nvim_buf_get_name, buf)
    if ok_name and (buf_name == "[PR Title]" or buf_name == "[PR Body]") then
      safe_win_close(win, true)
    end
  end

  -- Add a small delay to ensure proper cleanup after cancellation
  vim.defer_fn(function()
    -- Check for GitHub Copilot CLI and generate defaults
    local has_copilot = vim.fn.executable('copilot') == 1 and M.config.use_copilot_suggestions

    -- Show dialog immediately with loading state if using copilot
    if has_copilot then
      pr_copilot_loading = true  -- Set loading state
      prompt_for_pr_details("", "", true)  -- Show loading state
    end

    -- Generate PR defaults asynchronously with callback
    generate_pr_defaults(has_copilot, function(suggested_title, suggested_body)
      -- Use vim.schedule to escape fast event context
      vim.schedule(function()
        if has_copilot then
          -- Update the already-visible dialog with suggestions
          update_title_with_suggestions(suggested_title, suggested_body)
        else
          -- Show dialog for the first time (no copilot case)
          prompt_for_pr_details(suggested_title, suggested_body, false)
        end
      end)
    end)
  end, 50)  -- 50ms delay to ensure cleanup completes
end

-- ============================================================================
-- PR DATA VALIDATION
-- ============================================================================

---Validate PR list item from GitHub API (less strict than full PR data)
---@param pr_item any PR item from list API
---@return boolean is_valid
local function validate_pr_list_item(pr_item)
  if type(pr_item) ~= "table" then
    return false
  end

  -- Only require number and title for list items
  if not pr_item.number or type(pr_item.number) ~= "number" then
    vim.notify("PR list item missing or invalid number field", vim.log.levels.WARN)
    return false
  end

  if not pr_item.title or type(pr_item.title) ~= "string" or pr_item.title == "" then
    vim.notify("PR list item missing or invalid title field", vim.log.levels.WARN)
    return false
  end

  return true
end

---Validate PR details from GitHub API (more forgiving for GHE)
---@param pr_details any PR details from view API
---@return boolean is_valid
local function validate_pr_details(pr_details)
  if type(pr_details) ~= "table" then
    return false
  end

  -- For PR details, we're more forgiving - only require title
  -- GitHub Enterprise may not return all fields
  if not pr_details.title or type(pr_details.title) ~= "string" or pr_details.title == "" then
    vim.notify("PR details missing or invalid title field", vim.log.levels.WARN)
    return false
  end

  -- If number is present, validate it
  if pr_details.number and type(pr_details.number) ~= "number" then
    vim.notify("PR details has invalid number field", vim.log.levels.WARN)
    return false
  end

  return true
end

---Validate PR data from GitHub API (strict validation for full PR details)
---@param pr_data any Data from GitHub API
---@return boolean is_valid
local function validate_pr_data(pr_data)
  if type(pr_data) ~= "table" then
    return false
  end

  -- Define field validators
  local field_validators = {
    number = function(v) return type(v) == "number" and v > 0 and v == math.floor(v) end,
    title = function(v) return type(v) == "string" and v ~= "" end,
    state = function(v) return type(v) == "string" and vim.tbl_contains({"open", "closed", "merged"}, v:lower()) end,
    url = function(v) return type(v) == "string" and (v:match("^https?://") ~= nil) end,
    body = function(v) return v == nil or type(v) == "string" end,
    author = function(v)
      return v == nil or (type(v) == "table" and type(v.login) == "string")
    end,
    createdAt = function(v) return v == nil or type(v) == "string" end,
    updatedAt = function(v) return v == nil or type(v) == "string" end,
    statusCheckRollup = function(v) return v == nil or type(v) == "table" end,
    reviews = function(v) return v == nil or type(v) == "table" end,
    comments = function(v) return v == nil or type(v) == "table" end,
  }

  -- Validate each field
  for field, validator in pairs(field_validators) do
    if field == "number" or field == "title" or field == "state" or field == "url" then
      -- Required fields
      if pr_data[field] == nil then
        vim.notify("PR data missing required field: " .. field, vim.log.levels.WARN)
        return false
      end
    end

    if pr_data[field] ~= nil and not validator(pr_data[field]) then
      vim.notify("PR data field '" .. field .. "' has invalid type or value: " .. tostring(pr_data[field]), vim.log.levels.WARN)
      return false
    end
  end

  -- Additional sanity checks
  if pr_data.number and pr_data.number > 999999 then
    vim.notify("PR number seems unrealistic: " .. tostring(pr_data.number), vim.log.levels.WARN)
    return false
  end

  return true
end

-- ============================================================================
-- PR PICKER
-- ============================================================================

-- LRU Cache for PR data with max size to prevent memory leaks
local pr_cache = {}
local pr_cache_order = {}  -- Track access order for LRU eviction
local PR_CACHE_MAX_SIZE = 50  -- Maximum number of PRs to cache

-- Track active jobs for PR picker (O(1) lookup using job_id as key)
local pr_picker_jobs = {}

-- Track if PR picker is active to prevent race conditions
local pr_picker_active = false

-- Track currently previewed PR number (used to detect if reopen is needed)
local currently_previewed_pr = nil

-- Track concurrent fetch count for throttling
local concurrent_fetch_count = 0

-- Queue for pending PR fetches
local fetch_queue = {}

---Update cache with LRU eviction
---@param pr_number number PR number
---@param data table PR data
local function update_pr_cache(pr_number, data)
  -- Remove from current position in order list if exists
  for i, num in ipairs(pr_cache_order) do
    if num == pr_number then
      table.remove(pr_cache_order, i)
      break
    end
  end

  -- Add to front of order list
  table.insert(pr_cache_order, 1, pr_number)
  pr_cache[pr_number] = data

  -- Evict oldest if cache is too large
  while #pr_cache_order > PR_CACHE_MAX_SIZE do
    local evicted = table.remove(pr_cache_order)
    pr_cache[evicted] = nil
  end
end

---Remove a single PR from the cache
local function remove_from_pr_cache(pr_number)
  pr_cache[pr_number] = nil
  for i, num in ipairs(pr_cache_order) do
    if num == pr_number then
      table.remove(pr_cache_order, i)
      break
    end
  end
end

---Clear the PR cache
local function clear_pr_cache()
  pr_cache = {}
  pr_cache_order = {}
end

---Process the fetch queue (must be called within vim.schedule)
local function process_fetch_queue()
  -- Ensure atomic access to concurrent_fetch_count
  vim.schedule(function()
    while concurrent_fetch_count < M.config.max_concurrent_fetches and #fetch_queue > 0 do
      local item = table.remove(fetch_queue, 1)
      if item then
        item.execute()
      end
    end
  end)
end

---Fetch PR details with throttling
---@param pr_number number PR number
---@param callback function Callback with PR details
local function fetch_pr_details(pr_number, callback)
  -- Validate PR number
  if not pr_number or type(pr_number) ~= "number" or pr_number <= 0 or pr_number ~= math.floor(pr_number) then
    vim.notify("Invalid PR number: " .. tostring(pr_number), vim.log.levels.ERROR)
    callback(nil)
    return
  end

  if pr_cache[pr_number] then
    callback(pr_cache[pr_number])
    return
  end

  local function do_fetch()
    -- Atomically increment counter
    vim.schedule(function()
      concurrent_fetch_count = concurrent_fetch_count + 1
    end)

    -- Use array form to prevent injection
    local cmd = {
      "gh", "pr", "view", tostring(pr_number),
      "--json", "number,title,body,state,url,author,createdAt,updatedAt,statusCheckRollup,reviews,comments,reviewDecision"
    }

    -- Use pcall for jobstart to prevent crashes
    local ok, job_id = pcall(vim.fn.jobstart, cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local json_str = table.concat(data, "")
      local ok, pr_data = pcall(vim.json.decode, json_str)
      if ok and pr_data and validate_pr_details(pr_data) then
        -- Add PR number if missing (GitHub Enterprise quirk)
        if not pr_data.number then
          pr_data.number = pr_number
        end

        -- Fetch inline review comments separately using GitHub API
        -- Note: This runs asynchronously. The main callback will be invoked before
        -- resolution status (resolved_comment_ids) is available. This is intentional
        -- to avoid blocking the preview. Resolution data will be cached for subsequent views.
        local repo_cmd = "git remote get-url origin | sed 's|.*[:/]\\([^/]*/[^/]*\\)\\.git.*|\\1|'"
        vim.fn.jobstart({"sh", "-c", repo_cmd}, {
          stdout_buffered = true,
          on_stdout = function(_, repo_data)
            local repo_path = vim.trim(table.concat(repo_data, ""))
            if repo_path ~= "" then
              local hostname_cmd = "git remote get-url origin | sed 's|.*://\\([^/]*\\)/.*|\\1|' | sed 's|.*@\\([^:]*\\):.*|\\1|'"
              vim.fn.jobstart({"sh", "-c", hostname_cmd}, {
                stdout_buffered = true,
                on_stdout = function(_, hostname_data)
                  local hostname = vim.trim(table.concat(hostname_data, ""))
                  local api_cmd = {"gh", "api", "repos/" .. repo_path .. "/pulls/" .. tostring(pr_number) .. "/comments"}
                  if hostname ~= "" and hostname ~= "github.com" then
                    table.insert(api_cmd, "--hostname")
                    table.insert(api_cmd, hostname)
                  end

                  local review_callback_called = false
                  vim.fn.jobstart(api_cmd, {
                    stdout_buffered = true,
                    on_stdout = function(_, review_data)
                      if review_callback_called then return end
                      local review_json = table.concat(review_data, "")
                      local ok_review, review_comments = pcall(vim.json.decode, review_json)
                      if ok_review and review_comments then
                        pr_data.review_comments = review_comments

                        -- Fetch resolution status separately to enable filtering
                        local owner, repo = repo_path:match("([^/]+)/([^/]+)")
                        if owner and repo then
                          local graphql_query = string.format('query { repository(owner: "%s", name: "%s") { pullRequest(number: %d) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { databaseId } } } } } } }', owner, repo, pr_number)
                          local graphql_cmd = {"gh", "api", "graphql", "-f", "query=" .. graphql_query}
                          if hostname ~= "" and hostname ~= "github.com" then
                            table.insert(graphql_cmd, "--hostname")
                            table.insert(graphql_cmd, hostname)
                          end

                          vim.fn.jobstart(graphql_cmd, {
                            stdout_buffered = true,
                            on_stdout = function(_, gql_data)
                              local gql_json = table.concat(gql_data, "")
                              local ok_gql, response = pcall(vim.json.decode, gql_json)
                              if ok_gql and response and response.data and response.data.repository
                                 and response.data.repository.pullRequest and response.data.repository.pullRequest.reviewThreads then
                                local threads = response.data.repository.pullRequest.reviewThreads.nodes or {}
                                local resolved_ids = {}
                                for _, thread in ipairs(threads) do
                                  if thread.isResolved and thread.comments and thread.comments.nodes and #thread.comments.nodes > 0 then
                                    -- Get the first comment ID in this thread (the root comment)
                                    local comment_id = thread.comments.nodes[1].databaseId
                                    if comment_id then
                                      resolved_ids[comment_id] = true
                                    end
                                  end
                                end
                                pr_data.resolved_comment_ids = resolved_ids
                              end
                              update_pr_cache(pr_number, pr_data)
                            end,
                            on_exit = function()
                              -- This GraphQL call fetches comment resolution status asynchronously.
                              -- We don't block the main callback on this data to keep the UI responsive.
                              -- The data will be available in cache for future views.
                            end
                          })
                        end
                      end
                      update_pr_cache(pr_number, pr_data)
                      review_callback_called = true
                      vim.schedule(function()
                        callback(pr_data)
                      end)
                    end,
                    on_stderr = function()
                      if review_callback_called then return end
                      -- Ignore errors, just continue without review comments
                      update_pr_cache(pr_number, pr_data)
                      review_callback_called = true
                      vim.schedule(function()
                        callback(pr_data)
                      end)
                    end
                  })
                end
              })
            else
              update_pr_cache(pr_number, pr_data)
              vim.schedule(function()
                callback(pr_data)
              end)
            end
          end
        })
      else
        vim.schedule(function()
          if not ok then
            vim.notify("Failed to parse PR details: " .. tostring(pr_data or "unknown error"), vim.log.levels.ERROR)
          else
            vim.notify("Invalid PR data received from GitHub API", vim.log.levels.ERROR)
          end
          callback(nil)
        end)
      end
    end,
    on_stderr = function(_, data)
      local err = table.concat(data, "")
      if err ~= "" then
        vim.schedule(function()
          vim.notify("Failed to fetch PR details: " .. vim.trim(tostring(err)), vim.log.levels.ERROR)
          callback(nil)
        end)
      end
    end,
    on_exit = function()
      vim.schedule(function()
        -- Remove from tracked jobs (O(1) deletion)
        if ok and job_id then
          pr_picker_jobs[job_id] = nil
        end
        -- Atomically decrement concurrent count and process queue
        concurrent_fetch_count = math.max(0, concurrent_fetch_count - 1)
        process_fetch_queue()
      end)
    end,
  })

    -- Handle jobstart failure
    if not ok or not job_id or job_id <= 0 then
      vim.schedule(function()
        concurrent_fetch_count = math.max(0, concurrent_fetch_count - 1)
        vim.notify("Failed to start job for PR " .. tostring(pr_number) .. ": " .. tostring(job_id), vim.log.levels.ERROR)
        callback(nil)
        process_fetch_queue()
      end)
    else
      -- Track the job (O(1) insertion)
      pr_picker_jobs[job_id] = true
    end
  end

  -- Check if we can fetch immediately or need to queue
  if concurrent_fetch_count < M.config.max_concurrent_fetches then
    do_fetch()
  else
    -- Queue the fetch for later
    table.insert(fetch_queue, {
      pr_number = pr_number,
      callback = callback,
      execute = do_fetch
    })
  end
end

---Convert ISO timestamp to relative time format
---@param iso_timestamp string ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SSZ)
---@return string relative_time
---Note: This uses local time for comparison. GitHub timestamps are UTC,
---so there may be slight timezone-based inaccuracies in the relative time display.
local function format_relative_time(iso_timestamp)
  if not iso_timestamp or #iso_timestamp < 19 then
    return "unknown"
  end

  -- Parse ISO 8601 timestamp: YYYY-MM-DDTHH:MM:SSZ
  local year, month, day, hour, min, sec = iso_timestamp:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return "unknown"
  end

  -- Convert to Unix timestamp
  -- Note: This treats the timestamp as local time, which may cause slight
  -- inaccuracies since GitHub provides UTC timestamps
  local timestamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec)
  })

  local now = os.time()
  local diff = now - timestamp

  -- ANSI color codes
  local red = "\27[31m"
  local reset = "\27[0m"

  local time_str
  local is_old = false

  -- Format relative time
  if diff < 60 then
    time_str = "just now"
  elseif diff < 3600 then
    local mins = math.floor(diff / 60)
    time_str = mins == 1 and "1 min ago" or mins .. " mins ago"
  elseif diff < 86400 then
    local hours = math.floor(diff / 3600)
    time_str = hours == 1 and "1 hour ago" or hours .. " hours ago"
  elseif diff < 604800 then
    local days = math.floor(diff / 86400)
    time_str = days == 1 and "1 day ago" or days .. " days ago"
  elseif diff < 2592000 then
    local weeks = math.floor(diff / 604800)
    time_str = weeks == 1 and "1 week ago" or weeks .. " weeks ago"
    is_old = true
  elseif diff < 31536000 then
    local months = math.floor(diff / 2592000)
    time_str = months == 1 and "1 month ago" or months .. " months ago"
    is_old = true
  else
    local years = math.floor(diff / 31536000)
    time_str = years == 1 and "1 year ago" or years .. " years ago"
    is_old = true
  end

  -- Apply red color for timestamps 1 week or older
  if is_old then
    return red .. time_str .. reset
  else
    return time_str
  end
end

---Format PR entry for picker with ANSI colors
---@param pr PullRequest Pull request data
---@param max_width number Maximum PR number width
---@return string formatted_entry
local function format_pr_entry(pr, max_width)
  -- Validate PR object
  if not pr then
    return "  #???  (unknown)  Invalid PR"
  end

  -- ANSI color codes matching dashboard
  local green = "\27[32m"
  local red = "\27[31m"
  local yellow = "\27[33m"
  local reset = "\27[0m"

  -- Use centralized review status logic
  local icon, _, _ = get_review_status(pr)

  -- Colorize icon based on review status
  if icon == "✓" then
    icon = green .. icon .. reset
  elseif icon == "✗" then
    icon = red .. icon .. reset
  elseif icon == "○" then
    icon = yellow .. icon .. reset
  end

  local pr_num = pad_pr_number(pr.number or 0, max_width)
  -- Colorize PR number in green
  pr_num = green .. "#" .. pr_num .. reset

  local initials = get_author_initials((pr.author and pr.author.login) or "unknown")
  local title = pr.title and (#pr.title > 50 and pr.title:sub(1, 47) .. "..." or pr.title) or "No title"

  return string.format("%s  %s  (%s)  %s", icon, pr_num, initials, title)
end

---Helper to highlight inline code in backticks
---@param text string Text to process
---@return string Text with highlighted code
local function highlight_code(text)
  local green = "\27[32m"
  local reset = "\27[0m"
  -- Replace `code` with colored version
  return text:gsub("`([^`]+)`", green .. "`%1`" .. reset)
end

---Helper to convert markdown links from [text](url) to text (url)
---Also converts HTML anchor tags <a href="url">text</a> to text (url)
---@param text string Text containing markdown or HTML links
---@return string Text with converted links
local function convert_markdown_links(text)
  -- Replace [text](url) with text (url)
  text = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)")

  -- Replace <a href="url">text</a> with text (url)
  -- Handle both single and double quotes
  text = text:gsub('<a%s+href="([^"]+)"[^>]*>([^<]+)</a>', '%2 (%1)')
  text = text:gsub("<a%s+href='([^']+)'[^>]*>([^<]+)</a>", "%2 (%1)")

  return text
end

---Helper to wrap text at specified width, preserving ANSI codes
---@param text string Text to wrap
---@param width number Maximum width
---@param prefix string Prefix for wrapped lines
---@return string Wrapped text
local function wrap_text(text, width, prefix)
  prefix = prefix or ""
  local function strip_ansi(str)
    return str:gsub("\27%[[%d;]*m", "")
  end

  local visible_len = #strip_ansi(text)
  if visible_len <= width then
    return text
  end

  local result = {}
  local current_line = ""
  local current_visible = 0

  for word in text:gmatch("%S+") do
    local word_visible = #strip_ansi(word)
    if current_visible + word_visible + 1 > width then
      if current_line ~= "" then
        table.insert(result, current_line)
        current_line = prefix .. word
        current_visible = #strip_ansi(prefix) + word_visible
      else
        table.insert(result, prefix .. word)
        current_line = ""
        current_visible = 0
      end
    else
      if current_line == "" then
        current_line = word
        current_visible = word_visible
      else
        current_line = current_line .. " " .. word
        current_visible = current_visible + 1 + word_visible
      end
    end
  end

  if current_line ~= "" then
    table.insert(result, current_line)
  end

  return table.concat(result, "\n")
end

---Generate PR preview
---@param pr_data table PR details
---@return string[] preview_lines
local function generate_pr_preview(pr_data)
  local lines = {}

  -- ANSI color codes
  local green = "\27[32m"
  local red = "\27[31m"
  local yellow = "\27[33m"
  local cyan = "\27[36m"
  local bold = "\27[1m"
  local reset = "\27[0m"

  -- Header
  table.insert(lines, "# PR #" .. (pr_data.number or "?") .. ": " .. (pr_data.title or "No title"))
  table.insert(lines, "")

  -- Review Status (using centralized logic)
  local review_icon, _, review_status = get_review_status(pr_data)
  local status_color = yellow
  if review_icon == "✓" then
    status_color = green
  elseif review_icon == "✗" then
    status_color = red
  end

  table.insert(lines, string.format("%sReview Status:%s %s%s %s%s", cyan, reset, status_color, review_icon, review_status, reset))

  -- Metadata
  local author_name = (pr_data.author and (pr_data.author.name or pr_data.author.login)) or "unknown"
  table.insert(lines, cyan .. "Author:" .. reset .. " " .. author_name)
  table.insert(lines, cyan .. "Created:" .. reset .. " " .. format_relative_time(pr_data.createdAt))
  table.insert(lines, cyan .. "Updated:" .. reset .. " " .. format_relative_time(pr_data.updatedAt))
  table.insert(lines, "")

  -- Reviews (only show reviews with actual comment text)
  if pr_data.reviews and #pr_data.reviews > 0 then
    local reviews_with_comments = vim.tbl_filter(function(review)
      return review.body and review.body ~= ""
    end, pr_data.reviews)

    if #reviews_with_comments > 0 then
      table.insert(lines, cyan .. bold .. "Reviews" .. reset)
      for _, review in ipairs(reviews_with_comments) do
        local state = review.state == "APPROVED" and "✓ Approved"
                   or review.state == "CHANGES_REQUESTED" and "✗ Changes requested"
                   or "💬 Commented"
        local author = (review.author and review.author.login) or "unknown"
        table.insert(lines, string.format("%s by %s%s%s", state, cyan, author, reset))

        -- Show the comment body
        local body_lines = {}
        for line in (review.body .. "\n"):gmatch("([^\r\n]*)\r?\n") do
          table.insert(body_lines, line)
        end
        for _, line in ipairs(body_lines) do
          if line == "" then
            table.insert(lines, "")
          else
            local converted = convert_markdown_links(line)
            local wrapped = wrap_text(converted, 58, "> ")
            if wrapped:find("\n") then
              for wrapped_line in wrapped:gmatch("[^\n]+") do
                table.insert(lines, wrapped_line)
              end
            else
              table.insert(lines, "> " .. wrapped)
            end
          end
        end
        table.insert(lines, "")
      end
    end
  end

  -- Description
  if pr_data.body and pr_data.body ~= "" then
    table.insert(lines, cyan .. bold .. "Description" .. reset)
    -- Split on newlines but preserve empty lines
    local body_lines = {}
    for line in (pr_data.body .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      table.insert(body_lines, line)
    end
    for _, line in ipairs(body_lines) do
      if line == "" then
        table.insert(lines, "")
      else
        local converted = convert_markdown_links(line)
        local wrapped = wrap_text(converted, 60, "")
        if wrapped:find("\n") then
          for wrapped_line in wrapped:gmatch("[^\n]+") do
            table.insert(lines, wrapped_line)
          end
        else
          table.insert(lines, wrapped)
        end
      end
    end
    table.insert(lines, "")
  end

  -- Regular PR Comments
  if pr_data.comments and #pr_data.comments > 0 then
    local regular_comments = vim.tbl_filter(function(comment)
      local user = comment.user or comment.author
      if not user or not user.login then
        return false
      end
      local author = user.login:lower()
      return not author:match("bot$") and not author:match("^github%-actions")
    end, pr_data.comments)

    if #regular_comments > 0 then
      table.insert(lines, cyan .. bold .. "Comments" .. reset)
      for i, comment in ipairs(regular_comments) do
        if i <= 5 then
          local user = comment.user or comment.author
          local author = (user and user.login) or "unknown"
          local created_at = comment.created_at or comment.createdAt or ""
          local time_ago = format_relative_time(created_at)
          table.insert(lines, string.format("%s%s%s (%s):", cyan, author, reset, time_ago))
          local body = comment.body or ""
          body = body:gsub("\r\n", "\n")
          local body_lines = {}
          for line in (body .. "\n"):gmatch("([^\r\n]*)\r?\n") do
            table.insert(body_lines, line)
          end
          for _, line in ipairs(body_lines) do
            if line == "" then
              table.insert(lines, "")
            else
              local converted = convert_markdown_links(line)
              local highlighted_line = highlight_code(converted)
              local wrapped = wrap_text(highlighted_line, 60, "")
              if wrapped:find("\n") then
                for wrapped_line in wrapped:gmatch("[^\n]+") do
                  table.insert(lines, wrapped_line)
                end
              else
                table.insert(lines, wrapped)
              end
            end
          end
          table.insert(lines, "")
        end
      end
    end
  end

  -- Inline Review Comments (fetched separately from API) - Threaded view
  if pr_data.review_comments and #pr_data.review_comments > 0 then
    local review_comments = vim.tbl_filter(function(comment)
      local user = comment.user or comment.author
      if not user or not user.login then
        return false
      end
      local author = user.login:lower()
      return not author:match("bot$") and not author:match("^github%-actions")
    end, pr_data.review_comments)

    if #review_comments > 0 then
      -- ANSI color codes
      local cyan = "\27[36m"
      local yellow = "\27[33m"
      local blue = "\27[34m"
      local dim = "\27[2m"
      local reset = "\27[0m"

      -- Build comment lookup by ID and find root comments
      local comment_by_id = {}
      local root_comments = {}
      local resolved_comment_ids = pr_data.resolved_comment_ids or {}
      local M = require("reviewer")
      local show_only_unresolved = M.config.show_only_unresolved_review_comments

      for _, comment in ipairs(review_comments) do
        comment_by_id[comment.id] = comment
        if not comment.in_reply_to_id then
          -- Filter by resolution status if config is enabled
          if not show_only_unresolved or not resolved_comment_ids[comment.id] then
            table.insert(root_comments, comment)
          end
        end
      end

      -- Helper function to render a comment with optional indentation
      local function render_comment(comment, indent)
        local user = comment.user or comment.author
        local author = (user and user.login) or "unknown"
        -- Parse datetime from ISO format (2025-11-07T14:30:00Z) to readable format
        local created_at = comment.created_at or ""
        local datetime_str = "unknown"
        if created_at ~= "" then
          -- Use relative time format
          datetime_str = format_relative_time(created_at)
        end

        local indent_str = string.rep("  ", indent)
        local prefix = indent > 0 and indent_str .. blue .. "╰─ " .. reset or ""

        -- For root comments, show datetime, file, and author
        if indent == 0 then
          -- DateTime first with indentation
          table.insert(lines, string.format("   %s%s%s", dim, datetime_str, reset))
          -- File path on second line
          local path = comment.path or "unknown"
          -- Handle vim.NIL for line numbers
          local line_num = comment.line
          if line_num == vim.NIL then
            line_num = comment.original_line
          end
          if line_num == vim.NIL or not line_num then
            line_num = "?"
          end
          table.insert(lines, string.format("   %s%s:%s%s",
            yellow, path, tostring(line_num), reset))
          -- Author line
          table.insert(lines, string.format("   %s@%s%s", cyan, author, reset))
        else
          table.insert(lines, string.format("%s%s@%s%s %s· %s%s",
            prefix,
            cyan, author, reset,
            dim, datetime_str, reset))
        end

        local body = comment.body or ""
        body = body:gsub("\r\n", "\n")
        local body_indent = indent == 0 and "   " or indent_str .. "   "
        local prefix_with_bar = body_indent .. dim .. "│ " .. reset
        local body_lines = {}
        for line in (body .. "\n"):gmatch("([^\r\n]*)\r?\n") do
          table.insert(body_lines, line)
        end

        -- Process body lines, handling code blocks specially
        local in_code_block = false
        local code_color = "\27[90m"  -- Dark gray for code

        for _, line in ipairs(body_lines) do
          -- Check for code fence (``` with optional language)
          if line:match("^```") then
            in_code_block = not in_code_block
            -- Skip the fence line entirely (don't render ``` or ```suggestion)
          elseif line == "" then
            table.insert(lines, "")
          elseif in_code_block then
            -- Inside code block: render as-is without wrapping, with gray color
            table.insert(lines, prefix_with_bar .. code_color .. line .. reset)
          else
            -- Normal text: convert markdown links and highlight inline code
            local converted = convert_markdown_links(line)
            local highlighted_line = highlight_code(converted)
            -- Wrap text accounting for the visible prefix length (58 chars total - indent - "│ ")
            local wrap_width = 58 - #body_indent - 2  -- 2 for "│ "
            local wrapped = wrap_text(highlighted_line, wrap_width, prefix_with_bar)
            if wrapped:find("\n") then
              -- Multi-line: add prefix to first line, rest already have it from wrap_text
              local first_line = true
              for wrapped_line in wrapped:gmatch("[^\n]+") do
                if first_line then
                  table.insert(lines, prefix_with_bar .. wrapped_line)
                  first_line = false
                else
                  table.insert(lines, wrapped_line)
                end
              end
            else
              table.insert(lines, prefix_with_bar .. wrapped)
            end
          end
        end
        -- Don't add blank line here - separator handles spacing
      end

      -- Helper function to collect all replies to a comment
      local function get_replies(comment_id)
        local replies = {}
        for _, comment in ipairs(review_comments) do
          if comment.in_reply_to_id == comment_id then
            table.insert(replies, comment)
          end
        end
        -- Sort replies by creation date (descending - most recent first)
        table.sort(replies, function(a, b)
          return (a.created_at or "") > (b.created_at or "")
        end)
        return replies
      end

      -- Render threads recursively
      local function render_thread(comment, indent)
        render_comment(comment, indent)
        local replies = get_replies(comment.id)
        for _, reply in ipairs(replies) do
          render_thread(reply, indent + 1)
        end
      end

      -- Only show header and render if we have root comments to display
      if #root_comments > 0 then
        table.insert(lines, cyan .. bold .. "Review Comments" .. reset)

        -- Sort root comments by creation date (descending - most recent first)
        table.sort(root_comments, function(a, b)
          return (a.created_at or "") > (b.created_at or "")
        end)

        -- Render all threads with visual separators
        for i, root_comment in ipairs(root_comments) do
          if i <= 15 then  -- Limit total threads shown
            render_thread(root_comment, 0)
            if i < #root_comments and i < 15 then
              table.insert(lines, "")
              table.insert(lines, dim .. "─────────────────────────────────────────────" .. reset)
              table.insert(lines, "")
            end
          end
        end
      end
    end
  end

  return lines
end

-- ============================================================================
-- PICKER ADAPTERS
-- ============================================================================

---@class PickerAdapter
---@field check function Check if picker is available
---@field show function Show the picker

-- ============================================================================
-- COMMON PICKER FUNCTIONS
-- ============================================================================

---Prefetch all PR details in the background
---@param prs table[] List of PRs
local function prefetch_all_prs(prs)
  for _, pr in ipairs(prs) do
    fetch_pr_details(pr.number, function() end)
  end
end

---Open PR in browser
---@param pr_number number PR number
local function open_pr_in_browser(pr_number)
  -- Validate PR number
  if not pr_number or type(pr_number) ~= "number" or pr_number <= 0 or pr_number ~= math.floor(pr_number) then
    vim.notify("Invalid PR number: " .. tostring(pr_number), vim.log.levels.ERROR)
    return
  end
  vim.fn.jobstart({ "gh", "pr", "view", tostring(pr_number), "--web" }, { detach = true })
  vim.notify("Opening PR #" .. pr_number .. " in browser", vim.log.levels.INFO)
end

---Checkout PR branch
---@param pr_number number PR number
local function checkout_pr(pr_number)
  -- Validate PR number
  if not pr_number or type(pr_number) ~= "number" or pr_number <= 0 or pr_number ~= math.floor(pr_number) then
    vim.notify("Invalid PR number: " .. tostring(pr_number), vim.log.levels.ERROR)
    return
  end
  vim.fn.jobstart({ "gh", "pr", "checkout", tostring(pr_number) })
  vim.notify("Checking out PR #" .. pr_number, vim.log.levels.INFO)
end

---Get available picker adapter
---@return PickerAdapter? adapter
local function get_picker_adapter()
  local adapters = {}

  -- Snacks adapter (simplified fallback to FZF if available)
  adapters.snacks = {
    check = function()
      -- Temporarily disable Snacks picker due to API issues
      -- Fall back to FZF or Telescope
      return false
    end,
    show = function(prs, max_width)
      -- This shouldn't be called since check returns false
      vim.notify("Snacks picker temporarily disabled. Using fallback picker.", vim.log.levels.INFO)
    end,
  }

  -- FZF-lua adapter
  adapters.fzf = {
    check = function()
      return pcall(require, "fzf-lua")
    end,
    show = function(prs, max_width)
      local fzf = require("fzf-lua")

      local entries = {}
      local pr_lookup = {}  -- Map PR number to PR data

      -- Build lookup and entries first
      for _, pr in ipairs(prs) do
        pr_lookup[pr.number] = pr
        local entry = format_pr_entry(pr, max_width)
        table.insert(entries, entry)
      end

      -- Helper to open the fzf picker
      local function open_picker()
        fzf.fzf_exec(entries, {
        prompt = "PRs> ",
        -- Enable multi-select with Tab
        fzf_opts = {
          ["--multi"] = "",
          ["--bind"] = "tab:toggle",
          -- Add ANSI color support
          ["--ansi"] = "",
          -- Enable preview window without wrap indicators
          ["--preview-window"] = "right:50%:wrap",
          -- Show keybinding hints
          ["--header"] = "Tab=select | Enter=open in browser | Alt-o=checkout",
        },
        -- Configure preview window explicitly
        winopts = {
          preview = {
            layout = "horizontal",
            horizontal = "right:50%",
          },
        },
        -- Simple preview function (working version)
        preview = function(selected)
          if not selected or #selected == 0 then
            currently_previewed_pr = nil
            return ""
          end
          local entry = selected[1]

          -- Extract PR number from entry (format: "icon  #NUM  ...")
          local pr_num = entry:match("#(%d+)")
          if not pr_num then
            currently_previewed_pr = nil
            return "Could not extract PR number"
          end
          pr_num = tonumber(pr_num)

          -- Track which PR is currently being previewed
          currently_previewed_pr = pr_num

          local pr = pr_lookup[pr_num]
          if not pr then
            return "PR not found"
          end

          if not pr_cache[pr.number] then
            return string.format("Loading PR #%d details...", pr.number)
          end

          local preview_lines = generate_pr_preview(pr_cache[pr.number])
          return table.concat(preview_lines, "\n")
        end,
        actions = {
          ["default"] = function(selected)
            if not selected or #selected == 0 then
              vim.notify("No PR selected", vim.log.levels.WARN)
              return
            end

            -- Open all selected PRs in browser using gh pr view --web
            for _, entry in ipairs(selected) do
              -- Extract PR number from entry
              local pr_num = entry:match("#(%d+)")
              if pr_num then
                pr_num = tonumber(pr_num)
                vim.fn.jobstart({ "gh", "pr", "view", tostring(pr_num), "--web" }, { detach = true })
              end
            end

            -- Show notification
            if #selected == 1 then
              vim.notify("Opening PR in browser", vim.log.levels.INFO)
            else
              vim.notify(string.format("Opening %d PRs in browser", #selected), vim.log.levels.INFO)
            end
          end,
          ["alt-o"] = function(selected)
            if selected and selected[1] then
              -- Extract PR number from entry
              local pr_num = selected[1]:match("#(%d+)")
              if pr_num then
                pr_num = tonumber(pr_num)
                vim.fn.jobstart({ "gh", "pr", "checkout", tostring(pr_num) })
                vim.notify("Checking out PR #" .. pr_num, vim.log.levels.INFO)
              else
                vim.notify("Could not find PR number", vim.log.levels.WARN)
              end
            end
          end,
        },
      })
      end

      -- Fetch first PR details, then open picker
      if prs[1] then
        fetch_pr_details(prs[1].number, function()
          -- First PR loaded, prefetch the rest in background
          for i = 2, #prs do
            fetch_pr_details(prs[i].number, function() end)
          end
          -- Open picker now that first PR is cached
          open_picker()
        end)
      else
        -- No PRs, just open empty picker
        open_picker()
      end
    end,
  }

  -- Telescope adapter
  adapters.telescope = {
    check = function()
      return pcall(require, "telescope")
    end,
    show = function(prs, max_width)
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local previewers = require("telescope.previewers")

      -- Prefetch all PR details
      for _, pr in ipairs(prs) do
        fetch_pr_details(pr.number, function() end)
      end

      pickers.new({}, {
        prompt_title = "PRs (Tab=select | Enter=open | Alt-o=checkout)",
        finder = finders.new_table({
          results = prs,
          entry_maker = function(pr)
            if not pr then
              return {
                value = nil,
                display = "Invalid PR",
                ordinal = "",
              }
            end
            -- Strip ANSI codes from display (telescope doesn't render them)
            local display = format_pr_entry(pr, max_width):gsub("\27%[[%d;]*m", "")
            return {
              value = pr,
              display = display,
              ordinal = (pr.number or "?") .. " " .. (pr.title or ""),
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        previewer = previewers.new_termopen_previewer({
          get_command = function(entry)
            if not entry or not entry.value then
              currently_previewed_pr = nil
              return nil
            end
            local pr = entry.value
            if not pr or not pr.number then
              currently_previewed_pr = nil
              return nil
            end

            -- Track which PR is currently being previewed
            currently_previewed_pr = pr.number

            -- Check if we have cached data
            if pr_cache[pr.number] then
              local lines = generate_pr_preview(pr_cache[pr.number])
              local preview_text = table.concat(lines, "\n")
              -- Use printf to preserve ANSI codes
              return { "printf", "%s", preview_text }
            else
              -- Return loading message while we fetch
              return { "echo", "Loading PR #" .. pr.number .. " details..." }
            end
          end,
        }),
      attach_mappings = function(prompt_bufnr, map)
          -- Tab to toggle selection (matches fzf)
          map("i", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
          map("n", "<Tab>", actions.toggle_selection + actions.move_selection_worse)

          actions.select_default:replace(function()
            -- Get selections BEFORE closing
            local picker = action_state.get_current_picker(prompt_bufnr)
            local selections = picker:get_multi_selection()
            local current_selection = action_state.get_selected_entry()

            actions.close(prompt_bufnr)

            -- If multi-selection exists, use it; otherwise use current selection
            if #selections > 0 then
              for _, selection in ipairs(selections) do
                if selection.value and selection.value.number then
                  vim.fn.jobstart({ "gh", "pr", "view", tostring(selection.value.number), "--web" }, { detach = true })
                end
              end
              vim.notify("Opening " .. #selections .. " PRs in browser", vim.log.levels.INFO)
            else
              if current_selection and current_selection.value and current_selection.value.number then
                vim.fn.jobstart({ "gh", "pr", "view", tostring(current_selection.value.number), "--web" }, { detach = true })
                vim.notify("Opening PR #" .. current_selection.value.number .. " in browser", vim.log.levels.INFO)
              else
                vim.notify("No PR selected", vim.log.levels.WARN)
              end
            end
          end)

          -- Alt-o to checkout (matches fzf)
          map("i", "<M-o>", function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if selection and selection.value and selection.value.number then
              vim.fn.jobstart({ "gh", "pr", "checkout", tostring(selection.value.number) })
              vim.notify("Checking out PR #" .. selection.value.number, vim.log.levels.INFO)
            else
              vim.notify("No PR selected", vim.log.levels.WARN)
            end
          end)

          map("n", "<M-o>", function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if selection and selection.value and selection.value.number then
              vim.fn.jobstart({ "gh", "pr", "checkout", tostring(selection.value.number) })
              vim.notify("Checking out PR #" .. selection.value.number, vim.log.levels.INFO)
            else
              vim.notify("No PR selected", vim.log.levels.WARN)
            end
          end)

          return true
        end,
      }):find()
    end,
  }

  -- Find first available picker based on config order
  for _, picker_name in ipairs(M.config.picker_order) do
    local adapter = adapters[picker_name]
    if adapter and adapter.check() then
      return adapter
    end
  end

  return nil
end

---Pick and display PRs
function M.pick_pr()
  -- Check for GitHub CLI
  if not check_gh_cli() then
    vim.notify("reviewer: GitHub CLI (gh) is not installed. Please install it from https://cli.github.com/", vim.log.levels.ERROR)
    return
  end

  -- Validate git repository
  local is_valid, err_msg = validate_git_repo()
  if not is_valid then
    vim.notify("reviewer: " .. err_msg, vim.log.levels.ERROR)
    return
  end

  -- Check if PR picker is already active to prevent race conditions
  if pr_picker_active then
    vim.notify("PR picker already in progress", vim.log.levels.WARN)
    return
  end

  local adapter = get_picker_adapter()
  if not adapter then
    vim.notify("No compatible picker found. Install snacks.nvim, fzf-lua, or telescope.nvim", vim.log.levels.ERROR)
    return
  end

  -- Mark picker as active
  pr_picker_active = true

  -- Reset currently previewed PR (will be set when user navigates in picker)
  currently_previewed_pr = nil

  -- Don't clear cache - we'll invalidate only changed PRs

  -- Stop any existing picker jobs (iterate over hash table)
  for job_id, _ in pairs(pr_picker_jobs) do
    pcall(vim.fn.jobstop, job_id)
  end
  pr_picker_jobs = {}

  -- Clear fetch queue and reset concurrent count
  fetch_queue = {}
  concurrent_fetch_count = 0

  -- Check if we have any cached PRs to show immediately
  local has_cached_prs = next(pr_cache) ~= nil

  if has_cached_prs then
    -- Use cached PRs
    local display_prs = {}
    for pr_num, pr_data in pairs(pr_cache) do
      table.insert(display_prs, pr_data)
    end

    -- Sort by PR number descending
    table.sort(display_prs, function(a, b)
      return (a.number or 0) > (b.number or 0)
    end)

    -- Calculate max width
    local max_width = 0
    for _, p in ipairs(display_prs) do
      local width = #tostring(p.number)
      if width > max_width then
        max_width = width
      end
    end

    -- Show picker immediately with cached data
    vim.schedule(function()
      adapter.show(display_prs, max_width)
    end)
  else
    -- No cache - show notification, picker will open when data arrives
    vim.notify("Loading PRs...", vim.log.levels.INFO)
  end

  -- Start network request in background
  -- First: minimal request to check timestamps
  local check_cmd = {
    "gh", "pr", "list",
    "--search", M.config.pr_search_filter,
    "--limit", tostring(M.config.pr_limit),
    "--json", "number,updatedAt"
  }

  local job_id = vim.fn.jobstart(check_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      local json_str = table.concat(data, "")
      local ok, timestamp_list = pcall(vim.json.decode, json_str)

      if not ok or not timestamp_list or type(timestamp_list) ~= "table" or #timestamp_list == 0 then
        vim.schedule(function()
          pr_picker_active = false
          if not ok then
            vim.notify("Failed to parse PR list: " .. (timestamp_list or "unknown error"), vim.log.levels.ERROR)
          elseif type(timestamp_list) ~= "table" then
            vim.notify("Invalid PR list format from GitHub API", vim.log.levels.ERROR)
          else
            vim.notify("No PRs found", vim.log.levels.INFO)
          end
        end)
        return
      end

      -- Check which PRs need updating
      local prs_to_fetch = {}
      local prs_to_remove = {}

      for _, pr_info in ipairs(timestamp_list) do
        local cached = pr_cache[pr_info.number]
        if not cached or not cached.updatedAt or cached.updatedAt ~= pr_info.updatedAt then
          table.insert(prs_to_fetch, pr_info.number)
        end
      end

      -- Find PRs in cache that no longer exist in the list
      for pr_num, _ in pairs(pr_cache) do
        local found = false
        for _, pr_info in ipairs(timestamp_list) do
          if pr_info.number == pr_num then
            found = true
            break
          end
        end
        if not found then
          table.insert(prs_to_remove, pr_num)
        end
      end

      -- Remove stale PRs from cache
      for _, pr_num in ipairs(prs_to_remove) do
        remove_from_pr_cache(pr_num)
      end

      -- Handle updates: fetch changed PRs, notify about changes
      if not has_cached_prs or #prs_to_fetch > 0 or #prs_to_remove > 0 then
        local fetch_count = #prs_to_fetch

        if has_cached_prs and fetch_count > 0 then
          vim.notify(string.format("Refreshing %d updated PR%s...", fetch_count, fetch_count > 1 and "s" or ""), vim.log.levels.INFO)
        end

        -- Fetch full data for changed PRs
        local fetch_complete_count = 0
        local total_to_fetch = #prs_to_fetch

        -- Helper function to handle completion
        local function on_fetch_complete()
          vim.schedule(function()
            pr_picker_active = false

            -- Build display list from updated cache
            local display_prs = {}
            for _, pr_data in pairs(pr_cache) do
              table.insert(display_prs, pr_data)
            end

            -- Sort by PR number descending
            table.sort(display_prs, function(a, b)
              return (a.number or 0) > (b.number or 0)
            end)

            if #display_prs == 0 then
              vim.notify("No PRs found", vim.log.levels.INFO)
              return
            end

            -- Calculate max width
            local max_width = 0
            for _, p in ipairs(display_prs) do
              local width = #tostring(p.number)
              if width > max_width then
                max_width = width
              end
            end

            -- Show/refresh the picker with updated data
            -- If picker was already open, this reopens it with fresh icons/status
            adapter.show(display_prs, max_width)
          end)
        end

        -- Determine action based on what changed
        if total_to_fetch > 0 then
          -- Save old data that affects left window display (icon, title, author)
          -- so we can detect if left window needs refresh
          local old_left_window_data = {}
          for _, pr_num in ipairs(prs_to_fetch) do
            local cached = pr_cache[pr_num]
            if cached then
              old_left_window_data[pr_num] = {
                reviewDecision = cached.reviewDecision,
                title = cached.title,
                author = cached.author and cached.author.login or nil,
              }
            end
          end

          -- Invalidate cache entries for PRs that need updating
          -- This ensures fetch_pr_details will fetch fresh data instead of returning stale cache
          for _, pr_num in ipairs(prs_to_fetch) do
            remove_from_pr_cache(pr_num)
          end

          -- Track if any left window data changed
          local left_window_changed = false

          -- Check if the currently previewed PR is being updated
          local currently_previewed_pr_updated = false
          if currently_previewed_pr then
            for _, pr_num in ipairs(prs_to_fetch) do
              if pr_num == currently_previewed_pr then
                currently_previewed_pr_updated = true
                break
              end
            end
          end

          -- Fetch updated PRs
          for _, pr_num in ipairs(prs_to_fetch) do
            fetch_pr_details(pr_num, function(pr_data)
              fetch_complete_count = fetch_complete_count + 1

              -- Check if left window data changed for this PR
              if pr_data then
                local old_data = old_left_window_data[pr_num]
                local new_data = {
                  reviewDecision = pr_data.reviewDecision,
                  title = pr_data.title,
                  author = pr_data.author and pr_data.author.login or nil,
                }

                -- Compare: if any field differs, left window needs refresh
                if not old_data or
                   old_data.reviewDecision ~= new_data.reviewDecision or
                   old_data.title ~= new_data.title or
                   old_data.author ~= new_data.author then
                  left_window_changed = true
                end
              elseif not old_left_window_data[pr_num] then
                -- New PR (first time seeing it) - left window needs refresh
                left_window_changed = true
              end

              -- When done fetching all PRs (callbacks always invoked, even on failure)
              if fetch_complete_count == total_to_fetch then
                -- Determine if picker needs reopening
                local needs_reopen = not has_cached_prs or               -- First launch
                                     left_window_changed or               -- Left window changed (icons/titles)
                                     currently_previewed_pr_updated       -- Viewing updated PR (need fresh preview)

                -- Ensure we have at least some PRs in cache before showing picker
                if not has_cached_prs and next(pr_cache) == nil then
                  vim.schedule(function()
                    pr_picker_active = false
                    vim.notify("Failed to load PR data", vim.log.levels.ERROR)
                  end)
                elseif needs_reopen then
                  -- Need to refresh picker (left window changed or viewing updated PR)
                  on_fetch_complete()
                else
                  -- Only right window data changed for PRs user isn't viewing
                  -- Cache is updated, preview will show fresh data when user navigates
                  -- No need to reopen picker - better UX!
                  vim.schedule(function()
                    pr_picker_active = false
                  end)
                end
              end
            end)
          end
        elseif #prs_to_remove > 0 then
          -- Only removals, no fetches needed - reopen picker to show updated list
          if has_cached_prs then
            vim.notify(string.format("%d PR%s removed from list", #prs_to_remove, #prs_to_remove > 1 and "s" or ""), vim.log.levels.INFO)
          end
          on_fetch_complete()
        else
          -- Defensive: first launch with empty PR list
          -- (shouldn't happen - line 3041-3052 exits early if PR list is empty)
          vim.schedule(function()
            pr_picker_active = false
          end)
        end
      else
        -- Cache is up to date, nothing to do
        vim.schedule(function()
          pr_picker_active = false
        end)
      end
    end,
    on_stderr = function(_, data)
      local error_msg = table.concat(data, "")
      if error_msg and error_msg ~= "" then
        vim.schedule(function()
          pr_picker_active = false  -- Reset picker state
          vim.notify("Failed to fetch PRs: " .. error_msg, vim.log.levels.ERROR)
        end)
      end
    end,
  })

  -- Check if job started successfully
  if job_id <= 0 then
    pr_picker_active = false  -- Reset picker state
    vim.notify("Failed to start GitHub CLI. Is gh installed?", vim.log.levels.ERROR)
  end
end

-- ============================================================================
-- EXPORTS
-- ============================================================================

return M