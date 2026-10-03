-- Publish service provider: renders photos to <destination>/<relPath>/,
-- where relPath ('folders/...' or 'collections/...') is stored on each
-- mirrored published collection by CatalogSync.

local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrBinding = import 'LrBinding'

require 'CPUtil'
require 'Immich'

local bind = LrView.bind

local provider = {}

provider.supportsIncrementalPublish = 'only'
provider.canExportVideo = false
provider.small_icon = nil

provider.hideSections = { 'exportLocation', 'video', 'watermarking' }

provider.exportPresetFields = {
	{ key = 'cp_rootDir', default = '' },
	{ key = 'cp_autoPublish', default = true },
	{ key = 'cp_interval', default = 60 },
	{ key = 'cp_mirrorFolders', default = true },
	{ key = 'cp_mirrorCollections', default = true },
	{ key = 'cp_symlinkCollections', default = false },
	{ key = 'cp_soocPassthrough', default = false },
	{ key = 'cp_soocCopy', default = false },
	{ key = 'cp_excludes', default = '' },
	{ key = 'cp_includeRoots', default = '' },
	{ key = 'cp_immichAlbums', default = false },
	{ key = 'cp_immichUrl', default = '' },
	{ key = 'cp_immichApiKey', default = '' },
	{ key = 'cp_immichRoot', default = '' },
}

-- The mirror is managed by the plug-in; don't let renames drift from the catalog.
provider.disableRenamePublishedCollection = true
provider.disableRenamePublishedCollectionSet = true
provider.supportsCustomSortOrder = false

provider.titleForPublishedCollection = 'Mirrored Collection'
provider.titleForPublishedCollectionSet = 'Mirrored Set'

function provider.getCollectionBehaviorInfo(publishSettings)
	return {
		defaultCollectionName = 'Default',
		defaultCollectionCanBeDeleted = true,
		canAddCollection = true,
	}
end

function provider.metadataThatTriggersRepublish(publishSettings)
	return {
		default = false,
		rating = true,
		label = true,
		title = true,
		caption = true,
		keywords = true,
		gps = true,
		dateCreated = true,
	}
end

function provider.shouldDeletePhotosFromServiceOnDeleteFromCatalog(publishSettings, nPhotos)
	return 'delete'
end

