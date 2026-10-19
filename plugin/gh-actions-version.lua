local function mod()
	return require("gh-actions-version")
end

---@type table<string, {desc: string, run: fun(bang: boolean)}>
local subcommands = {
	check = {
		desc = "Resolve versions and lint the current buffer (default)",
		run = function()
			mod().resolve()
			mod().lint()
		end,
	},
	clear = {
		desc = "Clear annotations, diagnostics and cache",
		run = function()
			mod().clear()
			require("gh-actions-version.api").clear_cache()
		end,
	},
	approve = {
		desc = "Approve pinned action on cursor line (! = whole buffer)",
		run = function(bang)
			mod().approve({ all = bang })
		end,
	},
	learn = {
		desc = "Approve all pinned actions found in the current repo",
		run = function()
			mod().learn()
		end,
	},
	fix = {
		desc = "Pick an approved SHA / pin the action on the cursor line",
		run = function()
			mod().fix()
		end,
	},
	store = {
		desc = "Open the approved actions store",
		run = function()
			mod().open_store()
		end,
	},
}

vim.api.nvim_create_user_command("GhActionsVersion", function(o)
	local name = o.fargs[1] or "check"
	local sub = subcommands[name]
	if not sub then
		vim.notify(
			("GhActionsVersion: unknown subcommand '%s' (available: %s)"):format(
				name,
				table.concat(vim.tbl_keys(subcommands), ", ")
			),
			vim.log.levels.ERROR
		)
		return
	end
	sub.run(o.bang)
end, {
	nargs = "?",
	bang = true,
	desc = "gh-actions-version: " .. "check | clear | approve | learn | fix | store",
	complete = function(arglead, cmdline)
		-- only complete the first argument
		if #vim.split(vim.trim(cmdline), "%s+") > 1 and cmdline:match("%s$") then
			return {}
		end
		local out = vim.tbl_keys(subcommands)
		table.sort(out)
		return vim.tbl_filter(function(n)
			return vim.startswith(n, arglead)
		end, out)
	end,
})
