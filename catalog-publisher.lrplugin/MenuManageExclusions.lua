-- View and edit the menu-added exclusions (one pattern per line). The
-- Exclude field in the publish service settings is separate and merged in.

local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrView = import 'LrView'

require 'CPUtil'
require 'AutoPublish'

LrTasks.startAsyncTask(function()
	local prefs = LrPrefs.prefsForPlugin()
	local changed = false

	LrFunctionContext.callWithContext('cpManageExclusions', function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		props.text = tostring(prefs.cp_excludes or '')

		local result = LrDialogs.presentModalDialog {
			title = 'Catalog Publisher: Exclusions',
			contents = f:column {
				spacing = f:control_spacing(),
				bind_to_object = props,
				f:static_text {
					title = 'Patterns added via "Exclude Selected", one per line (or comma-separated).\nDeleting a line re-publishes that folder/collection on the next sync.',
					height_in_lines = 2,
				},
				f:edit_field {
					value = LrView.bind 'text',
					width_in_chars = 45,
					height_in_lines = 10,
					immediate = true,
				},
				f:static_text {
					title = 'Patterns from the publish service settings\' Exclude field are managed there.',
					font = '<system/small>',
				},
			},
		}

		if result == 'ok' and props.text ~= tostring(prefs.cp_excludes or '') then
			prefs.cp_excludes = props.text
			changed = true
		end
	end)

	if changed then
		local summary = AutoPublish.syncAllNow()
		LrDialogs.message('Catalog Publisher', 'Exclusions updated.\n\n' .. summary, 'info')
	end
end)
