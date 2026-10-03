-- Stacks burst-shot frames (Sony continuous drive) of photos already in
-- the catalog, so each burst collapses to one thumbnail and can be
-- reviewed on its own in Survey view. (Import from Card stacks at import
-- time instead and needs none of the UI scripting below.)
--
-- The SDK cannot create or modify stacks for photos already in the
-- catalog, so this selects each burst's frames and invokes Lightroom's own
-- Photo > Stacking > Group into Stack through macOS UI scripting
-- (osascript / System Events). Lightroom needs Accessibility and
-- Automation permission for that; macOS asks the first time.
--
-- Burst membership comes from the Sony maker notes, which the SDK cannot
-- read, so ExifTool is run once over all candidate files (argfile) and its
-- tab-separated output is parsed. Verified on an A6700: Sony:ReleaseMode is
-- 2 (Continuous) for burst frames, Sony:SequenceImageNumber counts 1, 2, 3…
-- within a burst and restarts at 1 on the next one. Culled frames leave
-- gaps in the counter, so "increasing" (not "+1") means same burst.

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
local LrApplicationView = import 'LrApplicationView'

require 'CPUtil'

BurstGroup = BurstGroup or {}

local RELEASE_MODE_CONTINUOUS = 2 -- Sony:ReleaseMode numeric value

local EXIFTOOL_CANDIDATES = {
	'/opt/homebrew/bin/exiftool',
	'/usr/local/bin/exiftool',
	'/usr/bin/exiftool',
	'C:\\Windows\\exiftool.exe',
}

local function defaultExiftoolPath()
	for _, p in ipairs(EXIFTOOL_CANDIDATES) do
		if LrFileUtils.exists(p) then return p end
	end
	return EXIFTOOL_CANDIDATES[1]
end

-- Settings live in plug-in preferences (this is a menu command, not a
-- publish service, so there is no export-settings table to store them in).
function BurstGroup.settings()
	local prefs = LrPrefs.prefsForPlugin()
	local s = {
		exiftoolPath = prefs.cp_exiftoolPath,
		gap = tonumber(prefs.cp_burstGap),
		source = prefs.cp_burstSource,
	}
	if type(s.exiftoolPath) ~= 'string' or s.exiftoolPath == '' then
		s.exiftoolPath = defaultExiftoolPath()
	end
	if not s.gap or s.gap <= 0 then s.gap = 1.0 end
	if s.source ~= 'previousImport' and s.source ~= 'selection' then
		s.source = 'previousImport'
	end
	return s
end

local function saveSettings(s)
	local prefs = LrPrefs.prefsForPlugin()
	prefs.cp_exiftoolPath = s.exiftoolPath
	prefs.cp_burstGap = s.gap
	prefs.cp_burstSource = s.source
end

-- Modal settings dialog; returns the settings table, or nil if cancelled.
function BurstGroup.showDialog(context)
	local s = BurstGroup.settings()
	local props = LrBinding.makePropertyTable(context)
	props.exiftoolPath = s.exiftoolPath
	props.gap = s.gap
	props.source = s.source

	local f = LrView.osFactory()
	local bind = LrView.bind
	local labelWidth = LrView.share 'bg_label'

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Photos:', alignment = 'right', width = labelWidth },
			f:popup_menu {
				value = bind 'source',
				items = {
					{ title = 'Previous Import', value = 'previousImport' },
					{ title = 'Selected photos', value = 'selection' },
				},
			},
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Time gap:', alignment = 'right', width = labelWidth },
			f:edit_field { value = bind 'gap', width_in_digits = 5, min = 0.1, max = 60, precision = 2 },
			f:static_text { title = 'seconds (fallback when the camera sequence counter is missing)' },
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'ExifTool:', alignment = 'right', width = labelWidth },
			f:edit_field { value = bind 'exiftoolPath', width_in_chars = 36, immediate = true },
			f:push_button {
				title = 'Choose…',
				action = function()
					local r = LrDialogs.runOpenPanel {
						title = 'Locate exiftool',
						canChooseFiles = true,
						canChooseDirectories = false,
						allowsMultipleSelection = false,
					}
					if r and r[1] then props.exiftoolPath = r[1] end
				end,
			},
		},

		f:row {
			f:static_text {
				title = 'Bursts of 2+ frames become stacks; single shots are left alone. Only raw files are\n'
					.. 'considered so RAW+JPEG pairs are not counted twice.\n'
					.. 'Stacks are made with Lightroom\'s own Group into Stack command via System Events;\n'
					.. 'allow Lightroom under Privacy & Security > Accessibility / Automation when asked.',
				font = '<system/small>',
				height_in_lines = 4,
			},
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = 'Catalog Publisher: Stack Bursts',
		contents = contents,
		actionVerb = 'Stack',
	}
	if result ~= 'ok' then return nil end

	s.exiftoolPath = tostring(props.exiftoolPath or '')
	s.gap = tonumber(props.gap) or 1.0
	s.source = props.source
	saveSettings(s)
	return s
