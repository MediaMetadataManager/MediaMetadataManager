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

## 1.3.0 (2026-10-17)

- Improved: the screenshots in the User Guide, the Getting Started Guide and the Help window were all retaken from the current version, so each window shown matches what you see: Preferences, the Queue with its review windows (naming, metadata, merge order) and Options panel, the Library scan, the editor and its metadata search, and the Message Log.
- New: the User Guide's "Searching for metadata" section now shows the Search Metadata window with a result selected, and the Queue section shows an opened folder and the Library scan editing files in place.
- Improved: the Word and PDF copies of both guides were rebuilt with the new pictures.

## 1.2.3 (2026-10-16)

- Changed: in **Preferences → Metadata**, the **Add** menu greys out an annotation that already has a row, so it cannot be added twice. Remove the row and it is offered again. Values stay available to use in any number of cells. The same goes for the tag menu when you edit a **Set**: a tag the Set already has is greyed out until you remove it.
- New: **Help** is now a Help window inside the app, built from the guides, with a search box and a list of topics. **Help → Media Metadata Manager Help** opens it. The Help menu's search box finds help topics as well as menu commands (it points at the command in the menu). The Welcome, Editor, Queue, Message log, Library scan and Preferences windows, the Queue's review windows (naming, metadata, choose a match, merge order) and the Queue Options panel have a **?** button that opens the matching section (in the Queue, Editor and Preferences toolbars it is the last item; in the Library scan window it is beside the gear; in Queue Options it is in the top right corner). The Queue and Editor toolbars start from their default layout once, because of the new item. The Help window can be used while a review window is open. The Help menu also opens the Getting Started Guide, the User Guide as a PDF, What's New and Report an Issue. Before, the Help item opened the project's web page.

## 1.1.2 (2026-10-16)