function provider.sectionsForTopOfDialog(f, propertyTable)
	return {
		{
			title = 'Catalog Publisher',
			synopsis = bind 'cp_rootDir',

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Destination:',
					alignment = 'right',
					width = LrView.share 'cp_label_width',
				},
				f:static_text {
					title = bind 'cp_rootDir',
					truncation = 'head',
					fill_horizontal = 1,
					width_in_chars = 30,
				},
				f:push_button {
					title = 'Choose…',
					action = function()
						local result = LrDialogs.runOpenPanel {
							title = 'Choose destination folder',
							canChooseFiles = false,
							canChooseDirectories = true,
							canCreateDirectories = true,
							allowsMultipleSelection = false,
						}
						if result and result[1] then
							propertyTable.cp_rootDir = result[1]
						end
					end,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Mirror:',
					alignment = 'right',
					width = LrView.share 'cp_label_width',
				},
				f:checkbox { title = 'Folders', value = bind 'cp_mirrorFolders' },
				f:checkbox {
					title = 'Collections',
					value = bind 'cp_mirrorCollections',
					enabled = LrBinding.negativeOfKey('cp_immichAlbums'),
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_label_width',
				},
				f:checkbox {
					title = 'Symlink collections/ into folders/ (saves disk, macOS only)',
					value = bind 'cp_symlinkCollections',
					enabled = bind 'cp_mirrorFolders',
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_label_width',
				},
				f:checkbox {
					title = 'Use camera JPEG for unedited photos (SOOC passthrough)',
					value = bind 'cp_soocPassthrough',
				},
				f:checkbox {
					title = 'as copies, not symlinks (self-contained mirror)',
					value = bind 'cp_soocCopy',
					enabled = bind 'cp_soocPassthrough',
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Only photos under:',
					alignment = 'right',
					width = LrView.share 'cp_label_width',
				},
				f:edit_field {
					value = bind 'cp_includeRoots',
					fill_horizontal = 1,
					width_in_chars = 30,
					height_in_lines = 3,
					immediate = true,
				},
				f:push_button {
					title = 'Add…',
					action = function()
						local result = LrDialogs.runOpenPanel {
							title = 'Choose source folder(s) to publish',
							canChooseFiles = false,
							canChooseDirectories = true,
							canCreateDirectories = false,
							allowsMultipleSelection = true,
						}
						if result and #result > 0 then
							local text = tostring(propertyTable.cp_includeRoots or ''):gsub('%s+$', '')
							for _, path in ipairs(result) do
								text = (text == '' and '' or text .. '\n') .. path
							end
							propertyTable.cp_includeRoots = text
						end
					end,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_label_width',
				},
				f:static_text {
					title = 'Source folders (one per line). Only photos stored inside them are published,\nin folders/ and collections/ alike. Leave empty to publish the whole catalog.',
					font = '<system/small>',
					fill_horizontal = 1,
					height_in_lines = 2,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Exclude:',
					alignment = 'right',
					width = LrView.share 'cp_label_width',
				},
				f:edit_field {
					value = bind 'cp_excludes',
					fill_horizontal = 1,
					width_in_chars = 30,
					immediate = true,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_label_width',
				},
				f:static_text {
					title = 'Comma-separated collection/folder paths to skip, * as wildcard.\nExcluding a set skips everything inside it, e.g.: Clients, */Rejects, *private*',
					font = '<system/small>',
					fill_horizontal = 1,
					height_in_lines = 2,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Auto-publish:',
					alignment = 'right',
					width = LrView.share 'cp_label_width',
				},
				f:checkbox { title = 'Enabled', value = bind 'cp_autoPublish' },
				f:static_text { title = 'Check every' },
				f:edit_field {
					value = bind 'cp_interval',
					width_in_digits = 5,
					min = 15,
					max = 3600,
					precision = 0,
				},
				f:static_text { title = 'seconds' },
			},

			f:row {
				f:static_text {
					title = 'Edits are published once no further changes have happened for a full interval,\nso publishing never runs while you are actively editing.',
					font = '<system/small>',
					fill_horizontal = 1,
					height_in_lines = 2,
				},
			},
		},
		{
			title = 'Immich Albums',
			synopsis = bind 'cp_immichUrl',

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_immich_label_width',
				},
				f:checkbox {
					title = 'Sync collections to Immich albums (instead of writing collections/)',
					value = bind 'cp_immichAlbums',
					enabled = bind 'cp_mirrorFolders',
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Server URL:',
					alignment = 'right',
					width = LrView.share 'cp_immich_label_width',
				},
				f:edit_field {
					value = bind 'cp_immichUrl',
					enabled = bind 'cp_immichAlbums',
					fill_horizontal = 1,
					width_in_chars = 30,
					immediate = true,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'API key:',
					alignment = 'right',
					width = LrView.share 'cp_immich_label_width',
				},
				f:password_field {
					value = bind 'cp_immichApiKey',
					enabled = bind 'cp_immichAlbums',
					fill_horizontal = 1,
					width_in_chars = 30,
					immediate = true,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = 'Destination in Immich:',
					alignment = 'right',
					width = LrView.share 'cp_immich_label_width',
				},
				f:edit_field {
					value = bind 'cp_immichRoot',
					enabled = bind 'cp_immichAlbums',
					fill_horizontal = 1,
					width_in_chars = 30,
					immediate = true,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_immich_label_width',
				},
				f:static_text {
					title = 'The destination folder\'s path as Immich sees it (e.g. inside its container).\nLeave empty if it is the same path. Immich must import <that path>/folders/ as an external library.',
					font = '<system/small>',
					fill_horizontal = 1,
					height_in_lines = 2,
				},
			},

			f:row {
				spacing = f:label_spacing(),
				f:static_text {
					title = '',
					width = LrView.share 'cp_immich_label_width',
				},
				f:push_button {
					title = 'Test Connection',
					enabled = bind 'cp_immichAlbums',
					action = function()
						LrTasks.startAsyncTask(function()
							local settings = {
								cp_immichAlbums = propertyTable.cp_immichAlbums,
								cp_immichUrl = propertyTable.cp_immichUrl,
								cp_immichApiKey = propertyTable.cp_immichApiKey,
								cp_immichRoot = propertyTable.cp_immichRoot,
								cp_rootDir = propertyTable.cp_rootDir,
							}
							local ok, msg = Immich.testConnection(settings)
							LrDialogs.message('Immich connection', msg, ok and 'info' or 'warning')
						end)
					end,
				},
			},
		},
	}
