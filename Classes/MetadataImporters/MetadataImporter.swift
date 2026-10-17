//
//  MetadataImporter.swift
//  Subler
//
//  Created by Damiano Galassi on 27/07/2017.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Custom and plugin metadata sources, Search All Providers, readable
//  language names for provider menus, library-server sources.
//

import Foundation
import MP42Foundation

public enum LanguageType {
    case ISO
    case ISO_639_2
    case custom

    public func displayName(language: String) -> String {
        switch self {
        case .ISO:
            return MP42Languages.defaultManager.localizedLang(forExtendedTag: language)
        case .ISO_639_2:
            let extendedTag = MP42Languages.defaultManager.extendedTag(forISO_639_2: language)
            return MP42Languages.defaultManager.localizedLang(forExtendedTag: extendedTag)
        case .custom:
            return language
        }
    }

    public func extendedTag(displayName: String) -> String {
        switch self {
        case .ISO:
            return MP42Languages.defaultManager.extendedTag(forLocalizedLang: displayName)
        case .ISO_639_2:
            return MP42Languages.defaultManager.extendedTag(forLocalizedLang: displayName)
        case .custom:
            return displayName
        }
    }

    public func tag(displayName: String) -> String {
        switch self {
        case .ISO:
            return MP42Languages.defaultManager.extendedTag(forLocalizedLang: displayName)
        case .ISO_639_2:
            let extendedTag = MP42Languages.defaultManager.extendedTag(forLocalizedLang: displayName)
            return MP42Languages.defaultManager.iso_639_2Code(forExtendedTag: extendedTag)
        case .custom:
            return displayName
        }
    }
}

public protocol MetadataService {

    var languageType: LanguageType { get }
    var languages: [String] { get }
    var defaultLanguage: String { get }

    var name: String { get }

    func search(tvShow: String, language: String) -> [String]
    func search(tvShow: String, language: String, season: Int?, episode: Int?) -> [MetadataResult]
    func loadTVMetadata(_ metadata: MetadataResult, language: String) -> MetadataResult

    func search(movie: String, language: String) -> [MetadataResult]
    func loadMovieMetadata(_ metadata: MetadataResult, language: String) -> MetadataResult

}

public enum MetadataNameSearch {
    case tvNameSearch(service: MetadataService, tvShow: String, language: String)

    public func search(completionHandler: @escaping ([String]) -> Void) -> Runnable {
        switch self {
        case let .tvNameSearch(service, tvShow, language):
            return RunnableTask(search: service.search(tvShow: tvShow, language: language),
                                              completionHandler: completionHandler)
        }
    }

}

public enum MetadataType : Int, CustomStringConvertible, Codable {
    public var description: String {
        switch self {
        case .movie:
            return "Movie"
        case .tvShow:
            return "TV"
        }
    }

    case movie
    case tvShow
}

public enum MetadataSearch {
    case movieSeach(service: MetadataService, movie: String, language: String)
    case tvSearch(service: MetadataService, tvShow: String, season: Int?, episode: Int?, language: String)

    public func search(completionHandler: @escaping ([MetadataResult]) -> Void) -> Runnable {
        switch self {
        case let .movieSeach(service, movie, language):
            return RunnableTask(search: service.search(movie: movie, language: language),
                                              completionHandler: completionHandler)
        case let .tvSearch(service, tvShow, season, episode, language):
            return RunnableTask(search: service.search(tvShow: tvShow, language: language, season: season, episode: episode),
                                              completionHandler: completionHandler)
        }
    }

    public func loadAdditionalMetadata(_ metadata: MetadataResult, completionHandler: @escaping (MetadataResult) -> Void) -> Runnable {
        switch self {
        case let .movieSeach(service, _, language):
            return RunnableTask(search: service.loadMovieMetadata(metadata, language: language),
                                              completionHandler: completionHandler)
        case let .tvSearch(service, _, _, _, language):
            return RunnableTask(search: service.loadTVMetadata(metadata, language: language),
                                              completionHandler: completionHandler)
        }
    }

    public var type: MetadataType {
        switch self {
        case .movieSeach:
            return .movie
        case .tvSearch:
            return .tvShow
        }
    }
}

extension MetadataSearch {

    /// Plugin-provided movie sources, loaded once at first use from
    /// ~/Library/Application Support/Subler/Plugins -- see
    /// MetadataPluginLoader and M3MetadataPlugin. Empty when no
    /// plugin bundles are installed, which is the common case; nothing
    /// else here behaves any differently when it's empty.
    private static let pluginServices: [PluginMetadataService] = MetadataPluginLoader.loadPlugins().map { PluginMetadataService(plugin: $0) }

    /// User-configured, JSON-field-mapped sources from the Custom Sources
    /// tab -- see CustomMetadataSource / MetadataPrefs.customMetadataSources.
    private static var customSources: [CustomMetadataSource] {
        MetadataPrefs.customMetadataSources
    }

