//
//  LinkPreviewHelper.swift
//  Glacier
//
//  Added for URL validation in link previews.
//

import Foundation

public enum LinkPreviewError: Error {
    case nonPermittedUrl
    case fetchFailure
}

public enum LinkPreviewHelper {
    private static let schemeAllowSet: Set<String> = ["https"]
    
    private static let domainRejectSet: Set<String> = [
        "example.com",
        "example.org",
        "example.net"
    ]
    
    private static let tldRejectSet: Set<String> = [
        "example",
        "i2p",
        "invalid",
        "localhost",
        "onion",
        "test"
    ]
    
    private static let urlDelimeters: Set<Character> = Set(":/?#[]@")
    
    private static let validURICharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "%:/?#[]@!$&'()*+,;=-._~")
        set.formUnion(.decimalDigits)
        set.formUnion(CharacterSet(charactersIn: "a"..."z"))
        set.formUnion(CharacterSet(charactersIn: "A"..."Z"))
        return set
    }()
    
    public static func isPermittedLinkPreviewUrl(
        _ url: URL,
        parsedFrom sourceString: String? = nil) -> Bool {
            
            guard let scheme = url.scheme?.lowercased(), schemeAllowSet.contains(scheme) else {
                return false
            }
            guard url.user == nil else { return false }
            guard url.password == nil else { return false }
            
            let rawHostname: String?
            if var sourceString {
                let schemePrefix = "\(scheme)://"
                if let schemeRange = sourceString.range(of: schemePrefix, options: [.anchored, .caseInsensitive]) {
                    sourceString.removeSubrange(schemeRange)
                }
                let delimiterIndex = sourceString.firstIndex { urlDelimeters.contains($0) }
                rawHostname = String(sourceString[..<(delimiterIndex ?? sourceString.endIndex)])
                
                if !isValidLink(sourceString) {
                    return false
                }
            } else {
                rawHostname = url.host
            }
            guard let hostname = rawHostname, isValidHostname(hostname) else { return false }
            
            // Validate path and query characters from source string if available
            if sourceString?.count ?? 0 > scheme.count + 4,
               let withoutScheme = sourceString?.dropFirst(scheme.count + 4),
               let pathOrParamsStart = withoutScheme.firstIndex(of: "/") ?? withoutScheme.firstIndex(of: "?"),
               withoutScheme[pathOrParamsStart...].rangeOfCharacter(from: validURICharacters.inverted) != nil {
                return false
            }
            
            return true
        }
    
    private static func isValidLink(_ text: String) -> Bool {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        return matches.count == 1 && matches.first?.range == range
    }
    
    private static func isValidHostname(_ hostname: String) -> Bool {
        let hostnameComponents = hostname.split(separator: ".")
        guard hostnameComponents.count >= 2,
              let tld = hostnameComponents.last?.lowercased(),
              let domain = hostnameComponents.dropLast().last?.lowercased() else {
            return false
        }
        
        let isValidTLD = !tldRejectSet.contains(tld)
        let isValidDomain = !domainRejectSet.contains([domain, tld].joined(separator: "."))
        let isAllASCII = hostname.allSatisfy { $0.isASCII }
        let isAllNonASCII = hostname.allSatisfy { !$0.isASCII || $0 == "." }
        
        return isValidTLD && isValidDomain && (isAllASCII || isAllNonASCII)
    }
}

