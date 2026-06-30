//
//  PushMetadataEnvelope.swift
//  Glacier
//
//  libsodium sealed-box envelope for encrypted push metadata.
//
//  Single source of truth shared by the app (key generation + registration) and the
//  Notification Service Extension (envelope open). The sealed box (crypto_box_seal) gives
//  confidentiality + integrity of the routing metadata and ciphertext that the server puts
//  in the push, so APNs never sees JIDs/type and cannot silently alter routing — a tampered
//  envelope simply fails to open and the NSE falls back to MAM.
//
//  IMPORTANT (target membership): add this file to the Glacier, GlacierNotifications, and
//  ChatSecureTests targets. The NSE must compile it to open envelopes while the device is
//  locked; the keychain items use the shared access group + AfterFirstUnlock(ThisDeviceOnly).
//

import Foundation
import CryptoKit
import Sodium
import SAMKeychain
import os

/// Privacy-safe diagnostic log (subsystem "com.glaciersec.push"). Logs reason codes, kid, and
/// the recovered stanza type only — never JIDs, ciphertext, or decrypted plaintext.
private let envelopeLog = Logger(subsystem: "com.glaciersec.push", category: "Envelope")

@objc public final class PushMetadataEnvelope: NSObject {

    /// Algorithm tag advertised to the server and required on inbound envelopes.
    @objc public static let algorithm = kGlacierPushSealedBoxAlg

    private static let sodium = Sodium()

