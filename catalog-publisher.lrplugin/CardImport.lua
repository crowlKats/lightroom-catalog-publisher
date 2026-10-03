-- Plug-in driven import: copies files from a memory card (or any folder)
-- into a date folder under the destination, adds them to the catalog with a
-- develop and/or metadata preset, and stacks burst frames at add time via
-- catalog:addPhoto(path, stackWithPhoto). This replaces Lightroom's Import
-- dialog for the "copy + preset + stack" case; the SDK offers no hook into
-- the real import, and no way to stack existing photos.

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrSelection = import 'LrSelection'

require 'CPUtil'
require 'BurstGroup'

CardImport = CardImport or {}

local RAW_EXTS = { arw = true, dng = true, cr2 = true, cr3 = true, nef = true, raf = true, orf = true, rw2 = true, pef = true }
local JPEG_EXTS = { jpg = true, jpeg = true }
local HEIF_EXTS = { hif = true, heic = true, heif = true }
local VIDEO_EXTS = { mp4 = true, mov = true }
local SIDECAR_EXTS = { xmp = true }

local NONE = '__none__'

local function extOf(path)
	return string.lower(LrPathUtils.extension(path) or '')
end

local function kindOf(path)
	local e = extOf(path)
	if RAW_EXTS[e] then return 'raw' end
	if JPEG_EXTS[e] then return 'jpeg' end
	if HEIF_EXTS[e] then return 'heif' end
	if VIDEO_EXTS[e] then return 'video' end
	if SIDECAR_EXTS[e] then return 'xmp' end
	return nil
end

