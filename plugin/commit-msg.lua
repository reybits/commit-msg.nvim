if vim.g.loaded_commit_msg == 1 then
    return
end
vim.g.loaded_commit_msg = 1

vim.api.nvim_create_user_command("CommitMsgGen", function(o)
    require("commit-msg").generate(nil, { force = true, no_cache = o.bang })
end, {
    bang = true,
    desc = "Generate a commit message via the Anthropic API. :CommitMsgGen! bypasses the cache.",
})

vim.api.nvim_create_user_command("CommitMsgCancel", function()
    require("commit-msg").cancel(nil)
end, {
    desc = "Cancel an in-flight commit message generation for the current buffer",
})
