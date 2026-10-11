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

## 1.0.6 (2026-10-11)

- Fixed: turning off **Automatically watch these folders for new files** (Media Intake) made M3 quit. Saving the setting and the Queue reading it back happened at the same moment, which macOS treats as a fatal error; the Queue now waits for the save to finish.
- Fixed: a name made from the Filename rules no longer keeps empty "[]" or "()" when the Studio or Release Date isn't known (it was "Title [] ()", now "Title").
- Fixed: after a file was edited in place and its folder renamed, a hidden backup copy (".name.m3-backup") was left in the renamed folder. The backup is now removed as soon as the edit succeeds.

## 1.0.5 (2026-10-11)

- Fixed: in a Media Locations or Filename rule, the value list for **Media Kind** was empty, and a typed value such as "Movie" never matched because the file stores Media Kind as a number. The list now offers the same names as the Metadata tab (Movie, TV Show and so on), and they match. **Content Rating** gets its list too.
- Improved: when the Queue looks up a title by itself it now searches every provider enabled on the Providers tab and merges the results of those that found the same title. The provider chosen in the Queue options is the primary one; blank fields are filled from the others, cast, genre and crew lists are combined, the longest description is kept, and artwork from all of them is pooled. A provider that found a different title is ignored. Editing a single file still uses the provider you choose.
- Improved: a file edited where it sits (a file already in the staging folder or another delivery folder) is copied aside first, in a hidden file next to it, and put back if the edit fails or M3 is quit part-way. The copy is deleted when the edit is done. On APFS the copy is instant and takes no extra space; if there is no room for a copy the edit goes ahead without one.
- Removed: the **Send to TV** checkbox in the Queue options. Finished files are delivered by the Media Locations settings (staging folder or straight to the library), so a separate send to the TV app only caused confusion.
- Fixed: a release that was merging when M3 was quit came back stuck as "merging" and could not be removed or retried. It now comes back as a failed merge, and Edit reopens the merge sheet.
- Fixed: a Set chosen in the Queue options was not applied to releases coming through the Intake workflow (only to files added by hand). It is now applied after the online search, and its values win over what the search found: every tag the Set fills in replaces the searched value, and tags it leaves blank keep the searched value. Nothing else is erased.
- Fixed: the **Artwork Position** choice in General preferences was never saved, so the Queue ignored it. It is now saved at once and the Queue always follows it.
- Improved: the Media Intake, Filename and Sets tabs have a heading and short description at the top, like the other tabs. The Sets description explains what Sets are and how they fit into a workflow. Media Locations explains that Movies and TV Shows are routed by Media Kind with no rule needed. The Media Intake note at the bottom was removed and one tooltip reworded.

## 1.0.4 (2026-10-10)

- Improved: the Library scan reads only each file's tags instead of loading the whole file, which is far lighter on a large or external drive. The status line names the file being read, a file that cannot be read within 20 seconds is listed as unreadable and skipped, and the scan stops with a message if three in a row fail. Slow reads go to the message log.
- Added: a gear button in the Library scan window. It shows the four tags that are always checked (Title, Release Date, Rating, Studio) and lets you tick any other Metadata tag to look for as well; the choice is remembered.
- Added: **Reset Scan…** next to Scan Now (Preferences > Sources > Media Locations). It forgets which files the Incoming Folder scan has already taken in and scans again, so a file or folder you removed from the Queue (or that was skipped) is picked up again. Items already in a Queue are not duplicated.
## 1.0.3 (2026-10-10)

- Fixed: Queue options (search provider, language, artwork, and the other checkboxes) were not remembered after quitting. The Movies and TV Shows queues each saved their own launch-time copy over the other's changes. Only settings you actually changed are saved now.
- Fixed: a file named like "Sample Title [Example Studio] ()" (studio in brackets, year missing) searched for a mangled title (the leading "A" dropped and the studio added to the end) and found nothing. The search now uses just the title in front of the brackets ("Sample Title").
- Fixed: dragging a folder from Finder into the Queue now behaves exactly like the Add button: the folder appears as a group (a folder row followed by its files). Dropping a single file still adds just that file.
- Fixed: adding files or folders that already sit in the staging folder (Ready for Media Library) to the Queue no longer makes a second copy. They are scanned, tagged and renamed where they are; for a movie, its folder is renamed to match. The same applies to any other delivery destination.
- Added: a new install gets a staging folder automatically: "Ready for Media Library" in your Movies folder (change it under Preferences > Sources > Media Locations). An existing choice is never replaced.
## 1.0.2 (2026-10-10)

- Changed: a new Custom Source that is closed without entering anything is discarded instead of staying in the list as "New Source", and clicking **+** again while an empty one exists reopens it rather than adding another. Empty ones left by earlier versions are cleaned up at launch.
- Added: after installing or removing a plugin, Media Metadata Manager offers **Restart Now** or **Later**. If the Queue is processing, a merge is running or a scan is in progress, it lists what is still running and offers **Restart When Finished**: it restarts by itself as soon as that work is done and never interrupts it.

## 1.0.1 (2026-10-10)

- Fixed: the release notes shown in the update window no longer cut long entries off after their first line.
- Added: release tooling keeps older releases in an archive so the update feed lists every version, and the feed is published only after the release download is live.

## 1.0.0 (2026-10-10)

