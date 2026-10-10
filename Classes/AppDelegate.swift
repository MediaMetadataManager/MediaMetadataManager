//
//  AppDelegate.swift
//  Subler
//
//  Created by Damiano Galassi on 16/02/2018.
//

import Cocoa
import MP42Foundation

final class DocumentController : NSDocumentController {

    private var openPanel: NSOpenPanel?

    /// Fires once when the Open panel started by the very next
    /// openDocument(_:) call is genuinely cancelled (Cancel button, Esc, or
    /// the panel otherwise closing without a usable selection) -- not when
    /// a selection succeeded but got routed somewhere other than a plain
    /// document open (a folder sent to the Queue, or a multi-file pick
    /// sent to the merge-or-open-separately choice). Set it immediately
    /// before calling openDocument(_:); it is read and cleared the moment
    /// the panel's result comes back, so it never lingers into some later,
    /// unrelated Open. WelcomeWindowController is the only current caller,
    /// using it to bring itself back after closing for the panel.
    var openPanelWasCancelledHandler: (() -> Void)?

    override func openDocument(_ sender: Any?) {
        if let openPanel = self.openPanel {
            openPanel.makeKeyAndOrderFront(self)
        } else {
            super.openDocument(sender)
        }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        if self.openPanel == nil {
            self.openPanel = openPanel
        }

        // `inTypes` (AppKit's own UTI/CFBundleDocumentTypes-based
        // resolution) has been observed leaving real, valid movie files
        // greyed out and unselectable in this panel -- reported as "File
        // Open... can expand directories but cannot select a .mp4 file"
        // (Sep 2026). Every other file picker in this app (selectFile,
        // selectMetadataFile) sidesteps that by setting
        // allowedFileTypes directly from a plain extension list instead of
        // trusting UTI-based resolution, and that has always worked
        // reliably, so do the same here for the standard Open panel.
        openPanel.allowedFileTypes = ["mp4", "m4v", "m4a", "m4b", "mkv", "mka", "mks", "mov", "sublertemp"]

        // Let a folder be picked here too, not just individual files --
        // canChooseFiles stays on so a mixed or files-only pick still
        // works exactly as before. allowedFileTypes above only ever
        // filtered selectable *files*; it never affected which folders
        // are browsable/selectable, so this is additive.
        openPanel.canChooseDirectories = true

        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: { result in
            self.openPanel = nil

            let cancelledHandler = self.openPanelWasCancelledHandler
            self.openPanelWasCancelledHandler = nil

            guard result == NSApplication.ModalResponse.OK.rawValue else {
                completionHandler(result)
                cancelledHandler?()
                return
            }

            let urls = openPanel.urls
            let containsFolder = urls.contains { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }

            if containsFolder {
                // A folder isn't necessarily one release's parts the way a
                // hand-picked set of files usually is -- it's just as
                // likely to be a whole library/batch of unrelated titles.
                // So skip the merge-or-not question entirely and just load
                // everything (each folder's contents flattened, same as
                // drag-and-drop already does) into the Queue for review --
                // see QueueController.insert(contentOf:at:), which already
                // handles one or more folder URLs mixed with plain files.
                completionHandler(NSApplication.ModalResponse.cancel.rawValue)
                self.routeToQueueForMerging(urls, offerMerge: false)
            } else if urls.count > 1 {
                // Picking 2+ *files* at once here used to just silently
                // open that many separate single-file document windows,
                // with zero connection to the Queue's already-built
                // multi-file merge workflow (reorder sheet, live
                // compatibility preview, Queue-serialized merge -- see
                // QueueController.mergeSelectedItems(_:)). Ask once, up
                // front, rather than changing what happens for the
                // ordinary single-file case.
                self.presentMergeOrOpenSeparatelyChoice(for: urls, completionHandler: completionHandler)
            } else {
                completionHandler(result)
            }
        })
    }

    /// Offers to route a multi-file Open-panel selection into the Queue's
    /// merge workflow instead of opening N separate single-file document
    /// windows. "Open Separately" passes the original OK response straight
    /// through, so AppKit's normal per-file opening proceeds exactly as it
    /// did before this existed. "Merge Into One File..." responds .cancel
    /// instead (so AppKit never opens these URLs as documents at all) and
    /// hands the files to routeToQueueForMerging(_:) below.
    private func presentMergeOrOpenSeparatelyChoice(for urls: [URL], completionHandler: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: NSLocalizedString("Open %d Files", comment: "Multi-file open alert -> title"), urls.count)
        alert.informativeText = NSLocalizedString("If these are parts of the same title, you can merge them into one file instead of opening each one separately.", comment: "Multi-file open alert -> body")
        alert.addButton(withTitle: NSLocalizedString("Merge Into One File\u{2026}", comment: "Multi-file open alert -> merge button"))
        alert.addButton(withTitle: NSLocalizedString("Open Separately", comment: "Multi-file open alert -> open separately button"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            completionHandler(NSApplication.ModalResponse.cancel.rawValue)
            routeToQueueForMerging(urls)
        default:
            completionHandler(NSApplication.ModalResponse.OK.rawValue)
        }
    }

    /// Queues the picked files/folders (the same insert(contentOf:at:) path
    /// used by dragging files into the Queue by hand -- it already
    /// flattens any folder URL into its supported contents, one or more
    /// folders at once). Reads the actual pre/post count rather than
    /// assuming urls.count files were inserted, since insert(contentOf:at:)
    /// silently skips anything MP42FileImporter doesn't recognize -- so an
    /// all-unsupported selection here is a safe no-op.
    ///
    /// `offerMerge` selects and merges the newly-inserted rows via the
    /// existing, already-built manual Merge flow
    /// (QueueController.mergeSelectedItems(_:)) -- reusing it end to end
    /// rather than adding a second merge entry point. Only appropriate
    /// when the caller already knows the selection is likely parts of one
    /// release (a hand-picked multi-file Open-panel selection); a folder
    /// drop passes false here instead, since a folder is just as likely to
    /// be a whole batch of unrelated titles as it is a single release's
    /// parts -- it's queued for review, not auto-merged.
    private func routeToQueueForMerging(_ urls: [URL], offerMerge: Bool = true) {
        let queueController = QueueController.shared
        let insertionIndex = queueController.count

        queueController.showWindow(self)
        queueController.insert(contentOf: urls, at: insertionIndex)

        guard offerMerge else { return }

        let insertedCount = queueController.count - insertionIndex
        guard insertedCount > 1 else { return }

        queueController.table.selectRowIndexes(IndexSet(integersIn: insertionIndex ..< (insertionIndex + insertedCount)), byExtendingSelection: false)
        queueController.mergeSelectedItems(self)
    }

    private func dismissOpenPanel() {
        self.openPanel?.close()
        self.openPanel = nil
    }

    override func addDocument(_ document: NSDocument) {
        self.dismissOpenPanel()

        // When a real file finishes opening while a blank, untitled,
        // unedited document window is also showing -- the empty main
        // editor from Prefs.LaunchBehavior.mainWindow, or a leftover
        // one from an earlier Open -- close that placeholder instead of
        // leaving it behind. Without this, "Show Main Window" + Open
        // reads as broken: the user starts with one (empty) window,
        // picks a file, and ends up with two -- the new one with the
        // file they just opened, and the original blank one still
        // sitting there with nothing in it. isDocumentEdited is always
        // false here (a blank document's change count is never bumped
        // -- see Document.init()), so this never discards anything.
        //
        // addDocument(_:) runs before the caller makes and shows the new
        // document's own window controllers (that's the very next thing
        // NSDocumentController's default open/make-untitled-document flow
        // does after this returns), so closing the placeholder here
        // immediately, synchronously, made the blank window disappear a
        // beat before the new one appeared -- reads as one window
        // vanishing and a second one popping up moments later, not a
        // clean swap. Deferring the close to the next run-loop turn lets
        // that still-synchronous makeWindowControllers()/showWindows()
        // call happen first, so the new window is already on screen by
        // the time the placeholder closes.
        let placeholders = documents.filter { existing in
            existing !== document && existing.fileURL == nil && existing.isDocumentEdited == false
        }
        if placeholders.isEmpty == false {
            DispatchQueue.main.async {
                for existing in placeholders {
                    existing.close()
                }
            }
        }

        super.addDocument(document)
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let ext = url.pathExtension.lowercased()

        if ["mkv", "mka", "mks", "mov", "264", "h264"].contains(ext) {
            do {
                let doc = try self.openUntitledDocumentAndDisplay(displayDocument)
                // See Document.importSourceURL's own comment -- this new
                // document has no fileURL of its own (it's an import, not
                // a direct open), so without this its first Save has no
                // way to know the source file even came from this folder.
                (doc as? Document)?.importSourceURL = url
                completionHandler(doc, false, nil)
                if let windowController = doc.windowControllers.first as? DocumentWindowController {
                    windowController.showImportSheet(fileURLs: [url])
                }
            } catch {
                completionHandler(nil, false, error)
            }
        }
        else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
    }

    override func document(for url: URL) -> NSDocument? {
        return self.documents.first { $0.fileURL == url }
    }
}

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    @IBOutlet weak var sendToExternalApp: NSMenuItem!

    @MainActor private lazy var prefsController: PrefsWindowController = {
        return PrefsWindowController()
    }()

    private let logger = Logger.shared

    @MainActor private lazy var activityWindowController: ActivityWindowController = {
        return ActivityWindowController(logger: logger)
    }()

    @MainActor private lazy var documentController: DocumentController = {
        return DocumentController()
    }()

    @MainActor private lazy var welcomeWindowController: WelcomeWindowController = {
        return WelcomeWindowController()
    }()

    @MainActor private func runDonateAlert() {
        let defaults = UserDefaults.standard
        let firstLaunch = defaults.bool(forKey: "SBFirstLaunch") ? false : true

        let donateNagTime = Double(60 * 60 * 24 * 7)
        let donateNagTimeLong = Double(60 * 60 * 24 * 180)

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastVersion = defaults.string(forKey: "SBDonateAskVersion") ?? ""

        let versionChanged = currentVersion != lastVersion

        if versionChanged {
            defaults.set(currentVersion, forKey: "SBDonateAskVersion")

            let lastDonateDate = defaults.object(forKey: "SBDonateAskDate") as? Date
            let timePassed = lastDonateDate == nil || (-1 * (lastDonateDate?.timeIntervalSinceNow ?? 0)) >= donateNagTimeLong

            if timePassed {
                defaults.removeObject(forKey: "SBWarningDonate")
                defaults.removeObject(forKey: "SBFirstLaunch")
                defaults.removeObject(forKey: "SBDonateAskDate")
            }
        }

        if defaults.bool(forKey: "SBWarningDonate") == false {
            let lastDonateDate = defaults.object(forKey: "SBDonateAskDate") as? Date
            let timePassed = lastDonateDate == nil || (-1 * (lastDonateDate?.timeIntervalSinceNow ?? 0)) >= donateNagTime

            if firstLaunch == false && timePassed {
                defaults.set(Date(), forKey: "SBDonateAskDate")

                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Support Subler", comment: "Donation -> title")
                alert.informativeText = NSLocalizedString(" A lot of time and effort have gone into development, coding, and refinement.\n If you enjoy using it, please consider showing your appreciation with a donation.", comment: "Donation -> message")
                alert.alertStyle = .informational

                alert.addButton(withTitle: NSLocalizedString("Donate", comment: "Donation -> button"))
                let noDonateButton = alert.addButton(withTitle: NSLocalizedString("Nope", comment: "Donation -> button"))
                noDonateButton.keyEquivalent = String(format: "%c", 0x1b) // escape key

                let allowAgain = lastDonateDate != nil //hide the "don't show again" check the first time - give them time to try the app
                alert.showsSuppressionButton = allowAgain

                if allowAgain {
                    alert.suppressionButton?.title = NSLocalizedString("Don't ask me about this again for this version.", comment: "Donation -> button")
                }

                let donateResult = alert.runModal()

                if donateResult == .alertFirstButtonReturn {
                    donate(self)
                }

                if allowAgain {
                    defaults.set(alert.suppressionButton?.state != .on, forKey: "SBWarningDonate")
                }
            }
        }

        if firstLaunch {
            defaults.set(true, forKey: "SBFirstLaunch")
        }
    }

    // MARK: delegates

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        MetadataPrefs.register()
        MediaIntakePrefs.register()

        _ = documentController
        _ = activityWindowController

        logger.clear()
        MP42File.setGlobalLogger(logger)

        _ = QueueController.shared
        _ = QueueController.tvShows

        if #available(macOS 10.15, *) {
            sendToExternalApp.title = NSLocalizedString("Send to TV", comment: "Send to tv app menu item")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        addCleanUpEmptyFoldersMenuItem()
        //if Prefs.suppressDonationAlert == false {
        //    runDonateAlert()
        //}
    }

    // MARK: About panel

    /// The system's default About panel reads its bold title from
    /// CFBundleName, which is "M3" (the internal project/code name, kept
    /// separate from the user-facing name on purpose -- see
    /// ApplicationSupport.swift's header for the same M3/Media Metadata
    /// Manager split). Overriding applicationName and applicationIcon here
    /// is what makes the About panel show the real name and current icon
    /// instead. Version and build number are left out of the options
    /// dictionary on purpose -- the panel already reads
    /// CFBundleShortVersionString/CFBundleVersion by default, and Subler's
    /// own version is credited in Credits.rtf's body text instead of
    /// duplicated here, so there's only one place to keep it current.
    @IBAction func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Media Metadata Manager",
            .applicationIcon: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage as Any
        ])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = QueueController.shared.status

        if state == .working || QueueController.tvShows.status == .working {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Are you sure you want to quit Subler?", comment: "Quit alert title.")
            alert.informativeText = NSLocalizedString("Your current queue will be lost. Do you want to quit anyway?", comment: "Quit alert description.")
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: "Quit alert default action."))
            alert.addButton(withTitle: NSLocalizedString("Don't Quit", comment: "Quit alert cancel action."))
            alert.alertStyle = .critical

            let result = alert.runModal()
            return result == .alertFirstButtonReturn ? .terminateNow : .terminateCancel

        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        do {
            try PresetManager.shared.save()
            try QueueController.shared.saveToDisk()
            try QueueController.tvShows.saveToDisk()
        } catch {
            logger.write(toLog: "Failed to save queue to disk!")
        }
    }

    /// What happens with no file to reopen from the last session -- see
    /// Prefs.LaunchBehavior's own doc comment for why this used to be
    /// two separate, independently-firing behaviors (this checkbox, plus
    /// an always-on Queue-visibility restore in
    /// applicationWillFinishLaunching(_:) above) and isn't anymore.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if Prefs.showWelcomeScreenAtLaunch {
            welcomeWindowController.showWindow(self)
            return false
        }

        switch Prefs.launchBehavior {
        case .openPanel:
            documentController.openDocument(self)
            return false
        case .mainWindow:
            // Let AppKit go ahead and create the normal untitled Document
            // window it would have made here by default.
            return true
        case .queue:
            QueueController.shared.showWindow(self)
            return false
        }
    }

    @IBAction func toggleStartStop(_ sender: Any?) {
        QueueController.shared.toggleStartStop(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action

        if action == #selector(toggleStartStop(_:)) {
            let state = QueueController.shared.status
            if state == .working {
                menuItem.title = NSLocalizedString("Stop Queue", comment: "Main Menu -> Stop Queue")
            } else {
                menuItem.title = NSLocalizedString("Start Queue", comment: "Main Menu -> Start Queue")
            }
        }

        return true
    }

    // MARK: actions

    @IBAction func openInQueue(_ sender: Any) {
        QueueController.shared.showWindow(self)
        QueueController.shared.open(sender)
    }

    @IBAction func showQueueWindow(_ sender: Any) {
        QueueController.shared.showWindow(self)
    }

    @IBAction func showTVShowQueueWindow(_ sender: Any) {
        QueueController.tvShows.showWindow(self)
    }

    @IBAction func cleanUpEmptyFolders(_ sender: Any?) {
        EmptyFolderCleaner.runManually()
    }

    /// Adds "Clean Up Empty Folders\u{2026}" to the main menu in code (right
    /// after "Show Queue" when that item can be found, otherwise at the end
    /// of the File menu) rather than through MainMenu.xib.
    private func addCleanUpEmptyFoldersMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let item = NSMenuItem(title: NSLocalizedString("Clean Up Empty Folders\u{2026}", comment: "Main Menu -> Clean Up Empty Folders"),
                              action: #selector(cleanUpEmptyFolders(_:)), keyEquivalent: "")
        item.target = self

        let tvQueueItem = NSMenuItem(title: NSLocalizedString("Show TV Shows Queue", comment: "Main Menu -> Show TV Shows Queue"),
                                     action: #selector(showTVShowQueueWindow(_:)), keyEquivalent: "")
        tvQueueItem.target = self

        for topLevel in mainMenu.items {
            guard let submenu = topLevel.submenu else { continue }
            if let index = submenu.items.firstIndex(where: { $0.action == #selector(showQueueWindow(_:)) }) {
                submenu.items[index].title = NSLocalizedString("Show Movies Queue", comment: "Main Menu -> Show Movies Queue")
                submenu.insertItem(tvQueueItem, at: index + 1)
                submenu.insertItem(item, at: index + 2)
                return
            }
        }

        for topLevel in mainMenu.items {
            guard let submenu = topLevel.submenu else { continue }
            if submenu.items.contains(where: { $0.action == #selector(NSDocumentController.openDocument(_:)) }) {
                submenu.addItem(NSMenuItem.separator())
                submenu.addItem(item)
                return
            }
        }
    }

    @IBAction func showPrefsWindow(_ sender: Any) {
        prefsController.showWindow(self)
    }

    @IBAction func showDebugLog(_ sender: Any) {
        activityWindowController.showWindow(self)
    }

    /// Temporary debug-only entry point for the Intake/Queue workflow's
    /// QueueRow/QueueRelease model, ahead of the real Intake folder
    /// watcher and naming/merge windows: pick a folder, scan it for
    /// supported media files, and drop it into the Queue as a `.release`
    /// row (see QueueController.makeRelease(contentOf:) and
    /// insertRelease(_:at:)) rather than the N-flat-QueueItems result a
    /// normal folder drop still produces. Exercises the model shape
    /// described in the "Queue release model" design doc published to the
    /// Subler claude.ai project -- naming/metadata/merge aren't wired up
    /// yet, so the row will just sit in the Queue in its pending-naming
    /// state and won't be muxed.
    @IBAction func addTestReleaseDebug(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.title = NSLocalizedString("Add Test Release (Debug)", comment: "Add test release debug open panel -> title")
        openPanel.message = NSLocalizedString("Choose a folder containing one or more media files.", comment: "Add test release debug open panel -> message")
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true

        openPanel.begin { response in
            guard response == NSApplication.ModalResponse.OK, let folderURL = openPanel.url else { return }

            let queueController = QueueController.shared
            queueController.showWindow(self)

            // addOrRefreshRelease(contentOf:), not makeRelease(contentOf:)
            // + insertRelease(_:at:) directly -- re-picking the same
            // folder after rejecting its naming or cancelling its merge
            // selection (this debug entry point's only way to retry
            // today) refreshes that same row instead of adding another
            // one for files that never moved. See its doc comment in
            // QueueController.swift.
            if queueController.addOrRefreshRelease(contentOf: folderURL) == false {
                let alert = NSAlert()
                alert.addButton(withTitle: NSLocalizedString("OK", comment: "Add test release debug alert -> button"))
                alert.messageText = NSLocalizedString("No Supported Media Files Found", comment: "Add test release debug alert -> title")
                alert.informativeText = folderURL.path
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// App menu -> Support…  (the action keeps its old name so the menu
    /// item's connection in MainMenu.xib stays valid). Links live in
    /// SupportLinks (PrefsWindowController.swift).
    @IBAction func donate(_ sender: Any) {
        SupportLinks.showSupportAlert()
    }

    @IBAction func help(_ sender: Any) {
        guard let url = URL(string: "https://github.com/MediaMetadataManager/MediaMetadataManager") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension AppDelegate {

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        if key == "queueItems" {
            return true
        } else {
            return false
        }
    }

    @MainActor @objc(queueItems) func queueItems() -> [QueueItem] {
        let queue = QueueController.shared
        let indexes = IndexSet(integersIn: 0..<Int(queue.count))
        return queue.items(at: indexes)
    }

    @MainActor @objc(insertObject:inItemsAtIndex:) func insert(object: QueueItem, inItemsAtIndex index: UInt) {
        QueueController.shared.insert(items: [object], at: IndexSet(integer: IndexSet.Element(index)))
    }

    @MainActor @objc(removeObjectFromItemsAtIndex:) func removeObjectFromItemsAtIndex(_ index: UInt) {
        QueueController.shared.remove(at: IndexSet(integer: IndexSet.Element(index)))
    }

}
