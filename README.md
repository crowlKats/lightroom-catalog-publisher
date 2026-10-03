# Lightroom Catalog Publisher

A Lightroom Classic plug-in that keeps a rendered copy of your catalog on
disk, mirroring your folder and collection structure:

```
<destination>/folders/<your folder hierarchy>/photo.jpg
<destination>/collections/<your collection hierarchy>/photo.jpg
```

It runs as a publish service. Edits are re-published automatically once you
stop editing, and photos removed from a folder or collection are removed from
the mirror. That makes the destination a good source for a photo server
such as Immich, a NAS share, or anything else that reads plain JPEGs.

Highlights:

- Automatic, debounced publishing of edits, new photos, moves and renames
- Choose which source folders to publish, and exclude folders or
  collections by pattern
- Optional symlinks so `collections/` doesn't duplicate `folders/` (macOS)
- Optional camera-JPEG passthrough for unedited RAW+JPEG photos
- Copes with an unmounted NAS: it pauses and resumes on its own
- Extras: stack bursts already in the catalog, and a card import that
  stacks bursts at import time (Sony maker notes via ExifTool)

Full documentation is in
[`catalog-publisher.lrplugin/README.md`](catalog-publisher.lrplugin/README.md).

## Install

1. Download `catalog-publisher-<version>.lrplugin.zip` from the
   [latest release](../../releases/latest) and unzip it.
2. In Lightroom Classic: **File → Plug-in Manager → Add**, then select the
   `catalog-publisher.lrplugin` folder.
3. In the Library module's **Publish Services** panel, click **Set Up…**
   next to *Catalog Publisher*, choose a destination folder, and save.

The burst features need [ExifTool](https://exiftool.org)
(`brew install exiftool`) and are macOS only.

## Development

The plug-in is plain Lua, loaded directly from `catalog-publisher.lrplugin`;
there is no build step. Add the folder from your checkout through the
Plug-in Manager and use **Reload Plug-in** after changes. Logs go to
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/CatalogPublisher.log`.

The API reference and SDK guide come from Adobe's
[Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/).
It isn't redistributable, so it isn't part of this repository: download
it and unpack it into the repo root if you want it nearby (`LrC_*_SDK/`
is git-ignored).

CI syntax-checks every Lua file with Lua 5.1, the version Lightroom uses.

## Releasing

Push a tag of the form `vX.Y.Z`:

```sh
git tag v0.1.0
git push origin v0.1.0
```

CI writes the version into `Info.lua`, zips the plug-in, and creates a
GitHub release with the zip attached.
