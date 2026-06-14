-- commit-msg.nvim
-- Generates a Conventional Commits draft from the staged diff via the Anthropic API.

local M = {}

local DEFAULT_SYSTEM_PROMPT = table.concat({
    "You generate a single Conventional Commits message from a git diff.",
    "Header: '<type>(<optional scope>): <subject>' where type is one of",
    "feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.",
    "Subject: imperative mood, lowercase start, no trailing period, max 50 chars.",
    "If the change needs explanation, add a blank line then a body with '- ' bullets,",
    "each stating a concrete change; otherwise output only the header.",
    "Output ONLY the raw commit message: no markdown fences, no quotes, no commentary.",
}, " ")

--- @class CommitMsgOpts
--- @field auto boolean|nil             Auto-generate on FileType gitcommit (default: true). Set false to use only :CommitMsgGen.
--- @field api_url string|nil           Anthropic API endpoint (default: messages endpoint).
--- @field api_key_env string[]|string|nil  Env var name(s) to look up the API key. First non-empty wins.
--- @field model string|nil             Model id (default: claude-haiku-4-5).
--- @field max_tokens integer|nil       Output cap (default: 512).
--- @field timeout_ms integer|nil       Hard cap on the curl call (default: 35000).
--- @field system_prompt string|nil     System prompt override.
--- @field prompt_extra string|nil      Appended to system_prompt with a blank line separator. Use for project conventions without rewriting the default prompt.
--- @field thinking table|nil           { budget_tokens = N } to enable extended thinking. nil = disabled.
--- @field should_generate fun(buf:integer):boolean|nil  Predicate gating auto-generation; return false to skip.
--- @field notify_usage boolean|nil     Notify model id and token usage on success (default: false).
--- @field max_diff_bytes integer|nil   Truncate the diff before sending if it exceeds this many bytes. 0 or nil disables.
--- @field secret_scan "warn"|"abort"|false|nil  Pre-flight scan for common credential patterns. "warn" notifies and sends, "abort" blocks the request, false skips the scan (default: "warn").
--- @field include_paths boolean|nil   Prepend the list of changed paths to the user message so the model can pick a better scope (default: true).
--- @field cache boolean|nil           Cache responses keyed by (model + system + user message) under stdpath('cache'). :CommitMsgGen! bypasses lookup (default: true).
--- @field preview boolean|nil         Show the generated message in a floating window with accept/regenerate/cancel instead of inserting immediately (default: false).

--- @type CommitMsgOpts
local defaults = {
    auto = true,
    api_url = "https://api.anthropic.com/v1/messages",
    api_key_env = { "ANTHROPIC_API_KEY_COMMIT_MSG", "ANTHROPIC_API_KEY" },
    model = "claude-haiku-4-5",
    max_tokens = 512,
    timeout_ms = 35000,
    system_prompt = DEFAULT_SYSTEM_PROMPT,
    prompt_extra = nil,
    thinking = nil,
    should_generate = nil,
    notify_usage = false,
    max_diff_bytes = 200000,
    secret_scan = "warn",
    include_paths = true,
    cache = true,
    preview = false,
}

local SECRET_PATTERNS = {
    { "AWS access key", "AKIA[0-9A-Z]+" },
    { "Anthropic API key", "sk%-ant%-[%w_%-]+" },
    { "Google API key", "AIza[%w_%-]+" },
    { "GitHub token", "gh[pousr]_[%w]+" },
    { "Slack token", "xox[abprs]%-[%w_%-]+" },
    { "private key block", "%-%-%-%-%-BEGIN [%w ]+PRIVATE KEY" },
}

local function scan_for_secrets(diff)
    for _, p in ipairs(SECRET_PATTERNS) do
        if diff:find(p[2]) then
            return p[1]
        end
    end
    return nil
end

local function cache_dir()
    local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "commit-msg")
    vim.fn.mkdir(dir, "p")
    return dir
end

local function cache_lookup(key)
    local path = vim.fs.joinpath(cache_dir(), key)
    if vim.fn.filereadable(path) == 0 then
        return nil
    end
    local ok, data = pcall(vim.fn.readfile, path, "b")
    if not ok then
        return nil
    end
    return table.concat(data, "\n")
end

local function cache_store(key, text)
    local path = vim.fs.joinpath(cache_dir(), key)
    pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), path, "b")
end

--- Extract the b-side file paths from a unified diff header sequence.
local function extract_paths(diff)
    local paths, seen = {}, {}
    for path in (diff .. "\n"):gmatch("diff %-%-git a/%S+ b/(%S+)\n") do
        if not seen[path] then
            seen[path] = true
            table.insert(paths, path)
        end
    end
    return paths
