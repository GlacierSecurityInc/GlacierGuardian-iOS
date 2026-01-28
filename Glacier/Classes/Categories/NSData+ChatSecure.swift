//  ChatSecure
//  Created by David Chiles on 2/16/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.

import Foundation


public extension NSData {
    @objc func hexString() -> String {
        return (self as Data).toHexString() // from hexString
    }
}

public extension Data {
    func toHexString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

public extension NSString {
    
    /// Create `Data` from hexadecimal string representation
    /// - returns: Data represented by this hexadecimal string.
    
    @objc func dataFromHex() -> Data? {
        let characters = (self as String)
        var data = Data(capacity: characters.count / 2)
        
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: (self as String), options: [], range: NSMakeRange(0, characters.count)) { match, flags, stop in
            let byteString = (self as NSString).substring(with: match!.range)
            var num = UInt8(byteString, radix: 16)!
            data.append(&num, count: 1)
        }
        
        guard data.count > 0 else {
            return nil
        }
        
        return data
    }
}