    private static var customMovieSourceNames: [String] {
        customSources.filter { $0.mediaTypes.contains(.movie) }.map { $0.name }
    }

    private static var customTVSourceNames: [String] {
        customSources.filter { $0.mediaTypes.contains(.tvShow) }.map { $0.name }
    }

    /// Subler's original, credential-free movie providers -- the ones that
    /// can be turned on or off from the "Movies" list in Preferences >
    /// Sources > Providers. Custom sources aren't part of this toggleable
    /// "core" set: they're always available and are configured instead on
    /// the Custom Sources tab.
    public static var coreMovieProviders: [String] { return [AppleTV().name, TheMovieDB().name, TheTVDB().name, iTunesStore().name] }

    /// Same as `coreMovieProviders`, but for the "TV Shows" list.
    public static var coreTVProviders: [String] { return [AppleTV().name, TheMovieDB().name, TheTVDB().name, iTunesStore().name] }

    /// Every installed plugin's name (see pluginServices above), in the
    /// order MetadataPluginLoader found them. Unlike a Custom Source,
    /// there's nothing to configure per plugin from within Subler -- a
    /// plugin is just on or off, same as a core provider -- so these are
    /// listed in their own "Plugins" section of the Providers tab (see
    /// SourcesPrefsViewController) with the same kind of checkbox, rather
    /// than on the Custom Sources tab.
    public static var pluginMovieProviders: [String] { return pluginServices.map { $0.name } }

    /// The installed plugins that are searched by title on the web (the
    /// default kind). Preferences > Sources > Providers lists these in the
    /// Movies column, next to the built-in providers.
    static var onlinePluginMovieProviders: [String] {
        return pluginServices.filter { $0.isLibraryServer == false }.map { $0.name }
    }

    /// The installed plugins that are library servers, switched on or off
    /// alike: Preferences > Sources > Providers lists these under "Library
    /// Servers". (libraryServerServices below is only the switched-on ones.)
    static var libraryServerProviderNames: [String] {
        return pluginServices.filter { $0.isLibraryServer }.map { $0.name }
    }

    /// True when the plugin bundle with this file name (without ".bundle")
    /// was loaded at launch and declares itself a library server. A bundle
    /// that did not load, or was installed after launch, counts as online.
    static func isLibraryServerBundle(named bundleName: String) -> Bool {
        _ = pluginServices   // makes sure loadPlugins() has run
        return MetadataPluginLoader.libraryServerBundleNames.contains(bundleName)
    }

    /// The installed plugins that declare themselves library servers (see
    /// M3MetadataPlugin.sourceKind) and are not switched off in
    /// Preferences > Sources > Providers: the Library scan's Source choices.
    static var libraryServerServices: [PluginMetadataService] {
        return pluginServices.filter { $0.isLibraryServer && MetadataPrefs.disabledMovieProviders.contains($0.name) == false }
    }

    /// The installed plugin with this provider name, if any. Used by the
    /// Providers tab to ask a plugin which settings it wants shown.
    static func plugin(named name: String) -> M3MetadataPlugin? {
        return pluginServices.first(where: { $0.name == name })?.plugin
    }

    /// Every movie provider that can appear in the Search Metadata dialog and
    /// the batch queue options: the core providers above, any always-on
    /// custom source configured on the Custom Sources tab that offers
    /// Movies, and any installed plugin.
    public static var allMovieProviders: [String] { return coreMovieProviders + customMovieSourceNames + pluginMovieProviders }

    /// Every TV provider that can appear in the Search Metadata dialog and
    /// the batch queue options: the core providers above, plus any custom
    /// source configured on the Custom Sources tab that offers TV Shows.
    public static var allTVProviders: [String] { return coreTVProviders + customTVSourceNames }

    /// The movie providers to actually offer, with anything the user
    /// disabled in Preferences > Sources > Providers removed. Core
    /// providers and plugins are both filterable this way (sharing the same
    /// disabledMovieProviders set, since a plugin name can never collide
    /// with a core provider's); custom sources are always-on and are never
    /// filtered -- same as they're left out of the Providers tab's checkbox
    /// list entirely and managed only from the Custom Sources tab. Falls
    /// back to every core provider if disabling would otherwise leave none
    /// enabled, so the popup always keeps at least one Subler-native
    /// option -- that fallback doesn't extend to plugins, since having zero
    /// of them enabled (or installed) is the normal, common case.
    public static var movieProviders: [String] {
        let enabledCore = coreMovieProviders.filter { !MetadataPrefs.disabledMovieProviders.contains($0) }
        let core = enabledCore.isEmpty ? coreMovieProviders : enabledCore
        let enabledPlugins = pluginMovieProviders.filter { !MetadataPrefs.disabledMovieProviders.contains($0) }
        return core + customMovieSourceNames + enabledPlugins
    }

