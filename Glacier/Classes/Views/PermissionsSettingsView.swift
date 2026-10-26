//
//  PermissionsSettingsView.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - Model

/// Standing list of Guardian's permissions and where each one currently stands.
///
/// This is the recovery path for a permission the user declined. iOS shows a permission
/// prompt exactly once — after a denial `requestAccess` returns the cached `false` and
/// displays nothing — so the only way back is Guardian's own page in iOS Settings. Until
/// now the only thing that pointed there was a transient alert at the moment a call
/// failed, and notifications had nothing at all: `registerForPushNotifications` posts
/// `GlacierUserNotificationsChanged` and nothing in the app listens to it, so a user who
/// declined simply stopped receiving messages with no indication why.
final class PermissionsSettingsModel: ObservableObject {

    struct Row: Identifiable {
        let kind: GuardianPermissionKind
        let status: GuardianPermissionStatus
        var id: Int { kind.rawValue }
    }

    @Published private(set) var rows: [Row] = []

    func refresh() {
        GuardianPermissionManager.shared.refreshStatuses { [weak self] statuses in
            self?.rows = statuses.map { Row(kind: $0.kind, status: $0.status) }
        }
    }

    /// What tapping a row does, which depends on whether iOS would still listen to us.
    func handleTap(on row: Row) {
        switch row.status {
        case .notDetermined:
            // Never answered, so the prompt still works — no need to send anyone to
            // Settings for it. This is how a permission that only became relevant later
            // gets granted, for instance contacts after an org turns on SMS.
            GuardianPermissionManager.shared.request(row.kind) { [weak self] _ in
                self?.refresh()
            }

        case .denied:
            openSystemSettings()

        case .granted:
            // Local network is the exception: `.granted` only records that the user was
            // asked, because iOS offers no way to read the answer back. Somebody checking
            // this row wants the page that can actually tell them.
            if !GuardianPermissionManager.isStatusQueryable(row.kind) {
                openSystemSettings()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Application.shared.open(url, options: [:], completionHandler: nil)
    }
}

// MARK: - Presentation

extension GuardianPermissionKind {

    var displayName: String {
        switch self {
        case .notifications: return NSLocalizedString("Notifications", comment: "Permission name")
        case .microphone:    return NSLocalizedString("Microphone", comment: "Permission name")
        case .camera:        return NSLocalizedString("Camera", comment: "Permission name")
        case .localNetwork:  return NSLocalizedString("Local Network", comment: "Permission name")
        case .contacts:      return NSLocalizedString("Contacts", comment: "Permission name")
        case .location:      return NSLocalizedString("Location", comment: "Permission name")
        }
    }

    var iconName: String {
        switch self {
        case .notifications: return "bell.badge"
        case .microphone:    return "mic"
        case .camera:        return "video"
        case .localNetwork:  return "wifi"
        case .contacts:      return "person.2"
        case .location:      return "location"
        }
    }

    /// What Guardian loses without it — the reason someone would come here to fix it.
    var consequence: String {
        switch self {
        case .notifications:
            return NSLocalizedString("Guardian can only reach you while it is open.",
                                     comment: "What is lost without notifications")
        case .microphone:
            return NSLocalizedString("Calls and voice messages will not work.",
                                     comment: "What is lost without the microphone")
        case .camera:
            return NSLocalizedString("Video calls and sending photos will not work.",
                                     comment: "What is lost without the camera")
        case .localNetwork:
            return NSLocalizedString("Guardian-to-Guardian calls take a slower route to connect.",
                                     comment: "What is lost without local network access")
        case .contacts:
            return NSLocalizedString("Calls show a number instead of a name.",
                                     comment: "What is lost without contacts")
        case .location:
            return NSLocalizedString("Sharing your location and live tracking will not work.",
                                     comment: "What is lost without location")
        }
    }
}

// MARK: - View

struct PermissionsSettingsView: View {

    @StateObject private var model = PermissionsSettingsModel()

    var body: some View {
        List {
            Section {
                ForEach(model.rows) { row in
                    Button {
                        model.handleTap(on: row)
                    } label: {
                        PermissionsSettingsRow(row: row)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(NSLocalizedString(
                    "iOS only asks for a permission once. Anything already declined has to be changed in Settings, and Guardian may restart when you change it.",
                    comment: "Permissions settings footer"))
            }
        }
        .listStyle(.insetGrouped)
        .onAppear { model.refresh() }
        // iOS normally terminates the app when a privacy toggle changes, so this mostly
        // matters for the cases where it does not.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

private struct PermissionsSettingsRow: View {

    let row: PermissionsSettingsModel.Row

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: row.kind.iconName)
                .font(.system(size: 17))
                .foregroundColor(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.kind.displayName)
                    .foregroundColor(.primary)

                if row.status != .granted {
                    Text(row.kind.consequence)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Text(statusText)
                .font(.subheadline)
                .foregroundColor(statusColor)

            if isActionable {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Local network cannot be read back from iOS, so it says whether the user has been
    /// asked rather than claiming an answer it does not have.
    private var isQueryable: Bool {
        GuardianPermissionManager.isStatusQueryable(row.kind)
    }

    private var statusText: String {
        switch row.status {
        case .granted:
            return isQueryable
                ? NSLocalizedString("Allowed", comment: "Permission state")
                : NSLocalizedString("Check in Settings", comment: "Permission state, not readable by the app")
        case .denied:
            return NSLocalizedString("Not allowed", comment: "Permission state")
        case .notDetermined:
            return NSLocalizedString("Not set", comment: "Permission state")
        }
    }

    private var statusColor: Color {
        return row.status == .denied ? .red : .secondary
    }

    private var isActionable: Bool {
        row.status != .granted || !isQueryable
    }
}

// MARK: - UIKit entry point

/// Hosts `PermissionsSettingsView` for the Settings table.
///
/// A plain `UIViewController` with the SwiftUI view as a child, rather than a
/// `UIHostingController` subclass, so `GlacierSettingsManager`'s existing
/// `viewControllerClass` mechanism can allocate it with `init` and needs no special case
/// in `SettingsViewController`.
@objc public class GuardianPermissionsViewController: UIViewController {

    public override func viewDidLoad() {
        super.viewDidLoad()

        // GlacierSettingsManager's row overwrites this with the setting's own title; it is
        // here so the screen is still named if it is ever pushed from anywhere else.
        if title == nil {
            title = NSLocalizedString("Permissions", comment: "Permissions settings title")
        }
        view.backgroundColor = .systemGroupedBackground

        let host = UIHostingController(rootView: PermissionsSettingsView())
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }
}