- New: the Library scan window has a **Clear** button (bottom left, after Send to Queue) and a right-click **Clear List** that empty the list once files are loaded. The folder stays chosen and the columns stay, so Scan starts again from it, and no file is changed. Both are off while a scan is running (press Stop first) and while a tag is being written.
- Fixed: the Library scan and the Queue showed Content Rating and Media Kind as their stored numbers (4, 9, 10). They now show the names the Editor uses (Explicit, Movie, TV Show), and a Rating such as "mpaa|R|300|" shows as "R". A code the lists do not know still shows as the number.
- New: the Queue options have an **Existing tags** choice under Artwork, for what the search does with tags a file already has: **Use Preferences** (follows Preferences > Metadata), **Fill missing only** (a tag that already has a value is never changed), **Append (add artwork)** (also adds new artwork next to the existing artwork) or **Overwrite**. A **Keep empty annotations** checkbox below it applies when the choice is not Use Preferences. Before this the Queue always overwrote, whatever the preferences said; it now follows Preferences > Metadata unless you choose otherwise, so with the default preferences a file's existing tags are kept and only the gaps are filled. A Queue saved by an earlier version opens with Use Preferences.
- New: **Pause** in the Library scan window. The scan finishes the file it is reading, shows what it has found so far and waits; **Resume** carries on from the same place. The scan buttons now sit in the bottom row (Pause, Scan, Done) and only the options (gear) button stays at the top right. While scanning, Scan reads **Stop** (it was Cancel) because the files found so far stay in the list; Stop or closing the window ends a scan, even a paused one.
- New: the Queue's columns can be sorted, resized and rearranged. The tag columns from a Library scan sort like the others (click the heading; files with no value come first, numbers sort as numbers; the files that have not been read yet are read first). Drag a heading to move a column anywhere between "#" and Actions; drag its edge to make it wider or narrower. The Library scan table now remembers its column order, widths and sort between scans and launches.
- New: files sent from the Library scan to the Queue bring the scan's tag columns with them (Title, Release Date and any extra tags), so you can watch the gaps being filled. Each file starts with the values the scan found (a red "Missing" for a gap) and is read again when the Queue has finished it, so the cell shows the tag that was written. The columns sit before Actions and go away when no such file is left in the Queue.
- New: fix the gaps found by a Library scan without leaving the window. Right-click a tag cell and choose **Edit…** to type a value, which is written straight into that file (a copy of the file is kept until the write has worked, and put back if it fails). Rating, artwork and other tags that are not plain text, numbers or dates are still changed in the Editor. You can also select files (Command-A for all, or Shift/Command-click) and choose **Send Selected to Queue…** (or **Send All to Queue…** when nothing is selected, or right-click > Send to Queue for In-Place Edit): the Queue searches for the metadata and writes the tags into each file where it sits, with no copy and no move to the library (and, when "Set output filename" is on in the Queue options, renames the file from its tags).
- Improved: the Library scan table now has a column for each tag being checked (Title and Release Date, plus any ticked in the gear panel), showing the file's value or a red "Missing". Columns can be made wider or narrower or dragged into a different order, a click on a heading sorts by it (with an arrow showing the direction; missing values come first), and the window opens larger and remembers the size you give it. Ticking a tag in the gear panel adds its column straight away.
- Changed: the Library scan now checks only Title and Release Date on every scan. Rating and Studio are no longer checked by default; they are in the gear panel's "Also look for" list and can be ticked if you want them.
- Fixed: the Genre drop-down in the editor (and in Sets) offered only ten TV categories, and could show items left over from another drop-down. It now lists the usual movie and TV genres in name order. You can still type any genre you like, and a genre you type is kept and offered in the list from then on.
- New: Preferences > Metadata has an **Edit My Genres…** button. It opens a list of the genres you have typed into the Genre box, where you can correct a misspelling (double-click it), add one, or remove one. Files already tagged with the old spelling are not changed.
- Fixed: a folder row that was waiting for a merge order kept asking for one after the other files were taken out of the folder in Finder and only one was left. When the folder is read again (when you open the row, or in the background) a folder with a single file is now treated as a single-file release and goes on to metadata, with no merge order.
- Fixed: the review windows (naming, merge order, metadata search and "already merged") could open behind other windows. They now always open on top of the app's other windows, still centred over the Queue and still movable.
- Fixed: a movie with its subtitle file beside it (an .mp4 and an .srt, for example) showed as "Needs merge order", as if the subtitle were a second part. A subtitle file (.srt, .ass, .ssa) beside a video is no longer counted as a part: the movie is one file, it is never merged, and the subtitles are embedded in the finished file. This covers folders and loose files in an Incoming Folder, and folders added by hand. With "Clean up processed files" on, the subtitle files that were embedded are moved to the Trash with the other originals. When a folder holds several parts, subtitle files are left alone.
- Fixed: dragging a TV show folder (a show folder holding Season folders) onto the Queue added nothing, because only the folder's own files were looked at. Folders are now searched a few levels down and each Season folder is added as its own group, on either tab.
- Changed: files added by hand are now always sorted onto the right tab. A movie dropped or added on the TV Shows tab goes to the Movies tab (1.1.1 left it on the TV Shows tab), and the status line says so. The "Send TV episodes to the TV Shows tab" checkbox in Media Intake is gone, since sorting is always wanted; a file that is sorted wrongly can have its media type changed in Edit.
- New: folder rows in the Queue can be opened and closed with the triangle in front of them (or the right and left arrow keys). Option-click the triangle to open or close them all. Folders start open, on the Movies and TV Shows tabs alike, and closing one hides its files without removing them.
- Fixed: adding the same files or folder to the Queue again added them a second and third time. Files that are already in the Queue and not yet completed are now skipped, and the status line says how many were left out. A completed file can still be added again.
- Fixed: rows added to the TV Shows tab while it was out of sight could show without their names. That tab is now redrawn when it is added to and when you switch to it.
- Fixed: removing a folder row from the Queue left the files under it behind. It now removes the folder and all its files (files being processed stay, and so does their folder row). Removing a single file keeps the folder row, and removing the last file of a folder removes the folder row too, as before.
- Fixed: a TV season added to the Movies tab as a folder named like "Season 1" (as store purchases are laid out, with no episode marker in the file names) stayed on the Movies tab. Files inside a season folder are now treated as TV episodes and go to the TV Shows tab.
- Improved: the Queue shows a season folder together with the folder above it (for example "Sample Show – Season 1"), so you can tell which show it belongs to.
- Fixed: in the Queue options, the language list for TV Shows showed short lowercase codes (such as "eng") when TheTVDB was the source. It now shows language names, the same as the Movies list, and your choice is still saved as the source's own code.

## 1.1.1 (2026-10-15)

- New: TV episodes added by hand to the Movies tab (Add button, drag and drop, File > Open) are put on the TV Shows tab automatically, and the status line says so. A folder holding both movies and episodes is split file by file. Movies added to the TV Shows tab are left alone. A new checkbox in Settings > Media Intake turns this off.
- Fixed: the app could quit when you clicked Search Metadata for a TV episode and a result's details were shown in the search window. The list of fields is now always built from the result as it is, in one fixed order, and the table no longer stops the app if a row or its sizing cell is missing.
- Removed: leftover internal code for the old "Send to TV" Queue option (the option itself was removed in 1.0.5).
- Improved: the User Guide now describes the TV episode setting and the option to run the Movies and TV Shows queues at the same time, and the README on GitHub has been rewritten with install and update notes.

## 1.1.0 (2026-10-11)

