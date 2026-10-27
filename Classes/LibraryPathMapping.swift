//
//  LibraryPathMapping.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  Path mapping for library servers. A server lists each file by the path it
//  knows (for example /volume1/Movies/Title.mp4 on a NAS, or D:\Movies\Title.mp4
//  on a Windows PC), which is often not where the same file is on this Mac
//  (/Volumes/Movies/Title.mp4). A mapping says "a path that starts with this
//  becomes a path that starts with that", so the Library scan can find the
//  files. Kept per server; a server can have several (one per library folder).
//

import Cocoa

struct PathMapRule: Codable, Equatable {
    /// The start of the path as the server writes it.
    var from: String
    /// The start of the same path on this Mac.
    var to: String
}

enum LibraryPathMapping {

    private static let key = "SBLibraryServerPathMaps"

    static func rules(forServer name: String) -> [PathMapRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: [PathMapRule]].self, from: data) else { return [] }
        return all[name] ?? []
    }

    static func setRules(_ rules: [PathMapRule], forServer name: String) {
        var all: [String: [PathMapRule]] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [PathMapRule]].self, from: data) {
            all = decoded
        }
        all[name] = rules
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }

    /// Windows-style separators are read as "/".
    static func normalized(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func looksLikeDriveLetter(_ path: String) -> Bool {
        let chars = Array(path)
        return chars.count >= 2 && chars[0].isLetter && chars[1] == ":"
    }

    /// `path` with the first matching rule applied (the match is on whole path
    /// components, so /movies does not match /movies2). Unchanged when no
    /// rule matches. Drive letters match without regard to case.
    static func map(_ path: String, rules: [PathMapRule]) -> String {
        let source = normalized(path)
        for rule in rules {
            let from = normalized(rule.from)
            let to = normalized(rule.to)
            guard from.isEmpty == false, to.isEmpty == false else { continue }
            let options: String.CompareOptions = looksLikeDriveLetter(from) ? [.anchored, .caseInsensitive] : [.anchored]
            guard let range = source.range(of: from, options: options) else { continue }
            let rest = source[range.upperBound...]
            guard rest.isEmpty || rest.hasPrefix("/") else { continue }
            return to + rest
        }
        return source
    }

    /// Mappings worked out from paths the server listed: for each path, every
    /// leading part of it is tried as the "server" side, and the rest is looked
    /// for under each of `candidateRoots` (the volumes mounted on this Mac). A
    /// hit gives "that leading part -> that volume". One mapping per server
    /// side, so two drives give two mappings. `fileExists` is a parameter so the
    /// search can be tested without a disk.
    static func suggestions(forServerPaths serverPaths: [String], candidateRoots: [String], fileExists: (String) -> Bool) -> [PathMapRule] {
        var found: [PathMapRule] = []
        for serverPath in serverPaths {
            let parts = normalized(serverPath).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            // At least one folder must remain beside the file name.
            guard parts.count >= 2 else { continue }
            let prefix = serverPath.hasPrefix("/") || normalized(serverPath).hasPrefix("/") ? "/" : ""
            lengthLoop: for length in 1..<parts.count {
                let from = prefix + parts[..<length].joined(separator: "/")
                if found.contains(where: { $0.from == from }) { break }
                let rest = parts[length...].joined(separator: "/")
                for root in candidateRoots {
                    let rootPath = normalized(root)
                    let candidate = rootPath + "/" + rest
                    if candidate != normalized(serverPath), fileExists(candidate) {
                        found.append(PathMapRule(from: from, to: rootPath))
                        break lengthLoop
                    }
                }
            }
        }
        return found
    }

    /// The volumes mounted on this Mac, and the home folder: where a server's
    /// files may be found.
    static func localCandidateRoots() -> [String] {
        var roots: [String] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            roots.append(contentsOf: names.sorted().map { "/Volumes/" + $0 })
        }
        roots.append(NSHomeDirectory())
        return roots
    }

    /// The folder part of a server path, to start a mapping from.
    static func suggestedFrom(forExamplePath path: String) -> String {
        let normalizedPath = normalized(path)
        guard let slash = normalizedPath.lastIndex(of: "/"), slash != normalizedPath.startIndex else { return normalizedPath }
        return String(normalizedPath[..<slash])
    }
}

/// The sheet opened by "Path Mapping..." in the Library scan: a list of
/// "server path -> path on this Mac" rows for one library server.
final class PathMappingViewController: NSViewController, NSTextFieldDelegate {