    // Shared app-group defaults: which key id is current, and the retained previous one.
    private static let currentKidDefaultsKey  = "GlacierPushEncryptCurrentKid"
    private static let previousKidDefaultsKey = "GlacierPushEncryptPreviousKid"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: kGlacierGroup)
    }

    // MARK: - kid

    /// kid = base64std( SHA256(pk)[0..8] ). Must match p2's derivation exactly.
    @objc public static func kid(forPublicKey pk: Data) -> String {
        let digest = SHA256.hash(data: pk)
        return Data(digest.prefix(8)).base64EncodedString()
    }

    // MARK: - Keychain storage (pk‖sk, 64 bytes, account = kid)

    @discardableResult
    private static func store(publicKey pk: Data, secretKey sk: Data, kid: String) -> Bool {
        var blob = Data()
        blob.append(pk)
        blob.append(sk)
        // Writes inherit SAMKeychain's global accessibility, set to
        // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly at app launch — required so the
        // NSE can read the secret key while the device is locked.
        return SAMKeychain.setPasswordData(blob,
                                           forService: kGlacierPushEncryptKeychainService,
                                           account: kid,
                                           accessGroup: kGlacierKeyGroup,
                                           error: nil)
    }

    /// Reads the keypair for `kid`. Returns nil if the key was rotated away or the app was
    /// reinstalled (ThisDeviceOnly items don't survive restore) — caller falls back to MAM.
    public static func readKeyPair(kid: String) -> (publicKey: [UInt8], secretKey: [UInt8])? {
        guard let blob = SAMKeychain.passwordData(forService: kGlacierPushEncryptKeychainService,
                                                  account: kid,
                                                  accessGroup: kGlacierKeyGroup,
                                                  error: nil),
              blob.count == 64 else {
            return nil
        }
        return ([UInt8](blob.prefix(32)), [UInt8](blob.suffix(32)))
    }

    // MARK: - App: registration fields for the XEP-0357 enable IQ

    @objc public static func currentKid() -> String? {
        sharedDefaults?.string(forKey: currentKidDefaultsKey)
    }

    /// Ensures a current keypair exists (generates one on first use) and returns the three
    /// XData fields for the enable IQ. Idempotent — returns the existing current key if present.
    @objc public static func ensureKeyPairForRegistration() -> [String: String]? {
        if let kid = currentKid(), let pair = readKeyPair(kid: kid) {
            return registrationFields(kid: kid, publicKey: Data(pair.publicKey))
        }
        return generateAndStore(retainingPrevious: false)
    }

    /// Generates a fresh keypair, makes it current, and KEEPS the previous private key so
    /// in-flight pushes encrypted to the old kid still open during the grace window. Re-send
    /// the enable IQ with the returned fields to register the new public key.
    @objc public static func rotateKeyPairForRegistration() -> [String: String]? {
        return generateAndStore(retainingPrevious: true)
    }

    private static func generateAndStore(retainingPrevious: Bool) -> [String: String]? {
        guard let kp = sodium.box.keyPair() else { return nil }
        let pk = Data(kp.publicKey)
        let sk = Data(kp.secretKey)
        let newKid = kid(forPublicKey: pk)
        guard store(publicKey: pk, secretKey: sk, kid: newKid) else { return nil }

        if retainingPrevious, let prior = currentKid(), prior != newKid {
            // Drop the generation older than "previous" so retained keys stay bounded at two.
            if let stale = sharedDefaults?.string(forKey: previousKidDefaultsKey), stale != prior {
                SAMKeychain.deletePassword(forService: kGlacierPushEncryptKeychainService,
                                           account: stale,
                                           accessGroup: kGlacierKeyGroup,
                                           error: nil)
            }
            sharedDefaults?.set(prior, forKey: previousKidDefaultsKey)
        }
        sharedDefaults?.set(newKid, forKey: currentKidDefaultsKey)
        return registrationFields(kid: newKid, publicKey: pk)
    }

    private static func registrationFields(kid: String, publicKey pk: Data) -> [String: String] {
        return [
            kGlacierPushEncryptAlgField:    algorithm,
            kGlacierPushEncryptPubkeyField: pk.base64EncodedString(),
            kGlacierPushEncryptKidField:    kid,
        ]
    }

    // MARK: - NSE: open a sealed envelope

    /// Recovered routing metadata from an opened envelope. `payloadB64` is the base64 of the
    /// serialized <encrypted> element, ready to hand to the existing OMEMO decrypt path.
    ///
    /// `origin` and `sid` are the message's stable identifiers, added so the Notification
    /// Service Extension can persist the decrypted message with the SAME dedup key the app's
    /// MAM/live path will later compute — letting the partial unique index on (thread,
    /// originId) collapse the two into one row. Both are optional: an envelope from an older
    /// server omits them, in which case the NSE decrypts for display only and does not write.
    ///
    /// Sealed-envelope JSON contract (produced by p2/ejabberd, opened here):
    ///   {
    ///     "v":       <int>      // envelope format version
    ///     "type":    <string>   // stanza type, e.g. "chat" / "groupchat"
    ///     "from":    <string>   // bare from — room JID for groups, sender JID for 1:1
    ///     "sender":  <string?>  // group only: sender's real bare JID
    ///     "payload": <string>   // base64 of the serialized <encrypted> element
    ///     "origin":  <string?>  // XEP-0359 origin-id stamped by the sending client
    ///     "sid":     <string?>  // XEP-0359 stanza-id (see by-JID rule below)
    ///   }
    ///
    /// `sid` is the XEP-0359 <stanza-id>, but WHICH one depends on the message type, because
    /// the archiving entity differs — and it must match the `by` JID the app's own
    /// `extractStanzaId` resolves to, or dedup fails:
    ///   - type == "chat"      (1:1): stanza-id stamped `by` the RECIPIENT's bare JID
    ///                                (the user's own MAM archive).
    ///   - type == "groupchat" (MUC): stanza-id stamped `by` the ROOM's bare JID
    ///                                (the room's MAM archive; == `from` here).
    /// `origin` is the primary dedup key and is type-independent; `sid` is a redundant
    /// secondary key. Either may be absent (older server, message not archived) — the NSE
    /// persists on `origin` alone and a missing `sid` is fine.
    public struct Fields {
        public let type: String
        public let from: String
        public let sender: String?
        public let payloadB64: String
        public let origin: String?
        public let sid: String?
    }

    /// Opens the sealed box for `kid` and parses the inner JSON. Returns nil on any failure
    /// (unknown/rotated kid, tampered or forged ciphertext, malformed JSON) so the caller
    /// falls back to MAM. Never logs the ciphertext, JIDs, or decrypted plaintext.
    public static func open(kid: String, base64Data: String) -> Fields? {
        guard let cipher = Data(base64Encoded: base64Data, options: .ignoreUnknownCharacters) else {
            envelopeLog.error("envelope: base64 decode failed kid=\(kid, privacy: .public)")
            return nil
        }
        guard let pair = readKeyPair(kid: kid) else {
            // Expected after rotation/reinstall — caller falls back to MAM.
            envelopeLog.info("envelope: no keypair for kid=\(kid, privacy: .public) -> MAM")
            return nil
        }
        guard let plain = openRaw(cipher: cipher, publicKey: pair.publicKey, secretKey: pair.secretKey) else {
            // Integrity/auth failure — tampered envelope or wrong key.
            envelopeLog.error("envelope: sealed box open failed kid=\(kid, privacy: .public) -> MAM")
            return nil
        }
        guard let fields = parse(plain) else {
            envelopeLog.error("envelope: JSON parse failed kid=\(kid, privacy: .public) -> MAM")
            return nil
        }
        envelopeLog.info("envelope: opened ok kid=\(kid, privacy: .public) type=\(fields.type, privacy: .public) hasSender=\(fields.sender != nil, privacy: .public)")
        return fields
    }

    /// Raw sealed-box open with explicit keys — no keychain. Used by `open(kid:)` and the
    /// interop test (fixed keypair against a Java-produced blob).
    public static func openRaw(cipher: Data, publicKey: [UInt8], secretKey: [UInt8]) -> Data? {
        guard let plain = sodium.box.open(anonymousCipherText: [UInt8](cipher),
                                          recipientPublicKey: publicKey,
                                          recipientSecretKey: secretKey) else {
            return nil
        }
        return Data(plain)
    }

    /// Parses the opened plaintext JSON {v, type, from, sender?, payload, origin?, sid?}.
    public static func parse(_ plain: Data) -> Fields? {
        guard let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let type = json["type"] as? String,
              let from = json["from"] as? String,
              let payload = json["payload"] as? String else {
            return nil
        }
        return Fields(type: type,
                      from: from,
                      sender: json["sender"] as? String,
                      payloadB64: payload,
                      origin: json["origin"] as? String,
                      sid: json["sid"] as? String)
    }
}
