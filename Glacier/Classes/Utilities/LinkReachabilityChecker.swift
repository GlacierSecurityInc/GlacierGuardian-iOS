//
//  LinkReachabilityChecker.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 15/09/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation

actor LinkReachabilityChecker {
    
    static let shared = LinkReachabilityChecker()
    private var cache: [String: Bool] = [:]
    
    /// Private initializer
    private init() {}
    
    /// Check if a given link is reachable.
    /// - Parameter urlString: The URL string to validate.
    /// - Returns: `true` if reachable, `false` otherwise.
    func isReachable(_ urlString: String) async -> Bool {
        
        // Return from cache if already checked
        if let cached = cache[urlString] {
            return cached
        }
        
        guard let url = URL(string: urlString) else {
            cache[urlString] = false
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200..<400).contains(httpResponse.statusCode) {
                cache[urlString] = true
                return true
            }
        } catch {
            // network error, mark as not reachable
        }
        
        cache[urlString] = false
        return false
    }
}
