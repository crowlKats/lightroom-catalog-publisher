local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'

require 'AutoPublish'

LrTasks.startAsyncTask(function()
	local summary = AutoPublish.syncAllNow()
	LrDialogs.message('Catalog Publisher — Sync', summary, 'info')
end)
