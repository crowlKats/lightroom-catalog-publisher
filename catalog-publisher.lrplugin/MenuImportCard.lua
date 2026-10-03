local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

require 'CPUtil'
require 'CardImport'

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('CatalogPublisher.ImportCard', function(context)
		local settings = CardImport.showDialog(context)
		if not settings then return end
		local ok, err = LrTasks.pcall(function() CardImport.run(context, settings) end)
		if not ok then
			CPUtil.log('import from card failed:', err)
			LrDialogs.message('Catalog Publisher: import failed', tostring(err), 'critical')
		end
	end)
end)