end

local function shellQuote(p)
	if WIN_ENV then
		return '"' .. tostring(p):gsub('"', '""') .. '"'
	end
	return "'" .. tostring(p):gsub("'", "'\\''") .. "'"
end

local function writeFile(path, text)
	local fh = io.open(path, 'w')
	if not fh then error('cannot write ' .. path) end
	fh:write(text)
	fh:close()
end

-- Run ExifTool once over all paths. Returns { [path] = { rm, seq, subsec, dto } }.
local function readBurstInfo(exiftoolPath, paths, scope)
	local tmp = LrPathUtils.getStandardFilePath('temp')
	local stamp = tostring(math.floor(LrDate.currentTime())) .. '-' .. tostring(math.random(1000000))
	local argsPath = LrPathUtils.child(tmp, 'cp-burst-' .. stamp .. '.args')
	local outPath = LrPathUtils.child(tmp, 'cp-burst-' .. stamp .. '.out')
	local errPath = LrPathUtils.child(tmp, 'cp-burst-' .. stamp .. '.err')

	-- -f prints '-' for missing tags (so every file yields a line),
	-- -n gives numeric ReleaseMode, -fast stops reading after the EXIF
	-- block (maker notes included), which keeps NAS reads small.
	local args = {
		'-f', '-n', '-m', '-q', '-q', '-fast',
		-- real tab characters: ExifTool does not unescape '\t' in -p formats
		'-p', '$directory/$filename\t$Sony:ReleaseMode\t$Sony:SequenceImageNumber\t$SubSecTimeOriginal\t$DateTimeOriginal',
	}
	for _, p in ipairs(paths) do args[#args + 1] = p end
	writeFile(argsPath, table.concat(args, '\n') .. '\n')

	local cmd = shellQuote(exiftoolPath) .. ' -@ ' .. shellQuote(argsPath)
		.. ' > ' .. shellQuote(outPath) .. ' 2> ' .. shellQuote(errPath)
	if WIN_ENV then cmd = '"' .. cmd .. '"' end
	if scope then scope:setCaption(string.format('Reading burst info for %d file(s) with ExifTool…', #paths)) end
	local rc = LrTasks.execute(cmd)

	local out = LrFileUtils.exists(outPath) and LrFileUtils.readFile(outPath) or ''
	local errText = LrFileUtils.exists(errPath) and LrFileUtils.readFile(errPath) or ''
	LrTasks.pcall(function()
		LrFileUtils.delete(argsPath)
		LrFileUtils.delete(outPath)
		LrFileUtils.delete(errPath)
	end)

	if out == '' and rc ~= 0 then
		error(string.format('ExifTool failed (exit %s): %s', tostring(rc),
			errText ~= '' and errText:sub(1, 300) or 'no output; check the ExifTool path'))
	end
	if errText ~= '' then CPUtil.log('exiftool stderr:', (errText:gsub('%s+$', ''))) end

	local info = {}
	local function num(v) if v == '-' or v == '' then return nil end return tonumber(v) end
	for line in out:gmatch('[^\r\n]+') do
		local cols = {}
		for col in (line .. '\t'):gmatch('([^\t]*)\t') do cols[#cols + 1] = col end
		if #cols >= 5 then
			local subsecStr = cols[4]
			local subsec = nil
			if subsecStr and subsecStr:match('^%d+$') then
				subsec = tonumber(subsecStr) / (10 ^ #subsecStr) -- '426' -> 0.426
			end
			info[cols[1]] = {
				rm = num(cols[2]),
				seq = num(cols[3]),
				subsec = subsec,
				dto = cols[5] ~= '-' and cols[5] or nil,
			}
		end
	end
	return info
end

BurstGroup._readBurstInfo = readBurstInfo -- exposed for offline tests

-- 'YYYY:MM:DD HH:MM:SS' -> seconds (Lightroom epoch), or nil
local function parseExifDate(s)
	local y, mo, d, h, mi, sec = tostring(s or ''):match('^(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)')
	if not y then return nil end
	return LrDate.timeFromComponents(tonumber(y), tonumber(mo), tonumber(d),
		tonumber(h), tonumber(mi), tonumber(sec), 'local')
end

BurstGroup._parseExifDate = parseExifDate

-- Split ordered records into bursts. Each record: { photo, path, t, rm, seq }.
-- Returns array of arrays (all groups, including singles).
function BurstGroup.group(records, gapSeconds)
	local groups = {}
	local current, prev = nil, nil
	-- Even when the counter keeps increasing, a large time gap means a
	-- different burst whose early frames were culled (the counter alone
	-- can't tell 1,2,3 | 1,2 from 1,_,_ | _,2 once frames are deleted).
	-- Continuous drive is >= 3 fps, so 2x the gap setting leaves room for
	-- a few culled frames without merging separate bursts.
	local safetyGap = 2 * gapSeconds
	for _, rec in ipairs(records) do
		local single = rec.rm ~= nil and rec.rm ~= RELEASE_MODE_CONTINUOUS
		local startNew = true
		if current and not single and not prev.single then
			local gap = rec.t - prev.t
			if rec.seq and prev.seq then
				-- counter keeps increasing within a burst (skips allowed for
				-- culled frames); a reset or a long pause means a new burst
				startNew = not (rec.seq > prev.seq and gap <= safetyGap)
			else
				startNew = gap > gapSeconds
			end
		end
		rec.single = single
		if startNew then
			current = {}
			groups[#groups + 1] = current
		end
		current[#current + 1] = rec
		prev = rec
	end
	return groups
end

-- Run an AppleScript (macOS). Returns exit code, combined output.
local function osascript(lines)
	local tmp = LrPathUtils.getStandardFilePath('temp')
	local outPath = LrPathUtils.child(tmp, 'cp-osa-' .. tostring(math.random(1000000)) .. '.out')
	local cmd = '/usr/bin/osascript'
	for _, l in ipairs(lines) do cmd = cmd .. ' -e ' .. shellQuote(l) end
	cmd = cmd .. ' > ' .. shellQuote(outPath) .. ' 2>&1'
	local rc = LrTasks.execute(cmd)
	local out = LrFileUtils.exists(outPath) and LrFileUtils.readFile(outPath) or ''
	LrTasks.pcall(function() LrFileUtils.delete(outPath) end)
	return rc, (out:gsub('%s+$', ''))
end

local LR_PROCESS = 'Adobe Lightroom Classic'
local STACKING_MENU = 'menu 1 of menu item "Stacking" of menu 1 of menu bar item "Photo" of menu bar 1'

-- Invoke Photo > Stacking > <item> in Lightroom via System Events.
local function clickStackingMenu(item, shortcutKey)
	local rc, out = osascript {
		'tell application "' .. LR_PROCESS .. '" to activate',
		'tell application "System Events" to tell process "' .. LR_PROCESS .. '"',
		'click menu item "' .. item .. '" of ' .. STACKING_MENU,
		'end tell',
	}
	if rc == 0 then return true end
	CPUtil.log('stacking menu click failed (', item, '):', out)
	if shortcutKey then
		-- menu titles are localized; the shortcut is not
		local rc2, out2 = osascript {
			'tell application "' .. LR_PROCESS .. '" to activate',
			'tell application "System Events" to keystroke "' .. shortcutKey .. '" using command down',
		}
		if rc2 == 0 then return true end
		CPUtil.log('stacking keystroke failed:', out2)
	end
	return false
end

BurstGroup._clickStackingMenu = clickStackingMenu

local function stackMembersOf(photo)
	local ok, n = LrTasks.pcall(function() return photo:getRawMetadata('countStackInFolderMembers') end)
	return ok and tonumber(n) or 0
end

local function setActiveSourcesAndWait(catalog, sources, matchFn)
	catalog:setActiveSources(sources)
	for _ = 1, 20 do
		local ok, srcs = LrTasks.pcall(function() return catalog:getActiveSources() end)
		if ok and type(srcs) == 'table' and matchFn(srcs) then return true end
		LrTasks.sleep(0.1)
	end
	return false
end

-- Stack each burst with Lightroom's Group into Stack. Stacks live in
-- folders, so the grid is switched to each burst's folder first. Returns
-- stacks made, frames stacked, and a list of skipped-burst reasons.
local function applyStacks(catalog, bursts, scope)
	if not MAC_ENV then
		error('Stacking needs macOS (it drives Lightroom\'s Group into Stack command via System Events).')
	end
	LrTasks.pcall(function()
		LrApplicationView.switchToModule('library')
		LrApplicationView.gridView()
	end)
	LrTasks.sleep(0.3)

	-- group bursts by folder so the source only switches when needed
	local byFolder, order = {}, {}
	for _, g in ipairs(bursts) do
		local dir = LrPathUtils.parent(g[1].path)
		if not byFolder[dir] then byFolder[dir] = {} order[#order + 1] = dir end
		table.insert(byFolder[dir], g)
	end

	local made, frames, problems = 0, 0, {}
	local done = 0
	for _, dir in ipairs(order) do
		local folder = catalog:getFolderByPath(dir)
		if not folder then
			problems[#problems + 1] = 'folder not in catalog: ' .. dir
		else
			local ok = setActiveSourcesAndWait(catalog, { folder }, function(srcs)
				local okP, p = LrTasks.pcall(function() return srcs[1]:getPath() end)
				return okP and p == dir
			end)
			if not ok then CPUtil.log('stack: grid did not switch to', dir, '- continuing anyway') end
			for _, g in ipairs(byFolder[dir]) do
				done = done + 1
				if scope:isCanceled() then return made, frames, problems end
				scope:setCaption(string.format('Stacking burst %d of %d…', done, #bursts))
				local first = g[1].photo
				-- already stacked with at least this many members: leave alone (re-run)
				if stackMembersOf(first) >= #g then
					frames = frames + #g
				else
					local others = {}
					for i = 2, #g do others[#others + 1] = g[i].photo end
					catalog:setSelectedPhotos(first, others)
					LrTasks.sleep(0.25)
					local sel = catalog:getTargetPhotos() or {}
					if #sel ~= #g then
						problems[#problems + 1] = string.format('%s: only %d of %d frames selectable (library filter hiding some?)',
							LrPathUtils.leafName(g[1].path), #sel, #g)
					elseif not clickStackingMenu('Group into Stack', 'g') then
						problems[#problems + 1] = 'could not invoke Group into Stack; check Accessibility/Automation permission for Lightroom'
						return made, frames, problems
					else
						local stacked = false
						for _ = 1, 20 do
							LrTasks.sleep(0.1)
							if stackMembersOf(first) >= #g then stacked = true break end
						end
						if stacked then
							made = made + 1
							frames = frames + #g
						else
							problems[#problems + 1] = LrPathUtils.leafName(g[1].path) .. ': stack not created'
						end
					end
				end
				scope:setPortionComplete(done, #bursts)
			end
			-- bursts collapse to one thumbnail each
			LrSelection.selectNone()
			clickStackingMenu('Collapse All Stacks')
		end
	end
	return made, frames, problems
end

-- Switch the grid to the requested source and return its photos.
local function targetPhotos(catalog, source)
	if source == 'previousImport' then
		catalog:setActiveSources(catalog.kPreviousImport)
		-- source switching is asynchronous; wait until the grid follows
		for _ = 1, 20 do
			local ok, srcs = LrTasks.pcall(function() return catalog:getActiveSources() end)
			if ok and type(srcs) == 'table' and srcs[1] == catalog.kPreviousImport then break end
			LrTasks.sleep(0.1)
		end
		LrSelection.selectNone()
		LrTasks.sleep(0.1)
	end
	return catalog:getTargetPhotos() or {}
end

-- Main entry. Must run inside an async task with a function context.
function BurstGroup.run(context, s)
	local catalog = LrApplication.activeCatalog()
	if not LrFileUtils.exists(s.exiftoolPath) then
		LrDialogs.message('Catalog Publisher: ExifTool not found',
			'No file at ' .. s.exiftoolPath .. '. Set the path in the Group Bursts dialog.', 'critical')
		return
	end

	local scope = LrProgressScope { title = 'Catalog Publisher: grouping bursts', functionContext = context }
	scope:setCancelable(true)
	scope:setCaption('Collecting photos…')

	local photos = targetPhotos(catalog, s.source)
	if #photos == 0 then
		scope:done()
		LrDialogs.showBezel('Catalog Publisher: no photos to group')
		return
	end

	-- keep raws only (RAW+JPEG pairs count once); if there are none, fall
	-- back to every non-video photo
	local records, raws = {}, {}
	for _, photo in ipairs(photos) do
		local ok, fmt, isVc, isVideo, path, t = LrTasks.pcall(function()
			return photo:getRawMetadata('fileFormat'), photo:getRawMetadata('isVirtualCopy'),
				photo:getRawMetadata('isVideo'), photo:getRawMetadata('path'),
				photo:getRawMetadata('dateTimeOriginal')
		end)
		if ok and not isVc and not isVideo and type(path) == 'string' then
			local rec = { photo = photo, path = path, t = t }
			records[#records + 1] = rec
			if fmt == 'RAW' or fmt == 'DNG' then raws[#raws + 1] = rec end
		end
	end
	if #raws > 0 then records = raws end
	if #records == 0 then
		scope:done()
		LrDialogs.showBezel('Catalog Publisher: no photos to group')
		return
	end

	local paths = {}
	for i, r in ipairs(records) do paths[i] = r.path end
	local info = readBurstInfo(s.exiftoolPath, paths, scope)
	if scope:isCanceled() then scope:done() return end

	-- merge ExifTool data; capture time = Lightroom's (or EXIF's) whole
	-- seconds + SubSecTimeOriginal
	local rmCounts, withSeq, missing = {}, 0, 0
	for _, r in ipairs(records) do
		local d = info[r.path]
		if d then
			r.rm, r.seq = d.rm, d.seq
			if r.t == nil then r.t = parseExifDate(d.dto) end
			if r.t and d.subsec then r.t = r.t + d.subsec end
			rmCounts[tostring(d.rm)] = (rmCounts[tostring(d.rm)] or 0) + 1
			if d.seq then withSeq = withSeq + 1 end
		else
			missing = missing + 1
		end
		r.t = r.t or 0
	end
	local rmSummary = {}
	for k, v in pairs(rmCounts) do rmSummary[#rmSummary + 1] = k .. '=' .. v end
	table.sort(rmSummary)
	CPUtil.log(string.format('bursts: %d photo(s), %d with sequence counter, %d without ExifTool data; ReleaseMode counts: %s',
		#records, withSeq, missing, table.concat(rmSummary, ' ')))

	table.sort(records, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		return a.path < b.path
	end)

	local groups = BurstGroup.group(records, s.gap)
	local bursts = {}
	for _, g in ipairs(groups) do
		if #g >= 2 then bursts[#bursts + 1] = g end
	end
	if #bursts == 0 then
		scope:done()
		LrDialogs.showBezel(string.format('Catalog Publisher: no bursts found in %d photo(s)', #records))
		return
	end

	local made, frames, problems = applyStacks(catalog, bursts, scope)
	scope:done()
	CPUtil.log(string.format('bursts: stacked %d frame(s) into %d stack(s); %d problem(s)', frames, made, #problems))
	for _, pr in ipairs(problems) do CPUtil.log('bursts: ', pr) end
	local msg = string.format('Catalog Publisher: %d burst(s) stacked (%d frames); %d single shot(s) left alone',
		made, frames, #records - frames)
	if #problems > 0 then
		LrDialogs.message('Catalog Publisher: some bursts were not stacked',
			msg .. '\n\n' .. table.concat(problems, '\n'), 'warning')
	else
		LrDialogs.showBezel(msg)
	end
end

return BurstGroup
