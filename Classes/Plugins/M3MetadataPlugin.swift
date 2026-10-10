//
//  M3MetadataPlugin.swift
//  Subler
//
//  The interface a dynamically-loaded metadata-source plugin bundle must
//  implement. See MetadataPluginLoader.swift for how a plugin gets found
//  and loaded, and PluginMetadataService.swift for how a loaded plugin is
//  wrapped so it behaves exactly like a built-in provider everywhere
//  Subler uses MetadataService.
//
//  This file is deliberately the ONLY thing shared between Subler's own
//  source and a plugin project -- it references nothing else in Subler
//  (no MetadataResult, no MP42Foundation, nothing internal), just
//  Foundation types. That keeps a plugin project free to build and
//  version itself entirely independently: it only ever needs this one
//  small protocol, never Subler's own source or Xcode project.
//
//  A plugin project gets this protocol from a small shared package
//  (M3PluginKit) rather than a relative file reference into this repo.
//  This copy, compiled directly into the app itself, is kept separate on
//  purpose -- if this protocol changes, mirror the change into that
//  package's copy of this file by hand.
//

import Foundation

/// A dynamically-loaded metadata-source plugin. A plugin is a normal
/// loadable bundle (.bundle) placed by the user in
/// ~/Library/Application Support/Subler/Plugins -- see
/// MetadataPluginLoader. The bundle's principal class (declared as
/// NSPrincipalClass in its Info.plist) must be an NSObject subclass with
/// a plain, parameterless init() that conforms to this protocol.
///
/// Movie search only, for now -- there's no TV show equivalent yet.
///
/// Every requirement below pins an explicit Objective-C selector with
/// @objc(...). That's not decorative: Subler talks to a loaded plugin
/// purely via Objective-C message sends (see PluginBridge.swift), never
/// via a Swift `as?` cast to this protocol, because this same source
/// file is compiled separately into Subler.app and into each plugin
/// bundle -- two separate compilations of "the same" Swift protocol are
/// two distinct, non-interchangeable types at the Swift runtime level,
/// so a Swift-level cast across that boundary always fails even when a
/// plugin correctly implements everything. Pinning the selectors here
/// keeps both sides of that boundary in agreement no matter what
/// Swift's own (otherwise deterministic) selector-synthesis rules would
/// have picked.
@objc public protocol M3MetadataPlugin: NSObjectProtocol {

    /// A stable, human-readable name for this source. Shown in the
    /// Search Metadata dialog and batch queue provider popups exactly
    /// like a built-in provider's name, so it should be short and not
    /// collide with an existing provider's name.
    @objc(pluginName)
    var pluginName: String { get }

    /// Searches for a movie by title. Each result dictionary must at
    /// least contain "id" (String) -- an opaque identifier this plugin
    /// will recognize when it comes back via loadMovieMetadata(id:) --
    /// and "title" (String). All other keys are optional:
    ///   - "releaseDate": String, "yyyy-MM-dd"
    ///   - "synopsis": String
    ///   - "studio": String
    ///   - "director": String
    ///   - "series": String
    ///   - "cast": [String]
    ///   - "genre": [String]
    ///   - "artworkURLs": [String], each an absolute image URL
    ///   - "ratingCountry": String, e.g. "USA" -- paired with "ratingName"
    ///     below to look up a real content-rating board entry in Subler's
    ///     own ratings table (the same one iTunes Store results use).
    ///     Both must be present together to have any effect.
    ///   - "ratingName": String, e.g. "PG-13" or "NC-17" -- the rating
    ///     board's own name for the rating, as Subler's ratings table
    ///     spells it.
    ///   - "contentRating": Int, the raw iTunes content-rating flag
    ///     (0 = none, 2 = Clean, 4 = Explicit).
    /// Any key that isn't relevant or available can simply be omitted.
    @objc(searchMovieWithQuery:)
    func searchMovie(query: String) -> [[String: Any]]

    /// Loads full metadata for one search result, identified by the "id"
    /// value that result carried. Returns a dictionary using the same
    /// key set as searchMovie's results, filled in as completely as
    /// possible. Return an empty dictionary if the id can no longer be
    /// resolved (e.g. the page was removed).
    @objc(loadMovieMetadataWithId:)
    func loadMovieMetadata(id: String) -> [String: Any]

    /// Optional: loads chapter markers for one search result, identified
    /// by the same "id" value passed to loadMovieMetadata(id:). Each
    /// dictionary in the returned array must contain "name" (String) and
    /// "timestamp" (an Int/NSNumber of milliseconds from the start of the
    /// movie), in playback order. Return an empty array (or simply don't
    /// implement this) if the source has no chapter/scene data.
    ///
    /// Marked `optional` (valid since this protocol is already @objc) so
    /// existing plugins that predate this requirement, like the sample
    /// PlexPlugin, keep conforming without changes.
    @objc(loadChaptersWithId:) optional
    func loadChapters(id: String) -> [[String: Any]]

    /// Optional: called once, right before this plugin's bundle file is
    /// deleted from disk -- the user clicking "-" on it in
    /// Preferences > Sources > Custom Sources (see
    /// CustomSourcesListViewController.removePlugin(at:)). Its purpose is
    /// to make "-" a genuinely clean uninstall rather than just a file
    /// delete: a plugin that keeps its own configuration somewhere
    /// outside the bundle itself -- an API key or base URL saved to
    /// UserDefaults, for example -- should implement
    /// this to remove that state too, so nothing of the plugin is left
    /// behind once it's gone. A plugin with no such external state
    /// simply has no reason to implement this.
    ///
    /// Called on the main thread; expected to return quickly (this runs
    /// synchronously as part of handling the button click, before the
    /// confirmed removal proceeds). Any failure should be handled
    /// silently -- there's no UI for reporting a partial cleanup, and a
    /// plugin being uninstalled is not a good moment to surface an error
    /// about it.
    ///
    /// Marked `optional`, like loadChapters(id:) above, so existing
    /// plugins that predate this requirement keep conforming without
    /// changes; a plugin with no external state has nothing to clean up.
    @objc(uninstall) optional
    func uninstall()

    /// Optional: the settings this plugin needs the user to enter -- an
    /// API key, a server address, and so on. When a plugin returns a
    /// non-empty array, Preferences > Sources > Providers shows a
    /// "Configure..." button next to its checkbox, with one text field
    /// per entry. The app knows nothing else about the plugin: it just
    /// reads and writes the UserDefaults key each entry names, and the
    /// plugin reads that same key itself.
    ///
    /// Each dictionary must contain:
    ///   - "key": String, the UserDefaults key the value is stored under
    ///   - "label": String, shown above the field
    /// and may contain:
    ///   - "placeholder": String, hint text shown in an empty field
    ///   - "secure": Bool, true to mask the field (API keys, tokens)
    ///
    /// Saving an emptied field removes the key entirely, so the plugin's
    /// own default applies, exactly as if it had never been set.
    ///
    /// Marked `optional`, like the requirements above, so plugins that
    /// predate it keep working; they simply get no Configure button.
    @objc(settingsFields) optional
    func settingsFields() -> [[String: Any]]
}
