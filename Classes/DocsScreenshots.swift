//
//  DocsScreenshots.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  Debug builds only. Takes the documentation screenshots by driving the app itself:
//  it opens each window with the made-up demo library, waits for it to draw, and saves
//  a PNG named exactly as in Documentation/images/screens/manifest.json.
//
//  Never part of a release build (everything here is inside #if DEBUG). Run it with
//  Tools/docs/capture-screenshots.sh, which builds the Debug app, builds the demo
//  library, starts from clean settings and puts your own settings back afterwards.
//
//  Launch arguments (the script passes them):
//    -M3DocsScreenshots YES        turn the mode on
//    -M3ScreenshotDir <folder>     where the PNG files go
//    -M3DemoRoot <folder>          the demo library (Tools/docs/make-demo-library.sh)
//    -M3MediaRoot <folder>         clips of real titles (Tools/docs/make-media2-library.sh)
//    -M3ScreenshotOnly a,b         optional: only these shots (names without .png)
//

#if DEBUG

import Cocoa
import MP42Foundation

@MainActor
enum DocsScreenshots {

    /// What to photograph: a whole window, or a screen area (for a popover over a window).
    private enum Target {
        case window(NSWindow)
        case region(NSRect)
    }

    private struct Step {
        let name: String
        /// Seconds to let the window draw before the picture is taken.
        let wait: TimeInterval
        /// Sets the window up and reports what to photograph (nil = skip this shot).
        let setUp: (_ done: @escaping (Target?) -> Void) -> Void
        /// Runs after the picture, to put things back (close a popover).
        var tearDown: (() -> Void)? = nil
    }

    private static var outputFolder = URL(fileURLWithPath: NSTemporaryDirectory())
    private static var demoRoot = URL(fileURLWithPath: "/Users/Shared/M3-Demo")
    /// Short clips of real titles (Tools/docs/make-media2-library.sh) for the shots that need real names.
    private static var mediaRoot = URL(fileURLWithPath: "/Users/Shared/M3-Media2")
    private static var steps: [Step] = []
    private static var failures: [String] = []

    // MARK: Start

    static var isRequested: Bool {
        return UserDefaults.standard.bool(forKey: "M3DocsScreenshots")
    }

    /// Called once from applicationDidFinishLaunching.
    static func startIfRequested() {
        guard isRequested else { return }
        say("starting")
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "M3ScreenshotDir") {
            outputFolder = URL(fileURLWithPath: path)
        }
        if let path = defaults.string(forKey: "M3DemoRoot") {
            demoRoot = URL(fileURLWithPath: path)
        }
        if let path = defaults.string(forKey: "M3MediaRoot") {
            mediaRoot = URL(fileURLWithPath: path)
        }
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        // Same look every time, and nothing that could interrupt a shot.
        if #available(macOS 10.14, *) {
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        // Made-up folders only: nothing here points at the person running this.
        MediaIntakePrefs.intakeFolders = [demoRoot.appendingPathComponent("incoming")]
        MediaIntakePrefs.readyForLibraryFolder = demoRoot.appendingPathComponent("staging")
        // Media Locations shows this folder; without it the app shows the real Apple TV folder in the user's home.
        let autoAdd = demoRoot.appendingPathComponent("Automatically Add to TV")
        try? FileManager.default.createDirectory(at: autoAdd, withIntermediateDirectories: true)
        MediaIntakePrefs.automaticMediaIngestFolders = [autoAdd]
        // Nothing may approve or merge by itself while a dialog is up for its picture.
        MediaIntakePrefs.autoApproveHighConfidenceNaming = false
        MediaIntakePrefs.autoMergeOnSequence = false

        var all = makeSteps()
        if let only = defaults.string(forKey: "M3ScreenshotOnly") {
            let wanted = Set(only.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            all = all.filter { wanted.contains($0.name) }
        }
        steps = all

        say("Screenshot mode: \(steps.count) shots to \(outputFolder.path)")
        // Give the launch (welcome window, restored windows) time to settle.
        after(3.0) { run(index: 0) }
    }

    // MARK: Steps

