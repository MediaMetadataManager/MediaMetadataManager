//
//  QueuePreferences.swift
//  M3
//
//  Created by Damiano Galassi on 28/03/2018.
//

import Foundation

final class QueuePreferences: NSObject {

    static private let SBQueueFileType: String = "SBQueueFileType"
    static private let SBQueueOrganize: String = "SBQueueOrganize"
    static private let SBQueueFixFallbacks: String = "SBQueueFixFallbacks"
    static private let SBQueueClearTrackName: String = "SBQueueClearTrackName"
    static private let SBQueuePrettifyAudioTrackName: String = "SBQueuePrettifyAudioTrackName"
    static private let SBQueueRenameChapters: String = "SBQueueRenameChapters"
    static private let SBQueueMetadata: String = "SBQueueMetadata"
    static private let SBQueueSubtitles: String = "SBQueueSubtitles"
    static private let SBQueueSet: String = "SBQueueSet"

    static private let SBQueueAutoStart: String = "SBQueueAutoStart"
    static private let SBQueueOptimize: String = "SBQueueOptimize"
    static private let SBQueueSendToiTunes: String = "SBQueueSendToiTunes"
    static private let SBQueueShowDoneNotification: String = "SBQueueShowDoneNotification"

    static private let SBQueueFixTrackLanguage: String = "SBQueueFixTrackLanguage"
    static private let SBQueueFixTrackLanguageValue: String = "SBQueueFixTrackLanguageValue"

    static private let SBQueueApplyColorSpace: String = "SBQueueApplyColorSpace"
    static private let SBQueueApplyColorSpaceValue: String = "SBQueueApplyColorSpaceValue"

    static private let SBQueueClearExistingMetadata: String = "SBQueueClearExistingMetadata"

    static private let SBQueueMovieProvider: String = "SBQueueMovieProvider"
    static private let SBQueueTVShowProvider: String = "SBQueueTVShowProvider"
    static private let SBQueueMovieProviderLanguage: String = "SBQueueMovieProviderLanguage"
    static private let SBQueueTVShowProviderLanguage: String = "SBQueueTVShowProviderLanguage"
    static private let SBQueueProviderArtwork: String = "SBQueueProviderArtwork2"
    static private let SBQueueProviderArtworkSize: String = "SBQueueProviderArtworkSize"

    static private let SBQueueSetOutputFilename: String = "SBQueueSetOutputFilename"
    static private let SBQueueDestination: String = "SBQueueDestination"

    static private let SBQueueChangeAudioLanguage: String = "SBQueueChangeAudioLanguage"
    static private let SBQueueChangeAudioLanguageValue: String = "SBQueueChangeAudioLanguageValue"
    static private let SBQueueChangeSubtitleLanguage: String = "SBQueueChangeSubtitleLanguage"
    static private let SBQueueChangeSubtitleLanguageValue: String = "SBQueueChangeSubtitleLanguageValue"

    @objc dynamic var clearExistingMetadata: Bool

    @objc dynamic var searchMetadata: Bool
    @objc dynamic var movieProvider: String
    @objc dynamic var movieProviderLanguage: String
    @objc dynamic var tvShowProvider: String
    @objc dynamic var tvShowProviderLanguage: String
    /// The artwork choice is one setting shown in two places (General
    /// preferences and the Queue options), each with its own instance of
    /// this class. A change is therefore saved at once, and picked up by
    /// every other instance (see artworkDefaultsChanged), instead of
    /// waiting for a save that the General pane never makes.
    @objc dynamic var providerArtwork: Int {
        didSet {
            if oldValue != providerArtwork {
                UserDefaults.standard.set(providerArtwork, forKey: QueuePreferences.SBQueueProviderArtwork)
            }
        }
    }
    @objc dynamic var providerArtworkSize: Int {
        didSet {
            if oldValue != providerArtworkSize {
                UserDefaults.standard.set(providerArtworkSize, forKey: QueuePreferences.SBQueueProviderArtworkSize)
            }
        }
    }

    @objc dynamic var organize: Bool
    @objc dynamic var fixFallbacks: Bool
    @objc dynamic var clearTrackName: Bool
    @objc dynamic var prettifyAudioTrackName: Bool
    @objc dynamic var renameChapters: Bool
    @objc dynamic var subtitles: Bool
    @objc dynamic var metadataSet: MetadataPreset?

    @objc dynamic var fixTrackLanguage: Bool
    @objc dynamic var fixTrackLanguageValue: String

    @objc dynamic var applyColorSpace: Bool
    @objc dynamic var applyColorSpaceValue: Int

    @objc dynamic var setOutputFilename: Bool
    @objc dynamic var fileType: String
    @objc dynamic var destination: URL?

    @objc dynamic var optimize: Bool
    @objc dynamic var sendToiTunes: Bool

    @objc dynamic var autoStart: Bool
    @objc dynamic var showDoneNotification: Bool

    @objc dynamic var changeAudioLanguage: Bool
    @objc dynamic var changeAudioLanguageValue: String
    @objc dynamic var changeSubtitleLanguage: Bool
    @objc dynamic var changeSubtitleLanguageValue: String

