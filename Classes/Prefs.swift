//
//  Prefs.swift
//  Subler
//
//  Created by Damiano Galassi on 07/02/2020.
//

import Foundation
import MP42Foundation

private let ud = UserDefaults.standard

private protocol Registable {
    func register(in dictionary: inout [String :Any])
}

private extension UserDefaults {
    func register(defaults values: [Registable]) {
        var defaults = [String : Any]()
        values.forEach { $0.register(in: &defaults) }
        self.register(defaults: defaults)
    }
}

@propertyWrapper
struct Stored<T> : Registable {
    let key: String
    let defaultValue: T

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get { ud.object(forKey: key) as? T ?? defaultValue }
        set { ud.set(newValue, forKey: key) }
    }

    func register(in dictionary: inout [String :Any]) {
        dictionary[key] = defaultValue
    }
}

@propertyWrapper
struct StoredCodable<T: Codable> : Registable {
    let key: String
    let defaultValue: T

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            guard let data = ud.data(forKey: key) else { return defaultValue }
            let value = try? JSONDecoder().decode(T.self, from: data)
            return value ?? defaultValue
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            ud.set(data, forKey: key)
        }
    }

    func register(in dictionary: inout [String :Any]) {
        if let data = try? JSONEncoder().encode(defaultValue) {
            dictionary[key] = data
        }
    }
}

/// What happens automatically when the app launches with no file to
/// reopen from the last session -- see AppDelegate's
/// applicationShouldOpenUntitledFile(_:). Replaces two previously
/// separate, independently-firing behaviors that could both trigger on
/// the very same launch -- the old standalone "Show open panel"
/// checkbox, and an always-on restore of the Queue window if it
/// happened to be visible when the app last quit -- with one explicit,
/// mutually exclusive choice. That overlap was exactly the "what opens
/// when the app starts" ambiguity this enum exists to remove.
enum LaunchBehavior: Int, CaseIterable {
    case openPanel = 0
    case mainWindow = 1
    case queue = 2

    var localizedName: String {
        switch self {
        case .openPanel: return NSLocalizedString("Show Open Panel", comment: "Launch behavior option")
        case .mainWindow: return NSLocalizedString("Show Main Window", comment: "Launch behavior option")
        case .queue: return NSLocalizedString("Show Queue", comment: "Launch behavior option")
        }
    }
}

enum Prefs {

    static func register() {
        ud.register(defaults: [_crashOnException, _suppressDonationAlert, _fileType, _organizeAlternateGroups,
                               _organizeAlternateGroups, _inferMediaCharacteristics, _audioMixdown,
                               _audioBitrate, _audioDRC, _audioConvertAC3, _audioKeepAC3, _audioConvertDts,
                               _audioDtsOptions, _subtitleConvertBitmap, _ratingsCountry, _chaptersPreviewPosition,
                               _chaptersPreviewTrack, _mp464bitOffset, _mp464bitTimes, _mp4SaveAsOptimize, _forceHvc1, _set4KHDVideoMetadata,
                               _logFormat, _renameFileToMatchMetadataOnSave, _syncMovieFolderNameOnSave,
                               _useAppleTVStyleTVFolders, _fillSeriesDescriptionOnSave, _showWelcomeScreenAtLaunch])
        migrateLaunchBehaviorIfNeeded()
    }

    @Stored(key: "NSApplicationCrashOnException", defaultValue: true)
    private static var crashOnException: Bool

    /// Stored as LaunchBehavior's raw Int value so
    /// GeneralPrefsViewController.xib's popup can bind directly to it
    /// (selectedTag), the same way the existing "Log Format" popup
    /// already binds to SBLogFormat. Deliberately NOT registered as a
    /// UserDefaults default in register() above -- that's what lets
    /// migrateLaunchBehaviorIfNeeded() below tell "never configured yet"
    /// apart from "explicitly set to openPanel", since
    /// ud.object(forKey:) only returns nil in the former case. Use the
    /// typed launchBehavior below instead of this raw value directly.
    @Stored(key: "SBLaunchBehavior", defaultValue: LaunchBehavior.openPanel.rawValue)
    static var launchBehaviorRawValue: Int

    static var launchBehavior: LaunchBehavior {
        get { LaunchBehavior(rawValue: launchBehaviorRawValue) ?? .openPanel }
        set { launchBehaviorRawValue = newValue.rawValue }
    }