    /// The TV providers to actually offer -- see `movieProviders`. Custom
    /// TV sources are always-on, same as their movie counterparts.
    public static var tvProviders: [String] {
        let enabledCore = coreTVProviders.filter { !MetadataPrefs.disabledTVProviders.contains($0) }
        let core = enabledCore.isEmpty ? coreTVProviders : enabledCore
        return core + customTVSourceNames
    }

    public static func service(name: String?) -> MetadataService {
        switch name {
        case AppleTV().name?:
            return AppleTV()
        case iTunesStore().name?:
            return iTunesStore()
        case TheMovieDB().name?:
            return TheMovieDB()
        case TheTVDB().name?:
            return TheTVDB()
        default:
            if let name = name, let plugin = pluginServices.first(where: { $0.name == name }) {
                return plugin
            }
            if let name = name, let source = customSources.first(where: { $0.name == name }) {
                return CustomSourceService(source: source)
            }
            return TheMovieDB()
        }
    }

    public static var defaultMovieService: MetadataService {
        get { MetadataSearch.service(name: MetadataPrefs.movieImporter) }
        set { MetadataPrefs.movieImporter = newValue.name }
    }

    public static var defaultTVService: MetadataService {
        get { MetadataSearch.service(name: MetadataPrefs.tvShowImporter) }
        set { MetadataPrefs.tvShowImporter = newValue.name }
    }

    public static func defaultLanguage(service: MetadataService, type: MetadataType) -> String {
        let language = UserDefaults.standard.string(forKey: "SBMetadataPreference|\(type.description)|\(service.name)|Language") ?? service.defaultLanguage
        return service.languageType.displayName(language: language)
    }

    public static func setDefaultLanguage(_ language: String, service: MetadataService, type: MetadataType) {
        let language = service.languageType.tag(displayName: language)
        UserDefaults.standard.set(language, forKey: "SBMetadataPreference|\(type.description)|\(service.name)|Language")
    }

    /// One provider's hit from a searchAllMovieProviders(title:) fan-out
    /// -- a flat struct (not the much larger MetadataResult) since a
    /// results picker only ever needs a provider name, a title, and a
    /// year to show and sort by. See NamingReviewWindowController's
    /// "Search All Providers..." second pass (Intake/Queue workflow
    /// design doc, section 7c).
    public struct ProviderSearchHit {
        public let provider: String
        public let title: String
        public let year: String?
    }

    /// Searches every provider in movieProviders for `title`, one at a
    /// time (RunnableTask.run() is a blocking, synchronous call -- same
    /// constraint NamingReviewWindowController.beginSearch() already
    /// works within), and collects each provider's own first result into
    /// one combined list -- unlike beginSearch()'s own search, which
    /// stops at the very first provider that answers at all. `title`
    /// should already be the bare title with no year riding along in it:
    /// year is meant to disambiguate between these results afterward,
    /// never to narrow the query sent to a provider. A provider that
    /// errors, times out, or returns nothing simply contributes no entry
    /// -- never a placeholder -- so the combined list is exactly as long
    /// as the number of providers that actually found something. Call
    /// this off the main thread: it blocks for as long as every enabled
    /// provider takes to answer, one after another.
    public static func searchAllMovieProviders(title: String) -> [ProviderSearchHit] {
        return movieProviders.compactMap { providerName -> ProviderSearchHit? in
            let service = MetadataSearch.service(name: providerName)
            let language = MetadataSearch.defaultLanguage(service: service, type: .movie)
            let search = MetadataSearch.movieSeach(service: service, movie: title, language: language)

            var results: [MetadataResult] = []
            search.search(completionHandler: { results = $0 }).run()

            guard let hit = results.first,
                  let onlineTitle = hit[.name] as? String,
                  onlineTitle.isEmpty == false
            else { return nil }

            let onlineYear = ParsedMediaName.firstFourDigitYear(in: hit[.releaseDate] as? String)
            return ProviderSearchHit(provider: providerName, title: onlineTitle, year: onlineYear)
        }
    }

}

extension LanguageType {

    /// What a menu shows for one of a service's language codes. A code the app
    /// has no name for is shown as it is, never as "Undetermined".
    public func menuName(for code: String) -> String {
        let name = displayName(language: code)
        if self == .ISO_639_2, code != "und",
           name == MP42Languages.defaultManager.localizedLang(forExtendedTag: "und") {
            return code
        }
        return name
    }

    /// The menu names for a service's language codes, in the same order.
    public func menuNames(for codes: [String]) -> [String] {
        return codes.map { menuName(for: $0) }
    }

    /// The service's own code for a name picked from a menu built from `codes`,
    /// or nil if no code in the list has that name.
    public func code(forMenuName name: String, among codes: [String]) -> String? {
        return codes.first { menuName(for: $0) == name }
    }
}
