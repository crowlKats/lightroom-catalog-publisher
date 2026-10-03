-- Immich album sync: every catalog collection becomes an Immich album holding
-- the photos' folders/ copies, which Immich reads as an external library.
-- Immich identifies those assets by path, so a re-publish (same path) keeps
-- the asset and everything attached to it.
--
-- Albums the plug-in creates carry MARKER as their description. Only those
-- are ever deleted, and only once no assets from outside the mirror remain.
-- An existing album with a collection's name is adopted, never deleted.
-- Assets from outside the mirror are never removed from any album.

local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrDate = import 'LrDate'

require 'CPUtil'
require 'CPJson'
require 'CatalogSync'

Immich = Immich or {}

local MARKER = 'Synced from Lightroom by Catalog Publisher'
local ALBUM_SEPARATOR = ' / '
local PAGE_SIZE = 1000
local CHUNK = 500
local RETRY_SECONDS = 120     -- re-check unresolved photos this often
local SCAN_SECONDS = 300      -- trigger a library scan at most this often
local MAX_RETRIES = 5         -- then accept photos Immich doesn't have

local state = Immich._state or {
	lastSig = {},      -- serviceId -> signature of the last fully synced state
	albumSigs = {},    -- serviceId -> { albumName = signature }
	pending = {},      -- serviceId -> { sig, summary, retryAt, attempts }
	lastScan = {},     -- serviceId -> time of the last library scan request
	scanDenied = false,
	lastError = nil,
}
Immich._state = state

local function trimSlash(p)
	return (tostring(p or ''):gsub('/+$', ''))
end

-- Connection settings for a service, or nil (and a reason) when off/incomplete.
function Immich.config(settings)
	if not CPUtil.setting(settings, 'cp_immichAlbums') then return nil, 'off' end
	if CPUtil.setting(settings, 'cp_mirrorFolders') == false then return nil, 'nofolders' end
	local url = trimSlash(CPUtil.setting(settings, 'cp_immichUrl')):gsub('/api$', '')
	local key = tostring(CPUtil.setting(settings, 'cp_immichApiKey') or ''):match('^%s*(.-)%s*$')
	local rootDir = trimSlash(CPUtil.setting(settings, 'cp_rootDir'))
	local immichRoot = trimSlash(CPUtil.setting(settings, 'cp_immichRoot'))
	if immichRoot == '' then immichRoot = rootDir end
	if url == '' or key == '' or rootDir == '' then return nil, 'incomplete' end
	return {
		url = url,
		key = key,
		rootDir = rootDir,
		immichRoot = immichRoot,
		foldersPrefix = immichRoot .. '/folders/',
	}
end

-- One API call. Returns (status, decodedBody); status is nil when the
-- server could not be reached, with an error message as second value.
local function request(cfg, method, path, body)
	local url = cfg.url .. '/api' .. path
	local headers = {
		{ field = 'x-api-key', value = cfg.key },
		{ field = 'Accept', value = 'application/json' },
		{ field = 'Content-Type', value = body and 'application/json' or 'skip' },
	}
	local resBody, resHeaders
	if method == 'GET' then
		resBody, resHeaders = LrHttp.get(url, headers, 30)
	else
		resBody, resHeaders = LrHttp.post(url, body and CPJson.encode(body) or '', headers, method, 30)
	end
	local status = resHeaders and tonumber(resHeaders.status)
	if not status then
		local err = resHeaders and resHeaders.error
		local msg = type(err) == 'table' and (err.name or err.nativeCode) or err
		return nil, 'cannot reach ' .. cfg.url .. (msg and (' (' .. tostring(msg) .. ')') or '')
	end
	local decoded = nil
	if type(resBody) == 'string' and resBody ~= '' then
		local ok, v = pcall(CPJson.decode, resBody)
		if ok then decoded = v end
	end
	return status, decoded
end

-- Like request(), but raises on anything other than a 2xx response.
local function call(cfg, method, path, body)
	local status, res = request(cfg, method, path, body)
	if not status then error(res, 0) end
	if status < 200 or status >= 300 then
		local msg = type(res) == 'table' and res.message or nil
		if type(msg) == 'table' then msg = table.concat(msg, '; ') end
		error(string.format('%s %s: HTTP %d%s', method, path, status,
			msg and (' ' .. tostring(msg)) or ''), 0)
	end
	return res
