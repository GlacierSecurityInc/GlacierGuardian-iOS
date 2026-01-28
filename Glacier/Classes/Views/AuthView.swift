//  Glacier
//  Created by andyfriedman on 12/10/24.
//  Copyright © 2024 Glacier. All rights reserved.

import SwiftUI
import Authenticator
import Amplify

struct AuthView: View {
    private let theme = AuthenticatorTheme()
    private var preuser: String?
    private let supportLink = URL(string: "https:
    
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
                    },
                    footerContent: {
                        VStack {
                            SignInFooter(supportLink: self.supportLink!)
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
            headerContent: {
                VStack {
                    Spacer().frame(height: 20)
                    Image("glacier", bundle: GlacierInfo.resourcesBundle).imageScale(.medium)
                    Spacer().frame(height: 20)
                }
            },
            footerContent: {
                VStack {
                    if let info = Bundle.main.infoDictionary, let appVersion = info["CFBundleShortVersionString"] as? String, let appBuild = info[kCFBundleVersionKey as String] as? String {
                        let versionTitle = String(format: "%@ %@ (%@)", VERSION_STRING(), appVersion, appBuild)
                        Text(versionTitle)
                    }
                }
            }
            
        ) { state in
        }
        .hidesSignUpButton()
        .authenticatorTheme(theme)
    }
}

extension Color {
    public static let glacierBlue: Color = Color(hue: 195.0 / 360.0, saturation: 0.81, brightness: 0.80)
}

