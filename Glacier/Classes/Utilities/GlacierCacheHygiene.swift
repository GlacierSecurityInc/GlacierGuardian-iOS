//
//  GlacierCacheHygiene.swift
//  Glacier
//
//  Keeps sensitive bytes out of the two disk locations that outlive an app
//  update: CFNetwork's URL cache and the temporary directory.
//
//  The September 2026 assessment recovered a Cognito profile response and a
//  complete AWS temporary credential response from Cache.db, plus private media
//  from fsCachedData and tmp. The credential responses were written by
//  smithy-swift <= 0.170, which ran AWS calls on a URLSession backed by the
//  default disk cache; 0.171.0 turned that off and we picked it up on
//  2026-01-16. Nothing ever purged what the older builds had already written,
//  so an eight-month-old credential response was still readable when the phone
//  was imaged.
//
//  Two jobs follow from that: delete the residue once, and make sure the shared
//  cache cannot write to disk again regardless of what a future dependency does.
//

import Foundation
import UIKit
import os.log

@objc public final class GlacierCacheHygiene: NSObject {

    /// In-memory ceiling for the replacement shared cache. Large enough to keep
    /// repeat image loads off the network, small enough to stay unremarkable.
    private static let memoryCapacity = 8 * 1024 * 1024

    /// Bump this to re-run the purge once on every install's next launch.
    private static let purgeGeneration = 1
    private static let purgeGenerationKey = "GlacierCachePurgeGeneration"

    /// Replaces the process-wide URL cache with one that has no disk store.
    ///
    /// Our own backend clients already use ephemeral sessions, but the media
    /// download paths use `URLSession.shared`, which inherits this cache — and so
    /// does any dependency that builds a session from `URLSessionConfiguration
    /// .default`. Setting a zero disk capacity here removes the disk as an option
    /// for all of them at once.
    ///
    /// Must run before anything touches `URLSession.shared`, so call it at the top
    /// of `application:didFinishLaunchingWithOptions:` and nowhere else.
    @objc public static func installMemoryOnlyURLCache() {
        URLCache.shared = URLCache(memoryCapacity: memoryCapacity,
                                   diskCapacity: 0,
                                   directory: nil)
    }

    /// Deletes cache and temporary files left behind by earlier builds. Runs once
    /// per purge generation and is a no-op afterwards.
    ///
    /// Call this *before* `installMemoryOnlyURLCache()`: the on-disk store has to
    /// still be the shared cache for us to shut it down cleanly.
    @objc public static func purgeLegacyDiskCachesIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: purgeGenerationKey) < purgeGeneration else { return }

        // A push can launch us into the background against a locked device, where
        // NSFileProtectionComplete makes these files unreachable. Leave the
        // generation unset and try again on a launch that can finish the job,
        // rather than recording a purge that silently did nothing.
        guard UIApplication.shared.isProtectedDataAvailable else {
            os_log("Cache hygiene: deferring purge, protected data unavailable",
                   log: .storage, type: .default)
            return
        }

        purge(reason: "upgrade")
        defaults.set(purgeGeneration, forKey: purgeGenerationKey)
    }

    /// Clears the same locations when the user signs out or their account is
    /// removed, so nothing from one session is left for whoever signs in next.
    ///
    /// Unconditional, unlike the launch purge: logout is user-initiated, so the
    /// device is unlocked and there is no generation to record. Anything still
    /// uploading is being torn down by the logout anyway.
    @objc public static func purgeOnLogout() {
        purge(reason: "logout")
    }

    private static func purge(reason: String) {
        let cacheFiles = purgeURLCacheOnDisk()
        let tempFiles = purgeTemporaryDirectory()

        // Counts only. The filenames are the user's private media.
        os_log("Cache hygiene: %{public}@ purge removed %d URL cache and %d temporary items",
               log: .storage, type: .default, reason, cacheFiles, tempFiles)
    }

    // MARK: - URL cache

    private static func purgeURLCacheOnDisk() -> Int {
        // Ask CFNetwork to drop its store first, while the shared cache is still
        // the disk-backed default. Deleting the files out from under an open
        // sqlite handle invites it to write them straight back.
        URLCache.shared.removeAllCachedResponses()

        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first else {
            return 0
        }

        // Only CFNetwork's own artefacts. Nothing else under Library/Caches is
        // ours to delete, and a blanket wipe would take dependency state with it.
        let cacheDirectory = caches.appendingPathComponent(bundleID, isDirectory: true)
        let artefacts = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

        return artefacts.reduce(0) { removed, name in
            removed + (remove(cacheDirectory.appendingPathComponent(name), label: name) ? 1 : 0)
        }
    }

    // MARK: - Temporary directory

    /// The send paths stage picked photos and video in `tmp` and only delete a
    /// file when the same name is picked again, so images have survived there for
    /// months. Fixing those call sites is separate work; this clears what they
    /// have already accumulated. Launch is the safe moment for it — no send or
    /// export can be in flight yet, and the `download` directory AWSAcctManager
    /// wants is recreated when that singleton first wakes up.
    private static func purgeTemporaryDirectory() -> Int {
        let fileManager = FileManager.default
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        guard let contents = try? fileManager.contentsOfDirectory(at: temporaryDirectory,
                                                                  includingPropertiesForKeys: nil) else {
            return 0
        }

        return contents.reduce(0) { removed, url in
            removed + (remove(url, label: "temporary item") ? 1 : 0)
        }
    }

    // MARK: - Staged media

    /// Deletes a file the send path staged in `tmp`, and silently refuses anything
    /// outside it.
    ///
    /// The send paths pass around URLs that may equally be a Photos asset, a
    /// security-scoped document, or our own encrypted media store, and the caller
    /// does not always know which it has. The location check is what makes this
    /// safe to call from a shared cleanup point.
    ///
    /// The successful upload already cleans up after itself in
    /// `FileTransferManager.send(url:thread:type:label:isPublic:completion:)`.
    /// This is for the branches that never reach it — a cancelled export, a file
    /// over the server limit, a thread that went away mid-send — where the staged
    /// copy would otherwise sit in `tmp` indefinitely.
    @objc public static func removeStagedTemporaryFile(at url: URL) {
        guard url.isFileURL else { return }

        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath().path
        guard url.resolvingSymlinksInPath().path.hasPrefix(temporaryDirectory + "/") else { return }

        _ = remove(url, label: "staged media")
    }

    // MARK: - Helpers

    /// Returns true when something was actually there and is now gone.
    ///
    /// `label` is what gets logged on failure — never the URL, because a
    /// temporary file's name is the user's own filename.
    private static func remove(_ url: URL, label: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return false }

        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            os_log("Cache hygiene: could not remove %{public}@: %{public}@",
                   log: .storage, type: .error, label, error.localizedDescription)
            return false
        }
    }
}