-- Volumes that look like memory cards (have a DCIM folder).
local function detectCards()
	local cards = {}
	if not MAC_ENV then return cards end
	local ok = LrTasks.pcall(function()
		for vol in LrFileUtils.directoryEntries('/Volumes') do
			local dcim = LrPathUtils.child(vol, 'DCIM')
			if LrFileUtils.exists(dcim) == 'directory' then cards[#cards + 1] = dcim end
		end
	end)
	table.sort(cards)
	return cards
end

function CardImport.settings()
	local prefs = LrPrefs.prefsForPlugin()
	local s = {
		source = prefs.ci_source,
		destRoot = prefs.ci_destRoot,
		folderFormat = prefs.ci_folderFormat,
		developPreset = prefs.ci_developPreset,
		metadataPreset = prefs.ci_metadataPreset,
		stack = prefs.ci_stack,
		collapse = prefs.ci_collapse,
		jpegSeparate = prefs.ci_jpegSeparate,
		skipExisting = prefs.ci_skipExisting,
	}
	if type(s.source) ~= 'string' then s.source = '' end
	if type(s.destRoot) ~= 'string' then s.destRoot = '' end
	if type(s.folderFormat) ~= 'string' or s.folderFormat == '' then s.folderFormat = '%Y/%Y-%m-%d' end
	if type(s.developPreset) ~= 'string' or s.developPreset == '' then s.developPreset = NONE end
	if type(s.metadataPreset) ~= 'string' or s.metadataPreset == '' then s.metadataPreset = NONE end
	if s.stack == nil then s.stack = true end
	if s.collapse == nil then s.collapse = false end
	if s.jpegSeparate == nil then s.jpegSeparate = false end
	if s.skipExisting == nil then s.skipExisting = true end
	return s
end

local function saveSettings(s)
	local prefs = LrPrefs.prefsForPlugin()
	prefs.ci_source = s.source
	prefs.ci_destRoot = s.destRoot
	prefs.ci_folderFormat = s.folderFormat
	prefs.ci_developPreset = s.developPreset
	prefs.ci_metadataPreset = s.metadataPreset
	prefs.ci_stack = s.stack
	prefs.ci_collapse = s.collapse
	prefs.ci_jpegSeparate = s.jpegSeparate
	prefs.ci_skipExisting = s.skipExisting
end

local function developPresetItems()
	local items = { { title = 'None', value = NONE } }
	LrTasks.pcall(function()
		for _, folder in ipairs(LrApplication.developPresetFolders() or {}) do
			local fname = folder:getName()
			for _, preset in ipairs(folder:getDevelopPresets() or {}) do
				items[#items + 1] = { title = fname .. ' / ' .. preset:getName(), value = preset:getUuid() }
			end
		end
	end)
	return items
end

local function metadataPresetItems()
	local items = { { title = 'None', value = NONE } }
	local list = {}
	LrTasks.pcall(function()
		for name, uuid in pairs(LrApplication.metadataPresets() or {}) do
			list[#list + 1] = { title = tostring(name), value = tostring(uuid) }
		end
	end)
	table.sort(list, function(a, b) return a.title < b.title end)
	for _, it in ipairs(list) do items[#items + 1] = it end
	return items
end

local function ensureValue(items, value)
	for _, it in ipairs(items) do
		if it.value == value then return value end
	end
	return NONE
end

-- Root folders of the catalog (what the Folders panel shows at top level),
-- like the native Import dialog's Destination tree. Mounted ones first.
local function catalogRootFolders()
	local paths = {}
	LrTasks.pcall(function()
		for _, folder in ipairs(LrApplication.activeCatalog():getFolders() or {}) do
			local okP, path = LrTasks.pcall(function() return folder:getPath() end)
			if okP and type(path) == 'string' and path ~= '' then
				paths[#paths + 1] = { path = path, mounted = LrFileUtils.exists(path) == 'directory' }
			end
		end
	end)
	table.sort(paths, function(a, b)
		if a.mounted ~= b.mounted then return a.mounted end
		return a.path < b.path
	end)
	return paths
end

function CardImport.showDialog(context)
	local s = CardImport.settings()
	local cards = detectCards()
	if s.source == '' or not LrFileUtils.exists(s.source) then
		s.source = cards[1] or s.source
	end
	local roots = catalogRootFolders()
	if s.destRoot == '' then
		-- default to the first mounted root folder, as the native importer
		-- defaults to a folder you already use
		for _, r in ipairs(roots) do
			if r.mounted then s.destRoot = r.path break end
		end
	end
	local rootItems = {}
	for _, r in ipairs(roots) do
		rootItems[#rootItems + 1] = {
			title = r.path .. (r.mounted and '' or '  (not mounted)'),
			value = r.path,
		}
	end
	local devItems = developPresetItems()
	local metaItems = metadataPresetItems()

	local props = LrBinding.makePropertyTable(context)
	props.source = s.source
	props.destRoot = s.destRoot
	props.folderFormat = s.folderFormat
	props.developPreset = ensureValue(devItems, s.developPreset)
	props.metadataPreset = ensureValue(metaItems, s.metadataPreset)
	props.stack = s.stack
	props.collapse = s.collapse
	props.jpegSeparate = s.jpegSeparate
	props.skipExisting = s.skipExisting

	local f = LrView.osFactory()
	local bind = LrView.bind
	local labelWidth = LrView.share 'ci_label'

	local function pathRow(label, key, chooseTitle, dirs)
		return f:row {
			spacing = f:label_spacing(),
			f:static_text { title = label, alignment = 'right', width = labelWidth },
			f:edit_field { value = bind(key), width_in_chars = 40, immediate = true },
			f:push_button {
				title = 'Choose…',
				action = function()
					local r = LrDialogs.runOpenPanel {
						title = chooseTitle,
						canChooseFiles = not dirs,
						canChooseDirectories = dirs,
						canCreateDirectories = dirs,
						allowsMultipleSelection = false,
					}
					if r and r[1] then props[key] = r[1] end
				end,
			},
		}
	end

	local cardNote = #cards > 0
		and ('Cards detected: ' .. table.concat(cards, ', '))
		or 'No memory card with a DCIM folder detected; choose any source folder.'

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),

		pathRow('Source:', 'source', 'Choose the card or source folder', true),
		f:row {
			f:static_text { title = '', width = labelWidth },
			f:static_text { title = cardNote, font = '<system/small>', width_in_chars = 60, truncation = 'middle' },
		},
		pathRow('Destination:', 'destRoot', 'Choose the destination root folder', true),
		#rootItems > 0 and f:row {
			spacing = f:label_spacing(),
			f:static_text { title = '', width = labelWidth },
			f:static_text { title = 'Catalog folders:', font = '<system/small>' },
			f:popup_menu {
				value = bind 'destRoot',
				items = rootItems,
				width_in_chars = 40,
				font = '<system/small>',
			},
		} or f:row {},
		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Folder:', alignment = 'right', width = labelWidth },
			f:edit_field { value = bind 'folderFormat', width_in_chars = 20, immediate = true },
			f:static_text {
				title = 'strftime pattern from capture date, e.g. %Y/%Y-%m-%d → 2026/2026-09-20',
				font = '<system/small>',
			},
		},
		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Develop preset:', alignment = 'right', width = labelWidth },
			f:popup_menu { value = bind 'developPreset', items = devItems, width_in_chars = 40 },
		},
		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Metadata preset:', alignment = 'right', width = labelWidth },
			f:popup_menu { value = bind 'metadataPreset', items = metaItems, width_in_chars = 40 },
		},
		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Bursts:', alignment = 'right', width = labelWidth },
			f:checkbox { title = 'Stack burst frames (needs ExifTool, see Stack Bursts settings)', value = bind 'stack' },
		},
		f:row {
			f:static_text { title = '', width = labelWidth },
			f:checkbox {
				title = 'Collapse stacks afterwards (drives Photo > Stacking via System Events)',
				value = bind 'collapse',
				enabled = bind 'stack',
			},
		},
		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Files:', alignment = 'right', width = labelWidth },
			f:checkbox { title = 'Skip files already present at the destination (same size)', value = bind 'skipExisting' },
		},
		f:row {
			f:static_text { title = '', width = labelWidth },
			f:checkbox { title = 'Add JPEGs that pair with a raw as separate photos', value = bind 'jpegSeparate' },
		},
		f:row {
			f:static_text {
				title = 'Raws, JPEGs, HEIF (.hif) and videos are copied; JPEGs next to a raw of the same name are\n'
					.. 'copied as sidecars. Files are added in place ("Add without moving") with the presets above.',
				font = '<system/small>',
				height_in_lines = 2,
			},
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = 'Catalog Publisher: Import from Card',
		contents = contents,
		actionVerb = 'Import',
	}
	if result ~= 'ok' then return nil end

	s.source = tostring(props.source or '')
	s.destRoot = tostring(props.destRoot or '')
	s.folderFormat = tostring(props.folderFormat or '%Y/%Y-%m-%d')
	s.developPreset = props.developPreset or NONE
	s.metadataPreset = props.metadataPreset or NONE
	s.stack = props.stack and true or false
	s.collapse = props.collapse and true or false
	s.jpegSeparate = props.jpegSeparate and true or false
	s.skipExisting = props.skipExisting and true or false
	saveSettings(s)
	return s
