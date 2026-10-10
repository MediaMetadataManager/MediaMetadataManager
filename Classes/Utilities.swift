//
//  Utilities.swift
//  Subler
//
//  Created by Damiano Galassi on 31/01/2019.
//

import Cocoa
import MP42Foundation

enum PrivacyConsentState {
    case unknown
    case granted
    case denied
}

func automationConsent(bundleIdentifier: String, promptIfNeeded: Bool) -> PrivacyConsentState {
    var result: PrivacyConsentState = .denied
    if #available(macOS 10.14, *) {
        bundleIdentifier.withCString { (identifier) in
            var addressDesc = AEAddressDesc()

            // Mare sure the target is running, if not the consent alert will not be shown.
            NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleIdentifier, options: [],
                                                 additionalEventParamDescriptor: nil, launchIdentifier: nil)

            let createDescResult = AECreateDesc(typeApplicationBundleID, identifier, strlen(identifier), &addressDesc)
            if createDescResult == noErr {
                let appleScriptPermission = AEDeterminePermissionToAutomateTarget(&addressDesc, typeWildCard, typeWildCard, promptIfNeeded)
                AEDisposeDesc(&addressDesc)
                switch appleScriptPermission {
                case -1744://Int32(errAEEventWouldRequireUserConsent):
                    result = .unknown
                case noErr:
                    result = .granted
                case Int32(errAEEventNotPermitted):
                    result = .denied
                case Int32(procNotFound):
                    result = .unknown
                default:
                    result = .unknown
                    break
                }
            }
        }
        return result
    } else {
        return .granted
    }
}

func sendToFileExternalApp(fileURL: URL) -> Bool {
    let filePath = fileURL.path

    if #available(macOS 10.15, *) {
        if let script = NSAppleScript(source: """
            tell application "TV" to add (POSIX file "\(filePath)")
            """) {

            let result = automationConsent(bundleIdentifier: "com.apple.TV", promptIfNeeded: true)
            if result == .granted {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                return error != nil
            }
        }
    } else {
        if let script = NSAppleScript(source: """
            tell application "iTunes" to add (POSIX file "\(filePath)")
            """) {

            let result = automationConsent(bundleIdentifier: "com.apple.iTunes", promptIfNeeded: true)
            if result == .granted {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                return error != nil
            }
        }
    }
    
    return false
}


extension String {

    // All content is licensed under the terms of the MIT open source license.
    // Copyright (c) 2016 Matthijs Hollemans and contributors

    func minimumEditDistance(other: String) -> Int {
        let m = self.count
        let n = other.count
        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        // initialize matrix
        for index in 1...m {
            // the distance of any first string to an empty second string
            matrix[index][0] = index
        }

        for index in 1...n {
            // the distance of any second string to an empty first string
            matrix[0][index] = index
        }

        // compute Levenshtein distance
        for (i, selfChar) in self.enumerated() {
            for (j, otherChar) in other.enumerated() {
                if otherChar == selfChar {
                    // substitution of equal symbols with cost 0
                    matrix[i + 1][j + 1] = matrix[i][j]
                } else {
                    // minimum of the cost of insertion, deletion, or substitution
                    // added to the already computed costs in the corresponding cells
                    matrix[i + 1][j + 1] = Swift.min(matrix[i][j] + 1, matrix[i + 1][j] + 1, matrix[i][j + 1] + 1)
                }
            }
        }
        return matrix[m][n]
    }
}

extension URL {

    /// True for a folder iTunes or Apple's TV app watches for automatic
    /// library ingestion -- "Automatically Add to iTunes.localized" /
    /// "Automatically Add to TV.localized". A file dropped straight into
    /// one of these is ingested and organized by that app itself, so
    /// wrapping it in a new folder first
    /// (Document.ensureOwnFolder(fileURL:targetName:), QueueSetOutputFilenameAction)
    /// would just leave an empty folder behind once ingestion moves the
    /// file out -- destinations matching this should be left exactly as
    /// the user (or that app) set them up.
    ///
    /// Resolved in three steps, most specific first: the user's own
    /// override (MediaIntakePrefs.automaticMediaIngestFolders, set in the
    /// Media Intake settings pane), then the live-detected OS default
    /// (MediaIntakePrefs.defaultAutomaticMediaIngestFolderURL()), and
    /// only if neither resolves/matches, a name-pattern fallback -- this
    /// last case mainly covers a relocated library whose ingest folder
    /// hasn't been explicitly configured yet.
    var isAutomaticMediaIngestFolder: Bool {
        let standardizedSelf = self.standardizedFileURL

        let configured = MediaIntakePrefs.automaticMediaIngestFolders
        if configured.contains(where: { $0.standardizedFileURL.path == standardizedSelf.path }) {
            return true
        }

        let detected = MediaIntakePrefs.defaultAutomaticMediaIngestFolderURL()
        if let detected = detected, detected.standardizedFileURL == standardizedSelf {
            return true
        }

        if configured.isEmpty && detected == nil {
            return lastPathComponent.lowercased().hasPrefix("automatically add to ")
        }
        return false
    }
}


