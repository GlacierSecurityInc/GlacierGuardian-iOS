//
//  PermissionsPrimerView.swift
//  Glacier
//
//  Copyright © 2026 Glacier. All rights reserved.
//

import SwiftUI

// MARK: - Row model

/// Where a single permission has got to in the run.
enum PermissionRowState {
    case waiting
    case asking
    case granted
    case denied
}

struct PermissionRow: Identifiable {

    let kind: GuardianPermissionKind
    let icon: String
    let title: String
    let detail: String
    /// Extra guidance shown under `detail`. Only location has any: it is the one
    /// permission iOS asks for twice, and the user has to pick the right answer both times.
    let note: String?
    var state: PermissionRowState = .waiting

    var id: Int { kind.rawValue }

    static func make(for kind: GuardianPermissionKind) -> PermissionRow {
        switch kind {
        case .notifications:
            return PermissionRow(
                kind: kind,
                icon: "bell.badge",
                title: NSLocalizedString("Notifications", comment: "Permission name"),
                detail: NSLocalizedString(
                    "Receive messages and calls the moment they arrive. Without this, Guardian can only reach you while it is open.",
                    comment: "Why Guardian needs notifications"),
                note: nil)

        case .microphone:
            return PermissionRow(
                kind: kind,
                icon: "mic",
                title: NSLocalizedString("Microphone", comment: "Permission name"),
                detail: NSLocalizedString(
                    "Needed for Guardian calls and voice messages. This one has to be granted before a call arrives — it cannot be turned on once a call is already ringing.",
                    comment: "Why Guardian needs the microphone"),
                note: nil)

        case .camera:
            return PermissionRow(
                kind: kind,
                icon: "video",
                title: NSLocalizedString("Camera", comment: "Permission name"),
                detail: NSLocalizedString(
                    "Video calls, and taking photos to send in a chat.",
                    comment: "Why Guardian needs the camera"),
                note: nil)

        case .localNetwork:
            return PermissionRow(
                kind: kind,
                icon: "wifi",
                title: NSLocalizedString("Local Network", comment: "Permission name"),
                detail: NSLocalizedString(
                    "Lets Guardian-to-Guardian calls connect directly across your network instead of routing the long way around.",
                    comment: "Why Guardian needs local network access"),
                note: nil)

        case .contacts:
            return PermissionRow(
                kind: kind,
                icon: "person.2",
                title: NSLocalizedString("Contacts", comment: "Permission name"),
                detail: NSLocalizedString(
                    "Puts names to the numbers that call you, and lets you start a call with someone you already know. Your contacts stay on your phone.",
                    comment: "Why Guardian needs contacts"),
                note: nil)

        case .location:
            // Copy follows LocationManager.handleNotDetermined, which has said this since
            // before the primer existed — including its softer wording for the accounts
            // where tracking is the user's choice rather than the organisation's.
            let isSelfManaged = ChatAccountModel.allXMPPAccounts().first?
                .username.starts(with: "appleuser") ?? false

            let detail = isSelfManaged
                ? NSLocalizedString(
                    "Lets you share where you are in a chat, and powers live location services if you choose to turn them on.",
                    comment: "Why Guardian needs location, self-managed account")
                : NSLocalizedString(
                    "Your organization enabled live tracking for your account. Guardian needs location access to provide it.",
                    comment: "Why Guardian needs location, organization-enabled tracking")

            let note = isSelfManaged
                ? NSLocalizedString(
                    "iOS will ask twice. Choose \"Allow While Using App\", then \"Change to Always Allow\" for live tracking — or \"Keep Only While Using\" if you would rather not.",
                    comment: "Two-stage location prompt guidance, self-managed account")
                : NSLocalizedString(
                    "iOS will ask twice. Choose \"Allow While Using App\" on the first prompt, then \"Change to Always Allow\" on the second.",
                    comment: "Two-stage location prompt guidance")

            return PermissionRow(kind: kind, icon: "location", title: NSLocalizedString("Location", comment: "Permission name"),
                                 detail: detail, note: note)
        }
    }
}

// MARK: - Model

/// Drives one run of the primer.
///
/// There is no way to skip: the only control is Continue, and the screen closes itself
/// once the last permission has been answered. That matches what Guardian did before the
/// screen existed — the prompts arrived whether you wanted them or not, and all you could
/// do was decline them individually — so the screen adds an explanation without also
/// adding a way to dodge the question.
final class PermissionsPrimerModel: ObservableObject {

    @Published private(set) var rows: [PermissionRow]
    @Published private(set) var isRunning = false
    @Published private(set) var isFinished = false

    /// How long to leave between one prompt being answered and the next appearing.
    ///
    /// iOS puts the next alert up the instant the last is dismissed. Without a gap the
    /// run reads as one undifferentiated stack again, with this screen inert behind it —
    /// the rows never visibly tick over, so there is no way to tell what was just
    /// answered or what is being asked now.
    ///
    /// Note the whole gap is not usable: dismissing one alert and presenting the next
    /// costs roughly 0.3s of animation during which the list is still obscured, so the
    /// clear view of the rows changing is about a third of a second shorter than this.
    private static let stepPacing: TimeInterval = 1.4

    /// The same idea for the first prompt, which has no preceding step to pace it. Gives
    /// the first row time to light up before iOS covers the screen with the alert, so the
    /// user can see what they are about to be asked.
    private static let leadIn: TimeInterval = 1.1

    /// Lifts the manager's prompt hold. Called once the run has been queued and the
    /// first row has had its moment, not when Continue is tapped — see `start`.
    private let onReadyToPrompt: () -> Void
    private let onFinished: () -> Void

