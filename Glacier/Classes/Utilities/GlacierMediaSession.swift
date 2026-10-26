//
//  GlacierMediaSession.swift
//  Glacier
//
//  One ephemeral URLSession for the media downloads that do not go through
//  FileTransferManager: inline chat images, MMS media, audio playback and Giphy.
//
//  These used URLSession.shared, which meant the process-wide disk cache — the
//  one the September 2026 assessment read two private JPEGs out of. Replacing
//  URLCache.shared closes that globally (see GlacierCacheHygiene), but the
//  guarantee should be local to the call site rather than resting on a global
//  another launch path might not have configured yet.
//
//  Deliberately not pinned. FileTransferManager pins because it talks to our own
//  upload host; these hosts are third-party CDNs — Twilio for MMS media, Giphy
//  for GIFs — that our Amazon and Google Trust Services pins do not cover, and
//  pinning them would break the feature rather than protect it. This mirrors the
//  split TwilioBackendManager already makes between its API and media sessions.
//

import Foundation

@objc public final class GlacierMediaSession: NSObject {

    /// Ephemeral: no disk cache, no cookie or credential storage. The in-memory
    /// cache that comes with `.ephemeral` is left in place — it never reaches
    /// disk, and it keeps repeat loads of the same image off the network.
    @objc public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
}
