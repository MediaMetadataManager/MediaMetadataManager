# Credits

## Subler

Media Metadata Manager is a fork of [Subler](https://github.com/SublerApp/Subler),
an app for muxing and tagging MP4/MOV/MKV files. Subler's engineering and
human interface design is by **Damiano Galassi**, with project contributors
including Douglas Stebila, Priit Varik, Ryan Walklin, Bicus, Odibi, and
maury.markowitz (per Subler's own About-panel credits).

All of the original muxing, tagging, chaptering, and file-handling code in
this app -- the foundation everything else here is built on -- is Subler's
code, unmodified except where noted in this project's own commit history.

## Supporting the project and the original author

Donations to Media Metadata Manager go through
[GitHub Sponsors](https://github.com/sponsors/MediaMetadataManager). The
app's Support dialog and Preferences > Support tab also link to the original
Subler project, because Subler and its author, **Damiano Galassi**, are the
foundation of this app. Subler's own donate page (subler.org/donate.php) no
longer works; the link in the app (`SupportLinks.originalAuthorSupportURL`)
is updated if upstream publishes a working one.

## MP42Foundation

The underlying media framework that Subler and this app both depend on is
[MP42Foundation](https://github.com/SublerApp/MP42Foundation), also
primarily authored by **Damiano Galassi**, with contributions from Brian
Gerfort, Andrew Hyatt, Clemens Schulz, Travis Cobbs, Blair Replogle,
Ching-Lan Huang, arnnalddo, and others credited in its own commit history.

## Metadata providers and third-party resources

Subler and this app use TMDb (TheMovieDB) and TheTVDB as metadata sources
(this product uses the TMDb API but is not endorsed or certified by TMDb),
and build on Tesseract, the Perian Project, HandBrake, mp4v2, FFmpeg, and
the Video::Filename Perl library by Behan Webster. See the app's own
About-panel credits for links.

## License

Subler and MP42Foundation are licensed under the GNU General Public License
version 2 (GPLv2) -- see `LICENSE` and `COPYING`, carried over unmodified.
Because of GPLv2, Media Metadata Manager is likewise fully open source under
the same terms, and its source is available to anyone it's distributed to.

Media Metadata Manager is currently based on Subler 1.9.2; upstream Subler
has since moved on to 1.9.3. This note is updated by hand whenever code is
merged in from upstream -- there's no automatic tracking (Sparkle
auto-update is deliberately disabled, see AppDelegate.swift and the
commit history, so nothing updates this fork's version on its own).

## Media Metadata Manager

The features, fixes, and rebrand specific to Media Metadata Manager --
including the Media Intake Manager and Queue-based naming/merge workflow,
the file-merge feature, the custom JSON-mapped
metadata source system, the third-party metadata plugin loader, the
Providers preferences pane, the "Open and Save" toolbar button, the
editable custom Rating field, the cover-art overwrite fix, the
blank-placeholder-fields merge fix, and this project's split from
Subler -- were made by **Hans Hoffmeister**.