    private static func makeSteps() -> [Step] {
        let incoming = demoRoot.appendingPathComponent("incoming")
        let dropfolder = demoRoot.appendingPathComponent("dropfolder")
        let library = demoRoot.appendingPathComponent("library")

        var list: [Step] = []

        list.append(Step(name: "welcome-window", wait: 1.0) { done in
            done(appDelegate?.docsWelcomeWindow().map { .window($0) })
        })

        func prefs(_ name: String, tab: String, sub: String? = nil, wait: TimeInterval = 2.5) -> Step {
            return Step(name: name, wait: wait) { done in
                done(appDelegate?.docsPrefsController().docsShowTab(tab, sub: sub).map { .window($0) })
            }
        }
        list.append(prefs("prefs-general", tab: "TOOLBAR_GENERAL"))
        list.append(prefs("prefs-metadata", tab: "TOOLBAR_METADATA"))
        list.append(prefs("prefs-filename-rules", tab: "TOOLBAR_OUTPUT"))
        list.append(prefs("prefs-providers", tab: "TOOLBAR_SOURCES", sub: "providers"))
        list.append(prefs("prefs-media-intake", tab: "TOOLBAR_SOURCES", sub: "mediaIntake"))
        list.append(prefs("prefs-media-locations", tab: "TOOLBAR_SOURCES", sub: "destinations"))

        // The Queue: fill both tabs once, then photograph each.
        list.append(Step(name: "queue-movies-tab", wait: 2.0) { done in
            emptyQueues()
            let movies = QueueController.shared
            movies.insertGrouped([
                incoming.appendingPathComponent("Loose Sample Movie.mp4"),
                dropfolder.appendingPathComponent("Dropped Sample Movie.mp4"),
                dropfolder.appendingPathComponent("Dropped Release"),
                incoming.appendingPathComponent("Sample Title Two (2021)")
            ], at: 0)
            // Episode names send these to the TV Shows tab.
            movies.insertGrouped([
                incoming.appendingPathComponent("Sample Show S01E01.mp4"),
                incoming.appendingPathComponent("Sample Show S01E02.mp4")
            ], at: 0)
            QueueWindowController.shared.show(movies)
            widenQueueWindow()
            QueueController.shared.reloadTable()
            QueueController.tvShows.reloadTable()
            after(0.5) {
                QueueController.shared.reloadTable()
                done(QueueWindowController.shared.window.map { .window($0) })
            }
        })

        list.append(Step(name: "queue-options-panel", wait: 1.2, setUp: { done in
            let queue = QueueWindowController.shared
            queue.show(QueueController.shared)
            queue.window?.makeKeyAndOrderFront(nil)
            after(0.6) {
                QueueController.shared.toggleOptions(nil)
                after(0.8) {
                    // The whole window plus the panel that hangs off it.
                    var area = queue.window?.frame ?? .zero
                    if let panel = QueueController.shared.docsPopoverFrame { area = area.union(panel) }
                    done(.region(area.insetBy(dx: -12, dy: -12)))
                }
            }
        }, tearDown: {
            // A second toggle closes the popover again.
            QueueController.shared.toggleOptions(nil)
        }))

        list.append(Step(name: "queue-tv-tab", wait: 1.5) { done in
            let queue = QueueWindowController.shared
            queue.show(QueueController.tvShows)
            widenQueueWindow()
            QueueController.tvShows.reloadTable()
            after(0.5) { done(queue.window.map { .window($0) }) }
        })

        list.append(Step(name: "library-scan-window", wait: 1.0) { done in
            let scan = LibraryScanWindowController.shared
            scan.docsScan(folder: library)
            waitUntil({ scan.docsIsScanning == false }, timeout: 40) {
                done(scan.window.map { .window($0) })
            }
        })

        list.append(Step(name: "editor-window", wait: 2.0) { done in
            let file = library.appendingPathComponent("Sample Title Ten (2017).mp4")
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { document, _, error in
                if let error = error { say("could not open \(file.lastPathComponent): \(error.localizedDescription)") }
                done(document?.windowControllers.first?.window.map { .window($0) })
            }
        })

        // The shots with real titles come last: the Message Log is taken after a real run.
        list.append(contentsOf: mediaSteps())

        return list
    }

    // MARK: Steps with real titles (phase 2)

    /// The releases the review dialogs are opened from.
    private static var reviewReleases: [String: QueueRelease] = [:]
    private static var openedDocument: NSDocument?

