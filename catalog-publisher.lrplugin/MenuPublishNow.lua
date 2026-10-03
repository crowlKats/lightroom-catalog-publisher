local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'

require 'AutoPublish'

LrTasks.startAsyncTask(function()
	LrDialogs.showBezel('Catalog Publisher: publishing pending changes…')
	local summary = AutoPublish.cycle(true)
	LrDialogs.showBezel('Catalog Publisher: ' .. summary:gsub('\n', ' | '))
end)
