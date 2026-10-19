local parse = require("gh-actions-version.parse")
local store = require("gh-actions-version.store")
local api = require("gh-actions-version.api")

local M = {}

M.ns = vim.api.nvim_create_namespace("gh-actions-version-lint")

---@type table<string, string|false>
local org_cache = {}

--- Owner of the git `origin` remote for the directory containing the buffer.
---@param bufnr integer
---@return string?
local function current_org(bufnr)
	local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))
	if not dir or dir == "" then
		return nil
	end
	local root = vim.fs.root(dir, ".git")
	if not root then
		return nil
	end
	if org_cache[root] == nil then
		local res = vim.system({ "git", "-C", root, "remote", "get-url", "origin" }, { text = true }):wait()
		local owner = res.code == 0 and res.stdout:match("github%.com[:/]([^/%s]+)/") or nil
		org_cache[root] = owner and owner:lower() or false
	end
	return org_cache[root] or nil
end

---@param bufnr integer
---@return table<string, true>
function M.trusted_owners(bufnr)
	local cfg = require("gh-actions-version").config
	local set = {}
	for _, o in ipairs(cfg.trusted_orgs) do
		set[o:lower()] = true
	end
	if cfg.trust_current_org then
		local org = current_org(bufnr)
		if org then
			set[org] = true
		end
	end
	return set
end

function M.clear_org_cache()
	org_cache = {}
end

---@param bufnr? integer
function M.run(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local trusted = M.trusted_owners(bufnr)
	local diags = {}

	for _, e in ipairs(parse.buffer(bufnr)) do
		local function add(sev, msg, code)
			diags[#diags + 1] = {
				lnum = e.line,
				col = e.ref_col,
				end_lnum = e.line,
				end_col = e.ref_end,
				severity = sev,
				source = "gh-actions-version",
				code = code,
				message = msg,
			}
		end

		-- Only pinned refs are linted; unpinned ones are left to actionlint / the LSPs.
		if parse.is_full_sha(e.ref) then
			local status = require("gh-actions-version").config.verify_sha and api.sha_status(e.repo, e.ref) or nil
			if status == nil and require("gh-actions-version").config.verify_sha then
				api.verify_sha(e.repo, e.ref, function(st)
					if st == "invalid" then
						vim.schedule(function()
							M.run(bufnr)
						end)
					end
				end)
			end

			if status == "invalid" then
				add(
					vim.diagnostic.severity.WARN,
					("commit %s not found in %s"):format(e.ref:sub(1, 7), e.repo),
					"invalid-sha"
				)
			elseif not trusted[e.owner] then
				local info = store.get(e.repo, e.ref)
				if not info then
					add(vim.diagnostic.severity.ERROR, ("%s@%s is not an org-approved commit"):format(e.repo, e.ref:sub(1, 7)), "unapproved")
				elseif info.tag and e.tag and info.tag ~= e.tag then
					add(
						vim.diagnostic.severity.WARN,
						("comment says %s but approved tag for this SHA is %s"):format(e.tag, info.tag),
						"tag-mismatch"
					)
				end
			end
		end
	end

	vim.diagnostic.set(M.ns, bufnr, diags)
end

---@param bufnr? integer
function M.clear(bufnr)
	vim.diagnostic.reset(M.ns, bufnr or vim.api.nvim_get_current_buf())
end

return M