    /// Review dialogs, the editor's metadata search, the Start question, an in-place editing
    /// run and the Message Log. These use short clips of real titles (Tools/docs/make-media2-library.sh)
    /// copied to `mediaRoot`, because the metadata search needs real names to find anything.
    /// Skipped when that folder is missing.
    private static func mediaSteps() -> [Step] {
        let incoming = mediaRoot.appendingPathComponent("incoming")
        let library = mediaRoot.appendingPathComponent("library")
        guard FileManager.default.fileExists(atPath: library.path) else {
            say("no clips at \(mediaRoot.path): the shots with real titles are left out")
            return []
        }

        var list: [Step] = []

        /// A fresh Queue holding one release per kind of review.
        func fillReviewQueue() {
            emptyQueues()
            let queue = QueueController.shared
            reviewReleases = [:]
            reviewReleases["naming"] = queue.docsAddRelease(folder: incoming.appendingPathComponent("Stick.Man.2015.1080p.WEB-DL.x264-GRP"), stage: .pendingNaming)
            reviewReleases["metadata"] = queue.docsAddRelease(folder: incoming.appendingPathComponent("Along Came Auntie (1926)"), stage: .pendingMetadata, approvedName: "Along Came Auntie (1926)")
            reviewReleases["merge"] = queue.docsAddRelease(folder: incoming.appendingPathComponent("Thicker then Water"), stage: .pendingMergeSelection, approvedName: "Thicker then Water")
            queue.reloadTable()
        }

        list.append(Step(name: "queue-folder-expanded", wait: 1.5) { done in
            fillReviewQueue()
            guard let window = showQueue(QueueController.shared, minHeight: 0) else { return done(nil) }
            after(0.5) {
                QueueController.shared.reloadTable()
                done(.window(window))
            }
        })

        /// One review dialog over the Queue. The dialog is photographed together with the Queue
        /// window it sits on, then closed without deciding anything.
        func review(_ name: String, _ key: String, wait: TimeInterval, close: NSApplication.ModalResponse) -> Step {
            return Step(name: name, wait: wait, setUp: { done in
                if reviewReleases[key] == nil || QueueController.shared.count < 3 { fillReviewQueue() }
                guard let release = reviewReleases[key],
                      let window = showQueue(QueueController.shared, minHeight: 640) else { return done(nil) }
                QueueController.shared.docsReview(release)
                after(1.0) {
                    guard NSApp.modalWindow != nil else {
                        say("no dialog opened for \(name)")
                        return done(nil)
                    }
                    done(.region(window.frame))
                }
            }, tearDown: {
                endModal(close)
            })
        }
        list.append(review("naming-review-sheet", "naming", wait: 7.0, close: NamingReviewWindowController.passResponse))
        list.append(review("metadata-review-sheet", "metadata", wait: 7.0, close: .cancel))
        list.append(review("merge-review-sheet", "merge", wait: 2.0, close: .cancel))

        // "Run the queue for how long?" is a sheet on the Queue window; Cancel puts it away.
        list.append(Step(name: "queue-run-time", wait: 1.0, setUp: { done in
            emptyQueues()
            let queue = QueueController.shared
            queue.insertGrouped([
                library.appendingPathComponent("Stick Man (2015).mp4"),
                library.appendingPathComponent("Along Came Auntie (1926).mp4"),
                library.appendingPathComponent("Laurel & Hardy - They Go Boom (1929).mp4")
            ], at: 0)
            guard let window = showQueue(queue, minHeight: 600) else { return done(nil) }
            queue.toggleStartStop(nil)
            after(1.0) { done(.region(window.frame)) }
        }, tearDown: {
            if let window = QueueWindowController.shared.window, let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            }
            emptyQueues()
        }))

        // The editor's Search Metadata sheet, with the first result chosen and its details loaded.
        list.append(Step(name: "editor-search-metadata", wait: 7.0, setUp: { done in
            let file = library.appendingPathComponent("Stick Man (2015).mp4")
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { document, _, error in
                if let error = error { say("could not open \(file.lastPathComponent): \(error.localizedDescription)") }
                guard let document = document,
                      let controller = document.windowControllers.first as? DocumentWindowController,
                      let window = controller.window else { return done(nil) }
                openedDocument = document
                place(window)
                window.makeKeyAndOrderFront(nil)
                after(1.5) {
                    controller.searchMetadata(nil)
                    after(1.5) {
                        var area = window.frame
                        for sheet in window.sheets { area = area.union(sheet.frame) }
                        done(.region(area.insetBy(dx: -12, dy: -12)))
                    }
                }
            }
        }, tearDown: {
            if let window = openedDocument?.windowControllers.first?.window {
                for sheet in window.sheets { window.endSheet(sheet) }
            }
            openedDocument?.close()
            openedDocument = nil
        }))

        // A real run: scan, send everything to the Queue to be edited where it sits, start,
        // and photograph the Queue when it is done. This also fills the Message Log.
        list.append(Step(name: "queue-library-scan-auto-editing", wait: 1.0) { done in
            emptyQueues()
            QueueController.shared.docsEnableMetadataSearch()
            QueueController.tvShows.docsEnableMetadataSearch()
            let scan = LibraryScanWindowController.shared
            scan.docsScan(folder: library)
            waitUntil({ scan.docsIsScanning == false }, timeout: 60) {
                let sent = scan.docsSendAllToQueue()
                say("sent \(sent) files from the scan to the Queue")
                guard let window = showQueue(QueueController.shared, minHeight: 0) else { return done(nil) }
                QueueController.shared.start(nil)
                QueueController.tvShows.start(nil)
                // Give the run time to begin, then wait for both Queues to finish.
                after(4.0) {
                    waitUntil({ QueueController.shared.docsIsIdle && QueueController.tvShows.docsIsIdle }, timeout: 180) {
                        QueueController.shared.reloadTable()
                        after(1.0) { done(.window(window)) }
                    }
                }
            }
        })

