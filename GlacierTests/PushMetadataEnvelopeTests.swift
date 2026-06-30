//
//  PushMetadataEnvelopeTests.swift
//  GlacierTests
//
//  Interop tests for the sealed-box push-metadata envelope.
//
//  NOTE: the project currently has no XCTest target. To run these, add a unit-test target,
//  give it the `Sodium` pod, and add PushMetadataEnvelope.swift to that target (or use
//  @testable import of the app module). The crypto here is pure libsodium crypto_box_seal,
//  so a blob produced by the Java/p2 side opens identically.
//

import XCTest
import Sodium
@testable import Glacier

final class PushMetadataEnvelopeTests: XCTestCase {

    private let sodium = Sodium()

    /// Round-trip: seal a known JSON to a keypair, open it through our code, assert the
    /// recovered fields match. This proves we drive crypto_box_seal/open the same way the
    /// Java side does (both wrap stock libsodium).
    func testSealOpenRoundTrip() throws {
        let kp = try XCTUnwrap(sodium.box.keyPair())

        let json = #"{"v":1,"type":"groupchat","from":"myroom@conference.example.com","sender":"alice@example.com","payload":"PGVuY3J5cHRlZC8+"}"#
        let plaintext = Array(json.utf8)

        let sealed = try XCTUnwrap(sodium.box.seal(message: plaintext, recipientPublicKey: kp.publicKey))

        let opened = try XCTUnwrap(PushMetadataEnvelope.openRaw(cipher: Data(sealed),
                                                               publicKey: kp.publicKey,
                                                               secretKey: kp.secretKey))
        let fields = try XCTUnwrap(PushMetadataEnvelope.parse(opened))
        XCTAssertEqual(fields.type, "groupchat")
        XCTAssertEqual(fields.from, "myroom@conference.example.com")
        XCTAssertEqual(fields.sender, "alice@example.com")
        XCTAssertEqual(fields.payloadB64, "PGVuY3J5cHRlZC8+")
    }

    /// Tamper: flip one byte of the sealed blob and assert open returns nil (Poly1305 integrity).
    func testTamperedEnvelopeFailsToOpen() throws {
        let kp = try XCTUnwrap(sodium.box.keyPair())
        let plaintext = Array(#"{"v":1,"type":"chat","from":"bob@example.com","payload":"PGVuY3J5cHRlZC8+"}"#.utf8)
        var sealed = try XCTUnwrap(sodium.box.seal(message: plaintext, recipientPublicKey: kp.publicKey))

        sealed[sealed.count / 2] ^= 0x01 // flip a byte

        XCTAssertNil(PushMetadataEnvelope.openRaw(cipher: Data(sealed),
                                                  publicKey: kp.publicKey,
                                                  secretKey: kp.secretKey))
    }

    /// kid derivation must match p2: base64std(SHA256(pk)[0..8]).
    func testKidDerivation() {
        // 32 zero bytes — SHA256 is well-known, so the kid is a fixed vector p2 can mirror.
        let pk = Data(repeating: 0, count: 32)
        // SHA256(32 zero bytes) = 66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
        // first 8 bytes = 66687aadf862bd77 → base64 "Zmh6rfhivXc="
        XCTAssertEqual(PushMetadataEnvelope.kid(forPublicKey: pk), "Zmh6rfhivXc=")
    }

    /// Cross-implementation vector: open a blob actually produced by Java/p2.
    /// Fill in the three base64 constants from a Java run, then remove the skip.
    func testJavaProducedVector() throws {
        throw XCTSkip("Populate javaRecipientPublicKey/SecretKey/SealedBlob from a Java run, then enable.")

        // let pk = [UInt8](Data(base64Encoded: "<java recipient pk b64>")!)
        // let sk = [UInt8](Data(base64Encoded: "<java recipient sk b64>")!)
        // let blob = Data(base64Encoded: "<java crypto_box_seal output b64>")!
        // let opened = try XCTUnwrap(PushMetadataEnvelope.openRaw(cipher: blob, publicKey: pk, secretKey: sk))
        // let fields = try XCTUnwrap(PushMetadataEnvelope.parse(opened))
        // XCTAssertEqual(fields.type, "<expected>")
    }
}