end

-- SOOC passthrough: photos without develop adjustments publish the camera
-- JPEG (the file itself, or the RAW's sidecar JPEG) instead of a Lightroom
-- render. The set of adjusted photos comes from one findPhotos query,
-- cached briefly so a multi-collection publish batch reuses it.
local adjustedCache = { time = 0, set = nil }

local function adjustedSet()
	local now = LrDate.currentTime()
	if adjustedCache.set and (now - adjustedCache.time) < 60 then
		return adjustedCache.set
	end
	local set = {}
	local ok = LrTasks.pcall(function()
		local photos = LrApplication.activeCatalog():findPhotos {
			searchDesc = { criteria = 'hasAdjustments', operation = 'isTrue', value = true },
		}
		for _, p in ipairs(photos or {}) do
			set[p.localIdentifier] = true
		end
	end)
	if not ok then
		CPUtil.log('SOOC: hasAdjustments query failed; falling back to rendering everything')
		return nil
	end
	adjustedCache.time = now
	adjustedCache.set = set
	return set
end

local SIDECAR_EXTS = { 'JPG', 'jpg', 'JPEG', 'jpeg' }

-- Returns the camera JPEG path for an unedited photo, or nil to render.
local function soocSourceFor(photo, adjusted)
	if adjusted == nil then return nil end
	local id = photo.localIdentifier
	if not id or adjusted[id] then return nil end
	local ok, isCropped, fmt, path = LrTasks.pcall(function()
		return photo:getRawMetadata('isCropped'),
			photo:getRawMetadata('fileFormat'),
			photo:getRawMetadata('path')
	end)
	-- crops don't count as 'hasAdjustments', but must render
	if not ok or isCropped or type(path) ~= 'string' then return nil end
	if fmt == 'JPG' then return path end
	if fmt == 'RAW' or fmt == 'DNG' then
		local base = LrPathUtils.removeExtension(path)
		for _, ext in ipairs(SIDECAR_EXTS) do
			local cand = base .. '.' .. ext
			if LrFileUtils.exists(cand) then return cand end
		end
	end
	return nil
end

function provider.processRenderedPhotos(functionContext, exportContext)
	local settings = exportContext.propertyTable
	local rootDir = CPUtil.setting(settings, 'cp_rootDir')
	local pubCollection = exportContext.publishedCollection

	if type(rootDir) ~= 'string' or rootDir == '' then
		error('Catalog Publisher: no destination folder configured. Edit the publish service settings.')
	end
	if not CPUtil.destinationAvailable(rootDir) then
		-- Destination not mounted: skip every rendition without rendering and
		-- return. Nothing gets recorded, so the photos simply stay pending
		-- and publish once the volume is back. Never error() here: that
		-- surfaces as a modal popup on every automatic publish.
		CPUtil.log('publish skipped: destination not available:', rootDir)
		local skipped = 0
		for _, rendition in exportContext.exportSession:renditions() do
			LrTasks.pcall(function() rendition:skipRender() end)
			skipped = skipped + 1
		end
		-- A manual publish from the panel gets a transient bezel (no dialog);
		-- the background loop never reaches this point once reloaded.
		if not (AutoPublish and AutoPublish._state and AutoPublish._state.busy) then
			LrTasks.pcall(function()
				LrDialogs.showBezel(string.format(
					'Catalog Publisher: destination not mounted, %d photo(s) left pending', skipped))
			end)
		end
		return
	end

	local relPath = CPUtil.relPathFor(pubCollection)
	local targetDir = CPUtil.toAbsolute(rootDir, relPath)

	-- Symlink mode: collections/ entries link to the photo's folders/ copy
	-- instead of storing a second rendered file.
	local useSymlinks = MAC_ENV
		and CPUtil.setting(settings, 'cp_symlinkCollections')
		and CPUtil.setting(settings, 'cp_mirrorFolders') ~= false
		and relPath:sub(1, 12) == 'collections/'
	local symlinkFailureLogged = false

	local soocEnabled = CPUtil.setting(settings, 'cp_soocPassthrough')
	local adjusted = soocEnabled and adjustedSet() or nil

	local serviceId = exportContext.publishService
		and exportContext.publishService.localIdentifier or nil
	local folderCopyCache = {} -- folder-collection localId -> { photoLocalId = remoteId }

	-- Find the on-disk path of this photo's folders/ copy in this service.
	local function folderCopyFor(photo)
		local okC, colls = LrTasks.pcall(function() return photo:getContainedPublishedCollections() end)
		if not okC or type(colls) ~= 'table' then return nil end
		for _, coll in ipairs(colls) do
			local sameService = true
			LrTasks.pcall(function()
				local svc = coll:getService()
				if serviceId and svc then
					sameService = (svc.localIdentifier == serviceId)
				end
			end)
			if sameService then
				local okR, rp = LrTasks.pcall(function() return CPUtil.relPathFor(coll) end)
				if okR and type(rp) == 'string' and rp:sub(1, 8) == 'folders/' then
					local cid = tostring(coll.localIdentifier)
					local map = folderCopyCache[cid]
					if not map then
						map = {}
						LrTasks.pcall(function()
							for _, pp in ipairs(coll:getPublishedPhotos() or {}) do
								local okP, p = LrTasks.pcall(function() return pp:getPhoto() end)
								if okP and p and p.localIdentifier then
									map[p.localIdentifier] = pp:getRemoteId()
								end
							end
						end)
						folderCopyCache[cid] = map
					end
					local rid = map[photo.localIdentifier]
					if type(rid) == 'string' and rid ~= '' then return rid end
				end
			end
		end
		return nil
	end

	local exportSession = exportContext.exportSession
	local nPhotos = exportSession:countRenditions()
	exportContext:configureProgress {
		title = string.format('Publishing %d photo(s) to %s', nPhotos, relPath),
	}

	for i, rendition in exportContext:renditions { stopIfCanceled = true } do
		local success, pathOrMessage = rendition:waitForRender()
		if success then
			local filename = LrPathUtils.leafName(pathOrMessage)
			local target = LrPathUtils.child(targetDir, filename)
			local oldPath = rendition.publishedPhotoId
			if type(oldPath) ~= 'string' or oldPath == '' then oldPath = nil end

			-- Same-named files: if the plain name is already taken by a file
			-- that is not this photo's own previous export, fall back to a
			-- name suffixed with the photo's stable local identifier. The
			-- suffix is deterministic, so republishing keeps overwriting the
			-- same file, and if the conflicting photo goes away the next
			-- republish migrates back to the plain name (cleaning up the
			-- suffixed file via the oldPath check below).
			if target ~= oldPath and LrFileUtils.exists(target) then
				local base = LrPathUtils.removeExtension(filename)
				local ext = LrPathUtils.extension(filename)
				local suffixed = base .. '-lrid' .. tostring(rendition.photo.localIdentifier)
				if ext and ext ~= '' then
					suffixed = suffixed .. '.' .. ext
				end
				target = LrPathUtils.child(targetDir, suffixed)
			end

			LrFileUtils.createAllDirectories(targetDir)

			-- clean up the previous copy if the target path changed
			if oldPath and oldPath ~= target then
				LrTasks.pcall(function() CPUtil.deletePublishedFile(oldPath, rootDir) end)
			end

			CPUtil.removeFileOrLink(target)

			local wrote = false

			-- SOOC passthrough: link (or copy) the camera JPEG instead of
			-- keeping the render; applies to folders/ and collections/ alike
			if soocEnabled then
				local soocSrc = soocSourceFor(rendition.photo, adjusted)
				if soocSrc then
					local soocCopy = CPUtil.setting(settings, 'cp_soocCopy')
					if not soocCopy and MAC_ENV and CPUtil.makeSymlink(target, soocSrc) then
						wrote = true
					else
						LrTasks.pcall(function() LrFileUtils.copy(soocSrc, target) end)
						wrote = LrFileUtils.exists(target) and true or false
					end
					if wrote then
						LrFileUtils.delete(pathOrMessage) -- discard the rendered temp file
					end
				end
			end

			if not wrote and useSymlinks then
				local folderCopy = folderCopyFor(rendition.photo)
				if folderCopy and LrFileUtils.exists(folderCopy) then
					if CPUtil.makeSymlink(target, folderCopy) then
						wrote = true
						LrFileUtils.delete(pathOrMessage) -- discard the rendered temp file
					elseif not symlinkFailureLogged then
						-- e.g. SMB/network volumes often refuse symlink creation
						symlinkFailureLogged = true
						CPUtil.log('symlink creation failed at', target,
							'- filesystem may not support symlinks; storing real files instead')
					end
				end
				-- no folders/ copy yet (e.g. it publishes later): fall through
				-- and store a real file; it becomes a symlink the next time
				-- this photo republishes
			end
			if not wrote then
				local moved = LrFileUtils.move(pathOrMessage, target)
				if not moved and LrFileUtils.exists(pathOrMessage) then
					-- move can fail across volumes; fall back to copy + delete
					LrFileUtils.copy(pathOrMessage, target)
					LrFileUtils.delete(pathOrMessage)
				end
			end

			if LrFileUtils.exists(target) then
				rendition:recordPublishedPhotoId(target)
			else
				rendition:uploadFailed('Failed to write ' .. target)
			end
		elseif not rendition.wasSkipped then
			rendition:uploadFailed(pathOrMessage)
		end
	end
end

function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
	local rootDir = CPUtil.setting(publishSettings, 'cp_rootDir')
	if type(rootDir) == 'string' and rootDir ~= '' and not CPUtil.destinationAvailable(rootDir) then
		-- don't acknowledge deletions we couldn't perform; Lightroom keeps
		-- them pending and retries once the destination is mounted again
		CPUtil.log('delete: destination not available, deferring', #arrayOfPhotoIds, 'deletion(s)')
		return
	end
	for _, photoId in ipairs(arrayOfPhotoIds) do
		if type(photoId) == 'string' and photoId ~= '' and type(rootDir) == 'string' and rootDir ~= '' then
			LrTasks.pcall(function() CPUtil.deletePublishedFile(photoId, rootDir) end)
		end
		deletedCallback(photoId)
	end
end

function provider.deletePublishedCollection(publishSettings, info)
	local rootDir = CPUtil.setting(publishSettings, 'cp_rootDir')
	if type(rootDir) ~= 'string' or rootDir == '' then return end
	local coll = info and info.publishedCollection
	if not coll then return end
	LrTasks.pcall(function()
		for _, pp in ipairs(coll:getPublishedPhotos() or {}) do
			local ok, remoteId = LrTasks.pcall(function() return pp:getRemoteId() end)
			if ok and type(remoteId) == 'string' then
				CPUtil.deletePublishedFile(remoteId, rootDir)
			end
		end
	end)
end

return provider