    private let serverName: String
    private let examplePath: String?
    private let samplePaths: [String]
    private var rules: [PathMapRule]
    private let rowsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(serverName: String, samplePaths: [String]) {
        self.serverName = serverName
        self.samplePaths = samplePaths
        self.examplePath = samplePaths.first
        var existing = LibraryPathMapping.rules(forServer: serverName)
        if existing.isEmpty {
            // Start from the folder the server's first file is in.
            existing = [PathMapRule(from: examplePath.map { LibraryPathMapping.suggestedFrom(forExamplePath: $0) } ?? "", to: "")]
        }
        self.rules = existing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 340))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = NSTextField(labelWithString: String(format: NSLocalizedString("Path Mapping for %@", comment: "Path mapping sheet title"), serverName))
        header.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        var text = NSLocalizedString("A library server lists each file by the path it knows, which can differ from where the same file is on this Mac. Enter the start of the server\u{2019}s path on the left and the matching folder on this Mac on the right.", comment: "Path mapping sheet description")
        if let example = examplePath {
            text += "\n\n" + String(format: NSLocalizedString("The server lists, for example: %@", comment: "Path mapping sheet example"), example)
        }
        let description = NSTextField(wrappingLabelWithString: text)
        description.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        description.preferredMaxLayoutWidth = 680
        description.isSelectable = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6

        let addButton = NSButton(title: NSLocalizedString("Add Mapping", comment: "Path mapping add button"), target: self, action: #selector(addRule(_:)))
        addButton.bezelStyle = .rounded
        let suggestButton = NSButton(title: NSLocalizedString("Suggest", comment: "Path mapping suggest button"), target: self, action: #selector(suggest(_:)))
        suggestButton.bezelStyle = .rounded
        suggestButton.isEnabled = samplePaths.isEmpty == false
        suggestButton.toolTip = NSLocalizedString("Look for the server\u{2019}s files on the drives mounted on this Mac and fill in the mappings that match.", comment: "Path mapping suggest tooltip")
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 680
        let doneButton = NSButton(title: NSLocalizedString("Done", comment: "Path mapping done button"), target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [addButton, suggestButton, NSView(), doneButton])
        buttons.orientation = .horizontal

        let content = NSStackView(views: [header, description, rowsStack, statusLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: 720)
        ])

        rebuildRows()

        // With nothing saved yet, look for the files on the mounted drives.
        if LibraryPathMapping.rules(forServer: serverName).isEmpty, samplePaths.isEmpty == false {
            runSuggestion(replacingEmptyRows: true)
        }
    }

    private func runSuggestion(replacingEmptyRows: Bool) {
        statusLabel.stringValue = NSLocalizedString("Looking for the files on the drives mounted on this Mac\u{2026}", comment: "Path mapping status while searching")
        let samples = samplePaths
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let suggested = LibraryPathMapping.suggestions(forServerPaths: samples,
                                                           candidateRoots: LibraryPathMapping.localCandidateRoots(),
                                                           fileExists: { FileManager.default.fileExists(atPath: $0) })
            DispatchQueue.main.async {
                guard let self = self else { return }
                if suggested.isEmpty {
                    self.statusLabel.stringValue = NSLocalizedString("Nothing matched. Check that the drives are connected in the Finder (Go \u{2192} Connect to Server), and that M3 is allowed to read them in System Settings \u{2192} Privacy & Security.", comment: "Path mapping status when nothing was found")
                    return
                }
                var merged = self.rules.filter { $0.to.isEmpty == false }
                for rule in suggested where merged.contains(where: { $0.from == rule.from }) == false {
                    merged.append(rule)
                }
                self.rules = merged
                self.save()
                self.rebuildRows()
                self.statusLabel.stringValue = String(format: NSLocalizedString("Found %d mapping(s) from the drives mounted on this Mac.", comment: "Path mapping status when mappings were found"), suggested.count)
            }
        }
    }

    @objc private func suggest(_ sender: Any?) {
        runSuggestion(replacingEmptyRows: false)
    }

    private func rebuildRows() {
        for subview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for (index, rule) in rules.enumerated() {
            let from = NSTextField(string: rule.from)
            from.placeholderString = NSLocalizedString("Server path, for example /volume1/Movies", comment: "Path mapping server field placeholder")
            from.tag = index * 2
            from.delegate = self
            from.widthAnchor.constraint(equalToConstant: 260).isActive = true

            let arrow = NSTextField(labelWithString: "\u{2192}")

            let to = NSTextField(string: rule.to)
            to.placeholderString = NSLocalizedString("Folder on this Mac, for example /Volumes/Movies", comment: "Path mapping Mac field placeholder")
            to.tag = index * 2 + 1
            to.delegate = self
            to.widthAnchor.constraint(equalToConstant: 260).isActive = true

            let choose = NSButton(title: NSLocalizedString("Choose\u{2026}", comment: "Path mapping choose button"), target: self, action: #selector(chooseFolder(_:)))
            choose.bezelStyle = .rounded
            choose.tag = index

            let remove = NSButton(title: "\u{2212}", target: self, action: #selector(removeRule(_:)))
            remove.bezelStyle = .rounded
            remove.tag = index
            remove.toolTip = NSLocalizedString("Remove this mapping", comment: "Path mapping remove tooltip")

            let row = NSStackView(views: [from, arrow, to, choose, remove])
            row.orientation = .horizontal
            row.spacing = 6
            rowsStack.addArrangedSubview(row)
        }
    }

    private func save() {
        // A row with nothing in it is not kept.
        LibraryPathMapping.setRules(rules.filter { $0.from.isEmpty == false || $0.to.isEmpty == false }, forServer: serverName)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let index = field.tag / 2
        guard index < rules.count else { return }
        if field.tag % 2 == 0 { rules[index].from = field.stringValue } else { rules[index].to = field.stringValue }
        save()
    }

    @objc private func chooseFolder(_ sender: NSButton) {
        guard sender.tag < rules.count else { return }
        let index = sender.tag
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Path mapping folder panel")
        panel.beginSheetModal(for: view.window ?? NSApp.mainWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self, index < self.rules.count else { return }
            self.rules[index].to = url.path
            self.save()
            self.rebuildRows()
        }
    }

    @objc private func addRule(_ sender: Any?) {
        rules.append(PathMapRule(from: "", to: ""))
        rebuildRows()
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard sender.tag < rules.count else { return }
        rules.remove(at: sender.tag)
        save()
        rebuildRows()
    }

    @objc private func done(_ sender: Any?) {
        // Take what is still being typed.
        view.window?.makeFirstResponder(nil)
        save()
        if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            dismiss(nil)
        }
    }
}
