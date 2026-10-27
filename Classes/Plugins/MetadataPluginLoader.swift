//
//  MetadataPluginLoader.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/14/2026.
//
//  Discovers and loads metadata-source plugin bundles. Plugins are
//  entirely optional -- with none installed, Subler behaves exactly as
//  it does with only its built-in providers and JSON-configured Custom
//  Sources. See M3MetadataPlugin.swift for the contract a plugin
//  implements, and PluginMetadataService.swift for how a loaded plugin
//  gets wired into the rest of the app.
//

import Foundation

/// A minimal, UI-only listing of a plugin bundle on disk -- name plus its
/// file URL. Deliberately separate from actually loading/instantiating a
/// plugin (see MetadataPluginLoader.loadPlugins()): the Custom Sources list
/// (CustomSourcesListViewController) needs to show what's installed and let
/// the user remove it, but loading every plugin just to render a row would
/// be wasteful and would run each plugin's own code as a side effect of
/// simply opening Settings.
struct InstalledPlugin {
    let name: String
    let url: URL
    /// True for a plugin that ships inside the app (Contents/PlugIns). It
    /// can't be removed from Settings; installing a bundle of the same name
    /// into the user's Plugins folder takes its place.
    var isBuiltIn: Bool = false
}

enum MetadataPluginLoader {

    /// Where Subler looks for plugin bundles. Not created automatically --
    /// a user installing a plugin creates it (or the plugin's own
    /// installer does), same as QueuePreferences.destination is just a
    /// folder the user picked rather than one Subler manages the
    /// lifecycle of.
    static var pluginsDirectory: URL? {
        return ApplicationSupport.url?.appendingPathComponent("Plugins", isDirectory: true)
    }

    /// Plugins that ship inside the app itself: Contents/PlugIns. The release
    /// script puts the paid library-server plugins there; they stay locked
    /// until a licence key is entered (see PluginLicence).
    static var builtInPluginsDirectory: URL? {
        return Bundle.main.builtInPlugInsURL
    }

