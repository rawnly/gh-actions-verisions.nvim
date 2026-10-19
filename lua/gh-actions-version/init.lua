local api = require("gh-actions-version.api")
local parse = require("gh-actions-version.parse")
local store = require("gh-actions-version.store")
local lint = require("gh-actions-version.lint")

local M = {}

local ns = vim.api.nvim_create_namespace("gh-actions-version")

---@class GhActionsVersionConfig
---@field hl_group? string Highlight group for virtual text (default: "Comment")
---@field lint? boolean Publish diagnostics for unpinned / unapproved actions (default: true)
---@field store_path? string JSON file with approved `owner/repo@sha` entries
---@field trusted_orgs? string[] Owners whose actions are always allowed (any pinned SHA)
---@field trust_current_org? boolean Trust the owner of the current repo's `origin` remote (default: true)
---@field verify_sha? boolean Check via `gh` that pinned SHAs exist in their repo (default: true)
---@field auto_learn? boolean Approve every pinned SHA found in a workflow on save (default: false)

---@type GhActionsVersionConfig
local defaults = {
	hl_group = "Comment",
	lint = true,
	store_path = vim.fn.stdpath("data") .. "/gh-actions-version/approved.json",
	trusted_orgs = {},
	trust_current_org = true,
	verify_sha = true,
	auto_learn = false,
}

---@type GhActionsVersionConfig
M.config = vim.deepcopy(defaults)

---@param bufnr integer
---@return boolean
local function is_workflow_buf(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	return path:match("%.github/workflows/") ~= nil
		or path:match("%.github/actions/") ~= nil
		or path:match("/action%.ya?ml$") ~= nil
end

--- Render virtual text for resolved versions
local function render(bufnr, results)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	for _, r in ipairs(results) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, r.line, 0, {
			virt_text = { { r.text, M.config.hl_group } },
			virt_text_pos = "eol",
		})
	end
end

