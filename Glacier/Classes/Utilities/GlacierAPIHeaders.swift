//
//  GlacierAPIHeaders.swift
//  Glacier
//
//  Created by OpenAI on 3/14/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Alamofire
import Amplify
import AWSPluginsCore

enum GlacierAPIHeaders {
    static func authHeaders() async -> HTTPHeaders? {
        do {
            let session = try await Amplify.Auth.fetchAuthSession()
            guard let provider = session as? AuthCognitoTokensProvider else {
                return nil
            }
            let tokensResult = provider.getCognitoTokens()
            let tokens = try tokensResult.get()
            let accessToken = tokens.accessToken
            return HTTPHeaders([
                "Authorization": "Bearer \(accessToken)",
                "X-Glacier-API-Version": GlacierInfo.glacierAPIVersion()
            ])
        } catch {
            print("Failed to fetch Cognito auth session: \(error)")
            return nil
        }
    }
}
