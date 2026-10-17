# Sample Library (stand-in library server plugin)

A small plugin for Media Metadata Manager (M3) that behaves like a library server but has no server behind it. It lists the video files in a folder and offers made-up details for each one (description, studio, director, cast, genre, rating, release date). It never reads or changes the files.

It exists for three reasons:

- **Documentation screenshots and demos** of the library scan's Source choice, Accept and Send to Queue, with a neutral name instead of a real product's.
- **Testing the library-server path** of the app without running Plex, Jellyfin or Emby.
- **A complete, small example** for anyone writing a library-server plugin. It needs no other library: the principal class answers the same few Objective-C selectors the real plugins do (`pluginName`, `searchMovieWithQuery:`, `loadMovieMetadataWithId:`, `sourceKind`, `listLibraryItems`, `settingsFields`). See `Classes/Plugins/M3MetadataPlugin.swift` in the app for what each one means.

## Build and install

1. Open `SampleLibraryServer.xcodeproj` in Xcode and build. The build copies `SampleLibraryServer.bundle` into `~/Library/Application Support/M3/Plugins/`.
2. Quit and restart M3 (plugins load once, at launch).
3. Preferences → Sources → Providers: **Sample Library** is listed under **Library Servers**. Tick it.
4. Optional: **Configure…** sets the folder to list. Empty means `/Users/Shared/M3-Media2`.

To remove it, delete the bundle from the Plugins folder (or select it in Preferences → Sources → Custom Sources and click −) and restart M3.

## Use

In Scan Library for Missing Metadata, choose **Sample Library** in the **Source** pop-up and scan. Every video in the folder is listed with an orange "Missing - server has: …" cell for each tag the file lacks. Accept writes the typeable values into the files; Send to Queue applies the item by its id.

The details are made up and the same on every run: they are derived from the file's path. A name ending in a year in brackets, such as `Example Film (2012).m4v`, gives that release year.

## Notes

- Do not point it at files you care about when you try Accept: Accept writes the made-up values into them. Use copies.
- Cover art is never offered (`hasCover` is false).
- The plugin has no password, address or key to configure and makes no network requests.