    private static func bundleURLs(in directory: URL?) -> [URL] {
        guard let directory = directory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "bundle" }
    }

    /// Combines the user's installed bundles with the ones built into the app.
    /// When both have the same file name the installed one wins, so a plugin
    /// built from source (or an updated one) overrides the built-in copy and
    /// the same plugin is never loaded twice.
    static func mergeBundles(installed: [URL], builtIn: [URL]) -> [InstalledPlugin] {
        let userPlugins = installed.map { InstalledPlugin(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
        let taken = Set(userPlugins.map { $0.name.lowercased() })
        let builtInPlugins = builtIn
            .map { InstalledPlugin(name: $0.deletingPathExtension().lastPathComponent, url: $0, isBuiltIn: true) }
            .filter { taken.contains($0.name.lowercased()) == false }
        return userPlugins + builtInPlugins
    }

    /// Every plugin bundle to consider: installed first, then built-in.
    static func pluginBundleLocations() -> [InstalledPlugin] {
        return mergeBundles(installed: bundleURLs(in: pluginsDirectory), builtIn: bundleURLs(in: builtInPluginsDirectory))
    }

    /// Loads every plugin bundle found in pluginsDirectory. A bundle that
    /// fails to load, or whose principal class doesn't conform to
    /// M3MetadataPlugin, is logged and skipped rather than treated as
    /// fatal -- one broken or incompatible plugin should never keep the
    /// rest of Subler from launching normally.
    static func loadPlugins() -> [M3MetadataPlugin] {
        var libraryServerNames = Set<String>()
        var lockedByBundle: [String: String] = [:]
        let loaded: [M3MetadataPlugin] = pluginBundleLocations()
            .map { $0.url }
            .compactMap { url in
                guard let plugin = loadPlugin(at: url) else { return nil }
                if PluginSourceKind.isLibraryServer(plugin.sourceKind?() ?? PluginSourceKind.online) {
                    libraryServerNames.insert(url.deletingPathExtension().lastPathComponent)
                }
                // A paid plugin without a genuine key for it stays off. It is
                // listed in lockedPluginIDsByBundle so Settings can ask for the key.
                guard PluginLicence.isLicensed(pluginName: plugin.pluginName) else {
                    lockedByBundle[url.deletingPathExtension().lastPathComponent] = PluginLicence.pluginID(forPluginName: plugin.pluginName)
                    NSLog("[MetadataPluginLoader] %@ needs a licence key; not loaded", url.lastPathComponent)
                    return nil
                }
                return plugin
            }
        libraryServerBundleNames = libraryServerNames
        lockedPluginIDsByBundle = lockedByBundle
        return loaded
    }

    /// File names (without ".bundle") of the loaded plugins that declare
    /// themselves library servers. Filled in by loadPlugins(), which runs
    /// once at launch; read it through MetadataSearch.isLibraryServerBundle(named:),
    /// which makes sure that has happened. The Custom Sources list uses it to
    /// file each installed bundle under "Online" or "Library Servers".
    static private(set) var libraryServerBundleNames: Set<String> = []

    /// Installed paid plugins that were NOT loaded because no genuine licence
    /// key is stored for them: bundle file name (without ".bundle") -> plugin
    /// id ("plex"). Filled in by loadPlugins(), so it describes this launch;
    /// the Custom Sources list uses it to mark those rows and take the key.
    static private(set) var lockedPluginIDsByBundle: [String: String] = [:]

    /// Lists installed plugin bundles without loading any of them -- see
    /// InstalledPlugin. Used only to populate the Custom Sources list's
    /// plugin rows and to resolve a row back to a file URL for removal;
    /// the actual, once-per-launch loaded list used for real searches
    /// still comes from loadPlugins() (see MetadataImporter.pluginServices).
    static func installedPluginBundles() -> [InstalledPlugin] {
        return pluginBundleLocations()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Gives the plugin bundle at `url` a chance to clean up its own
    /// external state -- see M3MetadataPlugin.uninstall() -- before
    /// the caller deletes the bundle file itself. Used only by
    /// CustomSourcesListViewController.removePlugin(at:), right before it
    /// removes the file from disk.
    ///
    /// This loads the plugin the same way loadPlugins() does at launch,
    /// which means its code stays mapped into the process for the rest of
    /// this run -- unavoidable, since Foundation has no bundle-unload
    /// primitive, and no worse than the normal case where every installed
    /// plugin is already loaded for the whole app lifetime. A plugin that
    /// fails to load, or doesn't implement uninstall(), is silently
    /// skipped: this is a best-effort courtesy, never a reason to block
    /// removal of a broken or incompatible bundle.
    static func notifyPluginWillUninstall(at url: URL) {
        loadPlugin(at: url)?.uninstall?()
    }

    // MARK: - Installing a picked file

    /// Why a picked file could not be turned into a plugin bundle.
    enum InstallError: LocalizedError {
        case unzipFailed(String)
        case notAPlugin(String)

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let name):
                return String(format: NSLocalizedString("\u{201c}%@\u{201d} could not be unpacked.", comment: ""), name)
            case .notAPlugin(let name):
                return String(format: NSLocalizedString("\u{201c}%@\u{201d} is not a Media Metadata Manager plugin.", comment: ""), name)
            }
        }
    }

    /// Unpacks a .zip into `directory` and returns the .bundle folders in it
    /// (at the top or one folder down, where a zip of a folder puts them).
    static func extractBundles(fromZip zip: URL, into directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallError.unzipFailed(zip.lastPathComponent) }

        var found = bundleURLs(in: directory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        for folder in folders where folder.pathExtension != "bundle" {
            found += bundleURLs(in: folder)
        }
        return found
    }

    /// A cheap check before copying: the folder is a loadable bundle that
    /// names a principal class. (Whether the class really implements the
    /// plugin contract is checked when it loads, see loadPlugin.)
    static func looksLikePlugin(_ url: URL) -> Bool {
        guard let bundle = Bundle(url: url) else { return false }
        // Read from Info.plist; asking for principalClass would run the plugin's code.
        return bundle.object(forInfoDictionaryKey: "NSPrincipalClass") != nil
    }

    /// A bundle downloaded in a browser carries the quarantine flag; remove it
    /// from the copy the user chose to install, so it can load.
    static func clearQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func loadPlugin(at url: URL) -> M3MetadataPlugin? {
        guard let bundle = Bundle(url: url) else {
            NSLog("[MetadataPluginLoader] %@ is not a valid bundle", url.lastPathComponent)
            return nil
        }
        guard bundle.load() else {
            NSLog("[MetadataPluginLoader] Failed to load %@", url.lastPathComponent)
            return nil
        }
        guard let principalClass = bundle.principalClass as? NSObject.Type else {
            NSLog("[MetadataPluginLoader] %@ has no usable principal class", url.lastPathComponent)
            return nil
        }
        // Deliberately not `principalClass.init() as? M3MetadataPlugin`:
        // that Swift-level cast always fails for a class loaded from a
        // different bundle's module, even a fully-conforming one -- see
        // PluginBridge.swift for why. PluginBridge does the equivalent
        // check itself, via selectors rather than a Swift protocol cast.
        guard let bridge = PluginBridge(wrapping: principalClass.init()) else {
            NSLog("[MetadataPluginLoader] %@'s principal class doesn't implement everything M3MetadataPlugin requires", url.lastPathComponent)
            return nil
        }
        return bridge
    }
}
