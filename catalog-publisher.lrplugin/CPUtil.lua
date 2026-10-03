local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrTasks = import 'LrTasks'
local LrPrefs = import 'LrPrefs'

CPUtil = CPUtil or {}

local logger = LrLogger('CatalogPublisher')
logger:enable('logfile')

function CPUtil.log(...)
	local parts = {}
	for i = 1, select('#', ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	logger:info(table.concat(parts, ' '))
end

-- Path components must not contain separators; Lightroom names can.
function CPUtil.sanitize(name)
	name = tostring(name or ''):gsub('[/\\:]', '_')
	-- avoid trailing dots/spaces which are problematic on some filesystems
	name = name:gsub('%s+$', ''):gsub('%.+$', '')
	if name == '' then name = '_' end
	return name
end

-- rel is a '/'-separated relative path; joins onto root using native separators
function CPUtil.toAbsolute(root, rel)
	local path = root
	for part in tostring(rel):gmatch('[^/]+') do
		path = LrPathUtils.child(path, part)
	end
	return path
end

-- Read one plug-in setting from a settings table. Depending on where the
-- table came from, plug-in keys are either plain ('cp_rootDir') or prefixed
-- with the plug-in id ('com...catalogpublisher_cp_rootDir').
function CPUtil.setting(settings, key)
	if type(settings) ~= 'table' then return nil end
	local v = settings[key]
	if v == nil then
		v = settings[_PLUGIN.id .. '_' .. key]
	end
	return v
end

-- Normalize a publish-settings table: unwrap '< contents >' nesting and add
-- unprefixed aliases for '<pluginId>_'-prefixed keys.
function CPUtil.normalizeSettings(s)
	if type(s) ~= 'table' then return {} end
	if type(s['< contents >']) == 'table' then s = s['< contents >'] end
	local out = {}
	local prefix = _PLUGIN.id .. '_'
	for k, v in pairs(s) do
		out[k] = v
	end
	for k, v in pairs(s) do
		if type(k) == 'string' and k:sub(1, #prefix) == prefix then
			local short = k:sub(#prefix + 1)
			if out[short] == nil then out[short] = v end
		end
	end
	return out
end

-- True when the destination root is reachable (exists as a directory).
-- A NAS or external drive that is not mounted fails this check, and callers
-- skip all disk work until it comes back rather than erroring every poll.
function CPUtil.destinationAvailable(rootDir)
	if type(rootDir) ~= 'string' or rootDir == '' then return false end
	local ok, kind = LrTasks.pcall(function() return LrFileUtils.exists(rootDir) end)
	return ok and kind == 'directory'
end

-- Read publish settings for a service, normalized.
function CPUtil.serviceSettings(service)
	local ok, s = LrTasks.pcall(function() return service:getPublishSettings() end)
	if not ok then return {} end
	return CPUtil.normalizeSettings(s)
end

-- Delete now-empty directories from dir upward, stopping at (and never deleting) stopAt.
function CPUtil.pruneEmptyDirs(dir, stopAt)
	if type(dir) ~= 'string' or type(stopAt) ~= 'string' or stopAt == '' then return end
	while dir and #dir > #stopAt and dir:sub(1, #stopAt) == stopAt do
		if not LrFileUtils.exists(dir) then
			dir = LrPathUtils.parent(dir)
		else
			local hasEntry = false
			for entry in LrFileUtils.directoryEntries(dir) do
				if LrPathUtils.leafName(entry) ~= '.DS_Store' then
					hasEntry = true
					break
				end
			end
			if hasEntry then break end
			local ds = LrPathUtils.child(dir, '.DS_Store')
			if LrFileUtils.exists(ds) then LrFileUtils.delete(ds) end
			LrFileUtils.delete(dir)
			dir = LrPathUtils.parent(dir)
		end
	end
end

local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Remove a file or symlink at path. exists() follows symlinks, so a dangling
-- symlink reports as missing — fall back to rm -f for those.
function CPUtil.removeFileOrLink(path)
	if LrFileUtils.exists(path) then
		LrFileUtils.delete(path)
	elseif MAC_ENV then
		LrTasks.pcall(function() LrTasks.execute('/bin/rm -f ' .. shellQuote(path)) end)
	end
end

-- Delete a published file (by absolute path) and prune empty dirs up to root.
function CPUtil.deletePublishedFile(path, root)
	if type(path) ~= 'string' or path == '' then return end
	if type(root) ~= 'string' or root == '' then return end
	-- never touch files outside the destination root
	if path:sub(1, #root) ~= root then return end
	CPUtil.removeFileOrLink(path)
	CPUtil.pruneEmptyDirs(LrPathUtils.parent(path), root)
end

-- Exclusion patterns: one per line or comma-separated; '*' is a wildcard;
-- matching is case-insensitive against the mirror path with or without the
-- 'collections/'/'folders/' prefix, and a match on any ancestor path
-- excludes the whole subtree.
function CPUtil.parseExcludes(text)
	local pats = {}
	for line in tostring(text or ''):gmatch('[^\r\n,]+') do
		line = line:match('^%s*(.-)%s*$')
		if line ~= '' then pats[#pats + 1] = line:lower() end
	end
	return pats
end

-- Exclusions added via the menu commands live in plug-in preferences (the
-- SDK cannot write publish-service settings); they merge with the patterns
-- from the service settings' Exclude field.
function CPUtil.combinedExcludes(settingsText)
	local pats = CPUtil.parseExcludes(settingsText)
	local prefs = LrPrefs.prefsForPlugin()
	for _, p in ipairs(CPUtil.parseExcludes(prefs.cp_excludes)) do
		pats[#pats + 1] = p
	end
	return pats
end

local function globToPattern(glob)
	local p = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*')
	return '^' .. p .. '$'
end

function CPUtil.isExcluded(relPath, patterns)
	if not patterns or #patterns == 0 then return false end
	local function ancestors(path)
		local list, acc = {}, nil
		for part in path:gmatch('[^/]+') do
			acc = acc and (acc .. '/' .. part) or part
			list[#list + 1] = acc
		end
		return list
	end
	local lower = tostring(relPath):lower()
	local stripped = lower:gsub('^collections/', ''):gsub('^folders/', '')
	local full = ancestors(lower)
	local short = ancestors(stripped)
	for _, pat in ipairs(patterns) do
		-- a pattern naming a tree matches the full path; others match the
		-- path without the 'collections/'/'folders/' prefix
		local sided = pat:find('^collections/') or pat:find('^folders/')
		local lpat = globToPattern(pat)
		for _, c in ipairs(sided and full or short) do
			if c:find(lpat) then return true end
		end
	end
	return false
end

-- Source roots: absolute paths, one per line or comma-separated. Only photos
-- stored under one of them are published; an empty list means everything.
-- Matching is case-insensitive (macOS volumes usually are).
local function normalizePath(p)
	p = tostring(p or ''):gsub('\\', '/'):gsub('/+$', '')
	return p:lower()
end

function CPUtil.parseIncludes(text)
	local roots = {}
	for line in tostring(text or ''):gmatch('[^\r\n,]+') do
		line = line:match('^%s*(.-)%s*$')
		if line ~= '' then roots[#roots + 1] = normalizePath(line) end
	end
	return roots
end

-- True when path is one of the roots or inside one (or no roots are set).
function CPUtil.isIncluded(path, roots)
	if not roots or #roots == 0 then return true end
	if type(path) ~= 'string' then return false end
	local p = normalizePath(path)
	for _, r in ipairs(roots) do
		if p == r or p:sub(1, #r + 1) == r .. '/' then return true end
	end
	return false
end

-- True when some root lies below path, so its subfolders must be walked.
function CPUtil.containsIncluded(path, roots)
	if type(path) ~= 'string' then return false end
	local p = normalizePath(path) .. '/'
	for _, r in ipairs(roots or {}) do
		if r:sub(1, #p) == p then return true end
	end
	return false
end

-- Relative path from fromDir to toPath (both absolute, '/'-separated).
function CPUtil.relativePath(fromDir, toPath)
	local function split(p)
		local t = {}
		for part in tostring(p):gmatch('[^/]+') do t[#t + 1] = part end
		return t
	end
	local a, b = split(fromDir), split(toPath)
	local i = 1
	while a[i] and b[i] and a[i] == b[i] do i = i + 1 end
	local parts = {}
	for _ = i, #a do parts[#parts + 1] = '..' end
	for j = i, #b do parts[#parts + 1] = b[j] end
	return table.concat(parts, '/')
end

-- Create/replace a relative symlink at linkPath pointing to targetPath.
-- Must be called from an async task. Returns true on success. macOS only.
function CPUtil.makeSymlink(linkPath, targetPath)
	if not MAC_ENV then return false end
	local rel = CPUtil.relativePath(LrPathUtils.parent(linkPath), targetPath)
	local rc = LrTasks.execute('/bin/ln -sfn ' .. shellQuote(rel) .. ' ' .. shellQuote(linkPath))
	return rc == 0
end

-- On-disk relative path ('folders/...' or 'collections/...') for a mirrored
-- published collection: stored in its collection settings by CatalogSync,
-- with a tree-walk fallback. Must be called from an async task.
function CPUtil.relPathFor(pubCollection)
	local ok, info = LrTasks.pcall(function() return pubCollection:getCollectionInfoSummary() end)
	local cs = ok and info and info.collectionSettings or nil
	if cs and type(cs.relPath) == 'string' and cs.relPath ~= '' then
		return cs.relPath
	end
	local names = { pubCollection:getName() }
	local okP, parent = LrTasks.pcall(function() return pubCollection:getParent() end)
	parent = okP and parent or nil
	while parent do
		table.insert(names, 1, parent:getName())
		local okN, nextParent = LrTasks.pcall(function() return parent:getParent() end)
		parent = okN and nextParent or nil
	end
	if #names >= 2 and names[#names] == names[#names - 1] then
		table.remove(names) -- folder-with-subfolders duplication
	end
	names[1] = string.lower(names[1])
	for i = 1, #names do names[i] = CPUtil.sanitize(names[i]) end
	return table.concat(names, '/')
end

return CPUtil
