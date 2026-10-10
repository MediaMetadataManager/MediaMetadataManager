//
//  MetadataPluginLoader.swift
//  M3
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
/// simply opening Preferences.
struct InstalledPlugin {
    let name: String
    let url: URL
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

    /// Loads every plugin bundle found in pluginsDirectory. A bundle that
    /// fails to load, or whose principal class doesn't conform to
    /// M3MetadataPlugin, is logged and skipped rather than treated as
    /// fatal -- one broken or incompatible plugin should never keep the
    /// rest of Subler from launching normally.
    static func loadPlugins() -> [M3MetadataPlugin] {
        guard let directory = pluginsDirectory else { return [] }

        let bundleURLs = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])) ?? []

        return bundleURLs
            .filter { $0.pathExtension == "bundle" }
            .compactMap { loadPlugin(at: $0) }
    }

    /// Lists installed plugin bundles without loading any of them -- see
    /// InstalledPlugin. Used only to populate the Custom Sources list's
    /// plugin rows and to resolve a row back to a file URL for removal;
    /// the actual, once-per-launch loaded list used for real searches
    /// still comes from loadPlugins() (see MetadataImporter.pluginServices).
    static func installedPluginBundles() -> [InstalledPlugin] {
        guard let directory = pluginsDirectory else { return [] }

        let bundleURLs = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                         includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])) ?? []

        return bundleURLs
            .filter { $0.pathExtension == "bundle" }
            .map { InstalledPlugin(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
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