- Added: Media Intake now actually watches the Incoming Folders (file-system events plus a 20-second sweep) and feeds the Queue; **Scan Now** forces a pass. TV episodes go to a separate **TV Shows Queue** window; the movie window is titled **Movies Queue**.
- Added: several Incoming and Automatically-Add folders, with + / - buttons.
- Added: opt-in **Clean up processed files** moves the original parts to the Trash after a successful merge or conversion and logs them in `Cleaned Up Processed Files.txt`.
- Added: the filename parser understands `<date or year>_<uploader>_<Title>_<Studio>_<quality>` uploads.
- Added: Queue rows have labelled Edit / Save buttons; **Save & Close**; default toolbar order Add, Merge, Start, Settings.
- Added: **Support** replaces the dead **Donate…** menu item. A small dialog and a new **Preferences > Support** tab link to GitHub Sponsors for Media Metadata Manager and to the original Subler project, crediting Damiano Galassi. Nothing is shown automatically, and the old subler.org donate page is no longer used. Links live in one place (`SupportLinks` in `PrefsWindowController.swift`). Added `.github/FUNDING.yml`. The new text is English-only for now.
- Added: plugins declare their own settings (an optional `settingsFields` selector). The app builds the **Configure…** form from that, so it contains no plugin-specific code or keys. Plugins are still loaded at launch; after adding one, restart and it appears in Preferences > Sources > Providers.
- Added: tooling for public releases in `Tools/` (clean public export with a safety scan, Sparkle key setup, release build and appcast, and a backup/restore script for your own settings). The app itself ships without plugins or personal configuration.
- Fixed: on the Media Intake tab the Incoming Folders minus button is disabled while only one folder row is left; the plus button on the Automatically Add to Apple TV Folders list works on the blank first row (the default folder is then kept as the first entry).
- Fixed: an automatic merge is written under a hidden temporary name and renamed when complete, so a half-written merged file can no longer be opened or tagged. After a merge, the release goes through the same metadata match as a single file (confident match continues, anything else stops at Metadata Review).
- Added: **Media Locations** tab (Preferences > Sources). The default destination is the Apple TV Automatically Add folder (followed live from the Apple TV app's own Media folder setting when the first row is blank); below it, separate Movies and TV Shows lists of delivery rules: each rule has an enable checkbox, a folder and conditions on the file's tagged metadata (same fields as the Filename rules), and the first matching rule picks the folder. The Ready for Media Library folder is now the **staging folder**. A new **Deliver automatically** switch (off by default) chooses between staging every finished file for your review and sending it straight to its rule's folder or the default destination. Files delivered to an Automatically Add folder go in alone, without a folder of their own.
- Fixed: when the online search finds no match at all, a single-file or merged release now waits at Metadata Review instead of silently continuing with empty tags. Metadata Review now has its own **Search for** box, a Search button and a list of results, so you can search with other words and choose the right title; **Continue Without Metadata** is offered when nothing is found.
- Fixed: the Rating value list in Filename and Destinations rules now follows the General tab's "Show ratings for" setting (previously only USA or Germany by system region, missing the "Movie & TV" ratings of other countries) and offers the exact rating codes that tagged files carry.
- Changed (documentation): a complete flow chart of the whole app (`Documentation/images/app-flow.png`, editable `Documentation/diagrams/M3-app-flow.drawio`) replaces the old Intake-only chart; `pipeline.png` and `stages.png` are updated for the metadata-review, merged-file and delivery changes. Both charts are generated by `Documentation/images/src/flow.py`.
- Added: **Remove finished items from the Queue automatically** (Media Intake tab, off by default): finished rows leave the Queue list as soon as a run completes. Files are never touched.
- Changed: the Automatically Add to Apple TV Folders list moved from the Media Intake tab to the Media Locations tab, where it is the default destination.
- Fixed: a release's file is now searched by the name you approved, not by its own file name. A file called `01.mp4` inside a release used to be searched as "01" when the Queue ran, which could tag it with an unrelated title; the same name now pre-fills the Search Metadata sheet when you open the file from the Queue.
- Changed: comments and examples in the source use neutral sample names.
- Documented: tagging a single file with Edit and Save works in place and moves the folder to Ready for Media Library; no original is kept and nothing goes to the Trash (the Trash is used only by the Queue's opt-in cleanup and by empty-folder cleanup).
- Added: documentation set in the `Documentation` folder (Getting Started, User Guide, internal Design and Project Manual) and a draw.io Media Intake flowchart.
- Fixed: a movie with no title tagged is no longer renamed or put in a "[] ()" folder.
- Fixed: re-adding a file with the same name as one ingested earlier is no longer skipped (remembered paths are forgotten once the file is gone).
- Fixed: even spacing between the Media Intake checkboxes; the empty-folders tooltip now points to the Window menu.
- Changed: iTunes Store artwork is no longer fetched (it was broken and added nothing).
- Ported from upstream Subler: undo/redo for tracks, chapters, metadata and the document UI; improved TVDB series-name matching; a queue decode-crash fix; an opt-in 4K HD Video flag.

- Fixed: MediaMetadataManager could be silently overwritten by a real upstream Subler auto-update, because the old Sparkle update-feed configuration was still pointing at Subler's appcast. Updates now come only from this project's own signed feed.
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