    override init() {
        QueuePreferences.registerUserDefaults()

        let ud = UserDefaults.standard

        self.clearExistingMetadata = ud.bool(forKey: QueuePreferences.SBQueueClearExistingMetadata)

        self.searchMetadata = ud.bool(forKey: QueuePreferences.SBQueueMetadata)
        self.movieProvider = ud.string(forKey: QueuePreferences.SBQueueMovieProvider) ?? "TheMovieDB"
        self.movieProviderLanguage = ud.string(forKey: QueuePreferences.SBQueueMovieProviderLanguage) ?? "en"
        self.tvShowProvider = ud.string(forKey: QueuePreferences.SBQueueTVShowProvider) ?? "TheTVDB"
        self.tvShowProviderLanguage = ud.string(forKey: QueuePreferences.SBQueueTVShowProviderLanguage) ?? "en"
        self.providerArtwork = ud.integer(forKey: QueuePreferences.SBQueueProviderArtwork)
        self.providerArtworkSize = ud.integer(forKey: QueuePreferences.SBQueueProviderArtworkSize)

        self.organize = ud.bool(forKey: QueuePreferences.SBQueueOrganize)
        self.fixFallbacks = ud.bool(forKey: QueuePreferences.SBQueueFixFallbacks)
        self.clearTrackName = ud.bool(forKey: QueuePreferences.SBQueueClearTrackName)
        self.prettifyAudioTrackName = ud.bool(forKey: QueuePreferences.SBQueuePrettifyAudioTrackName)
        self.renameChapters = ud.bool(forKey: QueuePreferences.SBQueueRenameChapters)
        self.subtitles = ud.bool(forKey: QueuePreferences.SBQueueSubtitles)
        if let presetName = ud.string(forKey: QueuePreferences.SBQueueSet) {
            self.metadataSet = PresetManager.shared.item(name: presetName) as? MetadataPreset
        }

        self.fixTrackLanguage = ud.bool(forKey: QueuePreferences.SBQueueFixTrackLanguage)
        self.fixTrackLanguageValue = ud.string(forKey: QueuePreferences.SBQueueFixTrackLanguageValue) ?? ""

        self.applyColorSpace = ud.bool(forKey: QueuePreferences.SBQueueApplyColorSpace)
        self.applyColorSpaceValue = ud.integer(forKey: QueuePreferences.SBQueueApplyColorSpaceValue)

        self.setOutputFilename = ud.bool(forKey: QueuePreferences.SBQueueSetOutputFilename)
        self.fileType = ud.string(forKey: QueuePreferences.SBQueueFileType) ?? "mp4"
        if let url = ud.url(forKey: QueuePreferences.SBQueueDestination), FileManager.default.fileExists(atPath: url.path) {
            self.destination = url
        }

        self.optimize = ud.bool(forKey: QueuePreferences.SBQueueOptimize)
        self.sendToiTunes = ud.bool(forKey: QueuePreferences.SBQueueSendToiTunes)

        self.autoStart = ud.bool(forKey: QueuePreferences.SBQueueAutoStart)
        self.showDoneNotification = ud.bool(forKey: QueuePreferences.SBQueueShowDoneNotification)

        self.changeAudioLanguage = ud.bool(forKey: QueuePreferences.SBQueueChangeAudioLanguage)
        self.changeAudioLanguageValue = ud.string(forKey: QueuePreferences.SBQueueChangeAudioLanguageValue) ?? ""
        self.changeSubtitleLanguage = ud.bool(forKey: QueuePreferences.SBQueueChangeSubtitleLanguage)
        self.changeSubtitleLanguageValue = ud.string(forKey: QueuePreferences.SBQueueChangeSubtitleLanguageValue) ?? ""

        super.init()

        // What was just loaded -- saveUserDefaults() below only writes
        // settings that differ from this, see there.
        recordOnly = true
        writeValues()
        recordOnly = false

        NotificationCenter.default.addObserver(self, selector: #selector(artworkDefaultsChanged(_:)),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    /// Another instance (or anything else) saved a different artwork
    /// choice: follow it, so the Queue always uses what General says.
    @objc private func artworkDefaultsChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let defaults = UserDefaults.standard
            let artwork = defaults.integer(forKey: QueuePreferences.SBQueueProviderArtwork)
            if artwork != self.providerArtwork { self.providerArtwork = artwork }
            let size = defaults.integer(forKey: QueuePreferences.SBQueueProviderArtworkSize)
            if size != self.providerArtworkSize { self.providerArtworkSize = size }
        }
    }

    convenience init(preset: QueuePreset) {
        self.init()
    }