    /// The row iOS is asking about right now, for the highlight and the scroll.
    var activeRowID: Int? {
        rows.first(where: { $0.state == .asking })?.id
    }

    var hasStarted: Bool { isRunning || isFinished }

    init(kinds: [GuardianPermissionKind],
         onReadyToPrompt: @escaping () -> Void,
         onFinished: @escaping () -> Void) {
        self.rows = kinds.map { PermissionRow.make(for: $0) }
        self.onReadyToPrompt = onReadyToPrompt
        self.onFinished = onFinished
    }

    func start() {
        guard !isRunning, !isFinished, !rows.isEmpty else { return }
        isRunning = true
        setState(.asking, at: 0)

        // One-shot, consumed by the first request that reaches LocationManager. The rows
        // above already carry that alert's explanation.
        LocationManager.shared().suppressesNextExplanatoryAlert = true

        // Queue the run while prompts are still held. Anything queued earlier — the
        // settings table's notification request, or the contacts request `parseNumbers`
        // raises whenever the backend answers — is folded into the run or pushed behind
        // it, instead of draining the instant the hold lifts and firing ahead of the
        // list the user is looking at.
        GuardianPermissionManager.shared.requestSequentially(
            rows.map { $0.kind },
            pacing: Self.stepPacing,
            progress: { [weak self] kind, status in
                self?.resolve(kind, status)
            },
            completion: { [weak self] in
                self?.finish()
            }
        )

        // Only then lift the hold, once the first row has had time to light up. Held
        // strongly on purpose: if this model went away before firing, nothing would ever
        // release the hold and no permission could be asked for again this session.
        let release = onReadyToPrompt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leadIn, execute: release)
    }

    private func resolve(_ kind: GuardianPermissionKind, _ status: GuardianPermissionStatus) {
        guard let index = rows.firstIndex(where: { $0.kind == kind }) else { return }
        setState(status == .granted ? .granted : .denied, at: index)
        setState(.asking, at: index + 1)
    }

    private func setState(_ state: PermissionRowState, at index: Int) {
        guard rows.indices.contains(index) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            rows[index].state = state
        }
    }

    private func finish() {
        isRunning = false
        isFinished = true
        // A beat so the last row's result is actually visible before the screen goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.onFinished()
        }
    }
}

// MARK: - View

struct PermissionsPrimerView: View {

    @ObservedObject var model: PermissionsPrimerModel
    @State private var visibleRows: Set<Int> = []
    @State private var headerVisible = false

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                                .opacity(headerVisible ? 1 : 0)
                                .padding(.bottom, 8)

                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                PermissionRowView(row: row, isDimmed: isDimmed(row))
                                    .id(row.id)
                                    .opacity(visibleRows.contains(index) ? 1 : 0)
                                    .offset(y: visibleRows.contains(index) ? 0 : 10)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 48)
                        .padding(.bottom, 28)
                    }
                    .onChange(of: model.activeRowID) { active in
                        guard let active = active else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(active, anchor: .center)
                        }
                    }
                }

                footer
            }
        }
        .interactiveDismissDisabled()
        .onAppear(perform: animateContentAppearance)
    }

    /// Once the run is under way everything except the permission currently being asked
    /// about is pushed back, so the alert on top has one obvious referent behind it.
    private func isDimmed(_ row: PermissionRow) -> Bool {
        guard model.isRunning else { return false }
        return row.state != .asking
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Set up Guardian", comment: "Permissions primer title"))
                .font(.largeTitle.bold())
                .foregroundColor(.primary)

            Text(NSLocalizedString(
                "Guardian needs a few permissions to keep you connected. You can change any of them later in iOS Settings.",
                comment: "Permissions primer subtitle"))
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()

            Button {
                model.start()
            } label: {
                ZStack {
                    Text(NSLocalizedString("Continue", comment: "Permissions primer action"))
                        .font(.headline)
                        .opacity(model.isRunning ? 0 : 1)

                    if model.isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                }
            }
            .buttonStyle(PermissionsPrimerButtonStyle())
            .disabled(model.isRunning || model.isFinished)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.systemBackground))
    }

    private func animateContentAppearance() {
        withAnimation(.easeOut(duration: 0.4)) {
            headerVisible = true
        }

        for index in model.rows.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(index + 1)) {
                withAnimation(.easeOut(duration: 0.35)) {
                    _ = visibleRows.insert(index)
                }
            }
        }
    }
}

private struct PermissionRowView: View {

    let row: PermissionRow
    let isDimmed: Bool

    var body: some View {
        content
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(row.state == .asking
                          ? Color.glacierBlue.opacity(0.12)
                          : Color.clear)
            )
            .opacity(isDimmed ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.25), value: row.state)
            .animation(.easeInOut(duration: 0.25), value: isDimmed)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: row.icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(row.detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = row.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            statusIndicator
                .frame(width: 22, height: 22)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconColor: Color {
        switch row.state {
        case .waiting: return .secondary
        case .asking: return .glacierBlue
        case .granted: return .green
        case .denied: return .secondary
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch row.state {
        case .waiting:
            EmptyView()
        case .asking:
            ProgressView().progressViewStyle(.circular)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
        }
    }

    private var accessibilityLabel: String {
        var parts = [row.title, row.detail]
        if let note = row.note { parts.append(note) }
        switch row.state {
        case .waiting, .asking: break
        case .granted: parts.append(NSLocalizedString("Allowed", comment: "Permission state"))
        case .denied: parts.append(NSLocalizedString("Not allowed", comment: "Permission state"))
        }
        return parts.joined(separator: ". ")
    }
}

/// Matches the pill button on the sign-in screens the user has just come from.
private struct PermissionsPrimerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .fill(Color.glacierBlue.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .foregroundColor(.white)
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
    }
}