    /// One-time migration from the old standalone "Show open panel"
    /// checkbox (SBShowOpenPanelAtLaunch) into the new three-way
    /// SBLaunchBehavior choice, run at every launch via register() above
    /// (a no-op once SBLaunchBehavior has ever been explicitly saved --
    /// see its own doc comment). The checkbox being off used to mean
    /// "don't show the open panel" with no further guidance on what
    /// should happen instead -- the closest equivalent in the new
    /// three-way choice is "just show the main window", so that's what
    /// an existing off setting becomes; on maps straight across to
    /// openPanel, the pre-existing default both before and after.
    private static func migrateLaunchBehaviorIfNeeded() {
        guard ud.object(forKey: "SBLaunchBehavior") == nil else { return }
        guard let legacyShowOpenPanel = ud.object(forKey: "SBShowOpenPanelAtLaunch") as? Bool else { return }
        launchBehavior = legacyShowOpenPanel ? .openPanel : .mainWindow
    }

    @Stored(key: "SBIgnoreDonationAlert", defaultValue: false)
    static var suppressDonationAlert: Bool

    @Stored(key: "rememberWindowSize", defaultValue: false)
    static var rememberDocumentWindowSize: Bool

    @Stored(key: "SBSaveFormat", defaultValue: "mp4")
    static var fileType: String

    @Stored(key: "SBOrganizeAlternateGroups", defaultValue: true)
    static var organizeAlternateGroups: Bool

    @Stored(key: "SBInferMediaCharacteristics", defaultValue: true)
    static var inferMediaCharacteristics: Bool

    @Stored(key: "SBAudioMixdown", defaultValue: 3)
    static var audioMixdown: UInt

    @Stored(key: "SBAudioBitrate", defaultValue: 96)
    static var audioBitrate: UInt32

    @Stored(key: "SBAudioDRC", defaultValue: 0)
    static var audioDRC: Float

    @Stored(key: "SBAudioConvertAC3", defaultValue: true)
    static var audioConvertAC3: Bool

    @Stored(key: "SBAudioKeepAC3", defaultValue: true)
    static var audioKeepAC3: Bool

    @Stored(key: "SBAudioConvertDts", defaultValue: true)
    static var audioConvertDts: Bool

    @Stored(key: "SBAudioDtsOptions", defaultValue: 0)
    static var audioDtsOptions: UInt

    @Stored(key: "SBSubtitleConvertBitmap", defaultValue: true)
    static var subtitleConvertBitmap: Bool

    @Stored(key: "SBRatingsCountry", defaultValue: "All countries")
    static var ratingsCountry: String

    @Stored(key: "SBChaptersPreviewPosition", defaultValue: 0.5)
    static var chaptersPreviewPosition: Float

    @Stored(key: "chaptersPreviewTrack", defaultValue: true)
    static var chaptersPreviewTrack: Bool

    @Stored(key: "mp464bitOffset", defaultValue: true)
    static var mp464bitOffset: Bool

    @Stored(key: "mp464bitTimes", defaultValue: false)
    static var mp464bitTimes: Bool

    @Stored(key: "mp4SaveAsOptimize", defaultValue: false)
    static var mp4SaveAsOptimize: Bool

    @Stored(key: "SBForceHvc1", defaultValue: true)
    static var forceHvc1: Bool

    /// Tag 4K video with the 4K HD Video flag. Off by default because upstream
    /// found it breaks AppleTV streaming. No checkbox yet (needs Interface Builder);
    /// enable with: defaults write <bundle id> SBSet4KHDVideoMetadata -bool YES
    @Stored(key: "SBSet4KHDVideoMetadata", defaultValue: false)
    static var set4KHDVideoMetadata: Bool

    /// Whether saving a file renames it to match its own tagged metadata
    /// (Title [Studio] (Year), or Title SxxEyy for a tagged TV episode --
    /// the same convention ReleaseFilenameParser.ParsedMediaName already
    /// uses for the Queue's naming-review workflow). On by default per
    /// Hans's request: once a file is done being tagged, its name should
    /// follow that same convention rather than staying whatever it was
    /// called before. Left as a preference (rather than unconditional)
    /// so it can be turned off without a code change if it ever gets in
    /// the way.
    @Stored(key: "SBRenameFileToMatchMetadataOnSave", defaultValue: true)
    static var renameFileToMatchMetadataOnSave: Bool