end

--- @type CommitMsgOpts
local config = vim.deepcopy(defaults)

--- Map of buf -> SystemObj for the curl request currently in flight.
local active = {}

--- Dedicated namespace for the "generating..." spinner overlay.
local ns = vim.api.nvim_create_namespace("commit_msg_spinner")

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_INTERVAL_MS = 100

--- Map of buf -> uv_timer animating the spinner overlay.
local spinner_timers = {}

local function notify(msg, level)
    vim.notify("commit-msg: " .. msg, level or vim.log.levels.WARN)
end

local function resolve_api_key()
    local names = config.api_key_env
    if type(names) == "string" then
        names = { names }
    end
    for _, name in ipairs(names or {}) do
        local v = vim.env[name]
        if v and v ~= "" then
            return v, name
        end
    end
    return nil, nil
end

local function parse_response(stdout)
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok or type(decoded) ~= "table" then
        return nil, "could not parse API JSON:\n" .. (stdout or "")
    end
    if decoded.error then
        local e = decoded.error
        return nil, "API error: " .. tostring(e.message or e.type or "unknown")
    end
    local content = decoded.content
    if type(content) ~= "table" then
        return nil, "unexpected API response shape"
    end
    -- With extended thinking enabled the response may contain thinking blocks
    -- before the text block; concatenate every non-empty 'text' block so that
    -- a multi-block reply (rare, but possible) isn't truncated to the first one.
    local parts = {}
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            if block.text ~= "" then
                table.insert(parts, block.text)
            end
        end
    end
    if #parts == 0 then
        return nil, "API returned no text block"
    end
    return {
        text = table.concat(parts, "\n\n"),
        model = decoded.model,
        usage = decoded.usage,
    }, nil
end

--- Find the first line that looks like the start of the git commit template.
--- Strong signatures match the standard English templates; the fallback
--- catches a run of three or more consecutive '#' lines, which holds for
--- localized templates too. Returns 1-based line index or nil.
local function find_template_start(lines)
    for i, line in ipairs(lines) do
        if
            line:match("^#%s*Please enter")
            or line:match("^#%s*On branch ")
            or line:match("^#%s*HEAD detached")
            or line:match("^#%s*-+%s*>8")
        then
            return i
        end
    end

    local run, run_start = 0, nil
    for i, line in ipairs(lines) do
        if line:match("^#") then
            if run == 0 then
                run_start = i
            end
            run = run + 1
            if run >= 3 then
                return run_start
            end
        else
            run, run_start = 0, nil
        end
    end
    return nil
end

--- Drop existing draft lines above the git-template comments. If no
--- template is detected (rare for a real gitcommit buffer), clear the
--- whole buffer so :CommitMsgGen still starts from a clean slate.
local function wipe_draft(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start = find_template_start(lines)
    local cut = start and (start - 1) or #lines
    if cut > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, cut, false, {})
    end
end

local function stop_spinner_timer(buf)
    local timer = spinner_timers[buf]
    if not timer then
        return
    end
    spinner_timers[buf] = nil
    pcall(function()
        timer:stop()
        timer:close()
    end)
end

local function show_placeholder(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    stop_spinner_timer(buf)

    local frame = 1
    local function render()
        if not vim.api.nvim_buf_is_valid(buf) then
            stop_spinner_timer(buf)
            return
        end
        local label = SPINNER_FRAMES[frame] .. " generating commit message..."
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
            id = 1,
            virt_text = { { label, "DiagnosticHint" } },
            virt_text_pos = "eol",
            hl_mode = "combine",
        })
        frame = frame % #SPINNER_FRAMES + 1
    end

    render()
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    spinner_timers[buf] = timer
    timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, vim.schedule_wrap(render))
end

