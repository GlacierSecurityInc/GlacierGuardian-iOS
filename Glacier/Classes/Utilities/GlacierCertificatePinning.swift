//
//  GlacierCertificatePinning.swift
//  Glacier
//
//  Swift rewrite of OTRCertificatePinning.
//
//  Handles TLS trust evaluation for XMPP connections with two layers:
//
//  1. CA Pinning (production Glacier infrastructure):
//     Accepts connections when standard TLS passes AND the certificate chain
//     contains a Glacier-pinned Amazon Trust Services CA. This covers all
//     Glacier-owned servers without requiring hardcoded domain names.
//
//  2. TOFU (Trust on First Use) for user-managed XMPP servers:
//     On first connection to an unknown server the delegate is called; the
//     caller stores the certificate and reconnects. Subsequent connections
//     are validated by matching the server's leaf public key against the
//     stored public key for that hostname.
//
//  Keychain storage uses the same service key as the previous OTRCertificatePinning
//  implementation so existing user-approved certificates are preserved.

import Foundation
import CommonCrypto
import XMPPFramework
import CocoaLumberjack

// MARK: - Delegate Protocol

@objc public protocol GlacierCertificatePinningDelegate: NSObjectProtocol {
    /// Called when a server's certificate fails both CA pinning and TOFU checks.
    /// The delegate should store the certificate (via addCertificateData(_:withHostName:))
    /// and retry the connection if the user approves.
    func didEncounterUntrustedCertificate(_ trust: SecTrust,
                                          forHostname hostname: String,
                                          systemTrustResult: SecTrustResultType)
}

// MARK: - Keychain Storage

/// Manages per-hostname certificate storage in the iOS Keychain.
/// Uses the same service identifier as the previous OTRCertificatePinning
/// implementation so that existing stored certificates are automatically migrated.
private enum CertificateKeychain {

    static let serviceName = "org.chatsecure.ChatSecure.Certificate"

    // MARK: Save

    static func save(_ certs: [Data], forHostname hostname: String) {
        guard !hostname.isEmpty, !certs.isEmpty,
              let data = archive(certs) else { return }

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: hostname
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: Load

    static func load(forHostname hostname: String) -> [Data] {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  serviceName,
            kSecAttrAccount as String:  hostname,
            kSecReturnData as String:   kCFBooleanTrue!,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return [] }
        return unarchive(data) ?? []
    }

    // MARK: Delete

    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func delete(forHostname hostname: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: hostname
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func allHostnames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      serviceName,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String:       kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: Archive Helpers

    /// Archive uses NSKeyedArchiver (non-secure-coding) for compatibility with
    /// data stored by the previous SAMKeychain-based implementation.
    private static func archive(_ certs: [Data]) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: certs as NSArray,
                                          requiringSecureCoding: false)
    }

    private static func unarchive(_ data: Data) -> [Data]? {
        // Try modern unarchiving first, fall back to legacy for old SAMKeychain data.
        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            if let array = obj as? [Data] { return array }
        }
        return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? [Data]
    }
}

// MARK: - GlacierCertificatePinning

@objc public class GlacierCertificatePinning: XMPPModule {

    // MARK: Properties

    @objc public weak var delegate: GlacierCertificatePinningDelegate?

    /// Transient flag suppressing repeated connection-error alerts while a new
    /// certificate is being added and the connection is being retried.
    private static var _addingCert = false

    // MARK: Init

    @objc public override init() {
        super.init()
    }

    /// Required override — XMPPModule's designated initializer. Called by the
    /// ObjC runtime when XMPPModule subclasses are instantiated with a custom
    /// dispatch queue. Without this, Swift leaves an unimplemented stub that
    /// crashes at runtime.
    @objc public override init(dispatchQueue queue: DispatchQueue?) {
        super.init(dispatchQueue: queue)
    }

    // MARK: - Adding-Cert Flag

    @objc public static func isAddingCert() -> Bool { _addingCert }

    @objc public static func setAddingCert() {
        _addingCert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { _addingCert = false }
    }

    // MARK: - Certificate Storage (Class Methods for ObjC / legacy compatibility)

    @objc public static func addCertificateData(_ certificateData: Data,
                                                withHostName hostname: String) {
        guard !hostname.isEmpty, !certificateData.isEmpty else { return }
        var existing = CertificateKeychain.load(forHostname: hostname)
        guard !existing.contains(certificateData) else { return }
        setAddingCert()
        existing.append(certificateData)
        CertificateKeychain.save(existing, forHostname: hostname)
    }

    @objc public static func addCertificate(_ cert: SecCertificate,
                                             withHostName hostname: String) {
        let data = SecCertificateCopyData(cert) as Data
        addCertificateData(data, withHostName: hostname)
    }

    /// Convenience alias used by some call sites.
    @objc public static func add(_ cert: SecCertificate, withHostName hostname: String) {
        addCertificate(cert, withHostName: hostname)
    }

    @objc public static func storedCertificates(withHostName hostname: String) -> [Data]? {
        let certs = CertificateKeychain.load(forHostname: hostname)
        return certs.isEmpty ? nil : certs
    }

