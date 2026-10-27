# Media Metadata Manager

Media Metadata Manager (M3) is a Mac app for tagging, muxing and organizing your video library. Drop in a movie or TV episode, pick the right match from TMDb, TheTVDB, the iTunes Store or your own sources, and M3 writes clean MP4 metadata with artwork, then files it where you want it.

It is a fork of [Subler](https://github.com/SublerApp/Subler) by Damiano Galassi and its contributors, and it keeps everything Subler does well. See [CREDITS.md](CREDITS.md).

<!-- Add a Queue window screenshot here, e.g. Documentation/images/queue.png:
![The M3 Queue](Documentation/images/queue.png)
-->

## What it does

- **Queue for movies and TV shows.** Add files or folders and M3 sorts them into separate Movies and TV Shows tabs. TV episodes added to the wrong tab move to the right one automatically, and you can turn that off in Settings.
- **Incoming folders.** Point M3 at a download folder and it watches for new releases, proposes clean names, and waits for your approval before anything is renamed or imported.
- **Metadata search with a full preview.** Pick a result and see all of its metadata before you commit. Fields that changed are highlighted, and nothing already in your file is overwritten unless you choose.
- **Many sources.** TMDb, TheTVDB and the iTunes Store are built in. Add your own sources with a JSON field mapping, or install third-party plugins for sources that need more than a mapping.
- **Lossless merge.** Join the parts of one recording end to end with no re-encode, with chapter markers added at the join points.
- **Everything Subler does.** Mux video, audio, chapters, subtitles and closed captions from MP4, MOV and MKV, create Apple-compatible tx3g subtitle tracks, and import raw H.264, AAC, AC3, Scenarist and VobSub streams.

## Install

M3 needs a Mac running macOS 10.13 or later (macOS 11 or later is recommended) and an internet connection for metadata and artwork lookups.

1. Download the latest zip from the [Releases page](https://github.com/MediaMetadataManager/MediaMetadataManager/releases).
2. Unzip it and drag **M3** into your Applications folder.
3. The first time you open it, macOS may say it can't verify the app. Open **System Settings > Privacy & Security**, scroll to the message about M3, click **Open Anyway**, and confirm. On older versions of macOS, right-clicking the app and choosing **Open** does the same thing. You only need to do this once.

M3 checks for updates and offers them in the app. Your settings, sources and plugins live in your own user folders, so updating never touches them.

## Getting started

The [Getting Started guide](Documentation/Getting-Started.md) takes you from your first file to a finished, tagged movie. The [User Guide](Documentation/User-Guide.md) covers every window and setting.

## Support the project

M3 is free. If it saves you time, you can sponsor its development through [GitHub Sponsors](https://github.com/sponsors/MediaMetadataManager). The app's **Support** menu item and **Settings > Support** tab link to the same page. The app also links to the original Subler project so you can support it too.

## Build from source

Clone the repository with its submodules:

```
git clone --recurse-submodules https://github.com/MediaMetadataManager/MediaMetadataManager.git
```

If you already cloned without submodules, run this inside the project folder:

```
git submodule update --init --recursive
```

Open `M3.xcodeproj` in Xcode, choose the **M3** scheme, and click Run.

## License

M3 is open source under the GNU General Public License version 2, inherited from Subler and MP42Foundation. See [LICENSE](LICENSE) and [COPYING](COPYING).
