//
//  PluginBridge.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/20/2026.
//
//  See the header comment on M3MetadataPlugin.swift for why this
//  class exists: a loaded plugin's principal class can never be safely
//  cast to M3MetadataPlugin with Swift's `as?`, because that
//  protocol is compiled separately into Subler.app and into the plugin
//  bundle. This class is the one and only place that boundary gets
//  crossed -- purely through Objective-C selectors, which (unlike Swift
//  protocol conformance) really are shared process-wide regardless of
//  which bundle compiled them.
//
//  PluginBridge itself conforms to M3MetadataPlugin using Subler's
//  own compiled copy of that protocol, so everything on Subler's side
//  of MetadataPluginLoader keeps working with a plain, statically-typed
//  M3MetadataPlugin value exactly as before -- only the loader's
//  own construction of that value changes.
//

import Foundation

final class PluginBridge: NSObject, M3MetadataPlugin {

    private let target: NSObject

    /// Fails if `target` doesn't actually respond to every selector this
    /// protocol requires -- the loader treats that the same as any other
    /// incompatible plugin, and logs accordingly.
    init?(wrapping target: NSObject) {
        guard target.responds(to: #selector(getter: M3MetadataPlugin.pluginName)),
              target.responds(to: #selector(M3MetadataPlugin.searchMovie(query:))),
              target.responds(to: #selector(M3MetadataPlugin.loadMovieMetadata(id:))) else {
            return nil
        }
        self.target = target
        super.init()
    }

    var pluginName: String {
        return target.value(forKey: "pluginName") as? String ?? ""
    }

    func searchMovie(query: String) -> [[String: Any]] {
        let selector = #selector(M3MetadataPlugin.searchMovie(query:))
        guard let result = target.perform(selector, with: query)?.takeUnretainedValue() as? [[String: Any]] else {
            return []
        }
        return result
    }

    func loadMovieMetadata(id: String) -> [String: Any] {
        let selector = #selector(M3MetadataPlugin.loadMovieMetadata(id:))
        guard let result = target.perform(selector, with: id)?.takeUnretainedValue() as? [String: Any] else {
            return [:]
        }
        return result
    }

    /// loadChapters(id:) is an optional protocol requirement, so unlike
    /// the two selectors checked in init?(wrapping:) above, `target` is
    /// never assumed to respond to this one -- it's checked again here on
    /// every call.
    func loadChapters(id: String) -> [[String: Any]] {
        let selector = #selector(M3MetadataPlugin.loadChapters(id:))
        guard target.responds(to: selector),
              let result = target.perform(selector, with: id)?.takeUnretainedValue() as? [[String: Any]] else {
            return []
        }
        return result
    }

    /// uninstall() is likewise an optional protocol requirement -- `target`
    /// is checked for it here rather than assumed, exactly like
    /// loadChapters(id:) above. perform(_:) (no argument) rather than
    /// perform(_:with:) since the selector takes none.
    func uninstall() {
        let selector = #selector(M3MetadataPlugin.uninstall)
        guard target.responds(to: selector) else { return }
        _ = target.perform(selector)
    }

    /// settingsFields() is optional too -- see M3MetadataPlugin. A plugin
    /// that doesn't implement it simply has no settings to show.
    func settingsFields() -> [[String: Any]] {
        let selector = #selector(M3MetadataPlugin.settingsFields)
        guard target.responds(to: selector),
              let result = target.perform(selector)?.takeUnretainedValue() as? [[String: Any]] else {
            return []
        }
        return result
    }

    /// sourceKind() is optional too: a plugin that does not implement it is
    /// an online source.
    func sourceKind() -> String {
        let selector = #selector(M3MetadataPlugin.sourceKind)
        guard target.responds(to: selector),
              let result = target.perform(selector)?.takeUnretainedValue() as? String else {
            return PluginSourceKind.online
        }
        return result
    }

    /// listLibraryItems() is optional: only a library-server plugin has it.
    func listLibraryItems() -> [[String: Any]] {
        let selector = #selector(M3MetadataPlugin.listLibraryItems)
        guard target.responds(to: selector),
              let result = target.perform(selector)?.takeUnretainedValue() as? [[String: Any]] else {
            return []
        }
        return result
    }
}
