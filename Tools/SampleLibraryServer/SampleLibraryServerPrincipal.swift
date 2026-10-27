//
//  SampleLibraryServerPrincipal.swift
//  SampleLibraryServer
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  A stand-in "library server" plugin with no server behind it. It answers the plugin
//  interface from a folder of video files: it lists every video it finds there and offers
//  made-up details for each (description, studio, director, cast, genre, rating, release
//  date). Nothing is read from or written to the files.
//
//  What it is for:
//    - Documentation screenshots and demos of the library scan's Source choice, Accept and
//      Send to Queue, with a neutral name instead of a real product's.
//    - Testing the library-server path of the app without running Plex, Jellyfin or Emby.
//    - A small, complete example for anyone writing a library-server plugin: it needs no
//      other library, only the Objective-C selectors below (see Classes/Plugins/
//      M3MetadataPlugin.swift in the app for what each one means).
//
//  Setting (Settings > Sources > Providers > Configure...): the folder to list. Empty
//  means /Users/Shared/M3-Media2, the folder the documentation screenshot run uses.
//

import Foundation

@objc(SampleLibraryServerPrincipal)
final class SampleLibraryServerPrincipal: NSObject {

    // MARK: Required by the plugin interface

    @objc(pluginName)
    var pluginName: String { return "Sample Library" }

    @objc(searchMovieWithQuery:)
    func searchMovie(query: String) -> [[String: Any]] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.isEmpty == false else { return [] }
        return videoFiles().compactMap { url -> [String: Any]? in
            let title = Self.title(for: url)
            guard title.lowercased().contains(needle) else { return nil }
            return ["id": url.path, "title": title, "releaseDate": Self.details(for: url)["releaseDate"] as Any]
        }
    }

    @objc(loadMovieMetadataWithId:)
    func loadMovieMetadata(id: String) -> [String: Any] {
        let url = URL(fileURLWithPath: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return Self.details(for: url)
    }

    // MARK: Library server

    @objc(sourceKind)
    func sourceKind() -> String { return "libraryServer" }

    @objc(listLibraryItems)
    func listLibraryItems() -> [[String: Any]] {
        return videoFiles().map { url in
            var item = Self.details(for: url)
            item["path"] = url.path
            item["hasCover"] = false   // no artwork to offer
            return item
        }
    }

    @objc(settingsFields)
    func settingsFields() -> [[String: Any]] {
        return [
            ["key": Self.folderDefaultsKey, "label": "Folder of sample files", "secure": false,
             "placeholder": Self.defaultFolder]
        ]
    }

    // MARK: Files

    private static let folderDefaultsKey = "SampleLibraryFolder"
    private static let defaultFolder = "/Users/Shared/M3-Media2"
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    private var folder: URL {
        let typed = (UserDefaults.standard.string(forKey: Self.folderDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: typed.isEmpty ? Self.defaultFolder : (typed as NSString).expandingTildeInPath)
    }

    /// Every video file under the folder, in path order, hidden files skipped.
    private func videoFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where Self.videoExtensions.contains(url.pathExtension.lowercased()) {
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Made-up details

    /// The file name without its extension, dots and underscores read as spaces, and a
    /// trailing "(2019)" taken off.
    private static func title(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: "_", with: " ")
        if let range = name.range(of: #"\s*\((19|20)\d{2}\)\s*$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private static func year(for url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"\((19|20)\d{2}\)\s*$"#, options: .regularExpression),
           let year = Int(name[range].dropFirst().prefix(4)) {
            return year
        }
        return 2005 + stableNumber(for: url) % 18
    }

    /// The same number for the same path on every run (String.hashValue is not).
    private static func stableNumber(for url: URL) -> Int {
        return url.path.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
    }

    /// The same made-up details for a file every time, in the plugin's result keys.
    private static func details(for url: URL) -> [String: Any] {
        let title = Self.title(for: url)
        let seed = stableNumber(for: url)
        let studios = ["Sample Pictures", "Example Films", "Placeholder Studios"]
        let directors = ["Alex Example", "Sam Sample", "Robin Placeholder"]
        let casts = [["Pat Example", "Jordan Sample"], ["Casey Placeholder", "Morgan Example", "Riley Sample"], ["Taylor Sample"]]
        let genres = ["Drama", "Comedy", "Documentary", "Adventure", "Thriller"]
        let ratings = ["G", "PG", "PG-13", "R"]

        return [
            "id": url.path,
            "title": title,
            "releaseDate": String(format: "%04d-%02d-%02d", year(for: url), 1 + seed % 12, 1 + seed % 28),
            "synopsis": "A made-up description of \(title), supplied by the sample library for demonstrations and tests. It does not describe the real film.",
            "studio": studios[seed % studios.count],
            "director": directors[(seed / 3) % directors.count],
            "cast": casts[(seed / 5) % casts.count],
            "genre": [genres[seed % genres.count]],
            "ratingCountry": "USA",
            "ratingName": ratings[(seed / 7) % ratings.count]
        ]
    }
}
