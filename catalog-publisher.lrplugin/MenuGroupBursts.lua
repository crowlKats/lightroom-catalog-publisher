local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

require 'CPUtil'
require 'BurstGroup'

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('CatalogPublisher.GroupBursts', function(context)
		local settings = BurstGroup.showDialog(context)
		if not settings then return end
		local ok, err = LrTasks.pcall(function() BurstGroup.run(context, settings) end)
		if not ok then
			CPUtil.log('group bursts failed:', err)
			LrDialogs.message('Catalog Publisher: grouping bursts failed', tostring(err), 'critical')
		end
	end)
end)
