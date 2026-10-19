--- Global store of org-approved pinned actions.
--- JSON shape: { version = 1, approved = { ["owner/repo"] = { [sha] = { tag = "v1.2.3" } } } }
local M = {}

---@type table<string, table<string, {tag?: string}>>
local data = {}
local loaded_mtime ---@type integer?

local function path()
	return require("gh-actions-version").config.store_path
end

local function mtime()
	local st = vim.uv.fs_stat(path())
	return st and st.mtime.sec * 1e9 + st.mtime.nsec or nil
end

local function load()
	local m = mtime()
	if loaded_mtime ~= nil and loaded_mtime == m then
		return
	end
	loaded_mtime = m
	data = {}
	local f = io.open(path(), "r")
	if not f then
		return
	end
	local s = f:read("*a")
	f:close()
	local ok, t = pcall(vim.json.decode, s)
	if ok and type(t) == "table" and type(t.approved) == "table" then
		data = t.approved
	end
end

local function save()
	vim.fn.mkdir(vim.fn.fnamemodify(path(), ":h"), "p")
	local payload = { version = 1, approved = data }
	local ok, s = pcall(vim.json.encode, payload, { indent = "  ", sort_keys = true })
	if not ok then
		s = vim.json.encode(payload)
	end
	local f = assert(io.open(path(), "w"))
	f:write(s, "\n")
	f:close()
	loaded_mtime = mtime()
end

---@return string
function M.path()
	return path()
end

---@param repo string
---@param sha string
---@return {tag?: string}?
function M.get(repo, sha)
	load()
	local r = data[repo:lower()]
	return r and r[sha:lower()] or nil
end

---@param repo string
---@param sha string
---@return boolean
function M.is_approved(repo, sha)
	return M.get(repo, sha) ~= nil
end

---@param repo string
---@return {sha: string, tag?: string}[]
function M.list(repo)
	load()
	local out = {}
	for sha, info in pairs(data[repo:lower()] or {}) do
		out[#out + 1] = { sha = sha, tag = info.tag }
	end
	table.sort(out, function(a, b)
		return (a.tag or "") > (b.tag or "")
	end)
	return out
end

--- Add one or more entries. Returns the number of newly added hashes.
---@param items {repo: string, sha: string, tag?: string}[]
---@return integer
function M.add(items)
	load()
	local added = 0
	for _, it in ipairs(items) do
		local repo, sha = it.repo:lower(), it.sha:lower()
		data[repo] = data[repo] or {}
		local cur = data[repo][sha]
		if not cur then
			data[repo][sha] = { tag = it.tag }
			added = added + 1
		elseif not cur.tag and it.tag then
			cur.tag = it.tag
			added = added + 1
		end
	end
	if added > 0 then
		save()
	end
	return added
end

return M
