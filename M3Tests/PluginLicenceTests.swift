//
//  PluginLicenceTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/18/2026.
//

import XCTest
import CryptoKit
@testable import M3

/// Licence keys for the paid plugins: genuine ones unlock, everything else does not.
final class PluginLicenceTests: XCTestCase {

    // A key made by the store's own fulfillment code (Store/fulfillment/worker.js) with a
    // throwaway key pair, so these tests also prove the Swift check accepts what the
    // service really produces. Not the production key.
    private let workerPublicKey = "SkKvzakNvCkwvG5kYr7dVwtxqEYW0lwMDBGco5x8JUY="
    private let workerKey = "M3L1-eyJ2IjoxLCJwIjoicGxleCIsImsiOiJTeHZqcTZpYVU1UlEiLCJ0IjoxNzYwMDAwMDAwfQ.t9RF-R8ycAJZLQMBJtO34nrVDc-6FYZr_b4HS4KF94sXJyPO4x894rj8vuZnlUyqowXOT7-Ny48CcqWUkmfVAQ"

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "PluginLicenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Signs a key the way the service does, with a key pair made here.
    private func makeKey(plugin: String, keyID: String = "abc123") -> (key: String, publicKey: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = try! JSONSerialization.data(withJSONObject: ["v": 1, "p": plugin, "k": keyID, "t": 1760000000],
                                                  options: [.sortedKeys])
        let signature = try! privateKey.signature(for: payload)
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return ("M3L1-\(b64url(payload)).\(b64url(Data(signature)))",
                privateKey.publicKey.rawRepresentation.base64EncodedString())
    }

    func testKeyFromTheFulfillmentServiceVerifies() {
        let payload = PluginLicence.verify(workerKey, publicKeyBase64: workerPublicKey)
        XCTAssertEqual(payload, PluginLicence.Payload(v: 1, p: "plex", k: "Sxvjq6iaU5RQ", t: 1760000000))
    }

    func testWrappedAndPaddedKeyStillVerifies() {
        let wrapped = "  " + String(workerKey.prefix(40)) + "\r\n" + String(workerKey.dropFirst(40)) + "\n"
        XCTAssertNotNil(PluginLicence.verify(wrapped, publicKeyBase64: workerPublicKey))
    }

    func testWrongPublicKeyRejectsTheKey() {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNil(PluginLicence.verify(workerKey, publicKeyBase64: other))
        // ...and so does the real production key, which did not sign this one.
        XCTAssertNil(PluginLicence.verify(workerKey))
    }

    func testChangedTruncatedAndJunkKeysAreRejected() {
        let parts = workerKey.split(separator: ".")
        let forgedPayload = Data(#"{"v":1,"p":"jellyfin","k":"x","t":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(PluginLicence.verify("M3L1-\(forgedPayload).\(parts[1])", publicKeyBase64: workerPublicKey))
        XCTAssertNil(PluginLicence.verify(String(parts[0]), publicKeyBase64: workerPublicKey))
        XCTAssertNil(PluginLicence.verify(String(workerKey.dropLast(4)), publicKeyBase64: workerPublicKey))
        XCTAssertNil(PluginLicence.verify("hello", publicKeyBase64: workerPublicKey))
        XCTAssertNil(PluginLicence.verify("", publicKeyBase64: workerPublicKey))
        XCTAssertNil(PluginLicence.verify("M3L1-.", publicKeyBase64: workerPublicKey))
    }

    func testOnlyThePaidPluginsNeedAKey() {
        XCTAssertTrue(PluginLicence.requiresLicence(pluginName: "Plex"))
        XCTAssertTrue(PluginLicence.requiresLicence(pluginName: " Jellyfin "))
        XCTAssertFalse(PluginLicence.requiresLicence(pluginName: "Sample"))
        XCTAssertTrue(PluginLicence.isLicensed(pluginName: "Sample", defaults: defaults))
    }

    func testPaidPluginIsLockedUntilItsOwnKeyIsSaved() {
        let plex = makeKey(plugin: "plex")
        XCTAssertFalse(PluginLicence.isLicensed(pluginName: "Plex", defaults: defaults, publicKeyBase64: plex.publicKey))

        XCTAssertNotNil(PluginLicence.save(key: plex.key, defaults: defaults, publicKeyBase64: plex.publicKey))
        XCTAssertTrue(PluginLicence.isLicensed(pluginName: "Plex", defaults: defaults, publicKeyBase64: plex.publicKey))
        // A Plex key does not unlock Jellyfin.
        XCTAssertFalse(PluginLicence.isLicensed(pluginName: "Jellyfin", defaults: defaults, publicKeyBase64: plex.publicKey))
    }

    func testAnInvalidKeyIsNotStored() {
        XCTAssertNil(PluginLicence.save(key: "M3L1-nonsense.nonsense", defaults: defaults))
        XCTAssertNil(PluginLicence.storedKey(forPluginID: "plex", defaults: defaults))
    }

    func testRevokedKeyNoLongerUnlocks() {
        let plex = makeKey(plugin: "plex", keyID: "refunded1")
        PluginLicence.save(key: plex.key, defaults: defaults, publicKeyBase64: plex.publicKey)
        XCTAssertTrue(PluginLicence.isLicensed(pluginName: "Plex", defaults: defaults, publicKeyBase64: plex.publicKey))

        PluginLicence.setRevokedKeyIDs(["refunded1"], defaults: defaults)
        XCTAssertFalse(PluginLicence.isLicensed(pluginName: "Plex", defaults: defaults, publicKeyBase64: plex.publicKey))
        // A revoked key can't be entered again either.
        PluginLicence.removeKey(forPluginID: "plex", defaults: defaults)
        XCTAssertNil(PluginLicence.save(key: plex.key, defaults: defaults, publicKeyBase64: plex.publicKey))
    }

    func testRemovingTheKeyLocksThePluginAgain() {
        let plex = makeKey(plugin: "plex")
        PluginLicence.save(key: plex.key, defaults: defaults, publicKeyBase64: plex.publicKey)
        PluginLicence.removeKey(forPluginID: "plex", defaults: defaults)
        XCTAssertFalse(PluginLicence.isLicensed(pluginName: "Plex", defaults: defaults, publicKeyBase64: plex.publicKey))
    }
}