    static func registerUserDefaults() {
        let prefs = [QueuePreferences.SBQueueFileType: "mp4",
                     QueuePreferences.SBQueueOrganize: true,
                     QueuePreferences.SBQueueFixTrackLanguage: false,
                     QueuePreferences.SBQueueFixTrackLanguageValue: "en",
                     QueuePreferences.SBQueueFixFallbacks: false,
                     QueuePreferences.SBQueueClearTrackName: false,
                     QueuePreferences.SBQueuePrettifyAudioTrackName: false,
                     QueuePreferences.SBQueueRenameChapters: false,
                     QueuePreferences.SBQueueMetadata: false,
                     QueuePreferences.SBQueueSubtitles: true,
                     QueuePreferences.SBQueueApplyColorSpace: false,
                     QueuePreferences.SBQueueApplyColorSpaceValue: 1,
                     QueuePreferences.SBQueueSetOutputFilename: false,
                     QueuePreferences.SBQueueAutoStart: false,
                     QueuePreferences.SBQueueOptimize: false,
                     QueuePreferences.SBQueueShowDoneNotification: true,
                     QueuePreferences.SBQueueClearExistingMetadata: false,
                     QueuePreferences.SBQueueMovieProvider: "TheMovieDB",
                     QueuePreferences.SBQueueTVShowProvider: "TheTVDB",
                     QueuePreferences.SBQueueMovieProviderLanguage: "en",
                     QueuePreferences.SBQueueTVShowProviderLanguage: "en",
                     QueuePreferences.SBQueueProviderArtwork: 0,
                     QueuePreferences.SBQueueProviderArtworkSize: 0,
                     QueuePreferences.SBQueueChangeAudioLanguage: false,
                     QueuePreferences.SBQueueChangeAudioLanguageValue: "en",
                     QueuePreferences.SBQueueChangeSubtitleLanguage: false,
                     QueuePreferences.SBQueueChangeSubtitleLanguageValue: "en"] as [String : Any]
        UserDefaults.standard.register(defaults: prefs)
    }

    /// The Movies and TV Shows queues each own a QueuePreferences, and both
    /// read and write the same UserDefaults keys. Writing every key on quit
    /// meant whichever queue saved last put its launch-time snapshot back
    /// over what the other had changed (e.g. the chosen search provider
    /// reverting to TheMovieDB). So only settings this instance actually
    /// changed since it loaded (or last saved) are written.
    private var baseline: [String: NSObject] = [:]
    private var recordOnly = false

    private func put(_ value: Any?, _ key: String) {
        let object = (value as? NSObject) ?? NSNull()
        if let known = baseline[key], known.isEqual(object) { return }
        baseline[key] = object
        guard recordOnly == false else { return }
        if object is NSNull {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let url = value as? URL {
            UserDefaults.standard.set(url, forKey: key)
        } else {
            UserDefaults.standard.set(object, forKey: key)
        }
    }

    func saveUserDefaults() {
        writeValues()
    }

    private func writeValues() {
        put(clearExistingMetadata, QueuePreferences.SBQueueClearExistingMetadata)

        put(searchMetadata, QueuePreferences.SBQueueMetadata)
        put(movieProvider, QueuePreferences.SBQueueMovieProvider)
        put(movieProviderLanguage, QueuePreferences.SBQueueMovieProviderLanguage)
        put(tvShowProvider, QueuePreferences.SBQueueTVShowProvider)
        put(tvShowProviderLanguage, QueuePreferences.SBQueueTVShowProviderLanguage)
        put(providerArtwork, QueuePreferences.SBQueueProviderArtwork)
        put(providerArtworkSize, QueuePreferences.SBQueueProviderArtworkSize)

        put(organize, QueuePreferences.SBQueueOrganize)
        put(fixFallbacks, QueuePreferences.SBQueueFixFallbacks)
        put(clearTrackName, QueuePreferences.SBQueueClearTrackName)
        put(prettifyAudioTrackName, QueuePreferences.SBQueuePrettifyAudioTrackName)
        put(renameChapters, QueuePreferences.SBQueueRenameChapters)
        put(subtitles, QueuePreferences.SBQueueSubtitles)
        put(metadataSet?.title, QueuePreferences.SBQueueSet)

        put(fixTrackLanguage, QueuePreferences.SBQueueFixTrackLanguage)
        put(fixTrackLanguageValue, QueuePreferences.SBQueueFixTrackLanguageValue)

        put(applyColorSpace, QueuePreferences.SBQueueApplyColorSpace)
        put(applyColorSpaceValue, QueuePreferences.SBQueueApplyColorSpaceValue)

        put(setOutputFilename, QueuePreferences.SBQueueSetOutputFilename)
        put(fileType, QueuePreferences.SBQueueFileType)
        put(destination, QueuePreferences.SBQueueDestination)

        put(optimize, QueuePreferences.SBQueueOptimize)
        put(sendToiTunes, QueuePreferences.SBQueueSendToiTunes)

        put(autoStart, QueuePreferences.SBQueueAutoStart)
        put(showDoneNotification, QueuePreferences.SBQueueShowDoneNotification)

        put(changeAudioLanguage, QueuePreferences.SBQueueChangeAudioLanguage)
        put(changeAudioLanguageValue, QueuePreferences.SBQueueChangeAudioLanguageValue)
        put(changeSubtitleLanguage, QueuePreferences.SBQueueChangeSubtitleLanguage)
        put(changeSubtitleLanguageValue, QueuePreferences.SBQueueChangeSubtitleLanguageValue)
    }

    var queueURL: URL? {
        return ApplicationSupport.url?.appendingPathComponent("queue.sbqueue", isDirectory: false)
    }
}