    /// Movie-only: when a Movie file is renamed to match its own tagged
    /// metadata (see renameFileToMatchMetadataOnSave above), also rename
    /// the folder the file sits in to match -- e.g. "Title (Year)/Title
    /// (Year).mp4", a Plex/iTunes-style one-folder-per-movie library
    /// layout. Off by default, since renaming a folder is a more
    /// consequential action than renaming the file inside it; see
    /// Document.syncMovieFolderNameIfNeeded(fileURL:baseName:) for the
    /// safety checks before this ever touches an existing folder (it
    /// only renames a folder that looks like it already belongs to just
    /// this one movie -- never one holding unrelated files).
    @Stored(key: "SBSyncMovieFolderNameOnSave", defaultValue: false)
    static var syncMovieFolderNameOnSave: Bool

    /// TV Shows only: nest a saved/queued episode under "<TV Show>/Season
    /// NN/", the on-disk layout Apple's TV app and Plex both expect for a
    /// TV library (see MP42File.preferredOutputSubfolder()). Unlike
    /// syncMovieFolderNameOnSave above, this never renames or touches an
    /// existing folder -- it only ever creates new subfolders beneath
    /// wherever the file already sits and moves that one file into them
    /// -- but it's still off by default so an existing, already-organized
    /// TV library isn't restructured without being asked.
    @Stored(key: "SBUseAppleTVStyleTVFolders", defaultValue: false)
    static var useAppleTVStyleTVFolders: Bool

    /// Movie-only: when a tagged Title (or, failing that, the file's own
    /// current name) ends in a number or a word like "Part"/"Chapter"
    /// followed by one (e.g. "John Wick 2", "Mission: Impossible Part
    /// 3") -- a sign it's one entry in a series rather than a standalone
    /// film -- fill the Series Description tag with the base title (the
    /// same text with that trailing number/part indicator removed, e.g.
    /// "John Wick") on every save. See Document.fillSeriesDescriptionIfNeeded
    /// and SeriesTitleDetector.baseSeriesTitle(from:). Off by default,
    /// like the other save-time metadata/folder conveniences -- this is a
    /// heuristic (it can't tell "Ocean's 11" or "Se7en" from an actual
    /// sequel number) and always overwrites whatever Series Description
    /// already says, so it's opt-in rather than unconditional.
    @Stored(key: "SBFillSeriesDescriptionOnSave", defaultValue: false)
    static var fillSeriesDescriptionOnSave: Bool

    /// Shows WelcomeWindowController (an Xcode-style "what would you
    /// like to do" screen -- Tag One File / Merge and Tag Files / Scan
    /// Library for Missing Metadata) at launch, before whatever
    /// LaunchBehavior would otherwise show. On by default, matching
    /// Xcode's own welcome window default; the checkbox for this lives
    /// in General prefs (GeneralPrefsViewController.xib) rather than on
    /// the welcome window itself, since the window only ever shows for
    /// as long as this is on -- there'd be nowhere to turn it back on
    /// from once unchecked there.
    @Stored(key: "SBShowWelcomeScreenAtLaunch", defaultValue: true)
    static var showWelcomeScreenAtLaunch: Bool

    @Stored(key: "SBArtworkSelectorZoomLevel", defaultValue: 50)
    static var artworkSelectorZoomLevel: Float

    @Stored(key: "SBMovieArtworkSelectorZoomLevel", defaultValue: 50)
    static var movieArtworkSelectorZoomLevel: Float

    @Stored(key: "SBPresetArtworkSelectorZoomLevel", defaultValue: 0)
    static var presetArtworkSelectorZoomLevel: Float

    @Stored(key: "SBLogFormat", defaultValue: 0)
    static var logFormat: Int  // 0 = Time Only, 1 = Date and Time
}

enum MetadataPrefs {

    static func register() {
        ud.register(defaults: [_movieImporter, _movieiTunesStoreLanguage,
                               _tvShowImporter, _tvShowiTunesStoreLanguage,
                               _tvShowTheTVDBLanguage, _tvShowTheMovieDBLanguage,
                               _keepEmptyAnnotations, _keepImportedFilesMetadata,
                               _overwriteExistingAnnotations, _appendExistingAnnotations, _allowAdultContent])
        migrateMovieNamingRulesIfNeeded()
        migrateTVShowNamingRulesIfNeeded()
    }

    @StoredCodable(key: "SBMovieFormatTokens", defaultValue: [Token(text: "{Name}")])
    static var movieFormatTokens: [Token]

    @StoredCodable(key: "SBTVShowFormatTokens", defaultValue: [Token(text: "{TV Show}"), Token(text: " s", isPlaceholder: false), Token(text: "{TV Season}"), Token(text: "e", isPlaceholder: false), Token(text: "{TV Episode #}")])
    static var tvShowFormatTokens: [Token]

