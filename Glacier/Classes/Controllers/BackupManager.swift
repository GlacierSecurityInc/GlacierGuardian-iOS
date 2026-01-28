//  Glacier
//  Created by Andy Friedman on 12/3/20.
//  Copyright © 2020 Glacier. All rights reserved.

import Foundation

@objc public class BackupManager: NSObject {
    
    @objc public static func encrypt(_ encryptable:Data, password:String) -> Data {
        let ciphertext = RNCryptor.encrypt(data: encryptable, withPassword: password)
        return ciphertext
    }
    
    @objc public static func decrypt(_ decryptable:Data, password:String) -> String {
            do {
                let originalData = try RNCryptor.decrypt(data: decryptable, withPassword: password)
                let decrypted = String(decoding: originalData, as: UTF8.self)
                return decrypted
            } catch {
                print(error)
            }
        return ""
    }
}