end

local function fileSize(path)
	local ok, attrs = LrTasks.pcall(function() return LrFileUtils.fileAttributes(path) end)
	return ok and attrs and tonumber(attrs.fileSize) or nil
end

local function fileModTime(path)
	local ok, attrs = LrTasks.pcall(function() return LrFileUtils.fileAttributes(path) end)
	return ok and attrs and tonumber(attrs.fileModificationDate) or nil
end

-- Copy src to dest; returns true when dest ends up present with src's size.
local function copyFile(src, dest, skipExisting)
	local srcSize = fileSize(src)
	if skipExisting and LrFileUtils.exists(dest) and fileSize(dest) == srcSize then
		return true, 'skipped'
	end
	LrFileUtils.createAllDirectories(LrPathUtils.parent(dest))
	if LrFileUtils.exists(dest) then LrFileUtils.delete(dest) end
	local ok = LrTasks.pcall(function() LrFileUtils.copy(src, dest) end)
	if ok and LrFileUtils.exists(dest) and (srcSize == nil or fileSize(dest) == srcSize) then
		return true, 'copied'
	end
	LrTasks.pcall(function() LrFileUtils.delete(dest) end)
	return false, 'copy failed'
end

function CardImport.run(context, s)
	local catalog = LrApplication.activeCatalog()
	local bs = BurstGroup.settings()

	if s.source == '' or LrFileUtils.exists(s.source) ~= 'directory' then
		LrDialogs.message('Catalog Publisher: source not found', 'No folder at ' .. tostring(s.source), 'critical')
		return
	end
	if s.destRoot == '' or not CPUtil.destinationAvailable(s.destRoot) then
		LrDialogs.message('Catalog Publisher: destination not available',
			'No folder at ' .. tostring(s.destRoot) .. ' (NAS not mounted?)', 'critical')
		return
	end
	if s.stack and not LrFileUtils.exists(bs.exiftoolPath) then
		LrDialogs.message('Catalog Publisher: ExifTool not found',
			'Burst stacking needs ExifTool; no file at ' .. bs.exiftoolPath
				.. '. Set the path in Stack Bursts… or turn off stacking.', 'critical')
		return
	end

	local scope = LrProgressScope { title = 'Catalog Publisher: importing from ' .. LrPathUtils.leafName(s.source), functionContext = context }
	scope:setCancelable(true)
	scope:setCaption('Scanning source…')

	-- 1. enumerate
	local files = {} -- { src, kind, base (lowercase dir/basename), dest, t }
	local byBase = {}
	for path in LrFileUtils.recursiveFiles(s.source) do
		local kind = kindOf(path)
		local leaf = LrPathUtils.leafName(path)
		if kind and leaf:sub(1, 1) ~= '.' then
			local base = string.lower(LrPathUtils.child(LrPathUtils.parent(path), LrPathUtils.removeExtension(leaf)))
			local rec = { src = path, kind = kind, base = base }
			files[#files + 1] = rec
			byBase[base] = byBase[base] or {}
			table.insert(byBase[base], rec)
		end
	end
	if #files == 0 then
		scope:done()
		LrDialogs.showBezel('Catalog Publisher: nothing to import in ' .. s.source)
		return
	end
	table.sort(files, function(a, b) return a.src < b.src end)

	-- 2. one ExifTool pass over every media file: capture time (+ burst
	-- fields for raws). Sidecar .xmp files are handled by name.
	local mediaPaths = {}
	for _, r in ipairs(files) do
		if r.kind ~= 'xmp' then mediaPaths[#mediaPaths + 1] = r.src end
	end
	local info = {}
	if #mediaPaths > 0 then
		info = BurstGroup._readBurstInfo(bs.exiftoolPath, mediaPaths, scope)
	end
	if scope:isCanceled() then scope:done() return end

	-- 3. destination folder per file
	local function rawSiblingOf(rec)
		for _, o in ipairs(byBase[rec.base] or {}) do
			if o.kind == 'raw' then return o end
		end
		return nil
	end
	for _, r in ipairs(files) do
		local d = info[r.src]
		local t = d and BurstGroup._parseExifDate(d.dto) or nil
		if t and d and d.subsec then t = t + d.subsec end
		r.t = t
		r.rm = d and d.rm or nil
		r.seq = d and d.seq or nil
	end
	for _, r in ipairs(files) do
		local anchor = r.kind ~= 'raw' and rawSiblingOf(r) or nil
		local t = (anchor and anchor.t) or r.t or fileModTime(r.src) or LrDate.currentTime()
		r.t = r.t or t
		local sub = LrDate.timeToUserFormat(t, s.folderFormat)
		r.dest = CPUtil.toAbsolute(s.destRoot, (sub:gsub('\\', '/')))
		r.dest = LrPathUtils.child(r.dest, LrPathUtils.leafName(r.src))
	end

	-- 4. copy
	local copied, skipped, failed = 0, 0, {}
	local totalBytes, doneBytes = 0, 0
	for _, r in ipairs(files) do totalBytes = totalBytes + (fileSize(r.src) or 0) end
	for i, r in ipairs(files) do
		if scope:isCanceled() then scope:done() return end
		scope:setCaption(string.format('Copying %d of %d: %s', i, #files, LrPathUtils.leafName(r.src)))
		local ok, how = copyFile(r.src, r.dest, s.skipExisting)
		if ok then
			r.ok = true
			if how == 'copied' then copied = copied + 1 else skipped = skipped + 1 end
		else
			failed[#failed + 1] = LrPathUtils.leafName(r.src) .. ': ' .. how
		end
		doneBytes = doneBytes + (fileSize(r.src) or 0)
		scope:setPortionComplete(doneBytes, math.max(totalBytes, 1))
	end
	CPUtil.log(string.format('import: %d copied, %d skipped (already present), %d failed', copied, skipped, #failed))

	-- 5. what to add: raws, HEIF, video, unpaired JPEGs (paired ones are
	-- sidecars unless requested as separate photos)
	local toAdd = {}
	for _, r in ipairs(files) do
		if r.ok and r.kind ~= 'xmp' then
			local paired = r.kind == 'jpeg' and rawSiblingOf(r) ~= nil
			if not paired or s.jpegSeparate then toAdd[#toAdd + 1] = r end
		end
	end

	-- 6. bursts among the raws
	local units = {} -- each unit: array of recs; multi-rec units are stacks
	local inBurst = {}
	local burstCount = 0
	if s.stack then
		local raws = {}
		for _, r in ipairs(toAdd) do
			if r.kind == 'raw' then raws[#raws + 1] = { rec = r, path = r.dest, t = r.t or 0, rm = r.rm, seq = r.seq } end
		end
		table.sort(raws, function(a, b)
			if a.t ~= b.t then return a.t < b.t end
			return a.path < b.path
		end)
		for _, g in ipairs(BurstGroup.group(raws, bs.gap)) do
			if #g >= 2 then
				local unit = {}
				for j, x in ipairs(g) do unit[j] = x.rec inBurst[x.rec] = true end
				units[#units + 1] = unit
				burstCount = burstCount + 1
			end
		end
	end
	for _, r in ipairs(toAdd) do
		if not inBurst[r] then units[#units + 1] = { r } end
	end
	table.sort(units, function(a, b)
		local ta, tb = a[1].t or 0, b[1].t or 0
		if ta ~= tb then return ta < tb end
		return a[1].dest < b[1].dest
	end)

	-- 7. add to catalog in batches (keeps the UI responsive)
	local devUuid = s.developPreset ~= NONE and s.developPreset or nil
	local metaUuid = s.metadataPreset ~= NONE and s.metadataPreset or nil
	local added, already, addFailed, stacksMade = 0, 0, {}, 0
	local destFolders = {}
	local BATCH = 20
	local idx = 1
	while idx <= #units do
		if scope:isCanceled() then break end
		local last = math.min(idx + BATCH - 1, #units)
		scope:setCaption(string.format('Adding to catalog %d of %d…', last, #units))
		catalog:withWriteAccessDo('Import from card', function()
			for u = idx, last do
				local unit = units[u]
				local anchor = nil
				for j, r in ipairs(unit) do
					local existing = catalog:findPhotoByPath(r.dest)
					local photo = existing
					if existing then
						already = already + 1
					else
						local ok, res = LrTasks.pcall(function()
							if j > 1 and anchor then
								return catalog:addPhoto(r.dest, anchor, 'below', metaUuid, devUuid)
							end
							return catalog:addPhoto(r.dest, nil, nil, metaUuid, devUuid)
						end)
						if ok then
							photo = res
							added = added + 1
						else
							addFailed[#addFailed + 1] = LrPathUtils.leafName(r.dest) .. ': ' .. tostring(res)
						end
					end
					if photo then
						destFolders[LrPathUtils.parent(r.dest)] = true
						-- chain so frames keep capture order inside the stack
						anchor = photo
					end
				end
				if #unit >= 2 and anchor then stacksMade = stacksMade + 1 end
			end
		end, { timeout = 120 })
		scope:setPortionComplete(last, #units)
		idx = last + 1
	end
	scope:done()

	-- 8. show the imported folder(s)
	local folders = {}
	for dir in pairs(destFolders) do
		local fo = catalog:getFolderByPath(dir)
		if fo then folders[#folders + 1] = fo end
	end
	if #folders > 0 then
		LrTasks.pcall(function() catalog:setActiveSources(folders) end)
		if s.stack and s.collapse and stacksMade > 0 and MAC_ENV then
			LrTasks.sleep(0.5)
			LrSelection.selectNone()
			BurstGroup._clickStackingMenu('Collapse All Stacks')
		end
	end

	local summary = string.format(
		'Catalog Publisher: %d file(s) copied, %d already present; %d photo(s) added (%d already in catalog); %d burst stack(s)',
		copied, skipped, added, already, stacksMade)
	CPUtil.log(summary)
	local problems = {}
	for _, x in ipairs(failed) do problems[#problems + 1] = x end
	for _, x in ipairs(addFailed) do problems[#problems + 1] = x end
	if #problems > 0 then
		local shown = {}
		for i = 1, math.min(#problems, 15) do shown[i] = problems[i] end
		if #problems > 15 then shown[#shown + 1] = string.format('… and %d more (see log)', #problems - 15) end
		for _, x in ipairs(problems) do CPUtil.log('import problem:', x) end
		LrDialogs.message('Catalog Publisher: import finished with problems',
			summary .. '\n\n' .. table.concat(shown, '\n'), 'warning')
	else
		LrDialogs.showBezel(summary)
	end
end

return CardImport