    @objc public static func allCertificates() -> [String: [Data]] {
        var result: [String: [Data]] = [:]
        for hostname in CertificateKeychain.allHostnames() {
            let certs = CertificateKeychain.load(forHostname: hostname)
            if !certs.isEmpty { result[hostname] = certs }
        }
        return result
    }

    @objc public static func deleteAllCertificates() {
        CertificateKeychain.deleteAll()
    }

    @objc public static func deleteAllCertificates(withHostName hostname: String) {
        CertificateKeychain.delete(forHostname: hostname)
    }

    @objc public static func deleteCertificate(_ cert: SecCertificate,
                                                withHostName hostname: String) {
        let certData = SecCertificateCopyData(cert) as Data
        var certs = CertificateKeychain.load(forHostname: hostname)
        certs.removeAll { $0 == certData }
        if certs.isEmpty {
            CertificateKeychain.delete(forHostname: hostname)
        } else {
            CertificateKeychain.save(certs, forHostname: hostname)
        }
    }

    // MARK: - Certificate Utilities

    @objc public static func data(forCertificate certificate: SecCertificate) -> Data {
        SecCertificateCopyData(certificate) as Data
    }

    /// Returns the leaf certificate from a SecTrust (index 0).
    @objc public static func cert(forTrust trust: SecTrust) -> SecCertificate? {
        GlacierPinningConfiguration.certificateChain(for: trust).first
    }

    @objc public static func cert(forData data: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, data as CFData)
    }

    /// Returns the public key for a certificate's DER data, or nil if extraction fails.
    @objc public static func publicKey(withCertData certData: Data) -> SecKey? {
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else { return nil }
        return SecCertificateCopyKey(cert)
    }

    /// SHA-256 fingerprint of certificate DER data, as a lowercase hex string.
    @objc public static func sha256Fingerprint(forCertificateData certificateData: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        certificateData.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(certificateData.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @objc public static func sha256Fingerprint(forCertificate certificate: SecCertificate) -> String? {
        let data = SecCertificateCopyData(certificate) as Data
        return sha256Fingerprint(forCertificateData: data)
    }

    // MARK: - Trust Evaluation (Instance Methods)

    /// Returns true if the trust passes CA pinning (production Glacier servers).
    private func passesCAPin(_ trust: SecTrust) -> Bool {
        var cfError: CFError?
        guard SecTrustEvaluateWithError(trust, &cfError) else { return false }
        return GlacierPinningConfiguration.chainContainsPinnedCA(trust: trust)
    }

    /// Returns true if the server's leaf public key matches a key previously
    /// stored for this hostname (TOFU for user-managed XMPP servers).
    private func passesTofuPin(_ trust: SecTrust, hostname: String) -> Bool {
        let chain = GlacierPinningConfiguration.certificateChain(for: trust)
        guard let leafCert = chain.first,
              let serverKeyData = rawPublicKeyData(from: leafCert) else { return false }

        let storedCerts = CertificateKeychain.load(forHostname: hostname)
        guard !storedCerts.isEmpty else { return false }

        return storedCerts.contains { certData in
            guard let cert = SecCertificateCreateWithData(nil, certData as CFData),
                  let storedKeyData = rawPublicKeyData(from: cert) else { return false }
            return serverKeyData == storedKeyData
        }
    }

    /// Extracts raw public key bytes from a certificate (for TOFU key comparison).
    private func rawPublicKeyData(from certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCopyExternalRepresentation(key, &error) as Data?
    }
}

// MARK: - XMPPStreamDelegate

extension GlacierCertificatePinning: XMPPStreamDelegate {

    public func xmppStream(_ sender: XMPPStream,
                            didReceive trust: SecTrust,
                            completionHandler: @escaping (Bool) -> Void) {
        guard let otrStream = sender as? GlacierXMPPStream,
              let hostname = otrStream.connectedHostName,
              !hostname.isEmpty else {
            DDLogError("GlacierCertificatePinning: stream is not GlacierXMPPStream or hostname missing")
            completionHandler(false)
            return
        }

        // Layer 1: CA pinning — fast path for production Glacier servers.
        if passesCAPin(trust) {
            completionHandler(true)
            return
        }

        // Layer 2: TOFU — user-managed XMPP servers with previously-trusted keys.
        if passesTofuPin(trust, hostname: hostname) {
            completionHandler(true)
            return
        }

        // Both checks failed. Evaluate system trust to pass context to the delegate.
        var trustResult: SecTrustResultType = .invalid
        SecTrustGetTrustResult(trust, &trustResult)

        DDLogWarn("GlacierCertificatePinning: untrusted cert for \(hostname), result=\(trustResult.rawValue)")

        if delegate?.responds(to: #selector(GlacierCertificatePinningDelegate
                .didEncounterUntrustedCertificate(_:forHostname:systemTrustResult:))) == true {
            delegate?.didEncounterUntrustedCertificate(trust,
                                                       forHostname: hostname,
                                                       systemTrustResult: trustResult)
        }
        completionHandler(false)
    }
}
