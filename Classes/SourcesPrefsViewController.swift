//
//  SourcesPrefsViewController.swift
//  Subler
//

import Cocoa

/// Preferences pane for metadata sources. Three tabs, switched with a
/// small, centered NSTabView -- the same native tab-button control (not a
/// manually-positioned NSSegmentedControl) the Metadata / Artwork switch
/// in the main document window uses (see MovieView.xib), so this pane's
/// tab buttons end up centered the same way instead of pinned to the
/// leading edge:
///
/// - "Providers": every checkbox-toggleable movie/TV metadata source,
///   listed under the media type(s) it applies to -- Movies and TV Shows,
///   since a provider can be relevant to one and not the other (this also
///   leaves room for future media types, such as Audiobooks or Descriptive
///   Audio, to get their own list here). A disabled provider is left out of
///   the Search Metadata provider popup and the batch queue options (see
///   MetadataSearch.movieProviders / tvProviders in MetadataImporter.swift).
///   Installed metadata-source plugins (see MetadataPluginLoader) are
///   listed inline in the Movies column, right alongside Subler's own
///   built-in providers (TheMovieDB, AppleTV, iTunes Store) -- movies only
///   for now, since plugins have no TV show equivalent yet -- rather than
///   under a separate "Plugins" heading of their own: to the person turning
///   a source on or off, a plugin-backed provider is just another movie
///   metadata source, not a different kind of thing. Custom sources aren't
///   part of either list -- they're always available and are managed on
///   the Custom Sources tab.
/// - "Custom Sources": user-configured, JSON-field-mapped metadata sources
///   (ported from Subler Clean -- see CustomSourcesListViewController).
///   This tab's content is that whole pane embedded as a child view
///   controller.
/// - "Media Intake" (MediaMetadataManager only): the settings side of the Intake/Queue
///   workflow -- see MediaIntakeManagerViewController's header comment.
///   The actual monitoring/naming/metadata/merge work runs in the Queue,
///   not here; this tab is just where the folder locations and the
///   auto-watch toggle live.
///
/// This class owns the Providers tab directly and the tab view switching
/// between all three; the other two tabs are child view controllers.
final class SourcesPrefsViewController: NSViewController, NSTabViewDelegate {

    /// Keeps the "Configure..." popover (see configurePlugin(_:)) alive
    /// while it's shown.
    private var activePopover: NSPopover?

    /// The toggleable core providers shown under "Movies" and "TV Shows" in
    /// the Providers tab -- see MetadataSearch.coreMovieProviders/coreTVProviders.
    private let movieProviders: [String] = MetadataSearch.coreMovieProviders
    private let tvProviders: [String] = MetadataSearch.coreTVProviders

    /// Installed plugins -- see MetadataSearch.pluginMovieProviders.
    /// Usually empty. Folded into allMovieProviders below rather than
    /// listed under a section of their own.
    private let pluginProviders: [String] = MetadataSearch.pluginMovieProviders

    /// Everything shown in the Movies column: Subler's own built-in
    /// providers followed by any installed plugin. Shares one combined
    /// checkbox list (and one toggle action, toggleMovieProvider(_:)) with
    /// no visual distinction between the two, since both are toggled the
    /// same way and write to the same disabledMovieProviders set -- a
    /// plugin's name can never collide with a core provider's (see
    /// MetadataSearch.coreMovieProviders/pluginMovieProviders).
    private var allMovieProviders: [String] { movieProviders + pluginProviders }

    /// Owns the actual Custom Sources list/detail UI -- see
    /// CustomSourcesListViewController. Kept as a real child view
    /// controller (addChild) rather than just borrowing its view, so its
    /// own view lifecycle (and anything it does via
    /// NSViewController-level plumbing) works normally.
    private let customSourcesController = CustomSourcesListViewController()

    /// Owns the Media Intake tab's UI -- see
    /// MediaIntakeManagerViewController. MediaMetadataManager only, not ported to the
    /// public Subler app.
    private let mediaIntakeManagerController = MediaIntakeManagerViewController()