/// Shared recovery for "moving a finished movie into Ready for Media
/// Library failed" -- typically that volume is out of space or offline.
/// Used by Document (Edit+Save) and by the Queue's QueueMoveToLibraryAction.
/// Cleans up what the failed attempt left behind (only while the original
/// is still in place), tells the user why, and offers a file navigator to
/// choose another location, retrying the same move there. Safe to call
/// from a background thread: the UI part is shown on the main thread and
/// the caller blocks until the user answers.
enum FolderMoveRecovery {

    /// - Parameters:
    ///   - itemURL: what was being moved -- the whole folder when
    ///     `movingWholeFolder`, else a single file that gets a new folder
    ///     of its own.
    ///   - folderName: the name for the destination folder.
    ///   - partialDestination: the folder path the failed attempt used.
    /// - Returns: the folder that now holds the item, or nil if it stayed
    ///   where it was.
    static func recover(error: Error, itemURL: URL, folderName: String, movingWholeFolder: Bool, partialDestination: URL) -> URL? {
        let fileManager = FileManager.default
        let sourceStillExists = fileManager.fileExists(atPath: itemURL.path)

        func cleanUp(_ destination: URL) {
            guard sourceStillExists, destination.standardizedFileURL != itemURL.standardizedFileURL else { return }
            if movingWholeFolder {
                try? fileManager.removeItem(at: destination)
            } else {
                try? fileManager.removeItem(at: destination.appendingPathComponent(itemURL.lastPathComponent))
                if let contents = try? fileManager.contentsOfDirectory(atPath: destination.path), contents.isEmpty {
                    try? fileManager.removeItem(at: destination)
                }
            }
        }

        cleanUp(partialDestination)
        guard sourceStillExists else { return nil }

        var result: URL?
        let work = {
            var lastError = error
            while true {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("Couldn't move to Ready for Media Library", comment: "")
                alert.informativeText = String(format: NSLocalizedString("\"%@\" couldn't be moved: %@\n\nChoose another location for its folder, or leave it where it is.", comment: ""), itemURL.lastPathComponent, lastError.localizedDescription)
                alert.addButton(withTitle: NSLocalizedString("Choose Another Location…", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Leave Where It Is", comment: ""))
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }

                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = NSLocalizedString("Move Here", comment: "")
                panel.message = NSLocalizedString("Choose where to put the movie's folder.", comment: "")
                guard panel.runModal() == .OK, let chosen = panel.url else { return }

                let destination = QueueController.uniqueFolderDestination(for: chosen.appendingPathComponent(folderName))
                do {
                    if movingWholeFolder {
                        try fileManager.moveItem(at: itemURL, to: destination)
                    } else {
                        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                        try fileManager.moveItem(at: itemURL, to: destination.appendingPathComponent(itemURL.lastPathComponent))
                    }
                    NSLog("[FolderSync] recovered: moved to user-chosen location \(destination.path)")
                    result = destination
                    return
                } catch {
                    NSLog("[FolderSync] FAILED again at user-chosen location: \(error.localizedDescription)")
                    lastError = error
                    cleanUp(destination)
                }
            }
        }

        if Thread.isMainThread {
            work()
        } else {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { work(); done.signal() }
            done.wait()
        }
        return result
    }
}

/// Finds folders that hold nothing but system junk (.DS_Store and the
/// like) -- typically the source folder a finished file was moved out of,
/// or a destination folder created for a write that then failed -- and
/// moves them to the Trash. Every folder it removes is appended to a plain
/// text log (Application Support/M3/Removed Empty Folders.txt) with its
/// full path, so one removed by mistake can be recreated or restored from
/// the Trash. Only ever looks inside the Intake and Ready for Media
/// Library folders (never at those folders themselves) and never follows
/// symlinks or descends into packages.
enum EmptyFolderCleaner {

    private static let junkFileNames: Set<String> = [".DS_Store", ".localized", "Thumbs.db", "desktop.ini"]

    private static func isJunk(_ name: String) -> Bool {
        return junkFileNames.contains(name) || name.hasPrefix("._")
    }

    static var logURL: URL? {
        return ApplicationSupport.url?.appendingPathComponent("Removed Empty Folders.txt")
    }

    /// True when `folder` contains no files other than junk, and no
    /// subfolder that isn't itself empty in the same sense.
    static func isEmptyTree(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey], options: []) else { return false }

