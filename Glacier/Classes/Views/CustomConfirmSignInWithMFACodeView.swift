//
//  CustomConfirmSignInWithMFACodeView.swift
//  Glacier
//
//  Created by andyfriedman on 10/14/25.
//  Copyright © 2025 Glacier. All rights reserved.
//


import SwiftUI
import Amplify
import Authenticator

/// Custom MFA code entry for Amplify 2.51.2
struct CustomConfirmSignInWithMFACodeView: View {
    @ObservedObject var state: ConfirmSignInWithCodeState

    //@State private var code: String = ""
    @FocusState private var isFocused: Bool

    // Resend timer
    @State private var canResend = false
    @State private var remainingTime = 30
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Clipboard monitor
    @State private var lastClipboard: String?
    @State private var lastPasteboardChangeCount: Int = -1

    var body: some View {
        VStack(spacing: 18) {
            Text("Please enter the code from your Authenticator app")
                .font(.headline)
                .multilineTextAlignment(.center)

            TextField(
                "6-digit code",
                text: Binding(
                    get: { state.confirmationCode },
                    set: { state.confirmationCode = $0 }
                )
                )
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit { submit() }
                .onChange(of: state.confirmationCode) { newValue in
                    // Auto-submit when full code entered
                    if newValue.count == 6 {
                        submit()
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isFocused = true
                    }
                    //startResendCountdown()
                }

            // Paste from SMS helper
            /*Button("Paste from SMS") {
                if let paste = UIPasteboard.general.string {
                    let trimmed = paste.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count == 6, trimmed.allSatisfy(\.isNumber) {
                        code = trimmed
                    }
                }
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .opacity(0.8)*/

            // Confirm button
            let isConfirmEnabled = state.confirmationCode.count == 6 && !state.isBusy

            Button {
                submit()
            } label: {
                HStack(spacing: 8) {
                    if state.isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                    Text("Confirm")
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlacierPrimaryButtonStyle())
            .disabled(!isConfirmEnabled)
            .opacity(isConfirmEnabled ? 1 : 0.5)

            // Resend helper
            /*Button {
                resend()
            } label: {
                Text(canResend ? "Resend Code" : "Resend in \(remainingTime)s")
            }
            .font(.footnote)
            .disabled(!canResend)
            .opacity(canResend ? 1 : 0.6)*/

            // Error
            /*if let error = state.error {
                Text(error.localizedDescription)
                    .foregroundColor(.red)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }*/
        }
        .padding()
        .onReceive(timer) { _ in
            if !canResend {
                remainingTime -= 1
                if remainingTime <= 0 {
                    canResend = true
                }
            }
            checkClipboardForCode()
        }
    }

    // MARK: - Actions

    private func submit() {
        guard !state.isBusy, state.confirmationCode.count == 6 else { return }
        Task {
            try? await state.confirmSignIn()
        }
    }

    private func resend() {
        Task {
            //try? await state. resendCode()
            startResendCountdown()
        }
    }

    private func startResendCountdown() {
        remainingTime = 30
        canResend = false
    }

    private func checkClipboardForCode() {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount

        guard changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = changeCount

        if #available(iOS 16.0, *) {
            pasteboard.detectValues(for: [.number]) { result in
                guard case .success(let detectedValues) = result else { return }
                if let code = extractSixDigitCode(from: detectedValues) {
                    applyCode(code)
                }
            }
        } else {
            if let clipboard = pasteboard.string {
                applyCode(clipboard)
            }
        }
    }

    @available(iOS 16.0, *)
    private func extractSixDigitCode(from detectedValues: [UIPasteboard.DetectionPattern : Any]?) -> String? {
        guard let detectedValues = detectedValues else { return nil }

        for value in detectedValues.values {
            if let num = value as? Double {
                let wholeNumberInt = Int(num) // This truncates the decimal part
                let str = String(wholeNumberInt)
                let code = validatedCode(from: str)
                return code
            }
        }
        return nil
    }

    private func applyCode(_ clipboard: String) {
        guard let code = validatedCode(from: clipboard) else { return }
        DispatchQueue.main.async {
            if lastClipboard != code {
                lastClipboard = code
                state.confirmationCode = code
                //submit()
            }
        }
    }

    private func validatedCode(from clipboard: String) -> String? {
        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }
}

private struct GlacierPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .fill(Color.glacierBlue.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .foregroundColor(.white)
            .contentShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
    }
}
