//
//  GeneralPrefsViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 06/02/2018.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Artwork position (Portrait/Landscape) setting, TV Shows naming-rule
//  editor, launch behaviour fixes.
//

import Cocoa
import MP42Foundation

class GeneralPrefsViewController: NSViewController {

    /// Backs the "Artwork Position" popup added to this pane -- a
    /// QueuePreferences instance whose providerArtwork/providerArtworkSize
    /// are UserDefaults-backed (see QueuePreferences.swift's own init),
    /// so binding to it here reads/writes the exact same persisted values
    /// as the "Artwork:" popup in the Queue Options popover
    /// (OptionsViewController/QueueOptions.xib) -- one setting, two entry
    /// points, matching the pattern already established for
    /// QueuePreferences elsewhere (e.g. ScriptCommand.swift's own
    /// throwaway instances). Not a live-synced singleton: if both panes
    /// are open at once, each holds its own snapshot until reopened --
    /// an accepted, pre-existing tradeoff of this app's QueuePreferences
    /// design, not something new introduced here.
    @objc private dynamic let options: QueuePreferences

    init() {
        self.options = QueuePreferences()
        super.init(nibName: nil, bundle: nil)
        self.title = NSLocalizedString("General", comment: "")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var nibName: NSNib.Name? {
        return "GeneralPrefsViewController"
    }

    @IBAction func clearRecentSearches(_ sender: Any) {
        MetadataSearchController.clearRecentSearches()
    }

    @IBAction func deleteCachedMetadata(_ sender: Any) {
        MetadataSearchController.deleteCachedMetadata()
    }

    @IBAction func updateRatingsCountry(_ sender: Any) {
        // Unused
    }

    @objc dynamic var ratingsCountries: [String] { return Ratings.shared.countries.map { $0.displayName } }

    @objc dynamic var logFormatOptions: [String] {
        return [
            NSLocalizedString("Time Only", comment: ""),
            NSLocalizedString("Date and Time", comment: "")
        ]
    }

    /// Backs the "At Launch:" popup -- see Prefs.LaunchBehavior. Order
    /// matches its raw Int values (0, 1, 2) exactly, the same convention
    /// logFormatOptions above already relies on for its own popup's
    /// selectedTag <-> values.SBLogFormat binding.
    @objc dynamic var launchBehaviorOptions: [String] {
        return LaunchBehavior.allCases.map { $0.localizedName }
    }

}
