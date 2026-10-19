local M = {}

---@class GhActionsVersion.Entry
---@field line integer 0-based line
---@field repo string "owner/repo" (lowercased)
---@field owner string lowercased owner
---@field path string full action path as written (may include subpath)
---@field ref string
---@field tag? string version from trailing `# vX.Y.Z` comment
---@field ref_col integer 0-based start col of ref
---@field ref_end integer 0-based end col (exclusive) of ref

---@param ref string
---@return boolean
function M.is_full_sha(ref)
	return #ref == 40 and ref:match("^%x+$") ~= nil
end

---@param ref string
---@return boolean
function M.is_short_sha(ref)
	return #ref >= 7 and ref:match("^%x+$") ~= nil
end

---@param ref string
---@return boolean
function M.is_version_tag(ref)
	return ref:match("^v?%d+$") ~= nil or ref:match("^v?%d+%.%d+$") ~= nil
end

---@param line string
---@param lnum integer 0-based
---@return GhActionsVersion.Entry?
function M.parse_line(line, lnum)
	local spec, rest = line:match("^%s*%-?%s*uses:%s*(%S+)(.*)$")
	if not spec then
		return nil
	end
	spec = spec:gsub("^['\"]", ""):gsub("['\"]$", "")
	local path, ref = spec:match("^([^@]+)@(.+)$")
	if not path or path:match("^[%./]") or path:match("^docker://") then
		return nil
	end
	local owner, name = path:match("^([^/]+)/([^/]+)")
	if not owner then
		return nil
	end
	local comment = rest:match("#%s*(.-)%s*$")
	local tag = comment and comment:match("^(%S+)") or nil
	local s = line:find(path .. "@" .. ref, 1, true)
	if not s then
		return nil
	end
	local ref_col = s - 1 + #path + 1
	return {
		line = lnum,
		repo = (owner .. "/" .. name):lower(),
		owner = owner:lower(),
		path = path,
		ref = ref,
		tag = tag,
		ref_col = ref_col,
		ref_end = ref_col + #ref,
	}
end

---@param lines string[]
---@return GhActionsVersion.Entry[]
function M.lines(lines)
	local out = {}
	for i, line in ipairs(lines) do
		local e = M.parse_line(line, i - 1)
		if e then
			out[#out + 1] = e
		end
	end
	return out
end

---@param bufnr integer
---@return GhActionsVersion.Entry[]
function M.buffer(bufnr)
	return M.lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

return M
