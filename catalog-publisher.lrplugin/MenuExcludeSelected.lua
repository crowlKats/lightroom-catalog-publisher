-- Excludes the currently selected Library sources (folders, collections,
-- collection sets — or the mirrored publish collections themselves) from
-- publishing, falling back to the active photo's folder.

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrPathUtils = import 'LrPathUtils'

require 'CPUtil'
require 'AutoPublish'

LrTasks.startAsyncTask(function()
	local catalog = LrApplication.activeCatalog()

	local function chainFor(obj)
		local names = {}
		local cur = obj
		while cur do
			table.insert(names, 1, CPUtil.sanitize(cur:getName()))
			local ok, parent = LrTasks.pcall(function() return cur:getParent() end)
			cur = ok and parent or nil
		end
		return table.concat(names, '/')
	end

	local patterns = {}
	local okS, sources = LrTasks.pcall(function() return catalog:getActiveSources() end)
	if okS and sources then
		for _, src in ipairs(sources) do
			local okT, ty = LrTasks.pcall(function() return src:type() end)
			if okT then
				if ty == 'LrFolder' then
					patterns[#patterns + 1] = 'folders/' .. chainFor(src)
				elseif ty == 'LrCollection' or ty == 'LrCollectionSet' then
					patterns[#patterns + 1] = 'collections/' .. chainFor(src)
				elseif ty == 'LrPublishedCollection' or ty == 'LrPublishedCollectionSet' then
					-- one of our mirrored collections selected in the publish panel
					local okR, rp = LrTasks.pcall(function() return CPUtil.relPathFor(src) end)
					if okR and type(rp) == 'string' and rp ~= '' then
						patterns[#patterns + 1] = rp
					end
				end
			end
		end
	end

	if #patterns == 0 then
		local photo = catalog:getTargetPhoto()
		if photo then
			local okP, path = LrTasks.pcall(function() return photo:getRawMetadata('path') end)
			if okP and type(path) == 'string' then
				local okF, folder = LrTasks.pcall(function()
					return catalog:getFolderByPath(LrPathUtils.parent(path))
				end)
				if okF and folder then
					patterns[#patterns + 1] = 'folders/' .. chainFor(folder)
				end
			end
		end
	end

	if #patterns == 0 then
		LrDialogs.message('Catalog Publisher',
			'Select a folder, collection, or photo to exclude first.', 'info')
		return
	end

	local answer = LrDialogs.confirm('Catalog Publisher: exclude from publishing?',
		table.concat(patterns, '\n')
		.. '\n\nTheir published files will be removed from the destination on the next sync.',
		'Exclude', 'Cancel')
	if answer ~= 'ok' then return end

	local prefs = LrPrefs.prefsForPlugin()
	local raw = tostring(prefs.cp_excludes or '')
	local have = {}
	for _, p in ipairs(CPUtil.parseExcludes(raw)) do have[p] = true end
	local added = 0
	for _, p in ipairs(patterns) do
		if not have[p:lower()] then
			raw = (raw == '') and p or (raw .. '\n' .. p)
			have[p:lower()] = true
			added = added + 1
		end
	end
	prefs.cp_excludes = raw

	local summary = AutoPublish.syncAllNow()
	LrDialogs.message('Catalog Publisher',
		string.format('Excluded %d item(s).\n\n%s', added, summary), 'info')
end)