end

-- All assets matching a metadata search, following pagination. Sends the
-- pre-3.2 'page' field, then switches to 'cursor' if the server returns one.
local function searchAll(cfg, query)
	local items = {}
	query.size = PAGE_SIZE
	query.page = 1
	for _ = 1, 10000 do
		local res = call(cfg, 'POST', '/search/metadata', query)
		local assets = type(res) == 'table' and res.assets or nil
		if type(assets) ~= 'table' then break end
		for _, a in ipairs(assets.items or {}) do items[#items + 1] = a end
		if type(assets.nextCursor) == 'string' and assets.nextCursor ~= '' then
			query.page = nil
			query.cursor = assets.nextCursor
		elseif assets.nextPage ~= nil and tonumber(assets.nextPage) then
			query.page = tonumber(assets.nextPage)
		else
			break
		end
	end
	return items
end

-- Immich asset id by originalPath, for every asset under the folders/ mirror.
-- The path filter is a case-insensitive substring match on the server, so
-- results are narrowed to exact prefix matches here.
local function mirrorIndex(cfg)
	local index = {}
	for _, a in ipairs(searchAll(cfg, { originalPath = cfg.foldersPrefix })) do
		local p = a.originalPath
		if type(p) == 'string' and type(a.id) == 'string'
			and p:sub(1, #cfg.foldersPrefix) == cfg.foldersPrefix then
			index[p] = a.id
		end
	end
	return index
end

local function albumAssets(cfg, albumId)
	return searchAll(cfg, { albumIds = { albumId } })
end

local function inChunks(ids, fn)
	for i = 1, #ids, CHUNK do
		local chunk = {}
		for j = i, math.min(i + CHUNK - 1, #ids) do chunk[#chunk + 1] = ids[j] end
		fn(chunk)
	end
end

-- photo localIdentifier -> path of its folders/ copy, from this service's
-- published folder collections
local function folderCopies(service)
	local map = {}
	local function visitCollection(coll)
		LrTasks.pcall(function()
			local rp = CPUtil.relPathFor(coll)
			if type(rp) ~= 'string' or rp:sub(1, 8) ~= 'folders/' then return end
			for _, pp in ipairs(coll:getPublishedPhotos() or {}) do
				LrTasks.pcall(function()
					local rid = pp:getRemoteId()
					local photo = pp:getPhoto()
					if type(rid) == 'string' and rid ~= '' and photo and photo.localIdentifier then
						map[photo.localIdentifier] = rid
					end
				end)
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
	return map
end

-- Ask Immich to rescan the external library holding the mirror. Needs an
-- admin API key; without one, Immich's own scheduled scan picks files up.
local function requestScan(cfg, sid)
	if state.scanDenied then return end
	local now = LrDate.currentTime()
	if state.lastScan[sid] and now - state.lastScan[sid] < SCAN_SECONDS then return end
	state.lastScan[sid] = now
	local status, libs = request(cfg, 'GET', '/libraries')
	if status == 401 or status == 403 then
		state.scanDenied = true
		CPUtil.log('Immich: API key cannot list libraries (admin only);'
			.. ' new photos appear after Immich\'s own library scan')
		return
	end
	if status ~= 200 or type(libs) ~= 'table' then return end
	for _, lib in ipairs(libs) do
		for _, importPath in ipairs(lib.importPaths or {}) do
			local ip = trimSlash(importPath) .. '/'
			if cfg.foldersPrefix:sub(1, #ip) == ip then
				local s = request(cfg, 'POST', '/libraries/' .. lib.id .. '/scan')
				CPUtil.log('Immich: requested scan of library', tostring(lib.name), '->', tostring(s))
				break
			end
		end
	end
end

-- Desired albums: { [albumName] = sorted list of Immich paths }
local function desiredAlbums(service, settings, cfg)
	local copies = folderCopies(service)
	local albums = {}
	for _, entry in ipairs(CatalogSync.albumEntries(settings)) do
		local seen, paths = {}, {}
		for _, photo in ipairs(entry.photos) do
			local rid = copies[photo.localIdentifier]
			if rid and rid:sub(1, #cfg.rootDir + 1) == cfg.rootDir .. '/' then
				local p = cfg.immichRoot .. rid:sub(#cfg.rootDir + 1)
				if not seen[p] then
					seen[p] = true
					paths[#paths + 1] = p
				end
			end
		end
		if #paths > 0 then
			table.sort(paths)
			albums[table.concat(entry.names, ALBUM_SEPARATOR)] = paths
		end
	end
	return albums
end

local function signatureOf(albums)
	local names = {}
	for name in pairs(albums) do names[#names + 1] = name end
	table.sort(names)
	local parts = {}
	for _, name in ipairs(names) do
		parts[#parts + 1] = name .. '\n' .. table.concat(albums[name], '\n')
	end
	return table.concat(parts, '\n\n')
end

-- Bring the Immich albums in line with the catalog's collections. Must run in
-- an async task with the destination mounted. force=true ignores the cached
-- state and checks every album. Returns a summary line, or nil when off.
function Immich.sync(service, settings, force)
	local cfg, why = Immich.config(settings)
	if not cfg then
		if why == 'incomplete' then return 'Immich: URL or API key missing' end
		if why == 'nofolders' then return 'Immich: album sync needs the Folders mirror' end
		return nil
	end
	local sid = tostring(service.localIdentifier)
	local now = LrDate.currentTime()

	local albums = desiredAlbums(service, settings, cfg)
	local sig = signatureOf(albums)
	local pending = state.pending[sid]
	if pending and pending.sig ~= sig then pending = nil end
	if force then
		state.albumSigs[sid] = {}
		pending = nil
	elseif sig == state.lastSig[sid] then
		return 'Immich: albums up to date'
	elseif pending and now < pending.retryAt then
		return pending.summary
	end
	local function retryLater(summary)
		state.lastSig[sid] = nil
		state.pending[sid] = {
			sig = sig,
			summary = summary,
			retryAt = now + RETRY_SECONDS,
			attempts = (pending and pending.attempts or 0) + 1,
		}
		return summary
	end
	local albumSigs = state.albumSigs[sid] or {}
	state.albumSigs[sid] = albumSigs

	local counts = { created = 0, added = 0, removed = 0, deleted = 0, unresolved = 0 }
	local ok, err = LrTasks.pcall(function()
		local existing = call(cfg, 'GET', '/albums') or {}
		local byName = {}
		for _, a in ipairs(existing) do
			local prev = byName[a.albumName]
			-- prefer an album the plug-in created over a same-named one
			if not prev or (a.description == MARKER and prev.description ~= MARKER) then
				byName[a.albumName] = a
			end
		end

		local index = mirrorIndex(cfg)
		local function isMirror(asset)
			return type(asset.originalPath) == 'string'
				and asset.originalPath:sub(1, #cfg.foldersPrefix) == cfg.foldersPrefix
		end

		for name, paths in pairs(albums) do
			local albumSig = table.concat(paths, '\n')
			local album = byName[name]
			if not (album and albumSigs[name] == albumSig) then
				local want, wantSet, missing = {}, {}, 0
				for _, p in ipairs(paths) do
					local id = index[p]
					if id then
						if not wantSet[id] then
							wantSet[id] = true
							want[#want + 1] = id
						end
					else
						missing = missing + 1
					end
				end
				counts.unresolved = counts.unresolved + missing

				if not album then
					if #want > 0 then
						call(cfg, 'POST', '/albums', {
							albumName = name,
							description = MARKER,
							assetIds = want,
						})
						counts.created = counts.created + 1
						counts.added = counts.added + #want
					end
				else
					local have, toRemove = {}, {}
					for _, a in ipairs(albumAssets(cfg, album.id)) do
						have[a.id] = true
						if isMirror(a) and not wantSet[a.id] then toRemove[#toRemove + 1] = a.id end
					end
					local toAdd = {}
					for _, id in ipairs(want) do
						if not have[id] then toAdd[#toAdd + 1] = id end
					end
					inChunks(toAdd, function(ids)
						call(cfg, 'PUT', '/albums/' .. album.id .. '/assets', { ids = ids })
					end)
					inChunks(toRemove, function(ids)
						call(cfg, 'DELETE', '/albums/' .. album.id .. '/assets', { ids = ids })
					end)
					counts.added = counts.added + #toAdd
					counts.removed = counts.removed + #toRemove
				end
				if missing == 0 and (album or #want > 0) then
					albumSigs[name] = albumSig
				else
					albumSigs[name] = nil
				end
			end
		end

		-- albums the plug-in created whose collection is gone
		for _, a in ipairs(existing) do
			if a.description == MARKER and not albums[a.albumName] then
				local toRemove, others = {}, 0
				for _, asset in ipairs(albumAssets(cfg, a.id)) do
					if isMirror(asset) then
						toRemove[#toRemove + 1] = asset.id
					else
						others = others + 1
					end
				end
				if others == 0 then
					call(cfg, 'DELETE', '/albums/' .. a.id)
					counts.deleted = counts.deleted + 1
				else
					inChunks(toRemove, function(ids)
						call(cfg, 'DELETE', '/albums/' .. a.id .. '/assets', { ids = ids })
					end)
					counts.removed = counts.removed + #toRemove
				end
				albumSigs[a.albumName] = nil
			end
		end
	end)

	if not ok then
		local msg = tostring(err)
		if msg ~= state.lastError then
			CPUtil.log('Immich sync failed:', msg)
			state.lastError = msg
		end
		return retryLater('Immich: ' .. msg)
	end
	state.lastError = nil

	local changes = string.format('%d album(s) created, +%d/-%d photos, %d album(s) deleted',
		counts.created, counts.added, counts.removed, counts.deleted)
	if counts.created + counts.added + counts.removed + counts.deleted > 0 then
		CPUtil.log('Immich [' .. service:getName() .. ']:', changes)
	end

	if counts.unresolved > 0 then
		-- published but not imported by Immich yet (or trashed/locked there)
		if (pending and pending.attempts or 0) < MAX_RETRIES then
			LrTasks.pcall(function() requestScan(cfg, sid) end)
			return retryLater(string.format(
				'Immich: %d photo(s) not imported by Immich yet, retrying', counts.unresolved))
		end
		CPUtil.log(string.format('Immich: %d photo(s) still missing in Immich after %d checks;'
			.. ' skipping them until the albums change', counts.unresolved, MAX_RETRIES))
	end
	state.lastSig[sid] = sig
	state.pending[sid] = nil
	return 'Immich: ' .. changes
end

-- Check URL and API key; returns (ok, message). Must run in an async task.
function Immich.testConnection(settings)
	local cfg, why = Immich.config(settings)
	if not cfg then
		if why == 'off' then return false, 'Immich album sync is turned off.' end
		if why == 'nofolders' then return false, 'Immich album sync needs the Folders mirror turned on.' end
		return false, 'Fill in the Immich URL and API key.'
	end
	local status, res = request(cfg, 'GET', '/users/me')
	if not status then return false, res end
	if status == 401 then return false, 'Immich rejected the API key (HTTP 401).' end
	if status ~= 200 or type(res) ~= 'table' then
		return false, 'Unexpected response from Immich (HTTP ' .. tostring(status) .. ').'
	end
	local ok, found = LrTasks.pcall(function()
		local items = call(cfg, 'POST', '/search/metadata',
			{ originalPath = cfg.foldersPrefix, size = 1, page = 1 })
		return items and items.assets and items.assets.items and #items.assets.items > 0
	end)
	local lines = { 'Connected as ' .. tostring(res.name or res.email) .. '.' }
	if not ok then
		lines[#lines + 1] = 'Searching assets failed: ' .. tostring(found)
	elseif found then
		lines[#lines + 1] = 'Immich has photos under ' .. cfg.foldersPrefix .. '.'
	else
		lines[#lines + 1] = 'No photos found under ' .. cfg.foldersPrefix .. ' yet. Check the'
			.. ' path Immich sees and that the external library includes it'
			.. ' (fine if nothing has been published or scanned yet).'
	end
	return ok, table.concat(lines, '\n')
end

return Immich
