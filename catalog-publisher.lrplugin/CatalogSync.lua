-- Mirrors the catalog's folder tree and collection tree into a Catalog Publisher
-- publish service, as two top-level published collection sets: 'Folders' and
-- 'Collections'. Each mirrored collection stores its on-disk relative path
-- ('folders/...' or 'collections/...') in its collection settings.

local LrApplication = import 'LrApplication'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

require 'CPUtil'

CatalogSync = CatalogSync or {}

local FOLDERS_TITLE = 'Folders'
local COLLECTIONS_TITLE = 'Collections'

local function keyFor(names)
	return table.concat(names, '\0')
end

local function copyAppend(t, v)
	local r = {}
	for i, x in ipairs(t) do r[i] = x end
	if v ~= nil then r[#r + 1] = v end
	return r
end

-- Add one entry per non-empty catalog collection, keyed by its names
-- (rootNames followed by the collection-set path and collection name).
local function addCollectionEntries(catalog, desired, excludes, rootNames)
	local function walkContainer(container, parentNames, parentRel)
		local okSets, sets = LrTasks.pcall(function() return container:getChildCollectionSets() end)
		if okSets and sets then
			for _, set in ipairs(sets) do
				local name = CPUtil.sanitize(set:getName())
				local rel = parentRel .. '/' .. name
				if not CPUtil.isExcluded(rel, excludes) then
					walkContainer(set, copyAppend(parentNames, name), rel)
				end
			end
		end
		local okColls, colls = LrTasks.pcall(function() return container:getChildCollections() end)
		if okColls and colls then
			for _, coll in ipairs(colls) do
				local name = CPUtil.sanitize(coll:getName())
				local rel = parentRel .. '/' .. name
				if not CPUtil.isExcluded(rel, excludes) then
					local okP, photos = LrTasks.pcall(function() return coll:getPhotos() end)
					if okP and photos and #photos > 0 then
						local names = copyAppend(parentNames, name)
						desired[keyFor(names)] = {
							names = names,
							relPath = rel,
							photos = photos,
						}
					end
				end
			end
		end
	end
	walkContainer(catalog, rootNames, 'collections')
end

-- Filter out videos (canExportVideo = false) and photos stored outside the
-- source roots, then drop entries that became empty.
local function filterEntries(catalog, desired, includes)
	local unique, uniqueList = {}, {}
	for _, entry in pairs(desired) do
		for _, p in ipairs(entry.photos) do
			local id = p.localIdentifier
			if id and not unique[id] then
				unique[id] = true
				uniqueList[#uniqueList + 1] = p
			end
		end
	end
	if #uniqueList > 0 then
		local ok, meta = LrTasks.pcall(function()
			return catalog:batchGetRawMetadata(uniqueList, { 'fileFormat', 'path' })
		end)
		if ok and meta then
			for _, entry in pairs(desired) do
				local filtered = {}
				for _, p in ipairs(entry.photos) do
					local m = meta[p]
					if not (m and m.fileFormat == 'VIDEO')
						and (#includes == 0 or (m and CPUtil.isIncluded(m.path, includes))) then
						filtered[#filtered + 1] = p
					end
				end
				entry.photos = filtered
			end
		end
	end

	for key, entry in pairs(desired) do
		if #entry.photos == 0 then desired[key] = nil end
	end
end

-- Build the desired mirror: { [key] = { names, relPath, photos } }
-- names includes the top-level set title ('Folders'/'Collections').
local function buildDesired(catalog, settings)
	local desired = {}
	local excludes = CPUtil.combinedExcludes(settings.cp_excludes)
	local includes = CPUtil.parseIncludes(settings.cp_includeRoots)

	if settings.cp_mirrorFolders ~= false then
		local function walkFolder(folder, parentNames, parentRel)
			local name = CPUtil.sanitize(folder:getName())
			local myNames = copyAppend(parentNames, name)
			local myRel = parentRel .. '/' .. name
			if CPUtil.isExcluded(myRel, excludes) then return end
			-- outside the source roots: only walk down towards a root below it
			local okPath, path = LrTasks.pcall(function() return folder:getPath() end)
			path = okPath and path or nil
			local inside = CPUtil.isIncluded(path, includes)
			if not inside and not CPUtil.containsIncluded(path, includes) then return end
			local photos
			if inside then
				local ok, p = LrTasks.pcall(function() return folder:getPhotos(false) end)
				photos = ok and p or nil
			end
			local ok2, children = LrTasks.pcall(function() return folder:getChildren() end)
			if not ok2 then children = nil end
			if photos and #photos > 0 then
				local collNames = myNames
				if children and #children > 0 then
					-- folder is both a set (for subfolders) and a collection (its own photos);
					-- the inner collection reuses the folder name, relPath stays the folder's path
					collNames = copyAppend(myNames, name)
				end
				desired[keyFor(collNames)] = { names = collNames, relPath = myRel, photos = photos }
			end
			if children then
				for _, child in ipairs(children) do
					walkFolder(child, myNames, myRel)
				end
			end
		end
		local ok, roots = LrTasks.pcall(function() return catalog:getFolders() end)
		if ok and roots then
			for _, root in ipairs(roots) do
				walkFolder(root, { FOLDERS_TITLE }, 'folders')
			end
		end
	end

	-- with Immich album sync, collections become albums instead of files
	local immichAlbums = settings.cp_immichAlbums and settings.cp_mirrorFolders ~= false
	if settings.cp_mirrorCollections ~= false and not immichAlbums then
		addCollectionEntries(catalog, desired, excludes, { COLLECTIONS_TITLE })
	end

	filterEntries(catalog, desired, includes)
	return desired
end

-- Desired Immich albums: the catalog's collections, filtered like the
-- collections/ mirror. Returns a list of { names, photos }, where names is
-- the collection path without the 'Collections' title.
function CatalogSync.albumEntries(settings)
	local catalog = LrApplication.activeCatalog()
	local desired = {}
	local excludes = CPUtil.combinedExcludes(settings.cp_excludes)
	addCollectionEntries(catalog, desired, excludes, {})
	filterEntries(catalog, desired, CPUtil.parseIncludes(settings.cp_includeRoots))
	local list = {}
	for _, entry in pairs(desired) do list[#list + 1] = entry end
	return list
end

-- Walk the publish service's existing tree: returns (collsByKey, setsByKey)
local function walkExisting(service)
	local colls, sets = {}, {}
	local function walkSet(set, parentNames)
		local names = copyAppend(parentNames, set:getName())
		sets[keyFor(names)] = { set = set, names = names }
		for _, c in ipairs(set:getChildCollections()) do
			local cNames = copyAppend(names, c:getName())
			colls[keyFor(cNames)] = { coll = c, names = cNames }
		end
		for _, s in ipairs(set:getChildCollectionSets()) do
			walkSet(s, names)
		end
	end
	for _, s in ipairs(service:getChildCollectionSets()) do
		walkSet(s, {})
	end
	for _, c in ipairs(service:getChildCollections()) do
		colls[keyFor({ c:getName() })] = { coll = c, names = { c:getName() } }
	end
	return colls, sets
end

local function idSet(photos)
	local s = {}
	for _, p in ipairs(photos) do
		if p.localIdentifier then s[p.localIdentifier] = p end
	end
	return s
end

-- Synchronize one publish service with the catalog. Must be called from an
-- async task. Returns a human-readable summary string.
function CatalogSync.sync(service, settings)
	local catalog = LrApplication.activeCatalog()
	settings = settings or CPUtil.serviceSettings(service)
	local rootDir = settings.cp_rootDir

	local desired = buildDesired(catalog, settings)
	local existingColls, existingSets = walkExisting(service)

	-- set chains needed by desired entries
	local neededSets = {}
	for _, entry in pairs(desired) do
		local chain = {}
		for i = 1, #entry.names - 1 do
			chain[#chain + 1] = entry.names[i]
			neededSets[keyFor(chain)] = copyAppend(chain)
		end
	end

	-- plan membership changes (read-only pass)
	local plans = {} -- { entry=, existing=coll or nil, toAdd={}, toRemove={}, needSettings=bool }
	local counts = { newColls = 0, addPhotos = 0, removePhotos = 0, delColls = 0, delSets = 0 }

	for key, entry in pairs(desired) do
		local ex = existingColls[key]
		local plan = { entry = entry, existing = ex and ex.coll or nil, toAdd = {}, toRemove = {}, needSettings = false }
		if ex then
			local okCur, current = LrTasks.pcall(function() return ex.coll:getPhotos() end)
			current = okCur and current or {}
			local wantIds = idSet(entry.photos)
			local haveIds = idSet(current)
			for id, p in pairs(wantIds) do
				if not haveIds[id] then plan.toAdd[#plan.toAdd + 1] = p end
			end
			for id, p in pairs(haveIds) do
				if not wantIds[id] then plan.toRemove[#plan.toRemove + 1] = p end
			end
			local okInfo, info = LrTasks.pcall(function() return ex.coll:getCollectionInfoSummary() end)
			local cs = okInfo and info and info.collectionSettings or nil
			if not (cs and cs.relPath == entry.relPath) then plan.needSettings = true end
		else
			plan.toAdd = entry.photos
			plan.needSettings = true
			counts.newColls = counts.newColls + 1
		end
		counts.addPhotos = counts.addPhotos + #plan.toAdd
		counts.removePhotos = counts.removePhotos + #plan.toRemove
		if #plan.toAdd > 0 or #plan.toRemove > 0 or plan.needSettings or not ex then
			plans[#plans + 1] = plan
		end
	end

	-- stale collections: exist in service but no longer in the catalog mirror
	local staleColls, staleFilePaths = {}, {}
	for key, ex in pairs(existingColls) do
		if not desired[key] then
			staleColls[#staleColls + 1] = ex.coll
			local okPP, pubPhotos = LrTasks.pcall(function() return ex.coll:getPublishedPhotos() end)
			if okPP and pubPhotos then
				for _, pp in ipairs(pubPhotos) do
					local okId, remoteId = LrTasks.pcall(function() return pp:getRemoteId() end)
					if okId and type(remoteId) == 'string' then
						staleFilePaths[#staleFilePaths + 1] = remoteId
					end
				end
			end
		end
	end
	counts.delColls = #staleColls

	-- stale sets: not needed by any desired entry; delete deepest-first
	local staleSets = {}
	for key, ex in pairs(existingSets) do
		if not neededSets[key] then
			staleSets[#staleSets + 1] = ex
		end
	end
	table.sort(staleSets, function(a, b) return #a.names > #b.names end)
	counts.delSets = #staleSets

	local anyChanges = #plans > 0 or #staleColls > 0 or #staleSets > 0
	if anyChanges then
		local sortedSetKeys = {}
		for key in pairs(neededSets) do sortedSetKeys[#sortedSetKeys + 1] = key end
		table.sort(sortedSetKeys, function(a, b)
			return #neededSets[a] < #neededSets[b]
		end)

		local ok, err = LrTasks.pcall(function()
			catalog:withWriteAccessDo('Catalog Publisher Sync', function()
				-- ensure set chains
				local setByKey = {}
				for k, ex in pairs(existingSets) do setByKey[k] = ex.set end
				for _, key in ipairs(sortedSetKeys) do
					if not setByKey[key] then
						local names = neededSets[key]
						local parent = nil
						if #names > 1 then
							parent = setByKey[keyFor(copyAppend({ unpack(names, 1, #names - 1) }))]
						end
						setByKey[key] = service:createPublishedCollectionSet(names[#names], parent, true)
					end
				end

				-- create/update collections
				for _, plan in ipairs(plans) do
					local coll = plan.existing
					if not coll then
						local names = plan.entry.names
						local parent = nil
						if #names > 1 then
							parent = setByKey[keyFor(copyAppend({ unpack(names, 1, #names - 1) }))]
						end
						coll = service:createPublishedCollection(names[#names], parent, true)
					end
					if coll then
						if plan.needSettings then
							coll:setCollectionSettings { relPath = plan.entry.relPath }
						end
						if #plan.toAdd > 0 then coll:addPhotos(plan.toAdd) end
						if #plan.toRemove > 0 then coll:removePhotos(plan.toRemove) end
					end
				end

				-- delete stale collections, then stale sets (deepest first)
				for _, coll in ipairs(staleColls) do
					LrTasks.pcall(function() coll:delete() end)
				end
				for _, ex in ipairs(staleSets) do
					LrTasks.pcall(function() ex.set:delete() end)
				end
			end, { timeout = 10 })
		end)
		if not ok then
			CPUtil.log('sync: write access failed:', err)
			return 'Sync failed: ' .. tostring(err)
		end

		-- remove files of deleted collections from disk (outside the write gate)
		if CPUtil.destinationAvailable(rootDir) then
			for _, path in ipairs(staleFilePaths) do
				LrTasks.pcall(function() CPUtil.deletePublishedFile(path, rootDir) end)
			end
		end
	end

	-- Self-heal (symlink mode): a folder rename moves the folders/ files,
	-- leaving collections/ symlinks dangling. Mark any published photo whose
	-- on-disk file is gone as edited so it republishes and re-links. Uses
	-- private write access, so this never creates an Undo entry.
	-- Only when the destination is reachable: with an unmounted NAS every
	-- file looks missing and the whole mirror would be re-marked.
	if (settings.cp_symlinkCollections or settings.cp_soocPassthrough)
		and CPUtil.destinationAvailable(rootDir) then
		local toMark = {}
		for key, ex in pairs(existingColls) do
			if desired[key] then
				LrTasks.pcall(function()
					for _, pp in ipairs(ex.coll:getPublishedPhotos() or {}) do
						local okId, rid = LrTasks.pcall(function() return pp:getRemoteId() end)
						if okId and type(rid) == 'string' and rid ~= ''
							and rid:sub(1, #rootDir) == rootDir
							and not LrFileUtils.exists(rid)
							and not pp:getEditedFlag() then
							toMark[#toMark + 1] = pp
						end
					end
				end)
			end
		end
		if #toMark > 0 then
			CPUtil.log('self-heal: re-marking', #toMark, 'photo(s) with missing files')
			LrTasks.pcall(function()
				catalog:withPrivateWriteAccessDo(function()
					for _, pp in ipairs(toMark) do
						LrTasks.pcall(function() pp:setEditedFlag(true) end)
					end
				end, { timeout = 10 })
			end)
		end
	end

	local summary = string.format(
		'%d new collections, +%d/-%d photos, removed %d collections and %d sets',
		counts.newColls, counts.addPhotos, counts.removePhotos, counts.delColls, counts.delSets)
	if anyChanges then
		CPUtil.log('sync [' .. service:getName() .. ']:', summary)
	end
	return summary
end

return CatalogSync