    /// The Movie naming-rule list (see NamingRules.swift) -- an ordered
    /// list of conditional Token templates, always including one
    /// condition-less "Default" rule (shown first in the Preferences UI,
    /// but its position in this array doesn't matter -- matchingTokens(for:)
    /// finds it by isDefault, not by position). Deliberately NOT
    /// registered as a UserDefaults default above (see
    /// migrateMovieNamingRulesIfNeeded below): that's what lets this
    /// property's own defaultValue tell "never configured yet" apart from
    /// "explicitly set", since ud.data(forKey:) only returns nil in the
    /// former case.
    @StoredCodable(key: "SBMovieNamingRules", defaultValue: [NamingRule(conditions: [], tokens: [Token(text: "{Name}")])])
    static var movieNamingRules: [NamingRule]

    /// One-time migration into the new rule list, run at every launch via
    /// register() above (a no-op once SBMovieNamingRules has ever been
    /// saved). Seeds a single Default rule from whatever the user already
    /// had configured as their plain Movie filename template
    /// (SBMovieFormatTokens) -- preserving it exactly instead of silently
    /// replacing it. No conditional rules are pre-populated: this ships
    /// blank, and the user adds their own from the Filename preferences
    /// tab.
    private static func migrateMovieNamingRulesIfNeeded() {
        guard ud.data(forKey: "SBMovieNamingRules") == nil else { return }

        movieNamingRules = [NamingRule(conditions: [], tokens: movieFormatTokens)]
    }

    /// The TV Show naming-rule list -- exactly the Movie list's design
    /// (see movieNamingRules' own doc comment and NamingRules.swift)
    /// applied to TV Shows too, so a TV episode's filename can vary by
    /// conditions (network, content rating, etc.) the same way a Movie's
    /// can, instead of the single fixed template TV Shows used to be
    /// limited to.
    @StoredCodable(key: "SBTVShowNamingRules", defaultValue: [NamingRule(conditions: [], tokens: [Token(text: "{TV Show}"), Token(text: " s", isPlaceholder: false), Token(text: "{TV Season}"), Token(text: "e", isPlaceholder: false), Token(text: "{TV Episode #}")])])
    static var tvShowNamingRules: [NamingRule]

    /// One-time migration into the new rule list, run at every launch via
    /// register() above (a no-op once SBTVShowNamingRules has ever been
    /// saved). Seeds a single Default rule from whatever the user already
    /// had configured as their plain TV Show filename template
    /// (SBTVShowFormatTokens) -- preserving it exactly instead of
    /// silently replacing it, mirroring migrateMovieNamingRulesIfNeeded()
    /// above.
    private static func migrateTVShowNamingRulesIfNeeded() {
        guard ud.data(forKey: "SBTVShowNamingRules") == nil else { return }

        tvShowNamingRules = [NamingRule(conditions: [], tokens: tvShowFormatTokens)]
    }

    /// Per-field history of naming-condition values the user has typed
    /// into the Filename tab's condition rows (e.g. past Keywords/Studio
    /// values), keyed by the condition's metadata field identifier --
    /// offered back as autocomplete suggestions the next time that same
    /// field is used in a condition. The Rating field doesn't use this:
    /// it's autocompleted from Ratings.conditionAutocompleteValues(_:)
    /// instead, since free-typed Rating values are exactly what produced
    /// the unmatchable "USA NC-17"-style conditions this feature exists
    /// to prevent.
    @StoredCodable(key: "SBNamingConditionValueHistory", defaultValue: [String: [String]]())
    static var namingConditionValueHistory: [String: [String]]

    /// Records `value` as a suggestion for future conditions on `field`,
    /// most-recent-first, deduplicated, capped so this doesn't grow
    /// without bound. No-op for blank values.
    static func recordNamingConditionValue(_ value: String, for field: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        var history = namingConditionValueHistory[field] ?? []
        history.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        history.insert(trimmed, at: 0)
        if history.count > 20 {
            history.removeLast(history.count - 20)
        }
        namingConditionValueHistory[field] = history
    }


    @Stored(key: "SBMetadataPreference|Movie", defaultValue: "TheMovieDB")
    static var movieImporter: String

    @Stored(key: "SBMetadataPreference|Movie|iTunes Store|Language", defaultValue: "USA (English)")
    static var movieiTunesStoreLanguage: String

    @Stored(key: "SBMetadataPreference|Movie|TheMovieDB|Language", defaultValue: "en")
    static var movieLanguage: String


