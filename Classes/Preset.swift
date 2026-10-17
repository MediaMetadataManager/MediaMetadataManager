//
//  Preset.swift
//  M3
//
//  Created by Damiano Galassi on 21/08/2017.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Sets folder now lives in M3's Application Support folder.
//

import Foundation

protocol Preset: NSSecureCoding, NSCopying {
    var title: String { get set }
    var changed: Bool { get set }
    var version: Int { get }

    var pathExtension: String { get }
}

extension Preset {

    private func appSupportURL() -> URL? {
        return ApplicationSupport.url
    }

    var fileURL: URL {
        guard let url = appSupportURL() else { fatalError() }
        return url.appendingPathComponent(title).appendingPathExtension(pathExtension)
    }
}
