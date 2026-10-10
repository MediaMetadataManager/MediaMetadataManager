# README #

### What is this repository for? ###

Media Metadata Manager is a Mac OS X app for muxing and tagging MP4/MOV/MKV
files, built as a fork of [Subler](https://github.com/SublerApp/Subler).
See `CREDITS.md` for the full attribution and license details (GPLv2,
inherited from Subler and MP42Foundation).

Main features include:

* Creation of tx3g subtitles tracks, compatible with all Apple's devices (iPod, AppleTV, iPhone, QuickTime?).
* Mux video, audio, chapters, subtitles and closed captions tracks from mov, mp4 and mkv.
* Raw formats: H.264 Elementary streams (.h264, .264), AAC (.aac), AC3 (.ac3), Scenarist (.scc), VobSub? (.idx).
* Metadata editing with TMDb, TheTVDB, iTunes Store, and pluggable custom/third-party metadata sources.
* A Media Intake Manager and Queue-based naming/merge workflow, and a file-merge feature.

### Support the project ###

Media Metadata Manager is free. If it saves you time, you can sponsor its development and upkeep through [GitHub Sponsors](https://github.com/sponsors/MediaMetadataManager). The app's **Support** menu item and **Preferences > Support** tab link to the same page.

It is built on Subler, created by Damiano Galassi and its contributors, and the app also links to the original Subler project so you can support them too.

### Build and run

Clone the repository and include all submodules
```
git clone --recurse-submodules https://github.com/MediaMetadataManager/MediaMetadataManager.git
```
If you already cloned without submodules and need to add the submodules manually, `cd` into the project directory and clone the dependency submodules with
```
git submodule update --init --recursive
```
Open `M3.xcodeproj` in Xcode.

Build and run the project by selecting the 'M3' scheme (`Product` -> `Scheme` -> `M3`) and clicking the 'Run' button in Xcode's toolbar.