        for item in contents {
            if isJunk(item.lastPathComponent) { continue }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true, isEmptyTree(item) {
                continue
            }
            return false
        }
        return true
    }

    /// The folders scanned: the Intake folder and the Ready for Media
    /// Library folder, where set.
    static func watchedRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        var candidates = MediaIntakePrefs.intakeFolders
        if let ready = MediaIntakePrefs.readyForLibraryFolder {
            candidates.append(ready)
        }
        for candidate in candidates {
            let root = candidate.standardizedFileURL
            guard seen.insert(root.path).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    /// The top-most empty folders strictly inside `roots`. With a
    /// `minimumAge`, a folder modified more recently than that is skipped,
    /// so one a running job has only just created isn't removed from
    /// under it.
    static func findEmptyFolders(in roots: [URL], minimumAge: TimeInterval = 0, maxDepth: Int = 6) -> [URL] {
        let fileManager = FileManager.default
        let now = Date()
        var found: [URL] = []

        func visit(_ folder: URL, depth: Int) {
            guard depth <= maxDepth,
                  let children = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            else { return }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true else { continue }

                if isEmptyTree(child) {
                    if minimumAge > 0, let modified = values?.contentModificationDate, now.timeIntervalSince(modified) < minimumAge {
                        continue
                    }
                    found.append(child)
                } else {
                    visit(child, depth: depth + 1)
                }
            }
        }

        for root in roots {
            visit(root, depth: 0)
        }
        return found
    }

    /// Moves each folder to the Trash and logs the ones that succeeded.
    /// Returns the folders actually moved.
    @discardableResult
    static func trash(_ folders: [URL], reason: String) -> [URL] {
        let fileManager = FileManager.default
        var removed: [URL] = []

        for folder in folders {
            var resulting: NSURL?
            do {
                try fileManager.trashItem(at: folder, resultingItemURL: &resulting)
                removed.append(folder)
            } catch {
                NSLog("[EmptyFolderCleaner] Couldn't move \(folder.path) to the Trash: \(error.localizedDescription)")
            }
        }

        if removed.isEmpty == false {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let stamp = formatter.string(from: Date())
            appendToLog(removed.map { "\(stamp)  \($0.path)  [moved to Trash: \(reason)]" })
        }
        return removed
    }

    private static func appendToLog(_ lines: [String]) {
        guard let url = logURL, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Runs after a Queue run or an Edit-window save when the "Remove
    /// empty folders automatically" Media Intake setting is on.
    static func runAutomaticallyIfEnabled() {
        guard MediaIntakePrefs.autoCleanEmptyFolders else { return }
        DispatchQueue.global(qos: .utility).async {
            let found = findEmptyFolders(in: watchedRoots(), minimumAge: 120)
            guard found.isEmpty == false else { return }
            trash(found, reason: "automatic cleanup")
        }
    }

    /// The "Clean Up Empty Folders\u{2026}" menu command: shows what it
    /// found and only removes anything after confirmation. Main thread.
    static func runManually() {
        let roots = watchedRoots()
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)

        guard roots.isEmpty == false else {
            alert.messageText = NSLocalizedString("No folders to scan", comment: "")
            alert.informativeText = NSLocalizedString("Set the Intake and/or Ready for Media Library folder in the Media Intake settings first.", comment: "")
            alert.runModal()
            return
        }

        let found = findEmptyFolders(in: roots)
        guard found.isEmpty == false else {
            alert.messageText = NSLocalizedString("No empty folders found", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Looked inside: %@", comment: ""), roots.map { $0.path }.joined(separator: "\n"))
            alert.runModal()
            return
        }

        let listed = found.prefix(15).map { $0.path }.joined(separator: "\n")
        let more = found.count > 15 ? "\n" + String(format: NSLocalizedString("\u{2026}and %d more", comment: ""), found.count - 15) : ""
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Move %d empty folder(s) to the Trash?", comment: ""), found.count)
        alert.informativeText = listed + more + "\n\n" + NSLocalizedString("They can be restored from the Trash, and their paths are saved to a log file.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Move to Trash", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removed = trash(found, reason: "manual cleanup")
        let done = NSAlert()
        done.messageText = String(format: NSLocalizedString("Moved %d folder(s) to the Trash", comment: ""), removed.count)
        if let log = logURL {
            done.informativeText = String(format: NSLocalizedString("Their paths were added to %@", comment: ""), log.path)
            done.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            done.addButton(withTitle: NSLocalizedString("Show Log", comment: ""))
            if done.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([log])
            }
        } else {
            done.runModal()
        }
    }
}


/// "Clean up processed files": after a release has been moved into Ready
/// for Media Library, moves the original files that were turned into the
/// finished file (merged parts, or a converted single file's source) to the
/// Trash and logs them. Only ever touches files the release itself listed
/// as its sources, only inside the release's own folder, never the
/// finished output, and only when the setting is on.
enum ProcessedFileCleaner {