        // Last, so the log holds the messages of the run above.
        list.append(Step(name: "message-log", wait: 1.5) { done in
            done(appDelegate?.docsLogWindow().map { .window($0) })
        })

        return list
    }

    /// Shows a Queue tab wide enough for the names, and tall enough for a dialog on top of it.
    private static func showQueue(_ controller: QueueController, minHeight: CGFloat) -> NSWindow? {
        let queue = QueueWindowController.shared
        queue.show(controller)
        widenQueueWindow()
        guard let window = queue.window else { return nil }
        if minHeight > 0, window.frame.height < minHeight {
            var frame = window.frame
            frame.size.height = minHeight
            window.setFrame(frame, display: true)
        }
        place(window)
        controller.reloadTable()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Ends the dialog that is open. The extra event wakes the modal loop so it notices at once.
    private static func endModal(_ response: NSApplication.ModalResponse) {
        guard NSApp.modalWindow != nil else { return }
        NSApp.stopModal(withCode: response)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }

    // MARK: Running

    private static func run(index: Int) {
        guard index < steps.count else { return finish() }
        let step = steps[index]
        hideAllWindows(except: nil)
        NSApp.activate(ignoringOtherApps: true)

        step.setUp { target in
            guard let target = target else {
                failures.append(step.name)
                say("SKIPPED \(step.name) (nothing to photograph)")
                return run(index: index + 1)
            }
            if case .window(let window) = target {
                place(window)
                hideAllWindows(except: window)
                window.makeKeyAndOrderFront(nil)
            }
            after(step.wait) {
                if case .window(let window) = target {
                    // No field left selected, and a freshly drawn shadow (a stale one shows as black corners).
                    window.makeFirstResponder(nil)
                    window.displayIfNeeded()
                    window.invalidateShadow()
                }
                after(0.5) {
                    capture(target, name: step.name)
                    step.tearDown?()
                    after(0.4) { run(index: index + 1) }
                }
            }
        }
    }

    private static func finish() {
        hideAllWindows(except: nil)
        if failures.isEmpty {
            say("Done. Pictures are in \(outputFolder.path)")
        } else {
            say("Done with problems. Not taken: \(failures.joined(separator: ", "))")
        }
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private static var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// Wide enough that file names are not cut short with "...".
    private static func widenQueueWindow() {
        guard let window = QueueWindowController.shared.window else { return }
        var frame = window.frame
        frame.size.width = max(frame.size.width, 1000)
        window.setFrame(frame, display: true)
    }

    private static func emptyQueues() {
        for queue in [QueueController.shared, QueueController.tvShows] where queue.count > 0 {
            queue.remove(at: IndexSet(integersIn: 0..<queue.count))
        }
    }

    private static func hideAllWindows(except keep: NSWindow?) {
        for window in NSApp.windows where window !== keep && window.isVisible {
            if let panel = window as? NSSavePanel { panel.cancel(nil); continue }
            window.orderOut(nil)
        }
    }

    /// Same place on screen for every window, so shots line up from run to run.
    private static func place(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first else { return }
        let top = screen.visibleFrame.maxY - 70
        let left = screen.visibleFrame.minX + 120
        window.setFrameTopLeftPoint(NSPoint(x: left, y: top))
    }

    private static func capture(_ target: Target, name: String) {
        let file = outputFolder.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: file)

        var arguments = ["-x"]
        switch target {
        case .window(let window):
            arguments += ["-l", String(window.windowNumber)]
        case .region(let rect):
            // screencapture counts from the top-left of the main display.
            let height = NSScreen.screens.first?.frame.height ?? 0
            arguments += ["-R", "\(Int(rect.minX)),\(Int(height - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"]
        }
        arguments.append(file.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            failures.append(name)
            say("FAILED \(name): \(error.localizedDescription)")
            return
        }
        // Never wait for ever: a permission prompt can hold screencapture up.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if process.isRunning { process.terminate() }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 0 {
            say("saved \(name).png")
        } else {
            failures.append(name)
            say("FAILED \(name): no picture. Allow Screen Recording for Terminal in System Settings > Privacy & Security, then run again.")
        }
    }

    /// Runs `block` after `seconds`, also while a modal window is open.
    private static func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        // The timer fires on the main run loop; the box only tells the compiler so.
        let box = UncheckedBlock(block)
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in box.block() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private final class UncheckedBlock: @unchecked Sendable {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
    }

    private static func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval, then block: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline { return block() }
            after(0.5, poll)
        }
        after(0.5, poll)
    }

    private static func say(_ text: String) {
        print("[screenshots] \(text)")
        fflush(stdout)
    }
}

#endif