local function clear_placeholder(buf)
    stop_spinner_timer(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return true
end

local function fail(buf, msg)
    notify(msg, vim.log.levels.ERROR)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local lines = { "# commit-msg failed:" }
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        table.insert(lines, "# " .. l)
    end
    table.insert(lines, "# Write the message manually, or retry with :CommitMsgGen.")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
end

--- @return boolean killed
local function cancel_request(buf, silent)
    local sys = active[buf]
    if not sys then
        if not silent then
            notify("nothing to cancel")
        end
        return false
    end
    active[buf] = nil
    pcall(function()
        sys:kill(15)
    end)
    clear_placeholder(buf)
    return true
end

local function insert_message(buf, text)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, lines)
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
        vim.api.nvim_win_set_cursor(win, { 1, #(lines[1] or "") })
    end
end

--- Map of main_buf -> { win, buf } for the preview window tied to that buffer.
local previews = {}

local function close_preview(main_buf)
    local p = previews[main_buf]
    if not p then
        return
    end
    previews[main_buf] = nil
    if p.win and vim.api.nvim_win_is_valid(p.win) then
        vim.api.nvim_win_close(p.win, true)
    end
    if p.buf and vim.api.nvim_buf_is_valid(p.buf) then
        vim.api.nvim_buf_delete(p.buf, { force = true })
    end
end

local function show_preview(main_buf, text, on_accept, on_regenerate)
    close_preview(main_buf)

    local lines = vim.split(text, "\n", { plain = true })
    local pbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.b[pbuf].commit_msg_skip = true
    vim.bo[pbuf].filetype = "gitcommit"

    local width = math.max(60, math.min(100, vim.o.columns - 10))
    local height = math.max(5, math.min(20, #lines + 2))
    local pwin = vim.api.nvim_open_win(pbuf, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = "minimal",
        border = "rounded",
        title = " commit-msg preview ",
        title_pos = "center",
        footer = " [<CR>/a] accept  [r] regenerate  [q/<Esc>] cancel ",
        footer_pos = "center",
    })

    previews[main_buf] = { win = pwin, buf = pbuf }

    local function accept()
        if not (pbuf and vim.api.nvim_buf_is_valid(pbuf)) then
            return
        end
        local edited = table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), "\n")
        close_preview(main_buf)
        on_accept(edited)
    end

    local function map(lhs, rhs)
        vim.keymap.set("n", lhs, rhs, { buffer = pbuf, nowait = true, silent = true })
    end
    map("a", accept)
    map("<CR>", accept)
    map("r", function()
        close_preview(main_buf)
        on_regenerate()
    end)
    map("q", function()
        close_preview(main_buf)
    end)
    map("<Esc>", function()
        close_preview(main_buf)
    end)
end

local function present_message(buf, text)
    if config.preview then
        show_preview(buf, text, function(final)
            insert_message(buf, final)
        end, function()
            M.generate(buf, { force = true, no_cache = true })
        end)
    else
        insert_message(buf, text)
    end
end

local function send_request(buf, api_key, diff, req_opts)
    req_opts = req_opts or {}
    cancel_request(buf, true)
    close_preview(buf)

    if config.secret_scan then
        local hit = scan_for_secrets(diff)
        if hit then
            if config.secret_scan == "abort" then
                notify(
                    "aborting: possible " .. hit .. " in diff (set secret_scan=false to override)",
                    vim.log.levels.ERROR
                )
                return
            end
            notify(
                "possible " .. hit .. " in diff; sending anyway (set secret_scan=false to silence)",
                vim.log.levels.WARN
            )
        end
    end

    local limit = config.max_diff_bytes
    if type(limit) == "number" and limit > 0 and #diff > limit then
        notify(
            string.format("diff is %d bytes, truncating to %d", #diff, limit),
            vim.log.levels.INFO
        )
        diff = diff:sub(1, limit) .. "\n\n[... diff truncated]"
    end

    local system = config.system_prompt or ""
    if type(config.prompt_extra) == "string" and config.prompt_extra ~= "" then
        system = system .. "\n\n" .. config.prompt_extra
    end

    local user_msg = "Here is the staged diff:\n\n" .. diff
    if config.include_paths then
        local paths = extract_paths(diff)
        if #paths > 0 then
            user_msg = "Changed files:\n"
                .. table.concat(paths, "\n")
                .. "\n\n"
                .. user_msg
        end
    end

    local cache_key = vim.fn.sha256(config.model .. "|" .. system .. "|" .. user_msg)
    if config.cache and not req_opts.no_cache then
        local hit = cache_lookup(cache_key)
        if hit then
            present_message(buf, hit)
            notify("loaded from cache", vim.log.levels.INFO)
            return
        end
    end

    show_placeholder(buf)

    local payload = {
        model = config.model,
        max_tokens = config.max_tokens,
        system = system,
        messages = { { role = "user", content = user_msg } },
    }
    if type(config.thinking) == "table" then
        payload.thinking = vim.tbl_extend("keep", config.thinking, { type = "enabled" })
    end

    local body = vim.json.encode(payload)
    -- Use a small curl timeout below the vim.system one so curl's own message wins on TLE.
    local curl_timeout = math.max(5, math.floor(config.timeout_ms / 1000) - 5)

    local sys
    local ok, err_or_sys = pcall(
        vim.system,
        {
            "curl",
            "-s",
            "--max-time",
            tostring(curl_timeout),
            config.api_url,
            "-H",
            "content-type: application/json",
            "-H",
            "x-api-key: " .. api_key,
            "-H",
            "anthropic-version: 2023-06-01",
            "-d",
            "@-",
        },
        { text = true, stdin = body, timeout = config.timeout_ms },
        function(res)
            vim.schedule(function()
                if active[buf] ~= sys then
                    -- cancelled or superseded by a newer request
                    return
                end
                active[buf] = nil
                if not clear_placeholder(buf) then
                    return
                end

                if res.code == nil then
                    fail(buf, "request timed out (no response).")
                    return
                end
                if res.code ~= 0 then
                    local detail = (res.stderr ~= nil and res.stderr ~= "") and res.stderr
                        or ("curl exited with code " .. tostring(res.code))
                    fail(buf, detail)
                    return
                end

                local info, perr = parse_response(res.stdout or "")
                if not info then
                    fail(buf, perr)
                    return
                end

                local text = info.text:gsub("```%w*\n?", ""):gsub("^%s+", ""):gsub("\n+$", "")
                if config.cache then
                    cache_store(cache_key, text)
                end
                present_message(buf, text)

                if config.notify_usage and info.usage then
                    notify(
                        string.format(
                            "%s | in=%s out=%s",
                            info.model or config.model,
                            tostring(info.usage.input_tokens or "?"),
                            tostring(info.usage.output_tokens or "?")
                        ),
                        vim.log.levels.INFO
                    )
                end
            end)
        end
    )

    if not ok then
        vim.schedule(function()
            clear_placeholder(buf)
            fail(buf, "failed to start curl:\n" .. tostring(err_or_sys))
        end)
        return
    end

    sys = err_or_sys
    active[buf] = sys
end

--- @param buf integer|nil
--- @param opts table|nil  { force = bool }
function M.generate(buf, opts)
    opts = opts or {}
    buf = buf or vim.api.nvim_get_current_buf()

    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "gitcommit" then
        notify("not a gitcommit buffer")
        return
    end

    if opts.force then
        wipe_draft(buf)
    else
        local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
        if first:find("%S") then
            return
        end
    end

    local api_key = resolve_api_key()
    if not api_key then
        local names = config.api_key_env
        if type(names) == "table" then
            names = table.concat(names, " or ")
        end
        notify("API key not set (expected env: " .. tostring(names) .. ")")
        return
    end
    if vim.fn.executable("curl") == 0 then
        notify("'curl' not found in PATH")
        return
    end

    local buf_name = vim.api.nvim_buf_get_name(buf)
    local cwd = buf_name ~= "" and vim.fs.dirname(buf_name) or nil
    local diff_cmd = { "git" }
    if cwd then
        table.insert(diff_cmd, "-C")
        table.insert(diff_cmd, cwd)
    end
    vim.list_extend(diff_cmd, { "diff", "--staged" })

    local ok, err = pcall(
        vim.system,
        diff_cmd,
        { text = true },
        vim.schedule_wrap(function(res)
            if not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            if res.code ~= 0 then
                local detail = vim.trim(res.stderr or "")
                if detail == "" then
                    detail = "exit code " .. tostring(res.code)
                end
                notify("git diff --staged failed: " .. detail, vim.log.levels.ERROR)
                return
            end
            local diff = res.stdout or ""
            if diff == "" then
                return
            end
            send_request(buf, api_key, diff, { no_cache = opts.no_cache })
        end)
    )
    if not ok then
        notify("failed to start git: " .. tostring(err), vim.log.levels.ERROR)
    end
end

--- @param buf integer|nil
function M.cancel(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    cancel_request(buf, false)
end

--- Read-only access to the current effective config (used by :checkhealth).
function M.get_config()
    return config
end

--- @param opts CommitMsgOpts|nil
function M.setup(opts)
    config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

    local group = vim.api.nvim_create_augroup("commit_msg", { clear = true })
    if config.auto then
        vim.api.nvim_create_autocmd("FileType", {
            group = group,
            pattern = "gitcommit",
            callback = function(ev)
                if vim.b[ev.buf].commit_msg_skip then
                    return
                end
                if type(config.should_generate) == "function" then
                    local ok, allow = pcall(config.should_generate, ev.buf)
                    if not ok or allow == false then
                        return
                    end
                end
                M.generate(ev.buf)
            end,
        })
    end

    -- Free in-flight handles and preview state tied to a buffer that's going away.
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(ev)
            cancel_request(ev.buf, true)
            close_preview(ev.buf)
        end,
    })
end

return M
