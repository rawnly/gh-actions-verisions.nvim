local M = {}

--- In-memory cache: "repo@ref" -> resolved string
---@type table<string, string>
local cache = {}

--- Run a gh CLI command asynchronously
---@param args string[]
---@param callback fun(ok: boolean, output: string)
local function gh_async(args, callback)
	local stdout_chunks = {}
	local stderr_chunks = {}

	vim.system(
		vim.list_extend({ "gh" }, args),
		{ text = true },
		function(result)
			if result.code == 0 then
				callback(true, vim.trim(result.stdout or ""))
			else
				callback(false, vim.trim(result.stderr or ""))
			end
		end
	)
end

--- Resolve a SHA to its matching tag name via GitHub API.
--- Tries to find a tag whose commit SHA starts with the given ref.
---@param repo string e.g. "actions/checkout"
---@param sha string the commit SHA (or prefix)
---@param callback fun(tag: string|nil)
function M.get_tag_for_sha(repo, sha, callback)
	local key = repo .. "@" .. sha
	if cache[key] then
		callback(cache[key])
		return
	end

	gh_async({
		"api",
		"repos/" .. repo .. "/git/matching-refs/tags",
		"--paginate",
		"--jq",
		'.[] | select(.object.sha | startswith("' .. sha .. '")) | .ref',
	}, function(ok, output)
		if not ok or output == "" then
			-- Fallback: the tag might point to a tag object, not a commit directly.
			-- Try listing tags and matching via the commit they point to.
			gh_async({
				"api",
				"repos/" .. repo .. "/tags",
				"--paginate",
				"--jq",
				'.[] | select(.commit.sha | startswith("' .. sha .. '")) | .name',
			}, function(ok2, output2)
				if ok2 and output2 ~= "" then
					-- Pick the most specific (longest) tag
					local best = pick_best_tag(output2)
					cache[key] = best
					callback(best)
				else
					callback(nil)
				end
			end)
			return
		end

		-- refs come as "refs/tags/v1.2.3", extract tag names
		local tags = {}
		for line in output:gmatch("[^\n]+") do
			local tag = line:match("refs/tags/(.+)")
			if tag then
				table.insert(tags, tag)
			end
		end

		if #tags == 0 then
			callback(nil)
			return
		end

		local best = pick_best_tag(table.concat(tags, "\n"))
		cache[key] = best
		callback(best)
	end)
end

--- Given newline-separated tag names, pick the most specific version tag.
--- Prefers semver-like tags (v1.2.3 > v1.2 > v1).
---@param tag_list string newline-separated tag names
---@return string
function pick_best_tag(tag_list)
	local best = nil
	local best_parts = 0
	for tag in tag_list:gmatch("[^\n]+") do
		tag = vim.trim(tag)
		if tag ~= "" then
			-- Count version parts (dots + 1)
			local _, dots = tag:gsub("%.", "")
			local parts = dots + 1
			if parts > best_parts then
				best = tag
				best_parts = parts
			end
		end
	end
	return best or vim.trim(tag_list:match("[^\n]+") or tag_list)
end

--- Resolve a short version tag (e.g. v4) to the latest full version.
--- Uses GitHub's tags list to find the most recent matching tag.
---@param repo string
---@param ref string e.g. "v4"
---@param callback fun(version: string|nil)
function M.get_full_version(repo, ref, callback)
	local key = repo .. "@" .. ref
	if cache[key] then
		callback(cache[key])
		return
	end

	-- First resolve what commit this tag points to
	gh_async({
		"api",
		"repos/" .. repo .. "/git/ref/tags/" .. ref,
		"--jq",
		".object.sha",
	}, function(ok, sha)
		if not ok or sha == "" then
			callback(nil)
			return
		end

		-- The ref might point to a tag object (annotated tag).
		-- Dereference to get the commit SHA.
		gh_async({
			"api",
			"repos/" .. repo .. "/git/tags/" .. sha,
			"--jq",
			".object.sha",
		}, function(ok2, commit_sha)
			local target_sha = (ok2 and commit_sha ~= "") and commit_sha or sha

			-- Now find all tags pointing to this commit
			gh_async({
				"api",
				"repos/" .. repo .. "/tags",
				"--paginate",
				"--jq",
				'.[] | select(.commit.sha == "' .. target_sha .. '") | .name',
			}, function(ok3, output)
				if not ok3 or output == "" then
					callback(nil)
					return
				end

				-- Filter out the ref itself to show something useful
				local tags = {}
				for tag in output:gmatch("[^\n]+") do
					tag = vim.trim(tag)
					if tag ~= "" and tag ~= ref then
						table.insert(tags, tag)
					end
				end

				if #tags == 0 then
					callback(nil)
					return
				end

				local best = pick_best_tag(table.concat(tags, "\n"))
				cache[key] = best
				callback(best)
			end)
		end)
	end)
end

--- Resolve any ref (tag, branch, short sha) to a full commit SHA.
---@param repo string
---@param ref string
---@param callback fun(sha: string|nil)
function M.resolve_sha(repo, ref, callback)
	gh_async({ "api", "repos/" .. repo .. "/commits/" .. ref, "--jq", ".sha" }, function(ok, out)
		callback(ok and out:match("^%x+$") and out or nil)
	end)
end

---@alias GhActionsVersion.ShaStatus "valid"|"invalid"|"unknown"

---@type table<string, GhActionsVersion.ShaStatus>
local sha_cache = {}
---@type table<string, true>
local sha_inflight = {}

--- Cached result of a previous verification (nil if not checked yet).
---@param repo string
---@param sha string
---@return GhActionsVersion.ShaStatus?
function M.sha_status(repo, sha)
	return sha_cache[repo .. "@" .. sha]
end

--- Check that a commit exists in the repo. Only a 404/422 counts as "invalid";
--- auth/network failures are "unknown" and never reported. Results are cached.
---@param repo string
---@param sha string
---@param callback fun(status: GhActionsVersion.ShaStatus)
function M.verify_sha(repo, sha, callback)
	local key = repo .. "@" .. sha
	if sha_cache[key] then
		return callback(sha_cache[key])
	end
	if sha_inflight[key] then
		return
	end
	sha_inflight[key] = true
	gh_async({ "api", "repos/" .. repo .. "/commits/" .. sha, "--jq", ".sha" }, function(ok, out)
		sha_inflight[key] = nil
		local status = "unknown"
		if ok then
			status = "valid"
		elseif out:find("HTTP 404", 1, true) or out:find("HTTP 422", 1, true) then
			status = "invalid"
		end
		-- don't cache "unknown" so it is retried later
		if status ~= "unknown" then
			sha_cache[key] = status
		end
		callback(status)
	end)
end

--- Clear the cache
function M.clear_cache()
	cache = {}
	sha_cache = {}
end

return M
