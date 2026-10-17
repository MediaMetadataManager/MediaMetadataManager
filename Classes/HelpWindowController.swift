//
//  HelpWindowController.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  The app's own Help window: a list of help pages (or search results) on the
//  left and the page itself on the right. The pages are the guides, built into
//  HTML by Tools/docs/build-helpbook.py and shipped inside the app; HelpIndex
//  does the searching. Built in code, like the other small windows. This window
//  replaces the system's Help Viewer, which did not find or search a book for
//  this app reliably.
//

import Cocoa
import WebKit

final class HelpWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate,
                                  NSTableViewDataSource, NSTableViewDelegate {

    static let shared = HelpWindowController()

    private enum Row {
        case page(HelpPage)
        case hit(HelpHit)
        case message(String)
    }

    private let index = HelpIndex.shared
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let splitView = NSSplitView()
    private var rows: [Row] = []
    private var highlightTerms: [String] = []
    private var ignoreSelectionChange = false
    private var didPositionDivider = false

    // MARK: Setup

    private init() {
        let window = HelpPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.title = NSLocalizedString("Media Metadata Manager Help", comment: "Help window title")
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.setFrameAutosaveName("M3HelpWindow")
        if window.frame.width < 640 { window.setContentSize(NSSize(width: 980, height: 700)) }
        window.center()
        showContents(selecting: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("HelpWindowController is made in code")
    }

    private func buildContent(in window: NSWindow) {
        searchField.placeholderString = NSLocalizedString("Search help", comment: "Help window search field")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("topic"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAutomaticRowHeights = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let left = NSView()
        left.addSubview(searchField)
        left.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(left)
        splitView.addArrangedSubview(webView)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        window.contentView = splitView
    }

    // MARK: Window level

    func windowDidResignKey(_ notification: Notification) {
        // Back to a normal window once no dialog is modal any more.
        if NSApp.modalWindow == nil { window?.level = .normal }
    }

    // MARK: Showing

    /// Opens the window on an anchor of the help (see HelpAnchor), or on the front page.
    func show(anchor: String? = nil) {
        present()
        searchField.stringValue = ""
        highlightTerms = []
        let page = anchor.flatMap { index.page(forAnchor: $0) } ?? index.pages.first
        showContents(selecting: page)
        if let page = page { load(page, anchor: anchor) }
    }

    /// Opens the window on a page found by a search, with the search words marked.
    func show(page: HelpPage, searchedFor query: String? = nil) {
        present()
        if let query = query, !query.isEmpty {
            searchField.stringValue = query
            runSearch(openFirst: false)
            highlightTerms = HelpIndex.terms(in: query)
        } else {
            searchField.stringValue = ""
            highlightTerms = []
            showContents(selecting: page)
        }
        load(page, anchor: nil)
    }

    /// Opens the window with a search already run (the Help menu's "Show All Help Topics").
    func show(searchString: String) {
        present()
        searchField.stringValue = searchString
        runSearch(openFirst: true)
    }

    private func present() {
        guard let window = window else { return }
        // A "?" button in a review dialog opens this while that dialog is modal: stay above it.
        window.level = HelpWindowController.level
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        if !didPositionDivider {
            didPositionDivider = true
            window.layoutIfNeeded()
            splitView.setPosition(290, ofDividerAt: 0)
        }
    }

    // MARK: Contents and search

    private func showContents(selecting page: HelpPage?) {
        rows = index.pages.map { Row.page($0) }
        tableView.reloadData()
        guard let page = page, let row = rows.firstIndex(where: {
            if case .page(let p) = $0 { return p.file == page.file }
            return false
        }) else {
            tableView.deselectAll(nil)
            return
        }
        ignoreSelectionChange = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        ignoreSelectionChange = false
    }

    @objc private func searchChanged(_ sender: Any?) {
        runSearch(openFirst: true)
    }

    private func runSearch(openFirst: Bool) {
        let query = searchField.stringValue
        let terms = HelpIndex.terms(in: query)
        guard !terms.isEmpty else {
            highlightTerms = []
            showContents(selecting: nil)
            return
        }
        highlightTerms = terms
        let hits = index.search(query)
        rows = hits.isEmpty
            ? [.message(String(format: NSLocalizedString("No help topic matches \u{201C}%@\u{201D}.", comment: "Help search with no result"), query))]
            : hits.map { Row.hit($0) }
        tableView.reloadData()
        guard openFirst, let first = hits.first else { return }
        ignoreSelectionChange = true
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        ignoreSelectionChange = false
        load(first.page, anchor: nil)
    }

    private func load(_ page: HelpPage, anchor: String?) {
        guard let url = index.url(for: page, anchor: anchor),
              let root = HelpIndex.resourcesFolder else { return }
        webView.loadFileURL(url, allowingReadAccessTo: root)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .page: return 24
        case .hit: return 58
        case .message: return 44
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .message = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("topicCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 3
            field.cell?.wraps = true
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let text = NSMutableAttributedString()
        switch rows[row] {
        case .page(let page):
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = CGFloat(page.level) * 14
            style.headIndent = CGFloat(page.level) * 14
            style.lineBreakMode = .byTruncatingTail
            text.append(NSAttributedString(string: page.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: page.level == 0 ? .semibold : .regular),
                .paragraphStyle: style
            ]))
        case .hit(let hit):
            text.append(NSAttributedString(string: hit.page.title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]))
            text.append(NSAttributedString(string: hit.snippet, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        case .message(let message):
            text.append(NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        cell.textField?.attributedStringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !ignoreSelectionChange, tableView.selectedRow >= 0 else { return }
        switch rows[tableView.selectedRow] {
        case .page(let page): load(page, anchor: nil)
        case .hit(let hit): load(hit.page, anchor: nil)
        case .message: break
        }
    }

    // MARK: Web view

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Keep the list in step when a link inside a page leads to another page.
        if let name = webView.url?.lastPathComponent, searchField.stringValue.isEmpty,
           let row = rows.firstIndex(where: {
               if case .page(let p) = $0 { return p.file == name }
               return false
           }), tableView.selectedRow != row {
            ignoreSelectionChange = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            ignoreSelectionChange = false
        }
        guard !highlightTerms.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: highlightTerms),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(HelpWindowController.highlightScript(terms: json), completionHandler: nil)
    }

    /// Marks every occurrence of the search words in the page and scrolls to the first one.
    static func highlightScript(terms json: String) -> String {
        """
        (function (terms) {
          var esc = terms.map(function (t) { return t.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'); });
          var test = new RegExp(esc.join('|'), 'i');
          var all = new RegExp('(' + esc.join('|') + ')', 'gi');
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var nodes = [];
          while (walker.nextNode()) { nodes.push(walker.currentNode); }
          nodes.forEach(function (n) {
            var p = n.parentNode;
            if (!p || /^(SCRIPT|STYLE|MARK)$/.test(p.nodeName) || !test.test(n.nodeValue)) { return; }
            var span = document.createElement('span');
            span.innerHTML = n.nodeValue.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(all, '<mark>$1</mark>');
            p.replaceChild(span, n);
          });
          var first = document.querySelector('mark');
          if (first && !location.hash) { first.scrollIntoView({block: 'center'}); }
        })(\(json));
        """
    }
}

/// The Help window as a panel that keeps working while one of the Queue's review dialogs is open
/// (those run modally, and a plain window would show but ignore every click).
final class HelpPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        worksWhenModal = true
    }

    override var canBecomeMain: Bool { true }
}

extension HelpWindowController {

    /// Above the review dialogs (level .modalPanel) while one is showing, normal otherwise.
    static var level: NSWindow.Level {
        NSApp.modalWindow == nil ? .normal : NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)
    }
}
