# Catalog Publisher

A Lightroom Classic publish-service plugin that continuously mirrors your
catalog to disk. Photos are published to:

```
<destination>/folders/<your folder hierarchy>/photo.jpg
<destination>/collections/<your collection hierarchy>/photo.jpg
```

When you edit a photo, it is automatically re-published — debounced, so
nothing happens while you are actively editing. Removing a photo from a
folder/collection (or the catalog) removes the file on disk; moving or
renaming re-publishes to the new location and cleans up the old file.

## Install

1. Lightroom Classic → **File → Plug-in Manager → Add** → select
   `catalog-publisher.lrplugin`.
2. In the **Publish Services** panel (left side of the Library module), click
   **Set Up…** next to *Catalog Publisher*.
3. In the *Catalog Publisher* section: choose the **Destination** folder,
   leave **Auto-publish** enabled, and pick the check interval (default 60 s).
   Pick your file format/quality/sizing in the standard sections below.
   Optionally enable **Symlink collections/** (macOS only): the
   `collections/` tree then contains relative symlinks into `folders/`
   instead of duplicate rendered files — a photo in many collections costs
   disk space only once, and an edit only renders once. A repair pass marks
   photos whose file/symlink went missing (e.g. after a folder rename) for
   automatic republish.
4. Click **Save**.

Within about one interval, the plugin creates two published sets — *Folders*
and *Collections* — mirroring your library, and starts publishing.

## SOOC passthrough (optional)

Enable **"Use camera JPEG for unedited photos"** in the service settings if
you shoot RAW+JPEG (imported as pairs, JPEG as sidecar). Photos with no
develop adjustments then publish the camera JPEG — as a symlink to the
sidecar when the destination shares a volume with the originals (zero extra
space), otherwise as a copy. As soon as a photo has develop adjustments (or
a crop), it publishes the Lightroom render instead; resetting it switches
back on the next republish. JPEG-only photos link to the original file
itself. Notes:

- The camera JPEG is used as-is: publish file settings (format, quality,
  sizing) don't apply to passthrough photos, and output renaming still does.
- SOOC symlinks point outside the mirror (into the originals). If a
  consumer of the mirror can't see the originals (e.g. an Immich/Docker
  container that only mounts the mirror), either mount the common parent
  and keep the import path on the mirror, or enable **"as copies, not
  symlinks"** for a self-contained mirror at the cost of duplicating the
  camera JPEGs.
- Lightroom still renders before the plugin discards the render, so this
  saves space, not render time.
- Sidecar JPEGs become load-bearing: don't delete them, or passthrough
  photos fall back to Lightroom renders on their next republish.

## Publishing only some source folders

**Only photos under** in the service settings takes absolute source paths
(one per line, or use **Add…**), e.g. `/Volumes/footage`. When set, only
photos whose original file is stored inside one of them are published:
the `folders/` side mirrors just those folders (keeping their usual path
under the catalog's root folder), and `collections/` only contains their
photos — a collection holding nothing but local photos isn't published.
Leave it empty to publish the whole catalog. Matching is case-insensitive.

Setting or narrowing it removes everything that falls outside from the
destination on the next sync.

## Excluding collections and folders

The **Exclude** field in the service settings takes comma-separated
patterns, matched case-insensitively against each collection's or folder's
mirror path (with or without the `collections/`/`folders/` prefix); `*` is a
wildcard. A pattern matching a set/folder excludes its whole subtree.
Examples:

- `Clients` — skip the top-level "Clients" set/folder
- `collections/Clients` — same, but only on the collections side
- `*/Rejects` — skip anything named "Rejects" one level deep; use
  `*/Rejects, Rejects` to catch it at any top level too
- `*private*` — skip any path containing "private"

Excluding something already published removes its mirrored collection and
deletes its files from the destination on the next sync.

Instead of typing patterns, you can select folders/collections in the
Library sidebar (or mirrored collections in the Publish Services panel) and
run **Library → Plug-in Extras → Catalog Publisher: Exclude Selected**; with
no source selected it excludes the active photo's folder. These exclusions
are stored in the plug-in preferences (the SDK can't write service
settings) and merge with the Exclude field. Review or remove them via
**Catalog Publisher: Manage Exclusions…** — removing one re-publishes that
folder/collection on the next sync. Note they apply to all Catalog
Publisher services, unlike the per-service Exclude field.

## How auto-publish works

- A background task wakes every *interval* seconds, re-syncs the mirror
  (new/removed/moved photos, new collections), and looks for pending changes.
- Pending changes are only published once they have been **stable for one full
  interval** (no further edits), so rapid editing doesn't thrash your machine.
  If you keep editing continuously, publishing happens anyway after ~10
  intervals as a backstop.
- Develop edits always trigger re-publish. Metadata re-publish triggers:
  rating, label, title, caption, keywords, GPS, capture date.

## Menu commands (Library → Plug-in Extras area of the Library menu)

- **Catalog Publisher: Sync Structure Now** — immediately mirror
  folders/collections into the publish service.
- **Catalog Publisher: Publish Pending Now** — publish everything pending
  right now, skipping the debounce.

## Stacking bursts already in the catalog

**Library > Plug-in Extras > Catalog Publisher: Stack Bursts…** turns
continuous-drive bursts among photos that are already in the catalog into
regular Lightroom stacks, collapsed to one thumbnail each, so every burst
can be reviewed on its own (select the stack, press N for Survey, P the
keeper, X the rest, then Delete Rejected Photos). Use it for imports done
through Lightroom's own Import dialog; Import from Card (below) stacks at
import time and doesn't need this. It works on the Previous Import by
default, or on the current selection, and only looks at raw files so
RAW+JPEG pairs are counted once. Single shots are left alone.

Burst membership comes from the Sony maker notes (`Sony:ReleaseMode`,
`Sony:SequenceImageNumber`, `SubSecTimeOriginal`), which the Lightroom SDK
cannot read, so [ExifTool](https://exiftool.org) is required (Homebrew:
`brew install exiftool`). It runs once per command over all files with an
argfile and `-fast`, so reads stay small even over a NAS. Verified on an
A6700: the sequence counter runs 1, 2, 3… within a burst and restarts at 1
on the next burst; a frame whose ReleaseMode is not Continuous is a single
shot. When the counter is missing (other cameras), frames closer together
than the configured time gap are grouped instead. Already-culled sets
group less reliably: once frames are deleted the counter alone can't
separate two adjacent bursts, so a pause longer than twice the time-gap
setting also starts a new burst.

The SDK cannot create stacks for existing photos, so the plugin selects
each burst's frames in its folder and invokes Lightroom's own **Photo >
Stacking > Group into Stack** via System Events (macOS only), then
**Collapse All Stacks**. The first run triggers macOS prompts to let
Lightroom control System Events; if nothing happens, add Adobe Lightroom
Classic under System Settings > Privacy & Security > Accessibility (and
Automation). Lightroom must not have a modal dialog open, and the Library
grid must not filter out burst frames, or those bursts are reported as
skipped. Bursts that are already stacked are left alone on re-runs.
**Photo > Stacking > Auto-Stack by Capture Time** remains a manual
alternative that needs no permissions. The SDK also offers no
import-completed hook, which is why this is a menu command.

## Importing from a card with bursts stacked

**Library > Plug-in Extras > Catalog Publisher: Import from Card…** is a
plug-in driven import that replaces the Import dialog for the "copy, apply
presets, stack bursts" case. Stacks can only be created by the SDK at the
moment a photo is added (`catalog:addPhoto` with a stack anchor), so this
is the one way to get real stacks without UI scripting.

What it does, all configurable in its dialog and remembered between runs:

- **Source**: memory cards (volumes with a `DCIM` folder) are detected and
  offered; any folder works.
- **Destination** root, picked from the catalog's top-level folders (the
  same list as the Folders panel, mounted ones first) or any folder via
  Choose…, plus a **folder pattern** built from the capture date
  (strftime, default `%Y/%Y-%m-%d`). Both are remembered between runs.
- **Develop preset** and **metadata preset** applied on add, picked from
  your preset folders (Lightroom 12.5+).
- **Bursts**: raws are grouped exactly as in Stack Bursts (same ExifTool
  path and time-gap settings) and frames 2..n are added stacked under
  frame 1 in capture order. Optionally collapse the new stacks afterwards
  (that part goes through System Events like Stack Bursts).
- **Files**: raws, JPEG, HEIF (.hif) and MP4/MOV are copied, plus .xmp
  sidecars. A JPEG next to a raw of the same name is copied as a sidecar
  and not added separately unless you tick that option. Files already
  present at the destination with the same size are skipped, and files
  already in the catalog are not added twice, so re-running is safe.

Compared to Lightroom's Import dialog this does not build previews up
front, rename files, make a second copy, or run duplicate detection across
other folders. Photos are added in place ("Add without moving") after the
copy, so the destination must be reachable (a NAS has to be mounted).
Whether Lightroom treats the copied JPEG as a sidecar follows its own
preference "Treat JPEG files next to raw files as separate photos".

## Notes & limitations

- The published collections are managed by the plugin: don't rename or
  reorganize them in the Publish Services panel — the next sync will put
  everything back to match your library. Change your library structure
  instead.
- Renaming a library collection/folder is treated as delete + create: files
  re-render under the new path and the old ones are removed.
- Smart collections are mirrored by their current contents.
- Videos are skipped.
- If the destination is not reachable (NAS or external drive not mounted),
  the plugin skips that service entirely — no sync, no publishing, no
  errors — and resumes on the next poll after it is mounted again. A manual
  publish from the panel leaves the photos pending and shows a brief
  "destination not mounted" bezel instead of an error dialog.
- Symlink mode: links are relative, so the whole destination folder can be
  moved or synced as-is (as long as the target preserves symlinks — some
  cloud-sync tools upload the linked file content instead). Network volumes
  mounted via SMB usually refuse symlink creation from macOS; the plugin
  then logs a warning once and stores real files instead. For a NAS
  destination, publish to a local folder and rsync (over SSH) to the NAS to
  keep the links. If a
  collections/ entry publishes before its folders/ copy exists (first
  publish ordering, manual publish from the panel), it falls back to a real
  file and becomes a symlink the next time that photo republishes. Turning
  symlink mode on later converts files to links as photos get edited, not
  all at once — use "Mark to Republish" on a collection to force it.
- If two photos would produce the same filename in the same directory (e.g.
  same-named files from different folders in one collection, or virtual
  copies), the later one gets a stable `-lrid<id>` suffix so nothing is
  overwritten. If the conflict goes away, the suffixed file migrates back to
  the plain name on its next re-publish.
- Sync changes appear in Lightroom's Undo history as "Catalog Publisher
  Sync"; be aware of this when hitting Cmd-Z right after a sync ran.
- Logs: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/CatalogPublisher.log`.
- Large catalogs: each cycle queries folder/collection membership. If cycles
  feel heavy, raise the interval in the publish service settings.
