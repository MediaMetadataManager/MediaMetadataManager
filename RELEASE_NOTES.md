# MediaMetadataManager Release Notes

This tracks fork-specific changes to MediaMetadataManager (the personal,
renamed fork of Subler) separately from `NEWS.markdown`, which is
upstream Subler's own changelog and shouldn't be mixed with changes that
only exist here.

New entries go under **Unreleased** as they're made. Once a batch has been
built and confirmed working, its heading gets replaced with the date it
shipped, and a new empty **Unreleased** section starts above it for the
next round of work.

## Unreleased

- Added: Media Intake now actually watches the Incoming Folders (file-system events plus a 20-second sweep) and feeds the Queue; **Scan Now** forces a pass. TV episodes go to a separate **TV Shows Queue** window; the movie window is titled **Movies Queue**.
- Added: several Incoming and Automatically-Add folders, with + / - buttons.
- Added: opt-in **Clean up processed files** moves the original parts to the Trash after a successful merge or conversion and logs them in `Cleaned Up Processed Files.txt`.
- Added: the filename parser understands `<date or year>_<uploader>_<Title>_<Studio>_<quality>` uploads.
- Added: Queue rows have labelled Edit / Save buttons; **Save & Close**; default toolbar order Add, Merge, Start, Settings.
- Added: **Support** replaces the dead **Donate…** menu item. A small dialog and a new **Preferences > Support** tab link to GitHub Sponsors for Media Metadata Manager and to the original Subler project, crediting Damiano Galassi. Nothing is shown automatically, and the old subler.org donate page is no longer used. Links live in one place (`SupportLinks` in `PrefsWindowController.swift`). Added `.github/FUNDING.yml`. The new text is English-only for now.
- Added: plugins declare their own settings (an optional `settingsFields` selector). The app builds the **Configure…** form from that, so it contains no plugin-specific code or keys. Plugins are still loaded at launch; after adding one, restart and it appears in Preferences > Sources > Providers.
- Added: tooling for public releases in `Tools/` (clean public export with a safety scan, Sparkle key setup, release build and appcast, and a backup/restore script for your own settings). The app itself ships without plugins or personal configuration.
- Changed: comments and examples in the source use neutral sample names.
- Added: documentation set in the `Documentation` folder (Getting Started, User Guide, internal Design and Project Manual) and a draw.io Media Intake flowchart.
- Fixed: a movie with no title tagged is no longer renamed or put in a "[] ()" folder.
- Fixed: re-adding a file with the same name as one ingested earlier is no longer skipped (remembered paths are forgotten once the file is gone).
- Fixed: even spacing between the Media Intake checkboxes; the empty-folders tooltip now points to the Window menu.
- Changed: iTunes Store artwork is no longer fetched (it was broken and added nothing).
- Ported from upstream Subler: undo/redo for tracks, chapters, metadata and the document UI; improved TVDB series-name matching; a queue decode-crash fix; an opt-in 4K HD Video flag.

- Fixed: MediaMetadataManager could be silently overwritten by a real
  upstream Subler auto-update, because the old Sparkle update-feed
  configuration was still pointing at Subler's appcast. Auto-update is
  now fully disabled for this fork.
- Fixed: the Custom Source detail window's Field Mapping section (the
  mapping/discovered-fields tables) could be scrolled or resized out of
  view entirely if the window was shrunk. The identity/search/auth
  fields above it no longer scroll in their own bounding box either --
  the whole form is laid out plainly now, and the window can't be
  resized smaller than what it needs to show all of that plus at least
  3 rows of the mapping/discovered-fields tables (which keep their own
  scrollbars for anything beyond that).
- Fixed: creating a new Set (Preferences > Sets > +) could lock up the
  app if the save failed for any reason other than a duplicate name
  (e.g. a missing/unwritable Application Support folder) -- it retried
  forever instead of surfacing the error.
- Added: a Settings toolbar button to the main document window, so
  Preferences can be reached without going through the app menu.

