//
//  ApplicationSupport.swift
//  M3
//
//  Centralizes the app's Application Support folder location. Presets,
//  the queue, OCR language data, custom-source config, the debug log,
//  and installed plugins were previously each computed independently
//  as Application Support/Subler by Logger, Preset, PresetManager,
//  QueuePreferences, OCRManager, and MetadataPluginLoader -- all six
//  now go through this one place instead.
//
//  Centralizing it also makes the one-time migration below safe: since
//  every one of those call sites now resolves the same lazily-computed
//  `url`, the migration is guaranteed to run exactly once, the first
//  time ANY of them is touched during launch, regardless of which one
//  that happens to be.
//

import Foundation

enum ApplicationSupport {

    private static let folderName = "M3"

    /// This app's data lived under Application Support/Subler through
    /// its early builds (it started as a Subler fork, before the
    /// MediaMetadataManager/M3 rename). Kept here only so existing
    /// installs migrate cleanly -- new installs never create this.
    private static let previousFolderName = "Subler"

    /// ~/Library/Application Support/M3, creating it if needed and
    /// migrating an existing ~/Library/Application Support/Subler
    /// folder into it the first time this runs after upgrading, so
    /// presets, queue state, OCR data, and custom sources all survive
    /// the rename instead of silently starting empty.
    static let url: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let fileManager = FileManager.default
        let newURL = base.appendingPathComponent(folderName, isDirectory: true)
        let oldURL = base.appendingPathComponent(previousFolderName, isDirectory: true)

        if fileManager.fileExists(atPath: oldURL.path), fileManager.fileExists(atPath: newURL.path) == false {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                NSLog("[ApplicationSupport] Migrated existing data from %@ to %@", oldURL.path, newURL.path)
            }
            catch {
                NSLog("[ApplicationSupport] Failed to migrate data from %@ to %@, starting fresh: %@", oldURL.path, newURL.path, error.localizedDescription)
            }
        }

        if fileManager.fileExists(atPath: newURL.path) == false {
            do {
                try fileManager.createDirectory(at: newURL, withIntermediateDirectories: true, attributes: [:])
            }
            catch {
                fatalError("Couldn't create the app support directory")
            }
        }

        return newURL
    }()
}
