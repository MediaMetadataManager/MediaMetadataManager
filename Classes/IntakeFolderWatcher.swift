//
//  IntakeFolderWatcher.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/14/2026.
//
//  Watches a single directory for changes using a DispatchSourceFileSystemObject
//  on the directory's own file descriptor -- kept as its own standalone
//  component (not tied to the Media Intake Manager UI, and not sharing any
//  state with the staging folder) so the watching mechanism itself stays
//  simple, testable, and reusable on its own.
//

import Foundation

/// Watches a directory for changes (files added, removed, or renamed
/// inside it) and calls back on the main queue when something changes.
/// Doesn't diff contents itself -- callers are expected to re-scan the
/// directory's contents from the callback.
final class IntakeFolderWatcher {

    private let url: URL
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let callback: () -> Void

    /// Fails (returns nil) if the folder can't be opened for watching --
    /// e.g. it was deleted or permissions changed since it was configured.
    init?(url: URL, callback: @escaping () -> Void) {
        self.url = url
        self.callback = callback

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.fileDescriptor = fd
    }

    /// Starts watching. No-op if already started.
    func start() {
        guard source == nil, fileDescriptor >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor,
                                                                    eventMask: [.write, .rename, .extend, .delete],
                                                                    queue: DispatchQueue.main)
        newSource.setEventHandler { [weak self] in
            self?.callback()
        }
        newSource.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        newSource.resume()
        self.source = newSource
    }

    /// Stops watching. Safe to call even if never started.
    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
