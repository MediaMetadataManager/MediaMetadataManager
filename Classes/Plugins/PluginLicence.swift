//
//  PluginLicence.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/18/2026.
//
//  Licence keys for the paid metadata-source plugins. A key is made by the
//  store's fulfillment service after a purchase and looks like
//
//      M3L1-<base64url JSON payload>.<base64url Ed25519 signature>
//
//  The payload names the plugin the key unlocks ("plex", "jellyfin"), a random
//  key id and the issue time. M3 checks the signature offline against the public
//  key below; the matching private key never leaves the fulfillment service, so
//  a key can't be made (or its payload changed) without it. The key holds no
//  personal data. Checking needs macOS 10.15 or later (CryptoKit).
//

import Foundation
import CryptoKit

enum PluginLicence {

    struct Payload: Decodable, Equatable {
        let v: Int      // format version, 1
        let p: String   // plugin id the key unlocks
        let k: String   // random key id (what a refund revokes)
        let t: Int      // issued, unix seconds
    }

    /// Public half of the signing key pair (raw Ed25519, base64). Safe to publish.
    static let publicKeyBase64 = "9h1xLWwr17Y3/ks6gKc2FRTx6f/mQQKIb1KS9w5K1Vk="

    /// Plugins (by lowercased pluginName) that need a key. Anything else -- the
    /// sample plugin, a user's own -- loads as before.
    static let paidPluginIDs: Set<String> = ["plex", "jellyfin"]

    /// Where a key is bought. Change this one line when the store moves to its own domain.
    static let storeBaseURL = "https://m3-store.pages.dev/"

    static func storeURL(forPluginID id: String) -> URL? {
        return URL(string: storeBaseURL + "?plugin=" + id)
    }

    private static let storedKeysDefaultsKey = "PluginLicenceKeys"
    private static let revokedDefaultsKey = "PluginLicenceRevokedKeyIDs"
    private static let prefix = "M3L1-"

    // MARK: - Checking a key

    /// The key's payload if the signature is genuine, otherwise nil. Whitespace
    /// anywhere in `key` is ignored, since pasted keys often arrive wrapped.
    static func verify(_ key: String, publicKeyBase64: String = PluginLicence.publicKeyBase64) -> Payload? {
        // CryptoKit (Ed25519) needs macOS 10.15. On 10.13/10.14 no key can be
        // checked, so a paid plugin stays locked there.
        guard #available(macOS 10.15, *) else { return nil }
        let compact = key.filter { !$0.isWhitespace }
        guard compact.hasPrefix(prefix) else { return nil }
        let parts = compact.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = decodeBase64URL(String(parts[0])),
              let signature = decodeBase64URL(String(parts[1])),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: payloadData),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              payload.v == 1, !payload.p.isEmpty, !payload.k.isEmpty
        else { return nil }
        return payload
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    // MARK: - Which plugins need one

    static func pluginID(forPluginName name: String) -> String {
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func requiresLicence(pluginName: String) -> Bool {
        return paidPluginIDs.contains(pluginID(forPluginName: pluginName))
    }

    // MARK: - Stored keys

    static func storedKey(forPluginID id: String, defaults: UserDefaults = .standard) -> String? {
        return (defaults.dictionary(forKey: storedKeysDefaultsKey) as? [String: String])?[id]
    }

    /// Checks `key` and, if genuine and not revoked, remembers it for the plugin
    /// it unlocks. Returns that payload, or nil (nothing is stored) if the key
    /// is not valid.
    @discardableResult
    static func save(key: String, defaults: UserDefaults = .standard,
                     publicKeyBase64: String = PluginLicence.publicKeyBase64) -> Payload? {
        guard let payload = verify(key, publicKeyBase64: publicKeyBase64),
              !revokedKeyIDs(defaults: defaults).contains(payload.k) else { return nil }
        var keys = (defaults.dictionary(forKey: storedKeysDefaultsKey) as? [String: String]) ?? [:]
        keys[payload.p] = key.filter { !$0.isWhitespace }
        defaults.set(keys, forKey: storedKeysDefaultsKey)
        return payload
    }

    static func removeKey(forPluginID id: String, defaults: UserDefaults = .standard) {
        var keys = (defaults.dictionary(forKey: storedKeysDefaultsKey) as? [String: String]) ?? [:]
        keys[id] = nil
        defaults.set(keys, forKey: storedKeysDefaultsKey)
    }

    /// Key ids that must no longer unlock anything (refunded purchases).
    static func revokedKeyIDs(defaults: UserDefaults = .standard) -> Set<String> {
        return Set(defaults.stringArray(forKey: revokedDefaultsKey) ?? [])
    }

    static func setRevokedKeyIDs(_ ids: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(Array(ids).sorted(), forKey: revokedDefaultsKey)
    }

    // MARK: - The answer the plugin loader needs

    /// True when the plugin may load: it is not a paid plugin, or a stored key
    /// for it is genuine, names this plugin and has not been revoked.
    static func isLicensed(pluginName: String, defaults: UserDefaults = .standard,
                           publicKeyBase64: String = PluginLicence.publicKeyBase64) -> Bool {
        let id = pluginID(forPluginName: pluginName)
        guard paidPluginIDs.contains(id) else { return true }
        guard let key = storedKey(forPluginID: id, defaults: defaults),
              let payload = verify(key, publicKeyBase64: publicKeyBase64),
              payload.p == id else { return false }
        return !revokedKeyIDs(defaults: defaults).contains(payload.k)
    }
}
