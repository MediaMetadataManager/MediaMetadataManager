//
//  PresetEditorViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 29/08/17.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  A Set's edits are saved immediately instead of only at quit.
//

import Cocoa

final class PresetEditorViewController: MovieViewController {

    let preset: MetadataPreset
    @IBOutlet weak var presetTitle: NSTextField!
    @IBOutlet weak var replaceArtworks: NSButton!
    @IBOutlet weak var replaceAnnotations: NSButton!

    override var nibName: NSNib.Name? {
        return "PresetEditorViewController"
    }

    override var greysOutTagsAlreadyInUse: Bool { true }

    init(preset: MetadataPreset) {
        self.preset = preset
        super.init(mp4: nil, metadata: preset.metadata)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        self.metadata = preset.metadata

        super.viewDidLoad()

        if #available(OSX 10.14, *) {} else {
            view.appearance = NSAppearance(named: .aqua)
        }
        presetTitle.stringValue = preset.title

        preset.changed = true
        replaceArtworks.state = preset.replaceArtworks == false ? .on : .off
        replaceAnnotations.state = preset.replaceAnnotations == false ? .on : .off
    }

    override var zoomLevel: Float {
        get {
            Prefs.presetArtworkSelectorZoomLevel
        }
        set (value) {
            Prefs.presetArtworkSelectorZoomLevel = value;
        }
    }

    @IBAction func done(_ sender: Any) {
        // PresetManager.save() only ever persists a preset whose
        // `changed` flag is set -- otherwise it's only ever written to
        // disk from AppDelegate.applicationWillTerminate(_:), i.e. only
        // on a clean quit. An edit made here (adding/removing an
        // annotation, replacing artwork, toggling replaceArtworks/
        // replaceAnnotations) was silently lost on anything short of
        // that -- a crash, a force quit, or Xcode killing a previous
        // build to launch a new one -- since nothing closing this sheet
        // ever wrote it out. Save right away instead of leaving it to
        // whatever happens (or doesn't) at quit time.
        do {
            try PresetManager.shared.save()
        } catch {
            view.window?.presentError(error)
        }
        presentingViewController?.dismiss(self)
    }

    @IBAction func setReplaceArtworksState(_ sender: NSButton) {
        preset.replaceArtworks = sender.state == .off ? true : false
    }

    @IBAction func setReplaceAnnotationsState(_ sender: NSButton) {
        preset.replaceAnnotations = sender.state == .off ? true : false
    }
}