- New: the Merge Order window now has a tick box beside each file, so a file can be left out of the merge (and the box starts unticked for a file that is about as big as all the others together, which is probably a merge already made). Merge is judged on the ticked files only.
- Improved: the Queue's review windows (naming, merge order, metadata search and "already merged") now open centred over the Queue but can be dragged aside, so the list and its Status column stay readable while you decide.
- New: a folder in the Queue that is still waiting to be named or merged now has a disclosure triangle. Click it (or press the Right/Left arrow keys on the selected folder) to list the files inside, Finder-style; Option-click opens or closes every folder at once. The listed files are for looking at only for now. Folders in the Queue also show a folder icon.
- Improved: the Queue window now has the same look as the tabs in Settings (such as Media Intake): small Movies / TV Shows tabs in a bordered panel set in from the window edge.
- Improved: while a folder is being merged, each of its files listed in the open folder shows "Merging" in the Status column ("Merge failed" if it did not work).
- Improved: a merge now shows its progress in the Queue ("Merging 42%" on the folder and on each of its files), and the progress bar and status line at the bottom follow the merge ("Merging <name> 42%") the same way they follow a file being processed, so a long merge no longer looks stuck.
- Fixed: in the Review Metadata window, results with exactly the same title were merged into one line in the list, so picking one could open a different result than the one chosen. Every result now has its own line.
- Improved: if a queued file was renamed in Finder and it is the only media file left in its folder, Edit finds it and carries on instead of saying it can't be found (the Queue entry follows the new name).
- Improved: Show in Finder now works for every Queue row, not just finished ones: it shows the file (or the folder of a folder row), and if that has been moved or renamed it opens the closest folder that still exists.
- Improved: when a queued file cannot be found, the message now names the folder it was looked for in and offers Find…, which lets you pick the file's new name or place; the Queue entry then follows it.
- New: once a folder has been merged, its part files show "Merged" in the Status column.
- Fixed: half-written merge files (hidden ".merging" files) left behind when M3 was quit or crashed during a merge are removed the next time M3 starts.
- New: the Review Metadata window has a "Search with" menu listing the sources switched on in Settings. The first search works as before; pick another source and it searches again there, and the match you choose from it is the one applied.
- Improved: in the Review Metadata window, results that share the same title (some sources list only titles) now get their year and studio added to the line once the details load, so the right one can be told apart.
- Improved: files changed outside the app now show up in the Queue when you come back to its window: sizes are re-read, and a folder still waiting to be named or merged picks up files that were added, removed or renamed in Finder. Clicking Edit (or double-clicking) also re-reads that folder or file from disk first, so the window that opens shows what is there now; if the file has been moved, renamed or deleted, you are told so instead of getting an error.
- Fixed: a movie title that a source printed with promotion text after it (such as a sale notice, set apart by line breaks or a long run of spaces) is now cut back to the real title, so searches and file names stay clean.
- New: when a release folder already holds a merged file (one about as big as all the other files together), the Queue no longer merges the parts again. The release is set aside with the status "Already merged: review"; double-click it to use the merged file, or to merge the parts anyway (the existing merged file is kept and renamed with " - OLD" added).
- New: the Movies and TV Shows queues now share one window with a tab for each, so the Queue is a single place to look. The toolbar (Add, Merge, Start, Settings) acts on whichever tab is showing, and the window remembers its position and the last tab used. A TV Show added by Intake opens its tab automatically.
- New: the Movies and TV Shows queues now take turns, one file at a time across both, which is kinder to a single disk. Preferences > Media Intake has a new option, "Run the Movies and TV Shows queues at the same time", for people whose files are on fast drives.
- New: the Queue windows (Movies and TV Shows) now have Name, Status, Size and Type columns. Click a header to sort the Queue by it (A to Z, with numbers in names sorted as numbers) and click again to reverse. Sorting changes the order files are processed in, can be undone with Edit > Undo, and rows can still be dragged. Files added from a folder stay under their folder.
- New: the Queue has a "#" column on the far left showing the order files were added. Click its header to put the Queue back in that order after sorting by another column. The Info and Edit buttons are now in their own column on the right, and the column headers have a tinted background so they stand out.
- New: under the Queue list, a line now shows how many files are in the Queue and how many are done, failed, waiting or need you. While the Queue runs it also shows the time elapsed, about how long is left and when it should finish (judged by file size), and afterwards how long the last run took.
- Improved: when the Queue picks movie cover art it now checks the real size of each image, because Apple TV and the iTunes Store return both portrait and landscape versions. A landscape (or square) image is skipped and the next poster is tried; if none is portrait, no cover is embedded. Images are never rotated.
- Edited: wording in the README and documentation tidied for readability.
- Improved: the Merge Order window now marks the file that doesn't fit the others (different codec, size, timescale or track count) with a warning icon and says why, even when it is the first file. The files are checked in the background when the window opens, so large files on a slow drive no longer freeze it, and dragging to reorder no longer re-reads them.

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