    @Stored(key: "SBMetadataPreference|TV", defaultValue: "TheTVDB")
    static var tvShowImporter: String

    @Stored(key: "SBMetadataPreference|TV|iTunes Store|Language", defaultValue: "USA (English)")
    static var tvShowiTunesStoreLanguage: String

    @Stored(key: "SBMetadataPreference|TV|TheTVDB|Language", defaultValue: "en")
    static var tvShowTheTVDBLanguage: String

    @Stored(key: "SBMetadataPreference|TV|TheMovieDB|Language", defaultValue: "en")
    static var tvShowTheMovieDBLanguage: String


    @StoredCodable(key: "SBMetadataMovieResultMap2", defaultValue: MetadataResultMap.movieDefaultMap)
    static var movieResultMap: MetadataResultMap

    @StoredCodable(key: "SBMetadataTvShowResultMap2", defaultValue: MetadataResultMap.tvShowDefaultMap)
    static var tvShowResultMap: MetadataResultMap

    /// Legacy storage for the old, simple Custom Sources editor (name /
    /// source location / API key only). No longer shown in Preferences --
    /// superseded by customMetadataSources below -- kept only so a source
    /// someone already saved here keeps working without retyping it.
    @StoredCodable(key: "SBAdditionalMetadataSources", defaultValue: [])
    static var additionalMetadataSources: [AdditionalMetadataSource]

    /// User-configured, JSON-field-mapped metadata sources -- see
    /// CustomMetadataSource. Ported from Subler Clean.
    @StoredCodable(key: "SBCustomMetadataSources", defaultValue: [])
    static var customMetadataSources: [CustomMetadataSource]

    @Stored(key: "SBMetadataKeepEmptyAnnotations", defaultValue: false)
    static var keepEmptyAnnotations: Bool

    // MediaMetadataManager-only default: off. Upstream ships this preference defaulting
    // to true (always overwrite), but that's exactly the "erases my
    // existing metadata/artwork when I pick a new search result" behavior
    // that prompted this preference's predecessor (the old "do not
    // overwrite" PR) in the first place. Kept non-destructive by default
    // here; never change this default in a branch meant for upstream
    // submission.
    @Stored(key: "SBMetadataOverwriteExistingAnnotations", defaultValue: false)
    static var overwriteExistingAnnotations: Bool

    /// Mutually exclusive with overwriteExistingAnnotations (the Preferences
    /// checkboxes enforce this -- see MetadataPrefsViewController). Scoped
    /// to cover art: when on, new artwork from a metadata search is added
    /// alongside whatever cover art the file already has instead of being
    /// skipped, without touching any other existing metadata. See
    /// MP42Metadata.mergeMetadata:overwrite:append: for the actual merge
    /// logic this drives.
    @Stored(key: "SBMetadataAppendExistingAnnotations", defaultValue: false)
    static var appendExistingAnnotations: Bool

    @Stored(key: "SBFileImporterImportMetadata", defaultValue: false)
    static var keepImportedFilesMetadata: Bool

    /// Names (matching MetadataService.name) of Subler's original, credential-free
    /// providers the user has switched off for movies in Preferences > Sources.
    /// Custom sources aren't part of this toggleable "core" set -- they're
    /// always available and are managed on the Custom Sources tab instead.
    /// See MetadataSearch.coreMovieProviders / movieProviders in MetadataImporter.swift
    /// for the safety fallback that keeps every core provider enabled if disabling
    /// would otherwise leave zero.
    @StoredCodable(key: "SBDisabledMovieMetadataProviders", defaultValue: [])
    static var disabledMovieProviders: Set<String>

    /// Same as `disabledMovieProviders`, but for the TV Show provider list.
    @StoredCodable(key: "SBDisabledTVMetadataProviders", defaultValue: [])
    static var disabledTVProviders: Set<String>

    /// Whether TheMovieDB search should include adult content, passed as
    /// TMDB's own `include_adult` search parameter (see TheMovieDBService).
    /// Off by default. This only affects the built-in TheMovieDB search --
    /// it has no effect on custom sources or installed plugins.
    @Stored(key: "SBAllowAdultContent", defaultValue: false)
    static var allowAdultContent: Bool
}

/// Preferences for the Intake/Queue workflow's settings side (Sources
/// tab, MediaMetadataManager only): where new/unprocessed media (e.g. from a download
/// client) lands, where a finished release goes once it's fully tagged,
/// and whether the incoming folder is watched automatically. The actual
/// monitoring, naming, metadata, and merge work happens in the Queue --
/// see MediaIntakeManagerViewController's header comment and the
/// Intake/Queue workflow design docs kept in this project's notes.
enum MediaIntakePrefs {

