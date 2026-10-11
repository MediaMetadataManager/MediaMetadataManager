//
//  DeliveryRules.swift
//
//  Delivery ("Destinations") rules: where a finished file goes once it has
//  been named, tagged and (if needed) merged. Works like the Filename
//  tab's naming rules -- an ordered list per media kind, each rule with
//  its own enable checkbox and "If <field> <operator> <value>" conditions
//  (the same NamingCondition type, so the same metadata fields and
//  operators) -- except that a rule picks a destination folder instead of
//  a name template. Movies and TV Shows have separate lists.
//
//  The first enabled rule whose conditions all match the file's tagged
//  metadata decides the folder. When nothing matches, the file goes to the
//  default destination: the Automatically Add to iTunes/TV folder.
//
//  Rules and the default destination only apply in "automatic delivery"
//  mode. Otherwise every finished file goes to the staging folder (Ready
//  for Media Library) for the user to review first.
//

import Foundation
import MP42Foundation

struct DeliveryRule: Codable {
    var conditions: [NamingCondition]
    /// Absolute path (a leading ~ is expanded when used).
    var folderPath: String
    var isEnabled: Bool

    init(conditions: [NamingCondition], folderPath: String = "", isEnabled: Bool = true) {
        self.conditions = conditions
        self.folderPath = folderPath
        self.isEnabled = isEnabled
    }

    var folderURL: URL? {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Same AND-across-fields / OR-within-a-field grouping as a naming rule.
    func matches(metadata: MP42Metadata) -> Bool {
        guard conditions.isEmpty == false else { return false }
        return NamingRule(conditions: conditions, tokens: []).matches(metadata: metadata)
    }
}

extension MediaIntakePrefs {

    /// The staging folder ("Ready for Media Library"): where finished files
    /// wait for the user to look them over when automatic delivery is off.
    static var stagingFolder: URL? { return readyForLibraryFolder }

    /// The default final destination. When the first row of the Automatically
    /// Add list is blank (or the list is empty) it is the folder the Apple TV
    /// app's own settings point to, read live; otherwise the first folder the
    /// user listed.
    static var finalDefaultFolder: URL? {
        let listed = automaticMediaIngestFolders.first(where: { $0.path.isEmpty == false })
        if listed == nil || ingestListFollowsAppleTV {
            return defaultAutomaticMediaIngestFolderURL() ?? listed
        }
        return listed
    }

    /// Where a file goes when no rule applies: the final default folder in
    /// automatic mode (the staging folder if there is no final default),
    /// otherwise the staging folder. Nil means "leave it where it is".
    static var fallbackDeliveryFolder: URL? {
        if deliverAutomatically { return finalDefaultFolder ?? stagingFolder }
        return stagingFolder
    }

    /// Where a file with this tagged metadata should be delivered. With
    /// automatic delivery off that is always the staging folder. With it on:
    /// the first enabled matching rule's folder (Movies and TV Shows have
    /// their own lists; metadata without a media kind counts as a movie),
    /// else the final default folder.
    static func deliveryFolder(for metadata: MP42Metadata?) -> URL? {
        guard deliverAutomatically else { return stagingFolder }

        var isTVShow = false
        if let metadata = metadata,
           let kindValue = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
           MediaKind(rawValue: kindValue) == .tvShow {
            isTVShow = true
        }

        if let metadata = metadata {
            let rules = isTVShow ? tvDeliveryRules : movieDeliveryRules
            for rule in rules where rule.isEnabled {
                if let folder = rule.folderURL, rule.matches(metadata: metadata) {
                    return folder
                }
            }
        }
        return fallbackDeliveryFolder
    }

    /// Every folder a finished file can be delivered to -- used so the
    /// Intake scan never picks a delivered release up again.
    static var allDeliveryFolders: [URL] {
        var folders: [URL] = []
        if let staging = stagingFolder { folders.append(staging) }
        folders.append(contentsOf: automaticMediaIngestFolders)
        if let detected = defaultAutomaticMediaIngestFolderURL() { folders.append(detected) }
        for rule in movieDeliveryRules + tvDeliveryRules {
            if let folder = rule.folderURL { folders.append(folder) }
        }
        return folders
    }

    /// Folders that already hold finished library files: the staging folder
    /// and every rule/default destination, except Automatically Add folders
    /// (the TV/Music app takes files out of those the moment they land).
    static var libraryRoots: [URL] {
        let roots = allDeliveryFolders
            .map { $0.standardizedFileURL }
            .filter { $0.path.isEmpty == false && $0.isAutomaticMediaIngestFolder == false }
        // Longest path first so the most specific root wins.
        return roots.sorted { $0.path.count > $1.path.count }
    }

    /// The library root a file or folder sits inside, if any.
    static func libraryRoot(containing url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return libraryRoots.first { path.hasPrefix($0.path + "/") }
    }

    /// True for an MP4-family file that already lives in the staging folder
    /// or another delivery destination. Adding such a file to the Queue
    /// scans and tags it where it is, instead of writing a second copy
    /// into a new folder.
    static func shouldEditInPlace(_ url: URL) -> Bool {
        guard ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) else { return false }
        return libraryRoot(containing: url) != nil
    }

    /// True when there is anywhere at all to deliver to.
    static var hasDeliveryDestination: Bool {
        return fallbackDeliveryFolder != nil
    }
}

extension MP42File {
    /// Where this file should be delivered, per the Media Locations settings.
    var deliveryFolder: URL? {
        return MediaIntakePrefs.deliveryFolder(for: metadata)
    }
}
