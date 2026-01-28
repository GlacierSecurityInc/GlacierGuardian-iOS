//
//  OTROTRSignalEncryptionHelper.swift
//  ChatSecure
//
//  Created by David Chiles on 10/3/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import CryptoKit

class OTRSignalEncryptionHelper {
    
    /**
     Encrypt data with IV and key using aes-128-gcm
     
     - parameter data: The data to be encrypted.
     - parameter key The symmetric key
     - parameter iv The initialization vector
     
     returns: The encrypted data
     */
    
    class func encryptData(_ data:Data, key:Data, iv:Data) throws -> CryptoData {
        let nonce = try AES.GCM.Nonce(data: iv)
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)
        return CryptoData(data: sealedBox.ciphertext, authTag: sealedBox.tag)
    }
    
    /**
     Decrypt data with IV and key using aes-128-gcm
     
     - parameter data: The data to be decrypted.
     - parameter key The symmetric key
     - parameter iv The initialization vector
     
     returns: The Decrypted data
     */
    class func decryptData(_ data:Data, key:Data, iv:Data, authTag:Data) throws -> Data? {
        
        // CryptoKit only accepts 12-byte IVs
        // had to reintroduce code from OTRKit because Android uses 16 byte IV
        // which is also what's in the XEP-0384 OMEMO spec
        if iv.count == 12 {
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: authTag)
            let symmetricKey = SymmetricKey(data: key)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } else {
            let cryptoData = CryptoData(data: data, authTag: authTag)
            return try CryptoUtility.decryptAESGCMData(cryptoData, key: key, iv: iv)
        }
    }
    
    /** Generates random data of length 16 bytes */
    
    /** Generates random key of length 16 bytes*/
    class func generateSymmetricKey() -> Data? {
        //return self.randomDataOfBlockLength()
        return OTRPasswordGenerator.randomData(withLength: 16)
    }
    /** Generates random iv of length 12 bytes */
    class func generateIV() -> Data? {
        //return self.randomDataOfBlockLength()
        return Data(AES.GCM.Nonce())
    }
    
}