    static var logURL: URL? {
        return ApplicationSupport.url?.appendingPathComponent("Cleaned Up Processed Files.txt")
    }

    /// `originals`: the source files as they were named before the folder
    /// moved; `oldFolder`/`newFolder`: where the release folder was and now
    /// is; `keeping`: the finished file's name(s), which are never trashed.
    @discardableResult
    static func trashOriginals(_ originals: [URL], oldFolder: URL, newFolder: URL, keeping keptNames: Set<String>) -> [URL] {
        guard MediaIntakePrefs.autoCleanProcessedFiles else { return [] }

        let fileManager = FileManager.default
        let oldPath = oldFolder.standardizedFileURL.path
        var moved: [URL] = []

        for original in originals {
            let path = original.standardizedFileURL.path
            // Only files that were directly inside the release folder.
            guard path.hasPrefix(oldPath + "/") else { continue }
            let relative = String(path.dropFirst(oldPath.count + 1))
            guard relative.contains("/") == false, keptNames.contains(relative) == false else { continue }

            let current = newFolder.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: current.path) else { continue }

            var resulting: NSURL?
            do {
                try fileManager.trashItem(at: current, resultingItemURL: &resulting)
                moved.append(current)
            } catch {
                NSLog("[ProcessedFileCleaner] Couldn't move \(current.path) to the Trash: \(error.localizedDescription)")
            }
        }

        if moved.isEmpty == false, let url = logURL {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let stamp = formatter.string(from: Date())
            let lines = moved.map { "\(stamp)  \($0.path)  [moved to Trash: processed original]" }
            if let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
            NSLog("[ProcessedFileCleaner] Moved \(moved.count) processed original file(s) to the Trash")
        }
        return moved
    }
}


/// Finds what is waiting in the Incoming Folders: loose media files sitting
/// directly in one, and folders (a download's own folder, up to a few
/// levels down) holding media files. Used by QueueController's automatic
/// intake watching. Never looks inside the Ready for Media Library folder,
/// hidden items, packages, or symlinks.
enum IntakeScanner {

    struct Candidate {
        let root: URL
        /// The folder holding the files, or nil for a loose file that sits
        /// directly in the Incoming Folder (it gets a folder of its own
        /// when it is brought into the Queue).
        let folder: URL?
        let files: [URL]
        /// Names, sizes and modification times of the files -- unchanged
        /// between scans means the download or copy has finished.
        let signature: String

        var key: String {
            return (folder ?? files[0]).standardizedFileURL.path
        }
    }

    /// How long a candidate's signature must stay the same before it is
    /// treated as finished copying.
    static let settleSeconds: TimeInterval = 10

    private static let maximumDepth = 3

    /// Extensions download clients give a file that is still arriving.
    private static let unfinishedExtensions: Set<String> = [
        "part", "crdownload", "!qb", "aria2", "download", "tmp", "partial", "opdownload", "filepart"
    ]

    static func candidates(in roots: [URL], excluding excluded: [URL]) -> [Candidate] {
        let fileManager = FileManager.default
        let formats = Set(MP42FileImporter.supportedFileFormats().map { $0.lowercased() })
        let excludedPaths = excluded.map { $0.standardizedFileURL.path }
        var result: [Candidate] = []

        func isExcluded(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        func signature(of files: [URL]) -> String {
            return files.map { file -> String in
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = values?.fileSize ?? -1
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return "\(file.path)|\(size)|\(modified)"
            }.joined(separator: "\n")
        }

        func scan(_ directory: URL, depth: Int, root: URL) {
            let entries = (try? fileManager.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                                                                options: [.skipsHiddenFiles])) ?? []

            var mediaFiles: [URL] = []
            var subfolders: [URL] = []
            var unfinished = false

            for url in entries {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                if values?.isSymbolicLink == true || isExcluded(url) { continue }

                if values?.isDirectory == true {
                    if values?.isPackage != true {
                        subfolders.append(url)
                    }
                    continue
                }

                let pathExtension = url.pathExtension.lowercased()
                if unfinishedExtensions.contains(pathExtension) {
                    unfinished = true
                } else if formats.contains(pathExtension) {
                    mediaFiles.append(url)
                }
            }

            mediaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            if depth == 0 {
                for file in mediaFiles {
                    result.append(Candidate(root: root, folder: nil, files: [file], signature: signature(of: [file])))
                }
                for folder in subfolders {
                    scan(folder, depth: 1, root: root)
                }
            } else if mediaFiles.isEmpty == false {
                if unfinished == false {
                    result.append(Candidate(root: root, folder: directory, files: mediaFiles, signature: signature(of: mediaFiles)))
                }
            } else if depth < maximumDepth {
                for folder in subfolders {
                    scan(folder, depth: depth + 1, root: root)
                }
            }
        }

        for root in roots {
            scan(root, depth: 0, root: root)
        }
        return result
    }
}
