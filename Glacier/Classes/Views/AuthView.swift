//
//  AuthView.swift
//  Glacier
//
//  Created by andyfriedman on 12/10/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import SwiftUI
import Authenticator
import Amplify

struct AuthView: View {
    private let theme = AuthenticatorTheme()
    private var preuser: String?
    private let supportLink = URL(string: "https://glacier.chat/support")
    
    init() {
        theme.components.button.primary.cornerRadius = 50
    }
    
    init(_ user:String) {
        theme.components.button.primary.cornerRadius = 50
        self.preuser = user
    }

    var body: some View {
        Authenticator (
            signInContent: { state in
                SignInView(
                    user: self.preuser,
                    state: state,
                    headerContent: {
                        //
                    },
                    footerContent: {
                        VStack {
                            SignInFooter(supportLink: self.supportLink!) //hidesSignUpButton: true)
                        }
                    }
                )
            },
            confirmSignInWithMFACodeContent: { state in
                CustomConfirmSignInWithMFACodeView(state: state)
            },
            confirmSignInWithTOTPCodeContent: { state in
                CustomConfirmSignInWithMFACodeView(state: state)
            },
            verifyUserContent: { state in
                AutoSkipVerifyUserView(state: state)
            },
            headerContent: {
                VStack {
                    Spacer().frame(height: 20)
                    Image("glacier", bundle: GlacierInfo.resourcesBundle).imageScale(.medium)
                    Spacer().frame(height: 20)
                }
            },
            footerContent: {
                VStack {
                    //Link("Support", destination: URL(string: "https://glacier.chat/support")!)
                        //.foregroundColor(.glacierBlue)
                        //.tint(.systemBlue) //.primary is white/label
                    //Spacer().frame(height: 60)
                    if let info = Bundle.main.infoDictionary, let appVersion = info["CFBundleShortVersionString"] as? String, let appBuild = info[kCFBundleVersionKey as String] as? String {
                        let versionTitle = String(format: "%@ %@ (%@)", VERSION_STRING(), appVersion, appBuild)
                        Text(versionTitle)
                    }
                }
            }
            
        ) { state in
            //ProgressView("Initializing…")
        }
        .hidesSignUpButton()
        .authenticatorTheme(theme)
    }
}

/// Stands in for the Authenticator's "Account recovery requires verified contact
/// information" step, which it inserts between sign-in and the signed-in state
/// whenever an account has an unverified contact attribute and no verified one.
///
/// Accounts created without an email address get a placeholder under the reserved
/// `.invalid` domain, deliberately left unverified so Cognito keeps refusing
/// self-service password recovery for them. That combination puts every one of
/// those accounts through this step after they set their first password, with an
/// address no code could ever reach. There is nothing here for the user to do, so
/// move straight on.
///
/// `skip()` only reads the current user and advances the step; it sends no request
/// to Cognito, and it falls back to the sign-in step on its own if that read fails.
private struct AutoSkipVerifyUserView: View {
    @ObservedObject var state: VerifyUserState

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .task {
                try? await state.skip()
            }
    }
}

extension Color {
    public static let glacierBlue: Color = Color(hue: 195.0 / 360.0, saturation: 0.81, brightness: 0.80)
}

//#Preview {
//    AuthView()
//}
