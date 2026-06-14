# commit-msg.nvim

Generate a [Conventional Commits](https://www.conventionalcommits.org/) draft for the current `gitcommit` buffer from the staged diff via the [Anthropic API](https://docs.anthropic.com/).

When `git commit` opens a buffer with an empty message, the staged diff is sent to the API and the generated message is inserted at the top of the buffer. The user keeps full control: edit, replace, or scrap it before saving.

## Requirements

- Neovim >= 0.10 (uses `vim.system`, `vim.json`).
- `curl` in `$PATH`.
- An Anthropic API key.

## Installation

### lazy.nvim

```lua
{
    "reybits/commit-msg.nvim",
    ft = "gitcommit",
    cmd = "CommitMsgGen",
    opts = {
        -- see "Configuration" below; the defaults are fine out of the box.
    },
}
```

## API key

The key is read from environment variables (never from disk in this plugin). By default the lookup order is:

1. `ANTHROPIC_API_KEY_COMMIT_MSG` — dedicated key for this plugin.
2. `ANTHROPIC_API_KEY` — the standard Anthropic key, used as a fallback.

```sh
export ANTHROPIC_API_KEY_COMMIT_MSG=sk-ant-...
# or
export ANTHROPIC_API_KEY=sk-ant-...
```

To change the variable name(s), set `api_key_env` in the plugin opts (see below).

## Configuration

Defaults:

```lua
require("commit-msg").setup({
    auto = true,         -- false disables the FileType autocmd; :CommitMsgGen still works
    api_url = "https://api.anthropic.com/v1/messages",
    api_key_env = { "ANTHROPIC_API_KEY_COMMIT_MSG", "ANTHROPIC_API_KEY" },
    model = "claude-haiku-4-5",
    max_tokens = 512,
    timeout_ms = 35000,
    system_prompt = nil, -- nil = built-in Conventional Commits prompt
    thinking = nil,      -- { budget_tokens = N } to enable extended thinking
})
```

Notes:

- `auto = false` keeps the plugin opt-in: nothing happens when a `gitcommit` buffer opens, and `:CommitMsgGen` is the only entry point.
- `api_key_env` accepts a string or a list of strings; the first env var with a non-empty value is used.
- `thinking` is forwarded to the API as `{ type = "enabled", budget_tokens = N }`. It produces a more deliberate message at the cost of latency and tokens. Only supported by models with extended thinking (e.g. `claude-haiku-4-5`, `claude-sonnet-4-x`).
- `system_prompt`, if set, replaces the default prompt entirely.

## Commands

- `:CommitMsgGen` — regenerate the message for the current `gitcommit` buffer. Wipes any existing draft above the git template comments and replaces it with a fresh response.

## How it works

1. On `FileType gitcommit`, if the first line is empty, the plugin runs `git diff --staged`.
2. The diff is sent to the Anthropic Messages API with a system prompt that constrains the output to a Conventional Commits message.
3. The response is inserted at the top of the buffer.
4. The placeholder `# ⏳ generating commit message...` shows during the call and is cleaned up afterwards (it's a comment line, so it's ignored by git even if something goes wrong).

## License

MIT
