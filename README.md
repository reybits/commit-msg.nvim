# commit-msg.nvim

Generate a [Conventional Commits](https://www.conventionalcommits.org/) draft for the current `gitcommit` buffer from the staged diff via the [Anthropic API](https://docs.anthropic.com/).

When `git commit` opens a buffer with an empty message, the staged diff is sent to the API and the generated message is inserted at the top of the buffer. The user keeps full control: edit, replace, or scrap it before saving.

## Requirements

- Neovim >= 0.10 (uses `vim.system`, `vim.json`, extmark virt_text, floating window footer).
- `curl` >= 7.55 in `$PATH` (the plugin uses `-H @<file>` to pass the API key without exposing it in argv).
- An Anthropic API key.

## Installation

### lazy.nvim

```lua
{
    "reybits/commit-msg.nvim",
    ft = "gitcommit",
    cmd = { "CommitMsgGen", "CommitMsgCancel" },
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

To change the variable name(s), set `api_key_env` in the plugin opts.

The key is never placed on curl's command line. Before each request, it is written to a temporary file created with mode `0600` (atomic, via `vim.uv.fs_open`) and passed to curl as `-H @<file>`. The file is unlinked as soon as curl returns — on success, failure, timeout, cancel, or buffer wipe.

## Commands

- `:CommitMsgGen` — regenerate the message for the current `gitcommit` buffer. Wipes any existing draft above the git template comments. Uses the cache.
- `:CommitMsgGen!` — same, but bypasses the cache to force a fresh API call.
- `:CommitMsgCancel` — cancel an in-flight generation for the current buffer (kills curl, removes the spinner).

## Configuration

Defaults:

```lua
require("commit-msg").setup({
    auto = true,                -- false disables the FileType autocmd; :CommitMsgGen still works.
    api_url = "https://api.anthropic.com/v1/messages",
    api_key_env = { "ANTHROPIC_API_KEY_COMMIT_MSG", "ANTHROPIC_API_KEY" },
    model = "claude-haiku-4-5",
    max_tokens = 512,
    timeout_ms = 35000,

    system_prompt = nil,        -- nil = built-in Conventional Commits prompt.
    prompt_extra = nil,         -- appended to system_prompt with a blank-line separator.
    thinking = nil,             -- { budget_tokens = N } to enable extended thinking.

    should_generate = nil,      -- fun(buf):boolean predicate gating auto-generation.
    notify_usage = false,       -- on success, notify the model id and token usage.

    max_diff_bytes = 200000,    -- truncate the diff before sending; 0 or nil disables.
    secret_scan = "warn",       -- "warn" | "abort" | false: pre-flight credential pattern check.
    include_paths = true,       -- prepend the list of changed paths to the user message.

    cache = true,               -- cache responses under stdpath('cache')/commit-msg.
    preview = false,            -- show the result in a floating window before insert.
})
```

### Notes

- `auto = false` keeps the plugin opt-in: nothing happens when a `gitcommit` buffer opens, and `:CommitMsgGen` is the only entry point.
- `api_key_env` accepts a string or a list of strings; the first env var with a non-empty value is used.
- `thinking` is forwarded to the API as `{ type = "enabled", budget_tokens = N }`. It produces a more deliberate message at the cost of latency and tokens. Only supported by models with extended thinking (e.g. `claude-haiku-4-5`, `claude-sonnet-4-x`).
- `prompt_extra` is appended to the built-in `system_prompt`; use it to add project conventions (ticket prefix, scope rule) without rewriting the default prompt.
- `should_generate` only gates the FileType autocmd. `:CommitMsgGen` always runs because it is an explicit request.
- `secret_scan` checks the diff for common patterns: AWS keys, `sk-ant-` tokens, Google API keys, GitHub PATs, Slack tokens, and PEM private-key headers. `"abort"` stops the request, `"warn"` notifies and continues.
- `cache` keys responses by `sha256(model + system + user_msg)`. The same diff produces a cache hit; `:CommitMsgGen!` forces a regeneration.

### Per-buffer opt-out

Set `vim.b.commit_msg_skip = true` to disable auto-generation for that buffer. Useful for amend flows or for buffers you do not want the model to touch.

### Preview window

With `preview = true`, the result opens in a centered floating window instead of being inserted directly. Keymaps:

- `<CR>` or `a` — accept (insert into the gitcommit buffer; edits made in the preview are kept)
- `r` — regenerate (bypasses the cache)
- `q` or `<Esc>` — cancel (close without inserting)

## Health check

```vim
:checkhealth commit-msg
```

Verifies Neovim version, `curl`, `git`, the API key env var, and the cache directory.

## How it works

1. On `FileType gitcommit` (or when `:CommitMsgGen` runs), `git diff --staged` is invoked asynchronously in the buffer's repository.
2. The diff is sent to the Anthropic Messages API with a system prompt that constrains the output to a Conventional Commits message.
3. The response is post-processed (markdown fences stripped, whitespace trimmed) and either inserted at the top of the buffer or shown in a preview window.
4. An animated braille spinner (`⠋ generating commit message...`) is shown as virtual text on the first line while the API call is in flight and removed afterwards. Since it is rendered through an extmark, it never touches the buffer text and survives whatever the cursor is doing.

## License

MIT