    private static let SBMediaIntakeFolder = "SBMediaIntakeFolder"
    private static let SBMediaIntakeReadyForLibraryFolder = "SBMediaIntakeReadyForLibraryFolder"
    private static let SBMediaIntakeRejectedFiles = "SBMediaIntakeRejectedFiles"

    static func register() {
        ud.register(defaults: [_autoWatchIntakeFolder, _renameSourceFolderAfterMerge, _autoApproveHighConfidenceNaming, _autoMergeOnSequence, _autoCleanEmptyFolders, _autoCleanProcessedFiles])
    }

    private static let SBMediaIntakeFolders = "SBMediaIntakeFolders"
    private static let SBAutomaticMediaIngestFolders = "SBAutomaticMediaIngestFolders"

    /// Reads a list of folders stored as an array of plain paths. A list
    /// that has never been saved falls back to the single folder older
    /// versions kept under `legacyKey`, so an existing setting carries
    /// over; once a list has been saved (even an empty one) it wins.
    private static func folderList(forKey key: String, legacyKey: String) -> [URL] {
        if let paths = ud.stringArray(forKey: key) {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        if let legacy = ud.url(forKey: legacyKey) {
            return [legacy]
        }
        return []
    }

    private static func setFolderList(_ urls: [URL], forKey key: String) {
        ud.set(urls.map { $0.path }, forKey: key)
    }

    /// The folders new, unprocessed media files are expected to land in
    /// (e.g. a download client's output folder), in the order the user
    /// listed them. Stored as plain paths, same approach as
    /// QueuePreferences.destination -- not security-scoped bookmarks,
    /// since this app isn't sandboxed.
    static var intakeFolders: [URL] {
        get { folderList(forKey: SBMediaIntakeFolders, legacyKey: SBMediaIntakeFolder) }
        set { setFolderList(newValue, forKey: SBMediaIntakeFolders) }
    }

    /// Where a release goes once the Queue-based workflow has finished
    /// naming, tagging, and (if needed) merging it -- a final holding
    /// folder for the user to look through before anything reaches the
    /// actual media server. Same plain-URL approach as intakeFolder.
    static var readyForLibraryFolder: URL? {
        get { ud.url(forKey: SBMediaIntakeReadyForLibraryFolder) }
        set { ud.set(newValue, forKey: SBMediaIntakeReadyForLibraryFolder) }
    }

    /// Delivery rules (see DeliveryRules.swift), one ordered list for
    /// movies and one for TV shows. Stored as JSON, like the naming rules.
    static var movieDeliveryRules: [DeliveryRule] {
        get { deliveryRules(forKey: "SBMovieDeliveryRules") }
        set { setDeliveryRules(newValue, forKey: "SBMovieDeliveryRules") }
    }

    static var tvDeliveryRules: [DeliveryRule] {
        get { deliveryRules(forKey: "SBTVShowDeliveryRules") }
        set { setDeliveryRules(newValue, forKey: "SBTVShowDeliveryRules") }
    }

    private static func deliveryRules(forKey key: String) -> [DeliveryRule] {
        guard let data = ud.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DeliveryRule].self, from: data)) ?? []
    }

    private static func setDeliveryRules(_ rules: [DeliveryRule], forKey key: String) {
        ud.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    private static let SBAutomaticMediaIngestFolder = "SBAutomaticMediaIngestFolder"

    /// The user's explicit override of iTunes/Apple TV's own "Automatically
    /// Add to..." folder(s) -- an empty list (the default, nothing set)
    /// means "use defaultAutomaticMediaIngestFolderURL()'s live-detected
    /// location instead" (see URL.isAutomaticMediaIngestFolder,
    /// Utilities.swift). More than one can be listed for someone who
    /// keeps several libraries. Same plain-path approach as intakeFolders.
    /// This is the first of what's meant to grow into a proper "where does
    /// your media live" settings section, surfaced in this same Media
    /// Intake pane.
    static var automaticMediaIngestFolders: [URL] {
        get { folderList(forKey: SBAutomaticMediaIngestFolders, legacyKey: SBAutomaticMediaIngestFolder) }
        set { setFolderList(newValue, forKey: SBAutomaticMediaIngestFolders) }
    }

    /// iTunes/Apple TV's own default "Automatically Add to..." folder,
    /// computed from FileManager's Movies/Music directory lookup rather
    /// than a hardcoded absolute path, so this tracks wherever the
    /// current user's home actually is. The modern (Catalina-onward
    /// Music/TV apps) paths were confirmed directly on Hans's own Mac --
    ///   ~/Movies/TV/Media.localized/Automatically Add to TV.localized
    ///   ~/Music/Music/Media.localized/Automatically Add to Music.localized
    /// -- replacing an earlier, unverified guess at "TV.localized" and
    /// "iTunes Media.localized" that didn't match either real folder.
    /// The old iTunes-era paths are kept as a fallback for a pre-Catalina
    /// Mac or Windows iTunes install, checked only once the modern ones
    /// come up empty. Returns whichever one is found to exist on disk,
    /// or nil if none is -- most likely because the user has relocated
    /// that library elsewhere, which is exactly what
    /// automaticMediaIngestFolder above is for. Not cached: the Movies/
    /// Music folder a sandboxed or relocated install sees can change
    /// between launches, and this is cheap enough to just check fresh.
    static func defaultAutomaticMediaIngestFolderURL() -> URL? {
        let fileManager = FileManager.default

        if let moviesFolder = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let tvAutoAdd = moviesFolder
                .appendingPathComponent("TV")
                .appendingPathComponent("Media.localized")
                .appendingPathComponent("Automatically Add to TV.localized")
            if fileManager.fileExists(atPath: tvAutoAdd.path) {
                return tvAutoAdd
            }

            // Pre-Catalina Mac: the TV app didn't exist yet, so video
            // went through iTunes' own "Automatically Add to iTunes"
            // folder instead, nested under Movies rather than Music.
            let legacyMoviesAutoAdd = moviesFolder
                .appendingPathComponent("iTunes")
                .appendingPathComponent("iTunes Media.localized")
                .appendingPathComponent("Automatically Add to iTunes.localized")
            if fileManager.fileExists(atPath: legacyMoviesAutoAdd.path) {
                return legacyMoviesAutoAdd
            }
        }

        if let musicFolder = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first {
            let musicAutoAdd = musicFolder
                .appendingPathComponent("Music")
                .appendingPathComponent("Media.localized")
                .appendingPathComponent("Automatically Add to Music.localized")
            if fileManager.fileExists(atPath: musicAutoAdd.path) {
                return musicAutoAdd
            }

            let iTunesAutoAdd = musicFolder
                .appendingPathComponent("iTunes")
                .appendingPathComponent("iTunes Media.localized")
                .appendingPathComponent("Automatically Add to iTunes.localized")
            if fileManager.fileExists(atPath: iTunesAutoAdd.path) {
                return iTunesAutoAdd
            }

            // Older iTunes versions used "iTunes Media" without the
            // .localized suffix.
            let legacyiTunesAutoAdd = musicFolder
                .appendingPathComponent("iTunes")
                .appendingPathComponent("iTunes Media")
                .appendingPathComponent("Automatically Add to iTunes.localized")
            if fileManager.fileExists(atPath: legacyiTunesAutoAdd.path) {
                return legacyiTunesAutoAdd
            }
        }

        return nil
    }

    /// Absolute paths of files the user has explicitly rejected from the
    /// naming-approval step, so a rejected release doesn't just get
    /// picked back up and re-surfaced the moment the intake folder is
    /// looked at again. Not currently read or written by anything --
    /// the working naming/approve-reject UI that used this has moved
    /// into the Queue and isn't built yet (see
    /// claude/sublerx-intake-queue-workflow-design.md) -- kept here so
    /// that future UI has somewhere to persist it, matching how it
    /// worked before. Plain strings in UserDefaults, same non-sandboxed
    /// approach as the rest of these prefs.
    static var rejectedFilePaths: Set<String> {
        get { Set(ud.stringArray(forKey: SBMediaIntakeRejectedFiles) ?? []) }
        set { ud.set(Array(newValue), forKey: SBMediaIntakeRejectedFiles) }
    }

    /// When true, the incoming folder should be watched continuously
    /// (see IntakeFolderWatcher) rather than only checked on demand.
    /// Not acted on by this settings pane itself -- the Queue's own
    /// intake coordinator (not yet built; see
    /// claude/sublerx-queue-release-model.md) is what actually
    /// starts/stops the watcher based on this.
    @Stored(key: "SBMediaIntakeAutoWatch", defaultValue: false)
    static var autoWatchIntakeFolder: Bool

    /// When true, the Queue's Merge button (QueueController.
    /// mergeSelectedItems(_:)) renames the merged files' shared source
    /// folder to match, whenever a correctly- or fixable-to-correctly-
    /// formatted release name can be found nearby (a cover image, the
    /// folder's own name, or a video file already carrying it -- see
    /// FileMerger.formattedReleaseName(for:)) and it differs from the
    /// folder's current name. Off by default: unlike
    /// FileMerger.suggestedDestinationName, which only ever fills in a
    /// save-panel field the user still confirms, this renames a real
    /// folder under the user's own downloads -- see
    /// FileMerger.renameSourceFolderIfPossible(for:) and the merge
    /// design doc's "0h" section.
    @Stored(key: "SBMediaIntakeRenameSourceFolderAfterMerge", defaultValue: false)
    static var renameSourceFolderAfterMerge: Bool

    /// "Automatic delivery" (Media Locations tab). Off (the default): finished
    /// files go to the staging folder (Ready for Media Library) for the user
    /// to look through, whatever the delivery rules say. On: they go straight
    /// from the watched folder to their final destination -- the first
    /// matching delivery rule's folder, else the default Automatically Add
    /// folder -- with no staging step. Off by default so trust in the rules
    /// is built up before they act without a human look.
    @Stored(key: "SBMediaIntakeDeliverAutomatically", defaultValue: false)
    static var deliverAutomatically: Bool

    /// When true, NamingReviewWindowController automatically approves a
    /// naming match it's confident about, rather than always waiting for
    /// a manual Approve click -- see
    /// NamingReviewWindowController.isHighConfidenceMatch(...) for
    /// exactly what counts as confident (title + year agreement between
    /// the local filename guess and the online search hit). Off by
    /// default: a wrong auto-approval means a mis-named/mis-filed
    /// release with no review step, so this stays a deliberate opt-in.
    /// Auto-approval still briefly shows the naming sheet with the match
    /// filled in before closing it, rather than resolving silently, so
    /// there's a moment to catch and reject a bad match.
    @Stored(key: "SBMediaIntakeAutoApproveHighConfidenceNaming", defaultValue: false)
    static var autoApproveHighConfidenceNaming: Bool

    /// When true, a multi-file release whose files are confirmed
    /// compatible (MergeCompatibility.check) AND every one of which
    /// carries an actually *detected* sequence number (not the "no
    /// number, keep original order" fallback -- see
    /// MergeReorderWindowController.everyFileHasDetectedSequence(_:))
    /// merges automatically the moment its naming is approved, instead
    /// of always stopping at the manual reorder/confirmation sheet. Off
    /// by default, same reasoning as autoApproveHighConfidenceNaming
    /// above: a wrong automatic merge is much more work to undo than a
    /// wrong name. Deliberately scoped to this intake/scan path only --
    /// a manual multi-select merge from the Queue table
    /// (QueueController.mergeSelectedItems(_:)) always goes through the
    /// confirmation sheet regardless of this setting. See
    /// QueueController.attemptAutoMerge(for:): opening the row's merge
    /// review manually during the brief delay before an automatic merge
    /// actually starts cancels it, same as typing into the naming
    /// window cancels its pending auto-approve.
    @Stored(key: "SBMediaIntakeAutoMergeOnSequence", defaultValue: false)
    static var autoMergeOnSequence: Bool

    /// When true, EmptyFolderCleaner.runAutomaticallyIfEnabled() moves
    /// empty folders inside the Intake and Ready for Media Library
    /// folders to the Trash (and logs them) after each Queue run and
    /// each Edit-window save. Off by default.
    @Stored(key: "SBMediaIntakeAutoCleanEmptyFolders", defaultValue: false)
    static var autoCleanEmptyFolders: Bool

    /// When true, once a release has been moved into Ready for Media
    /// Library, the original files that went into it (the parts that were
    /// merged, or the pre-conversion source of a single file) are moved
    /// to the Trash -- recoverable -- and logged, leaving only the
    /// finished file and whatever else was in the folder. Off by
    /// default: until it is on, those originals stay beside the result
    /// as a backup.
    @Stored(key: "SBMediaIntakeAutoCleanProcessedFiles", defaultValue: false)
    static var autoCleanProcessedFiles: Bool

    /// When true, the Queue drops its finished rows (the ones showing a
    /// checkmark) by itself as soon as a run completes, instead of leaving
    /// them until "Remove completed items" or the next launch. Only
    /// removes rows from the list; files are never touched. Failed rows and
    /// rows still waiting on you stay. Off by default.
    @Stored(key: "SBMediaIntakeAutoRemoveCompletedItems", defaultValue: false)
    static var autoRemoveCompletedItems: Bool
}
