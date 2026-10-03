return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'com.crowlkats.catalogpublisher',
	LrPluginName = 'Catalog Publisher',

	LrInitPlugin = 'Init.lua',
	LrForceInitPlugin = true,

	LrExportServiceProvider = {
		title = 'Catalog Publisher',
		file = 'PublishServiceProvider.lua',
	},

	LrLibraryMenuItems = {
		{ title = 'Catalog Publisher: Sync Structure Now', file = 'MenuSyncNow.lua' },
		{ title = 'Catalog Publisher: Publish Pending Now', file = 'MenuPublishNow.lua' },
		{ title = 'Catalog Publisher: Exclude Selected', file = 'MenuExcludeSelected.lua' },
		{ title = 'Catalog Publisher: Manage Exclusions…', file = 'MenuManageExclusions.lua' },
		{ title = 'Catalog Publisher: Stack Bursts…', file = 'MenuGroupBursts.lua' },
		{ title = 'Catalog Publisher: Import from Card…', file = 'MenuImportCard.lua' },
	},

	VERSION = { major = 0, minor = 1, revision = 0 },
}
