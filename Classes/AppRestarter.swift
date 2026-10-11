//
//  AppRestarter.swift
//  M3
//
//  "Restart now or later" after something that only takes effect on the next
//  launch -- today, installing or removing a plugin (see
//  CustomSourcesListViewController). The app never restarts under work that is
//  still running: if the Queue is muxing, a merge is writing a file, or a scan
//  is walking a folder, the person is told exactly what is still running and
//  the app restarts by itself the moment the last of it has finished.
//
//  How the restart works: the app asks to terminate as usual (so unsaved
//  documents still get their Save prompts and the queue is saved by
//  applicationWillTerminate), and only once termination is certain does
//  applicationWillTerminate call relaunchIfRequested(), which starts a tiny
//  detached shell that waits for this process to exit and then reopens the
//  app. A cancelled quit therefore never leaves a stray relaunch behind.
//

import Cocoa

enum AppRestarter {

    private static var waitTimer: Timer?

    /// Set when a restart has been decided; honored by relaunchIfRequested()
    /// only if the quit completes within `requestLifetime`, so a restart the
    /// person cancelled (for instance at an unsaved-document prompt) can
    /// never turn a much later, ordinary Quit into a surprise relaunch.
    private static var relaunchRequestedAt: Date?
    private static let requestLifetime: TimeInterval = 600

    /// True while a "restart when finished" is waiting for work to end.
    static var isRestartScheduled: Bool { waitTimer != nil }

    // MARK: Busy work

    /// Short, plain descriptions of everything that is still running, empty
    /// when the app is idle. Each line is shown to the person as-is.
    static func runningWork() -> [String] {
        var lines: [String] = []

        for controller in [QueueController.shared, QueueController.tvShows] {
            let name = controller === QueueController.shared
                ? NSLocalizedString("Movies Queue", comment: "Restart -> running work")
                : NSLocalizedString("TV Shows Queue", comment: "Restart -> running work")

            if controller.status == .working {
                lines.append(String(format: NSLocalizedString("%@ is processing files", comment: "Restart -> running work"), name))
            }
            let merges = controller.mergesInProgress
            if merges > 0 {
                lines.append(merges == 1
                    ? String(format: NSLocalizedString("%@: a merge is running", comment: "Restart -> running work"), name)
                    : String(format: NSLocalizedString("%@: %d merges are running", comment: "Restart -> running work"), name, merges))
            }
            if controller.isIntakeScanRunning {
                lines.append(String(format: NSLocalizedString("%@: a Media Intake scan is running", comment: "Restart -> running work"), name))
            }
        }

        if LibraryScanWindowController.activeScanCount > 0 {
            lines.append(NSLocalizedString("A Library scan is running", comment: "Restart -> running work"))
        }

        return lines
    }

    // MARK: Offering a restart

    /// Tells the person something needs a restart and lets them choose when.
    /// `messageText`/`informativeText` describe what happened (for example
    /// "Plugin installed"); the buttons and the list of running work are
    /// added here.
    static func offerRestart(messageText: String, informativeText: String) {
        NSApp.activate(ignoringOtherApps: true)

        if isRestartScheduled {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = messageText
            alert.informativeText = informativeText + "\n\n" + NSLocalizedString("A restart is already scheduled. Media Metadata Manager will restart as soon as the running work has finished.", comment: "Restart")
            alert.addButton(withTitle: NSLocalizedString("Keep Waiting", comment: "Restart -> button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel Restart", comment: "Restart -> button"))
            if alert.runModal() == .alertSecondButtonReturn {
                cancelScheduledRestart()
            }
            return
        }

        let running = runningWork()
        let alert = NSAlert()
        alert.messageText = messageText

        if running.isEmpty {
            alert.alertStyle = .informational
            alert.informativeText = informativeText
            alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: "Restart -> button"))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: "Restart -> button"))
            if alert.runModal() == .alertFirstButtonReturn {
                restartNow()
            }
        } else {
            alert.alertStyle = .warning
            let list = running.map { "\u{2022} " + $0 }.joined(separator: "\n")
            alert.informativeText = informativeText + "\n\n"
                + NSLocalizedString("Still running:", comment: "Restart") + "\n" + list + "\n\n"
                + NSLocalizedString("To avoid interrupting this work, Media Metadata Manager can restart automatically as soon as it has finished.", comment: "Restart")
            alert.addButton(withTitle: NSLocalizedString("Restart When Finished", comment: "Restart -> button"))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: "Restart -> button"))
            if alert.runModal() == .alertFirstButtonReturn {
                scheduleRestartWhenIdle()
            }
        }
    }

    // MARK: Restarting

    private static func scheduleRestartWhenIdle() {
        guard waitTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            if runningWork().isEmpty {
                cancelScheduledRestart()
                restartNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waitTimer = timer
    }

    static func cancelScheduledRestart() {
        waitTimer?.invalidate()
        waitTimer = nil
    }

    /// Asks the app to quit normally and marks that it should reopen itself.
    private static func restartNow() {
        relaunchRequestedAt = Date()
        NSApp.terminate(nil)
    }

    /// Called by AppDelegate when a quit was cancelled (the Queue-running
    /// confirmation, say), so that cancelled restart is forgotten.
    static func quitWasCancelled() {
        relaunchRequestedAt = nil
    }

    /// Called at the very end of applicationWillTerminate -- termination is
    /// certain by then. Starts a detached shell that waits for this process
    /// to be gone and then opens the app again.
    static func relaunchIfRequested() {
        guard let requested = relaunchRequestedAt,
              Date().timeIntervalSince(requested) < requestLifetime else { return }
        relaunchRequestedAt = nil

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$1\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            NSLog("[AppRestarter] Couldn't schedule the relaunch: %@", error.localizedDescription)
        }
    }
}