    /// Owns the Media Locations tab (default destination, delivery rules, staging).
    private let destinationsController = DestinationsViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = NSLocalizedString("Sources", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// PrefsWindowController just swaps window.contentView in and out
    /// (see selectItem(_:animate:)) with no resize call of its own --
    /// NIB-based tabs (General/Metadata/Sets) happen to make the window
    /// grow AND shrink to fit anyway, because their root view is Auto
    /// Layout constrained tightly enough that window.layoutIfNeeded()
    /// has no choice but to satisfy it. This view controller's
    /// containerView has no such requirement (it is a plain frame-based
    /// NSView), so nothing forces a shrink: arriving here from a taller
    /// tab (Metadata, Filename) leaves the window at that taller height,
    /// with this tab's content top-aligned above the leftover space --
    /// exactly the "stays tall" behavior reported. Explicitly resizing on
    /// every appearance (viewWillAppear fires every time this pane is
    /// selected, unlike viewDidLoad -- OutputPrefsViewController's own
    /// identical fix relies on the same thing) makes this pane resize the
    /// same way regardless of which pane was active before it.
    override func viewWillAppear() {
        super.viewWillAppear()
        resizeWindowToFitContent(adjustWidth: true)
    }

    /// Switching between the Providers/Custom Sources/Media Intake tabs
    /// can switch to a noticeably taller or shorter one now that they're
    /// separate NSTabViewItems rather than overlapping views sharing one
    /// canvas sized for the tallest of the three (see this file's git
    /// history for that earlier approach) -- resize on every in-pane tab
    /// switch too, the same way OutputPrefsViewController does for its
    /// own Movies/TV Shows tabs. Width stays fixed across these in-pane
    /// switches (adjustWidth: false) -- only the toolbar-level switch into
    /// this pane (viewWillAppear() above) is allowed to change the
    /// window's width, so cycling between the three sub-tabs here doesn't
    /// also make the window visibly widen/narrow each time, which read as
    /// "looks strange" (and, combined with the Custom Sources tab's own
    /// width needs, could make it look collapsed/cramped on a switch that
    /// had just shrunk the window for a narrower tab).
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        resizeWindowToFitContent(adjustWidth: false)
    }

    /// The Media Intake tab calls this when its folder lists gain or lose
    /// a row, so the window follows the tab's new height.
    func contentSizeDidChange() {
        resizeWindowToFitContent(adjustWidth: false)
    }

