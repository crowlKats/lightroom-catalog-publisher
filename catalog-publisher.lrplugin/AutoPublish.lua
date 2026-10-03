-- Background engine: periodically syncs the mirror and publishes pending
-- changes, debounced so publishing only happens after a full interval with no
-- further edits.

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrDate = import 'LrDate'

require 'CPUtil'
require 'CatalogSync'
require 'Immich'

AutoPublish = AutoPublish or {}

local state = AutoPublish._state or {
	running = false,   -- background loop started
	busy = false,      -- a cycle (or manual action) is in progress
	lastSig = {},      -- serviceId -> pending signature from previous poll
	unstable = {},     -- serviceId -> consecutive polls with a changing signature
}
AutoPublish._state = state

local MIN_INTERVAL = 15
local DEFAULT_INTERVAL = 60
local MAX_UNSTABLE_POLLS = 10 -- publish anyway after this many changing polls

local function ourServices()
	local catalog = LrApplication.activeCatalog()
	local ok, services = LrTasks.pcall(function()
		return catalog:getPublishServices(_PLUGIN.id)
	end)
	if ok and services and #services > 0 then return services end
	if not ok then
		CPUtil.log('getPublishServices(pluginId) failed:', tostring(services))
	end
	-- fallback: the filtered query can come up empty (e.g. right after a
	-- plug-in reload); enumerate all services and match by plugin id
	local result = {}
	local ok2, all = LrTasks.pcall(function() return catalog:getPublishServices() end)
	if ok2 and all then
		for _, s in ipairs(all) do
			local okId, pid = LrTasks.pcall(function() return s:getPluginId() end)
			if okId and pid == _PLUGIN.id then result[#result + 1] = s end
		end
		if #result == 0 and not state.diagLogged then
			state.diagLogged = true
			local descr = {}
			for _, s in ipairs(all) do
				LrTasks.pcall(function()
					descr[#descr + 1] = s:getName() .. ' (' .. tostring(s:getPluginId()) .. ')'
				end)
			end
			CPUtil.log('no services match plugin id', tostring(_PLUGIN and _PLUGIN.id),
				'; services in catalog:', #all == 0 and 'none' or table.concat(descr, ', '))
		end
	end
	return result
end

-- Collect collections with pending work and a signature of that pending state.
-- The signature includes each pending photo's lastEditTime so that ongoing
-- editing keeps changing the signature (which defers publishing).
local function collectPending(service)
	local pendingCollections = {}
	local sigParts = {}

	local function visitCollection(coll)
		LrTasks.pcall(function()
			local pubPhotos = coll:getPublishedPhotos() or {}
			local photos = coll:getPhotos() or {}
			local inColl = {}
			for _, p in ipairs(photos) do
				if p.localIdentifier then inColl[p.localIdentifier] = p end
			end
			local seen = {}
			local tokens = {}
			for _, pp in ipairs(pubPhotos) do
				local okP, photo = LrTasks.pcall(function() return pp:getPhoto() end)
				local id = okP and photo and photo.localIdentifier or nil
				if id then
					seen[id] = true
					if not inColl[id] then
						tokens[#tokens + 1] = 'd' .. id
					elseif pp:getEditedFlag() then
						local okT, t = LrTasks.pcall(function() return photo:getRawMetadata('lastEditTime') end)
						tokens[#tokens + 1] = 'e' .. id .. '@' .. tostring(okT and t or 0)
					end
				else
					-- photo gone from catalog but published entry remains
					tokens[#tokens + 1] = 'x' .. tostring(pp:getRemoteId())
				end
			end
			for id, photo in pairs(inColl) do
				if not seen[id] then
					local okT, t = LrTasks.pcall(function() return photo:getRawMetadata('lastEditTime') end)
					tokens[#tokens + 1] = 'n' .. id .. '@' .. tostring(okT and t or 0)
				end
			end
			if #tokens > 0 then
				table.sort(tokens)
				pendingCollections[#pendingCollections + 1] = coll
				sigParts[#sigParts + 1] = tostring(coll.localIdentifier) .. '=' .. table.concat(tokens, ',')
			end
		end)
	end

	local function visitSet(set)
		for _, c in ipairs(set:getChildCollections()) do visitCollection(c) end
		for _, s in ipairs(set:getChildCollectionSets()) do visitSet(s) end
	end

	LrTasks.pcall(function()
		for _, c in ipairs(service:getChildCollections()) do visitCollection(c) end
		for _, s in ipairs(service:getChildCollectionSets()) do visitSet(s) end
	end)

	table.sort(sigParts)
	return pendingCollections, table.concat(sigParts, ';')
end

local function publishCollections(collections)
	-- folders/ collections first: in symlink mode the collections/ side
	-- links to the folders/ copies, so those files must be written first
	local keyed = {}
	for _, coll in ipairs(collections) do
		local ok, rp = LrTasks.pcall(function() return CPUtil.relPathFor(coll) end)
		rp = ok and type(rp) == 'string' and rp or ''
		keyed[#keyed + 1] = { coll = coll, rp = rp, foldersSide = rp:sub(1, 8) == 'folders/' }
	end
	table.sort(keyed, function(a, b)
		if a.foldersSide ~= b.foldersSide then return a.foldersSide end
		return a.rp < b.rp
	end)
	collections = {}
	for i, k in ipairs(keyed) do collections[i] = k.coll end

	local published = 0
	for _, coll in ipairs(collections) do
		local done = false
		local ok = LrTasks.pcall(function()
			coll:publishNow(function() done = true end)
		end)
		if ok then
			local waited = 0
			while not done and waited < 900 do
				LrTasks.sleep(1)
				waited = waited + 1
			end
			published = published + 1
		end
	end
	return published
end

-- One pass over all services. force=true skips the debounce.
-- Returns a summary string.
function AutoPublish.cycle(force)
	if state.busy then return 'busy' end
	state.busy = true
	local summary = {}
	local ok, err = LrTasks.pcall(function()
		for _, service in ipairs(ourServices()) do
			local settings = CPUtil.serviceSettings(service)
			local rootDir = settings.cp_rootDir
			local sid = tostring(service.localIdentifier)
			if type(rootDir) == 'string' and rootDir ~= '' then
				if not force and settings.cp_autoPublish == false then
					summary[#summary + 1] = service:getName() .. ': auto-publish off'
				elseif not CPUtil.destinationAvailable(rootDir) then
					-- NAS / external drive not mounted: touch nothing (no sync,
					-- no publish, no self-heal) until it comes back
					state.lastSig[sid] = nil
					state.unstable[sid] = 0
					summary[#summary + 1] = service:getName()
						.. ': destination not available (not mounted?), skipping: ' .. rootDir
				else
					LrTasks.pcall(function() CatalogSync.sync(service, settings) end)
					local pending, sig = collectPending(service)
					if #pending == 0 then
						state.lastSig[sid] = ''
						state.unstable[sid] = 0
						summary[#summary + 1] = service:getName() .. ': up to date'
					else
						local stable = (sig == state.lastSig[sid])
						if not stable then
							state.unstable[sid] = (state.unstable[sid] or 0) + 1
						end
						if force or stable or (state.unstable[sid] or 0) >= MAX_UNSTABLE_POLLS then
							local n = publishCollections(pending)
							state.lastSig[sid] = nil
							state.unstable[sid] = 0
							summary[#summary + 1] = string.format(
								'%s: published %d collection(s)', service:getName(), n)
						else
							state.lastSig[sid] = sig
							summary[#summary + 1] = service:getName() .. ': changes detected, waiting for edits to settle'
						end
					end
					-- after publishing, so new folders/ files are on disk
					local okI, immich = LrTasks.pcall(function() return Immich.sync(service, settings, force) end)
					if okI and immich then
						summary[#summary + 1] = service:getName() .. ': ' .. immich
					elseif not okI then
						CPUtil.log('Immich sync error:', tostring(immich))
					end
				end
			else
				-- log the settings keys once so a settings-nesting problem is visible
				state.warnedNoRoot = state.warnedNoRoot or {}
				if not state.warnedNoRoot[sid] then
					state.warnedNoRoot[sid] = true
					local keys = {}
					for k in pairs(settings) do keys[#keys + 1] = tostring(k) end
					table.sort(keys)
					CPUtil.log('service', service:getName(),
						'has no cp_rootDir; settings keys:', table.concat(keys, ', '))
				end
				summary[#summary + 1] = service:getName() .. ': no destination folder configured'
			end
		end
	end)
	state.busy = false
	if not ok then
		CPUtil.log('cycle error:', err)
		return 'Error: ' .. tostring(err)
	end
	if #summary == 0 then
		return 'No Catalog Publisher publish service found. Create one in the Publish Services panel.'
	end
	return table.concat(summary, '\n')
end

-- Sync structure only (no publishing) for all services; returns summary.
function AutoPublish.syncAllNow()
	if state.busy then return 'A publish/sync cycle is already running; try again shortly.' end
	state.busy = true
	local lines = {}
	local ok, err = LrTasks.pcall(function()
		local services = ourServices()
		if #services == 0 then
			lines[#lines + 1] = 'No Catalog Publisher publish service found. Create one in the Publish Services panel.'
		end
		for _, service in ipairs(services) do
			local rootDir = CPUtil.serviceSettings(service).cp_rootDir
			if type(rootDir) == 'string' and rootDir ~= ''
				and not CPUtil.destinationAvailable(rootDir) then
				lines[#lines + 1] = service:getName()
					.. ': destination not available (not mounted?): ' .. rootDir
			else
				local settings = CPUtil.serviceSettings(service)
				local s = CatalogSync.sync(service, settings)
				lines[#lines + 1] = service:getName() .. ': ' .. s
				local okI, immich = LrTasks.pcall(function() return Immich.sync(service, settings, true) end)
				if okI and immich then
					lines[#lines + 1] = service:getName() .. ': ' .. immich
				elseif not okI then
					lines[#lines + 1] = service:getName() .. ': Immich sync error: ' .. tostring(immich)
				end
			end
		end
	end)
	state.busy = false
	if not ok then return 'Sync failed: ' .. tostring(err) end
	return table.concat(lines, '\n')
end

local function currentInterval()
	local interval = nil
	for _, service in ipairs(ourServices()) do
		local settings = CPUtil.serviceSettings(service)
		local v = tonumber(settings.cp_interval)
		if v then
			interval = interval and math.min(interval, v) or v
		end
	end
	interval = interval or DEFAULT_INTERVAL
	if interval < MIN_INTERVAL then interval = MIN_INTERVAL end
	return interval
end

-- Each start() claims the loop by writing a fresh token to a temp file; a
-- loop from before a plug-in reload sees the token change and exits, so
-- reloads never stack multiple loops.
local tokenPath = LrPathUtils.child(
	LrPathUtils.getStandardFilePath('temp'), 'catalogpublisher-loop-token.txt')

local function readToken()
	local ok, data = LrTasks.pcall(function() return LrFileUtils.readFile(tokenPath) end)
	return ok and data or nil
end

function AutoPublish.start()
	if state.running then return end
	state.running = true
	local myToken = tostring(LrDate.currentTime()) .. '-' .. tostring(math.random(1000000000))
	LrTasks.pcall(function()
		local f = io.open(tokenPath, 'w')
		if f then f:write(myToken) f:close() end
	end)
	LrTasks.startAsyncTask(function()
		LrTasks.sleep(20) -- let Lightroom finish opening the catalog
		CPUtil.log('auto-publish loop started')
		local lastLogged = nil
		while true do
			local current = readToken()
			if current ~= nil and current ~= myToken then
				CPUtil.log('auto-publish loop superseded (plug-in reloaded); exiting')
				return
			end
			local ok, result = LrTasks.pcall(function() return AutoPublish.cycle(false) end)
			local line = ok and tostring(result) or ('cycle failed: ' .. tostring(result))
			if line ~= lastLogged then -- log state changes, not every quiet poll
				CPUtil.log('cycle:', (line:gsub('\n', ' | ')))
				lastLogged = line
			end
			LrTasks.sleep(currentInterval())
		end
	end)
end

return AutoPublish
