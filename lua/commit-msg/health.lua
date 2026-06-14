local M = {}

local function parse_curl_version(s)
    local maj, min = s:match("^(%d+)%.(%d+)")
    if not maj then
        return nil
    end
    return tonumber(maj), tonumber(min)
end

local function check_curl()
    if vim.fn.executable("curl") ~= 1 then
        vim.health.error("`curl` not found in $PATH; required for API calls")
        return
    end
    local out = vim.fn.system({ "curl", "--version" })
    local version = out:match("curl ([%w.]+)") or "unknown"
    local maj, min = parse_curl_version(version)
    if not maj then
        vim.health.warn("could not parse curl version (" .. version .. ")")
        return
    end
    -- 7.55 introduced `-H @<file>`, which we rely on to keep the API key
    -- out of argv. Earlier curl would treat `@file` as a literal header
    -- value and the API call would fail.
    if maj < 7 or (maj == 7 and min < 55) then
        vim.health.error(
            "curl " .. version .. " is too old; need >= 7.55 for `-H @file` (used to pass the API key without exposing it in argv)"
        )
        return
    end
    vim.health.ok("curl found (" .. version .. ")")
end

local function check_git()
    if vim.fn.executable("git") ~= 1 then
        vim.health.error("`git` not found in $PATH; required to read the staged diff")
        return
    end
    local out = vim.fn.system({ "git", "--version" })
    local version = out:match("git version ([%w.]+)") or "unknown"
    vim.health.ok("git found (" .. version .. ")")
end

local function check_neovim()
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.error(
            "Neovim 0.10+ required (vim.system, virt_lines_above, floating window footer)"
        )
    end
end

local function check_api_key()
    local cfg = require("commit-msg").get_config()
    local names = cfg.api_key_env
    if type(names) == "string" then
        names = { names }
    end
    if type(names) ~= "table" or vim.tbl_isempty(names) then
        vim.health.error("api_key_env is empty; nothing to look up")
        return
    end
    for _, name in ipairs(names) do
        local v = vim.env[name]
        if v and v ~= "" then
            vim.health.ok("API key found in $" .. name)
            return
        end
    end
    vim.health.error(
        "API key not set; expected one of: " .. table.concat(names, ", "),
        { "Set ANTHROPIC_API_KEY or ANTHROPIC_API_KEY_COMMIT_MSG in your shell environment" }
    )
end

local function check_cache_dir()
    local cfg = require("commit-msg").get_config()
    if not cfg.cache then
        vim.health.info("cache disabled (cache = false)")
        return
    end
    local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "commit-msg")
    local ok = pcall(vim.fn.mkdir, dir, "p")
    if ok and vim.fn.isdirectory(dir) == 1 then
        vim.health.ok("cache dir: " .. dir)
    else
        vim.health.warn("cache dir not writable: " .. dir)
    end
end

function M.check()
    vim.health.start("commit-msg.nvim")
    check_neovim()
    check_curl()
    check_git()
    check_api_key()
    check_cache_dir()
end

return M
