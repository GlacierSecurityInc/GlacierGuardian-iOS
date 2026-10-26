//
//  GlacierAccountMetadataMigration.swift
//  Glacier
//
//  Clears the account metadata that older builds left in the shared app-group
//  preferences file.
//
//  The September 2026 assessment (GUA 02) recovered a display name, JID, organization id,
//  connection state and voice extension from that file out of an unencrypted MobileBackup2
//  backup. Nothing writes those keys any more - every reader goes to the ChatAccount record
//  in the SQLCipher database instead - but an upgrade does not rewrite a preferences file,
//  so on existing installs the values stay on disk until something deletes them. That is
//  this.
//
//  Two details worth keeping if this is ever rewritten:
//
//  - The presence of the keys is the only state. There is no "migration done" flag to get
//    out of step with reality, and running twice is the same as running once.
//  - The purge is skipped when there is a stranded orgid and no account to move it to, so a
//    launch that happens before the database is readable retries on the next one rather than
//    throwing the value away. The one caller that would suffer is `refreshXMPPCredentials`, which
//    needs an organization precisely when the Cognito session has lapsed.
//

import Foundation
import os

private let migrationLog = Logger(subsystem: "com.glaciersec.storage", category: "AccountMetadata")

@objc public final class GlacierAccountMetadataMigration: NSObject {

    /// Keys older builds wrote into the app group. "connection" and "extension" had no
    /// reader even then; "password" never had a writer, but is listed so a value left by
    /// some older build still gets cleared.
    private static let legacyKeys = [
        "username", "displayname", "orgid", "connection", "extension", "password"
    ]

    private static let orgKey = "orgid"

    /// Runs once the database is readable. Safe to call again; safe to call with no account.
    @objc public static func purgeLegacyAppGroupMetadata() {
        guard let defaults = UserDefaults(suiteName: kGlacierGroup) else { return }

        let present = legacyKeys.filter { defaults.object(forKey: $0) != nil }
        guard !present.isEmpty else { return }

        // Keep the organization if this install never got it onto the account record.
        if let strandedOrg = defaults.string(forKey: orgKey), !strandedOrg.isEmpty {
            guard let account = ChatAccountModel.firstAccount() else {
                // No account to hold it. Either the database is not up yet or the user is
                // signed out; in both cases the next launch is a better time than now.
                migrationLog.info("Deferring app-group purge: no account to hold the organization")
                return
            }
            let recordedOrg = account.grdbRecord?.org ?? ""
            if recordedOrg.isEmpty {
                account.grdbRecord?.org = strandedOrg
                account.saveXMPPAccount()
                migrationLog.info("Backfilled the account's organization from the app group")
            }
        }

        for key in present {
            defaults.removeObject(forKey: key)
        }
        // Keys only; the suite still carries the app/user active flags and the push key ids,
        // which the Notification Service Extension reads and which are not account metadata.
        migrationLog.info("Purged \(present.count, privacy: .public) legacy app-group keys")
    }
}
