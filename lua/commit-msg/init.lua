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
--- @field api_url string|nil           Anthropic API endpoint (default: messages endpoint).
--- @field api_key_env string[]|string|nil  Env var name(s) to look up the API key. First non-empty wins.
--- @field model string|nil             Model id (default: claude-haiku-4-5).
--- @field max_tokens integer|nil       Output cap (default: 512).
--- @field timeout_ms integer|nil       Hard cap on the curl call (default: 35000).
--- @field system_prompt string|nil     System prompt override.
--- @field thinking table|nil           { budget_tokens = N } to enable extended thinking. nil = disabled.

--- @type CommitMsgOpts
local defaults = {
    api_url = "https://api.anthropic.com/v1/messages",
    api_key_env = { "ANTHROPIC_API_KEY_COMMIT_MSG", "ANTHROPIC_API_KEY" },
    model = "claude-haiku-4-5",
    max_tokens = 512,
    timeout_ms = 35000,
    system_prompt = DEFAULT_SYSTEM_PROMPT,
    thinking = nil,
}

--- @type CommitMsgOpts
local config = vim.deepcopy(defaults)

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

local function extract_text(stdout)
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
    -- before the text block; pick the first 'text' block we find.
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            if block.text ~= "" then
                return block.text, nil
            end
        end
    end
    return nil, "API returned no text block"
end

--- Drop existing draft lines above the first git-template comment.
local function wipe_draft(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local cut = #lines
    for i, line in ipairs(lines) do
        if line:match("^#") then
            cut = i - 1
            break
        end
    end
    if cut > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, cut, false, {})
    end
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
        if first:match("^%s*$") == nil then
            return
        end
    end

    local api_key, key_name = resolve_api_key()
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

    local diff = vim.fn.system("git diff --staged")
    if vim.v.shell_error ~= 0 or diff == "" then
        return
    end

    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# ⏳ generating commit message..." })

    local function clear_placeholder()
        if not vim.api.nvim_buf_is_valid(buf) then
            return false
        end
        local l0 = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
        if l0:match("generating commit message") then
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
        end
        return true
    end

    local function fail(msg)
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

    local payload = {
        model = config.model,
        max_tokens = config.max_tokens,
        system = config.system_prompt,
        messages = { { role = "user", content = "Here is the staged diff:\n\n" .. diff } },
    }
    if type(config.thinking) == "table" then
        payload.thinking = vim.tbl_extend("force", { type = "enabled" }, config.thinking)
    end

    local body = vim.json.encode(payload)
    -- Use a small curl timeout below the vim.system one so curl's own message wins on TLE.
    local curl_timeout = math.max(5, math.floor(config.timeout_ms / 1000) - 5)

    local ok, err = pcall(
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
                if not clear_placeholder() then
                    return
                end

                if res.code == nil then
                    fail("request timed out (no response).")
                    return
                end
                if res.code ~= 0 then
                    local detail = (res.stderr ~= nil and res.stderr ~= "") and res.stderr
                        or ("curl exited with code " .. tostring(res.code))
                    fail(detail)
                    return
                end

                local text, perr = extract_text(res.stdout or "")
                if not text then
                    fail(perr)
                    return
                end

                text = text:gsub("```%w*\n?", ""):gsub("^%s+", ""):gsub("\n+$", "")
                vim.api.nvim_buf_set_lines(
                    buf,
                    0,
                    0,
                    false,
                    vim.split(text, "\n", { plain = true })
                )
            end)
        end
    )

    if not ok then
        vim.schedule(function()
            clear_placeholder()
            fail("failed to start curl:\n" .. tostring(err))
        end)
    end

    -- Silence unused-var warning while keeping key_name reachable for future logging.
    _ = key_name
end

--- @param opts CommitMsgOpts|nil
function M.setup(opts)
    config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

    local group = vim.api.nvim_create_augroup("commit_msg", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = "gitcommit",
        callback = function(ev)
            M.generate(ev.buf)
        end,
    })

    vim.api.nvim_create_user_command("CommitMsgGen", function()
        M.generate(nil, { force = true })
    end, {
        desc = "Generate a commit message via the Anthropic API (overwrites the current draft)",
    })
end

return M