--- Resolve all actions in the buffer and show versions as virtual text
---@param bufnr? number
function M.resolve(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local actions = vim.tbl_filter(function(e)
		return parse.is_short_sha(e.ref) or parse.is_version_tag(e.ref)
	end, parse.buffer(bufnr))
	if #actions == 0 then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		return
	end

	local pending, virt = #actions, {}
	local function done(line, text)
		if text then
			virt[#virt + 1] = { line = line, text = " " .. text }
		end
		pending = pending - 1
		if pending == 0 then
			vim.schedule(function()
				render(bufnr, virt)
			end)
		end
	end

	for _, a in ipairs(actions) do
		local known = parse.is_full_sha(a.ref) and store.get(a.repo, a.ref) or nil
		if known and known.tag then
			done(a.line, known.tag)
		elseif parse.is_short_sha(a.ref) then
			api.get_tag_for_sha(a.repo, a.ref, function(tag)
				done(a.line, tag)
			end)
		else
			api.get_full_version(a.repo, a.ref, function(v)
				done(a.line, v)
			end)
		end
	end
end

--- Clear virtual text and diagnostics
---@param bufnr? number
function M.clear(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	lint.clear(bufnr)
end

function M.lint(bufnr)
	lint.run(bufnr)
end

---@param entries GhActionsVersion.Entry[]
---@return {repo: string, sha: string, tag?: string}[]
local function pinned(entries)
	local items = {}
	for _, e in ipairs(entries) do
		if parse.is_full_sha(e.ref) then
			items[#items + 1] = { repo = e.repo, sha = e.ref, tag = e.tag }
		end
	end
	return items
end

--- Approve the pinned action on the cursor line (or all in the buffer with `all`).
---@param opts? {all?: boolean, bufnr?: integer}
function M.approve(opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local entries = parse.buffer(bufnr)
	if not opts.all then
		local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
		entries = vim.tbl_filter(function(e)
			return e.line == lnum
		end, entries)
	end
	local items = pinned(entries)
	if #items == 0 then
		vim.notify("gh-actions-version: no pinned (40-char SHA) action found", vim.log.levels.WARN)
		return
	end
	local n = store.add(items)
	lint.run(bufnr)
	vim.notify(("gh-actions-version: approved %d new entr%s"):format(n, n == 1 and "y" or "ies"))
end

--- Approve all pinned actions found in this repo's workflows/actions.
---@param root? string
function M.learn(root)
	root = root or vim.fs.root(0, ".git") or vim.fn.getcwd()
	local files = vim.fn.globpath(root, ".github/workflows/*.y*ml", false, true)
	vim.list_extend(files, vim.fn.globpath(root, ".github/actions/**/*.y*ml", false, true))
	vim.list_extend(files, vim.fn.globpath(root, "action.y*ml", false, true))
	local items = {}
	for _, f in ipairs(files) do
		local ok, lines = pcall(vim.fn.readfile, f)
		if ok then
			vim.list_extend(items, pinned(parse.lines(lines)))
		end
	end
	local n = store.add(items)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and is_workflow_buf(b) then
			lint.run(b)
		end
	end
	vim.notify(("gh-actions-version: scanned %d files, approved %d new entries"):format(#files, n))
end

--- Replace the ref (and version comment) of an entry.
local function replace_ref(bufnr, e, sha, tag)
	local line = vim.api.nvim_buf_get_lines(bufnr, e.line, e.line + 1, false)[1]
	local quote = line:sub(e.ref_end + 1):match("^(['\"]?)") or ""
	local new = line:sub(1, e.ref_col) .. sha .. quote .. (tag and ("  # " .. tag) or "")
	vim.api.nvim_buf_set_lines(bufnr, e.line, e.line + 1, false, { new })
end

--- Fix the action on the cursor line: pick an approved SHA, or pin the current ref.
function M.fix()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
	local e = parse.parse_line(vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or "", lnum)
	if not e then
		vim.notify("gh-actions-version: no `uses:` on this line", vim.log.levels.WARN)
		return
	end

	local choices = {}
	for _, a in ipairs(store.list(e.repo)) do
		choices[#choices + 1] = { label = ("approved  %s  %s"):format(a.tag or "?", a.sha:sub(1, 12)), sha = a.sha, tag = a.tag }
	end
	if not parse.is_full_sha(e.ref) then
		choices[#choices + 1] = { label = ("pin `%s` from GitHub"):format(e.ref), resolve = true }
	end
	if #choices == 0 then
		vim.notify("gh-actions-version: nothing to suggest for " .. e.repo, vim.log.levels.INFO)
		return
	end

	vim.ui.select(choices, {
		prompt = e.repo,
		format_item = function(c)
			return c.label
		end,
	}, function(c)
		if not c then
			return
		end
		if c.resolve then
			api.resolve_sha(e.repo, e.ref, function(sha)
				vim.schedule(function()
					if not sha then
						return vim.notify("gh-actions-version: could not resolve " .. e.ref, vim.log.levels.ERROR)
					end
					replace_ref(bufnr, e, sha, e.ref)
					lint.run(bufnr)
				end)
			end)
		else
			replace_ref(bufnr, e, c.sha, c.tag)
			lint.run(bufnr)
		end
	end)
end

function M.open_store()
	vim.cmd.edit(vim.fn.fnameescape(store.path()))
end

---@param opts? GhActionsVersionConfig
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})
	lint.clear_org_cache()

	local group = vim.api.nvim_create_augroup("GhActionsVersion", { clear = true })

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		pattern = { "*.yml", "*.yaml" },
		callback = function(ev)
			if not is_workflow_buf(ev.buf) then
				return
			end
			if M.config.auto_learn and ev.event == "BufWritePost" then
				store.add(pinned(parse.buffer(ev.buf)))
			end
			if M.config.lint then
				lint.run(ev.buf)
			end
			M.resolve(ev.buf)
		end,
	})

	if M.config.lint then
		vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
			group = group,
			pattern = { "*.yml", "*.yaml" },
			callback = function(ev)
				if is_workflow_buf(ev.buf) then
					lint.run(ev.buf)
				end
			end,
		})
	end
end

return M