    /// Mirrors OutputPrefsViewController.resizeWindowToFitContent(): grows
    /// or shrinks the window to this view's actual fitting size, which
    /// now follows whichever of the three sub-tabs is currently selected
    /// (see tabView(_:didSelect:) above). adjustWidth is false for an
    /// in-pane sub-tab switch so only height follows the selected tab --
    /// see tabView(_:didSelect:)'s own comment for why.
    private func resizeWindowToFitContent(adjustWidth: Bool) {
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize

        guard let window = view.window else {
            let width = adjustWidth ? max(fitting.width, 640) : view.frame.width
            view.setFrameSize(NSSize(width: width, height: fitting.height))
            return
        }

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let width = adjustWidth ? max(fitting.width, 640) : contentRect.width

        guard abs(contentRect.height - fitting.height) > 0.5 || abs(contentRect.width - width) > 0.5 else { return }

        var frame = window.frame
        let deltaHeight = fitting.height - contentRect.height
        let deltaWidth = width - contentRect.width
        frame.size.height += deltaHeight
        frame.origin.y -= deltaHeight
        frame.size.width += deltaWidth
        frame.origin.x -= deltaWidth / 2
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    override func loadView() {
        // Plain placeholder, assigned immediately -- the real construction
        // happens in buildUI(), called from viewDidLoad() below, once
        // self.view already exists. This mirrors
        // OutputPrefsViewController.loadView()/viewDidLoad() exactly, and
        // for the same reason: NSTabView.addTabViewItem(_:) auto-selects
        // the very first item it's given and fires
        // tabView(_:didSelect:) for it synchronously, which calls
        // resizeWindowToFitContent() -- and that reads this controller's
        // own `view` property. Reading `view` before it has been assigned
        // makes NSViewController call loadView() again to produce one,
        // which builds the tab view and calls addTabViewItem(_:) again,
        // which selects again and resizes again, and so on forever --
        // this used to be built entirely here with self.view assigned
        // only at the very end, which recursed until the app crashed from
        // a stack overflow the moment Sources was first opened.
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    // Small control size + NSTabView (not a manually-positioned
    // NSSegmentedControl) to match MovieView.xib's Metadata/Artwork
    // tab view exactly -- see this file's header comment. Each tab's
    // root view is pinned on every edge, including bottom, to its
    // actual content (see each one's own loadView -- Media Intake's
    // mainStack bottom-pin is what makes this work for it); NSTabView
    // auto-pins the currently selected tabViewItem's view to its own
    // content area the same way, so this view's fittingSize naturally
    // follows whichever of the three tabs is currently selected (see
    // tabView(_:didSelect:) above, which resizes the window to match on
    // every switch).
    private func buildUI() {
        addChild(customSourcesController)
        addChild(mediaIntakeManagerController)
        addChild(destinationsController)

        // Each tab's own root view defaults to
        // translatesAutoresizingMaskIntoConstraints == true (none of the
        // three set it themselves -- they used to rely on this class's
        // old show/hide loop to turn it off); NSTabView pins the selected
        // item's view with its own Auto Layout constraints, which would
        // conflict with that view's translated autoresizing-mask
        // constraints left on, so it has to go off here instead.
        let providersView = makeProvidersView()
        providersView.translatesAutoresizingMaskIntoConstraints = false
        let customSourcesView = customSourcesController.view
        customSourcesView.translatesAutoresizingMaskIntoConstraints = false
        let mediaIntakeManagerView = mediaIntakeManagerController.view
        mediaIntakeManagerView.translatesAutoresizingMaskIntoConstraints = false
        let destinationsView = destinationsController.view
        destinationsView.translatesAutoresizingMaskIntoConstraints = false

        let providersTabViewItem = NSTabViewItem(identifier: "providers")
        providersTabViewItem.label = NSLocalizedString("Providers", comment: "")
        providersTabViewItem.view = providersView

        let customSourcesTabViewItem = NSTabViewItem(identifier: "customSources")
        customSourcesTabViewItem.label = NSLocalizedString("Custom Sources", comment: "")
        customSourcesTabViewItem.view = customSourcesView

        let mediaIntakeTabViewItem = NSTabViewItem(identifier: "mediaIntake")
        mediaIntakeTabViewItem.label = NSLocalizedString("Media Intake", comment: "")
        mediaIntakeTabViewItem.view = mediaIntakeManagerView

        let destinationsTabViewItem = NSTabViewItem(identifier: "destinations")
        destinationsTabViewItem.label = NSLocalizedString("Media Locations", comment: "")
        destinationsTabViewItem.view = destinationsView

        let tabView = NSTabView()
        tabView.controlSize = .small
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        tabView.addTabViewItem(providersTabViewItem)
        tabView.addTabViewItem(customSourcesTabViewItem)
        tabView.addTabViewItem(mediaIntakeTabViewItem)
        tabView.addTabViewItem(destinationsTabViewItem)

        view.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }

    // MARK: - Providers tab

    private func makeProvidersView() -> NSView {
        let view = NSView()

        let headerLabel = NSTextField(labelWithString: NSLocalizedString("Metadata Providers", comment: ""))
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let descriptionLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("Turn the built-in providers on or off, separately for movies and TV shows. A disabled provider is removed from the search provider menu and the Queue options. When the Queue looks up a title on its own, it searches every provider ticked here and merges what the ones that found the same title return, so the result is as complete as possible. When you edit a single file, you choose the provider yourself. Custom sources are always available and are configured on the Custom Sources tab.", comment: ""))
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.preferredMaxLayoutWidth = 600

        // Toggles TMDB's own public include_adult search parameter (see
        // TheMovieDBService.includeAdultParam), labelled "Complete Content
        // Search" because that is what it does: ask TheMovieDB for its
        // complete result set. Placed inline next to the TheMovieDB checkbox in the
        // Movies column (see makeProviderSection's extraControl
        // parameter) rather than as its own standalone row, since it's
        // a TheMovieDB-specific search option, not a general one that
        // applies across every provider in the list.
        let allowAdultContentCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Complete Content Search", comment: ""),
                                                  target: self, action: #selector(toggleAllowAdultContent(_:)))
        allowAdultContentCheckbox.state = MetadataPrefs.allowAdultContent ? .on : .off
        allowAdultContentCheckbox.translatesAutoresizingMaskIntoConstraints = false
        allowAdultContentCheckbox.toolTip = NSLocalizedString("Includes TheMovieDB's complete result set in search, including titles it classifies separately as adult content.", comment: "")

        let movieSection = makeProviderSection(title: NSLocalizedString("Movies", comment: ""),
                                                providers: allMovieProviders,
                                                disabled: MetadataPrefs.disabledMovieProviders,
                                                action: #selector(toggleMovieProvider(_:)),
                                                extraControl: { name in name == TheMovieDB().name ? allowAdultContentCheckbox : nil })
        let tvSection = makeProviderSection(title: NSLocalizedString("TV Shows", comment: ""),
                                             providers: tvProviders,
                                             disabled: MetadataPrefs.disabledTVProviders,
                                             action: #selector(toggleTVProvider(_:)))

        let sections = NSStackView(views: [movieSection, tvSection])
        sections.orientation = .horizontal
        sections.alignment = .top
        sections.distribution = .fillEqually
        sections.spacing = 32
        sections.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLabel)
        view.addSubview(descriptionLabel)
        view.addSubview(sections)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            descriptionLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            sections.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 16),
            sections.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sections.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])

        sections.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20).isActive = true

        return view
    }

    /// Builds one titled column of provider checkboxes (e.g. "Movies" or
    /// "TV Shows") for the Providers tab.
    private func makeProviderSection(title: String, providers: [String], disabled: Set<String>, action: Selector, extraControl: (String) -> NSView? = { _ in nil }) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        for (index, name) in providers.enumerated() {
            let checkbox = NSButton(checkboxWithTitle: name, target: self, action: action)
            checkbox.tag = index
            checkbox.state = disabled.contains(name) ? .off : .on

            var rowViews: [NSView] = [checkbox]

            if PluginSettings.fields(for: name) != nil {
                // This provider (a plugin, never a core built-in one --
                // see PluginSettings.fields(for:)) has its own settings,
                // like an API key, that need somewhere to be entered.
                // Adds a small "Configure..." button right next to its
                // checkbox rather than a separate list elsewhere, since
                // it's still fundamentally about this one provider.
                let configureButton = NSButton(title: NSLocalizedString("Configure…", comment: ""),
                                                target: self, action: #selector(configurePlugin(_:)))
                configureButton.bezelStyle = .inline
                configureButton.controlSize = .small
                configureButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                configureButton.identifier = NSUserInterfaceItemIdentifier(name)
                configureButton.translatesAutoresizingMaskIntoConstraints = false
                rowViews.append(configureButton)
            }

            if let extra = extraControl(name) {
                // A provider-specific option (e.g. TheMovieDB's "Complete
                // Content Search") shown inline next to that one
                // provider's checkbox rather than as a standalone row --
                // see makeProvidersView().
                rowViews.append(extra)
            }

            if rowViews.count > 1 {
                let row = NSStackView(views: rowViews)
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                stackView.addArrangedSubview(row)
            } else {
                stackView.addArrangedSubview(checkbox)
            }
        }

        container.addSubview(titleLabel)
        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            stackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    @objc private func toggleAllowAdultContent(_ sender: NSButton) {
        MetadataPrefs.allowAdultContent = sender.state == .on
    }

    /// Opens the "Configure..." popover for a plugin-backed provider
    /// that has its own settings -- see PluginSettings.fields(for:) and
    /// PluginSettingsViewController.
    @objc private func configurePlugin(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue,
              let fields = PluginSettings.fields(for: name) else { return }

        let popover = NSPopover()
        let controller = PluginSettingsViewController(pluginName: name, fields: fields)
        controller.onFinish = { [weak popover] in popover?.performClose(nil) }
        popover.contentViewController = controller
        popover.behavior = .transient
        activePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// Handles both Subler's own built-in movie providers and any installed
    /// plugin -- see allMovieProviders. Both write to the same
    /// disabledMovieProviders set, so there's no need to tell which kind of
    /// provider sender.tag refers to.
    @objc private func toggleMovieProvider(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < allMovieProviders.count else { return }
        let name = allMovieProviders[sender.tag]

        var disabled = MetadataPrefs.disabledMovieProviders
        if sender.state == .off {
            disabled.insert(name)
        } else {
            disabled.remove(name)
        }
        MetadataPrefs.disabledMovieProviders = disabled
    }

    @objc private func toggleTVProvider(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < tvProviders.count else { return }
        let name = tvProviders[sender.tag]

        var disabled = MetadataPrefs.disabledTVProviders
        if sender.state == .off {
            disabled.insert(name)
        } else {
            disabled.remove(name)
        }
        MetadataPrefs.disabledTVProviders = disabled
    }
}
