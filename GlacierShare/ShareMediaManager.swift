//
//  ShareMediaManager.swift
//  GlacierShare
//
//  Created by Andy Friedman on 1/5/21.
//  Copyright © 2021 Glacier. All rights reserved.
//

import Foundation
import XMPPFramework
import CocoaLumberjack
import Alamofire

extension UIImage {
    enum DataSize {
        case unlimited
        case maxBytes(UInt)
        var numBytes: UInt {
            switch self {
            case .unlimited:
                return UInt.max
            case .maxBytes(let limit):
                return limit
            }
        }
    }
     struct Quality {
        //static let low = Quality(initial: 0.4, decrementFactor: 0.65)
        //static let medium = Quality(initial: 0.65, decrementFactor: 0.65)
        static let low = Quality(initial: 0.3, decrementFactor: 0.3)
        static let medium = Quality(initial: 0.5, decrementFactor: 0.5)
        static let high = Quality(initial: 0.75, decrementFactor: 0.75)
        
        /// This value cannot be > 1 or bad things will happen
        let initial: CGFloat
        /// Multiplied to reduce the initial value. This value cannot be > 1 or bad things will happen
        let decrementFactor: CGFloat
    }
    func jpegData(dataSize: DataSize,
                  resize: Quality = Quality.medium,
                  jpeg: Quality = Quality.low,
                  maxTries: UInt = 10) -> Data? {
        let image = self
        //var scaledImageData: Data? = nil
        let scaledImageData = UIImageJPEGRepresentation(image, 0.5)
        return scaledImageData
    }
}



public enum ShareMediaError: LocalizedError, CustomNSError {
    case unknown
    case noServers
    case serverError
    case exceedsMaxSize
    case urlFormatting
    case fileNotFound
    case keyGenerationError
    case cryptoError
    case automaticDownloadsDisabled
    case userCanceled
    
    public var errorUserInfo: [String : Any] {
        if let errorDescription = self.errorDescription {
            return [NSLocalizedDescriptionKey: errorDescription];
        }
        return [:]
    }
    
    // localizedDescription
    public var errorDescription: String? {
        switch self {
        case .unknown:
            return UNKNOWN_ERROR_STRING()
        case .noServers:
            return NO_HTTP_UPLOAD_SERVERS_STRING() + " " + PLEASE_CONTACT_SERVER_OP_STRING()
        case .serverError:
            return UNKNOWN_ERROR_STRING() + " " + PLEASE_CONTACT_SERVER_OP_STRING()
        case .exceedsMaxSize:
            return FILE_EXCEEDS_MAX_SIZE_STRING()
        case .urlFormatting:
            return COULD_NOT_PARSE_URL_STRING()
        case .fileNotFound:
            return FILE_NOT_FOUND_STRING()
        case .cryptoError, .keyGenerationError:
            return errSSLCryptoString()
        case .automaticDownloadsDisabled:
            return AUTOMATIC_DOWNLOADS_DISABLED_STRING()
        case .userCanceled:
            return USER_CANCELED_STRING()
        }
    }
}

public class ShareMediaManager: NSObject {

    let httpFileUpload: XMPPHTTPFileUpload
    let internalQueue = DispatchQueue(label: "ShareMediaManager Queue")
    let callbackQueue = DispatchQueue.main
    let sessionManager: Session
    let uploadDomain: String
    let shareDelegate: ShareMessageDelegate
    private var servers: [HTTPServer] = []
    
    @objc public var canUploadFiles: Bool {
        return self.servers.first != nil
    }
    
    deinit {
        httpFileUpload.removeDelegate(self)
    }
    
    
    @objc public func removeDelegates() {
        httpFileUpload.removeDelegate(self)
    }
    
    //IOSM-517
    @objc public func teardownConnections() {
        //self.connection = nil
    }
    
    // MARK: - Public Methods
    
    @objc public func compressImage(_ imageURL: URL, to pointSize: CGSize, scale: CGFloat) -> UIImage {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
     
        let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions)!
      
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions =  [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceShouldCacheImmediately: true,
                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels] as CFDictionary
        let downsampledImage =   CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions)!
        return UIImage(cgImage: downsampledImage)
    }
    
    //IOSM-548
    @objc public func compressImageData(_ imageData: Data, to pointSize: CGSize, scale: CGFloat) -> UIImage {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
     
        let imageSource = CGImageSourceCreateWithData(imageData as CFData, imageSourceOptions)!
      
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * scale
        let downsampleOptions =  [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceShouldCacheImmediately: true,
                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels] as CFDictionary
        let downsampledImage =   CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions)!
        return UIImage(cgImage: downsampledImage)
    }

        }
    }*/
    
    /// Currently just a wrapper around sendData
    
            
            if UInt(data.count) > service.maxSize {
                DDLogError("HTTP Upload exceeds max size \(data.count) > \(service.maxSize)")
                self.callbackQueue.async {
                    completion(nil, ShareMediaError.exceedsMaxSize)
                }
                return
            }
            
            // TODO: Refactor to use streaming encryption
            var outData = data
            var outKeyIv: Data? = nil
            if shouldEncrypt {
                guard let key = OTRPasswordGenerator.randomData(withLength: 32), let iv = OTRSignalEncryptionHelper.generateIV() else {
                //guard let key = OTRPasswordGenerator.randomData(withLength: 32), let iv = OTRPasswordGenerator.randomData(withLength: 16) else {
                    DDLogError("Could not generate key/iv")
                    self.callbackQueue.async {
                        completion(nil, ShareMediaError.keyGenerationError)
                    }
                    return
                }
                outKeyIv = iv + key
                do {
                    let crypted = try OTRSignalEncryptionHelper.encryptData(data, key: key, iv: iv)
                    //let crypted = try OTRCryptoUtility.encryptAESGCMData(data, key: key, iv: iv)
                    outData = crypted.data + crypted.authTag
                } catch let error {
                    outData = Data()
                    DDLogError("Could not encrypt data for file transfer \(error)")
                    self.callbackQueue.async {
                        completion(nil, error)
                    }
                    return
                }
            }
            
            self.httpFileUpload.requestSlot(fromService: service.jid, filename: filename, size: UInt(outData.count), contentType: contentType, completion: { (slot: XMPPSlot?, iq: XMPPIQ?, error: Error?) in
                guard let slot = slot else {
                    let outError = error ?? ShareMediaError.serverError
                    DDLogError("\(service) failed to assign upload slot: \(outError)")
                    self.callbackQueue.async {
                        completion(nil, outError)
                    }
                    return
                }
                
                self.sessionManager.upload(outData, to: slot.putURL, method: .put)
                    .validate()
                    .response(queue: self.callbackQueue) { response in
                        switch response.result {
                        case .success:
                            if let outKeyIv = outKeyIv {
                                // If there's a AES-GCM key, we gotta put it in the url
                                // and change the scheme to `aesgcm`
                                if var components = URLComponents(url: slot.getURL, resolvingAgainstBaseURL: true) {
                                    components.scheme = URLScheme.aesgcm.rawValue
                                    components.fragment = outKeyIv.toHexString()
                                    if let outURL = components.url {
                                        completion(outURL, nil)
                                    } else {
                                        completion(nil, ShareMediaError.urlFormatting)
                                    }
                                } else {
                                    completion(nil, ShareMediaError.urlFormatting)
                                }
                            } else {
                                // The plaintext case
                                completion(slot.getURL, nil)
                            }
                        case .failure(let error):
                            completion(nil, error)
                            DDLogError("Upload error: \(error)")
                        }
                    }.uploadProgress(queue: self.internalQueue) { progress in
                        //DDLogVerbose("Upload progress \(progress.fractionCompleted)")
                        if let media = OTRMediaItem.getMediaItem(with: media.uniqueId) { //, completion: {
                            media.transferProgress = Float(progress.fractionCompleted)
                            media.save(completion: {
                                media.touchParent()
                            })
                        })
                    }
                }
            })
        }
    }*/
    
    
    
    
    
    
    
    //IOSM-486, IOSM-557
    
    
    
    
    // MARK: - Private Methods
    
    private func serversFromCapabilities(capabilities: [XMPPJID : XMLElement]) -> [HTTPServer] {
        var servers: [HTTPServer] = []
        for (jid, element) in capabilities {
            let supported = element.supportsHTTPUpload()
            let maxSize = element.maxHTTPUploadSize()
            if supported && maxSize > 0 {
                let server = HTTPServer(jid: jid, maxSize: maxSize)
                servers.append(server)
            }
        }
        return servers
    }
}

// MARK: - Extensions

fileprivate struct HTTPServer {
    /// service jid for upload service
    let jid: XMPPJID
    /// max upload size in bytes
    let maxSize: UInt
}

public extension XMLElement {
    
    // For use on a <query> element
    func supportsHTTPUpload() -> Bool {
        let features = self.elements(forName: "feature")
        var supported = false
        for feature in features {
            if let value = feature.attributeStringValue(forName: "var"),
                value == XMPPHTTPFileUploadNamespace  {
                supported = true
                break
            }
        }
        return supported
    }
    
    /// Returns 0 on failure, or max file size in bytes
    func maxHTTPUploadSize() -> UInt {
        var maxSize: UInt = 0
        let xes = self.elements(forXmlns: "jabber:x:data")
        
        for x in xes {
            let fields = x.elements(forName: "field")
            var correctXEP = false
            for field in fields {
                if let value = field.element(forName: "value") {
                    if value.stringValue == XMPPHTTPFileUploadNamespace {
                        correctXEP = true
                    }
                    if let varMaxFileSize = field.attributeStringValue(forName: "var"), varMaxFileSize == "max-file-size" {
                        maxSize = value.stringValueAsNSUInteger()
                    }
                }
            }
            if correctXEP && maxSize > 0 {
                break
            }
        }
        
        return maxSize
    }
}

// expand to http?
enum URLScheme: String {
    case https = "https"
    case aesgcm = "aesgcm"
    static let downloadableSchemes: [URLScheme] = [.https, .aesgcm]
}

extension URL {
    
    /** URL scheme matches aesgcm:// */
    var isAesGcm: Bool {
        return scheme == URLScheme.aesgcm.rawValue
    }
    
    /** Has hex anchor with key and IV. 48 bytes w/ 16 iv + 32 key */
    var anchorData: Data? {
        guard let anchor = self.fragment else { return nil }
        let data = anchor.dataFromHex()
        return data
    }
    
    var aesGcmKey: (key: Data, iv: Data)? {
        guard let data = self.anchorData else { return nil }
        let ivLength: Int
        switch data.count {
        case 48:
            // legacy clients send 16-byte IVs
            ivLength = 16
        case 44:
            // newer clients send 12-byte IVs
            ivLength = 12
        default:
            return nil
        }
        let iv = data.subdata(in: 0..<ivLength)
        let key = data.subdata(in: ivLength..<data.count)
        
        return (key, iv)
    }
}

@objc public extension NSString {
    var isSingleURLOnly: Bool {
        return (self as String).isSingleURLOnly
    }
    
    @objc var urls: [URL] { //IOSM-486, IOSM-557
        return (self as String).urls
    }
}

public extension String {
    
    private var urlRanges: ([URL], [NSRange]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return ([], [])
        }
        var urls: [URL] = []
        var ranges: [NSRange] = []
        
        let matches = detector.matches(in: self, options: NSRegularExpression.MatchingOptions(rawValue: 0), range: NSRange(location: 0, length: self.utf16.count))
        
        for match in matches where match.resultType == .link {
            if let url = match.url {
                if (!url.absoluteString.hasPrefix("mailto")) { //IOSM-579
                    urls.append(url)
                    ranges.append(match.range)
                }
            }
        }
        return (urls, ranges)
    }
    
    /** Grab any URLs from a string */
    var urls: [URL] {
        let (urls, _) = urlRanges
        return urls
    }
    
    /** Returns true if the message is ONLY a single URL */
    var isSingleURLOnly: Bool {
        let (_, ranges) = urlRanges
        guard ranges.count == 1,
            let range = ranges.first,
            range.length == self.count else {
            return false
        }
        return true
    }
    
    /** Use this for extracting potentially downloadable URLs from a message. Currently checks for https:// and aesgcm:// */
    var downloadableURLs: [URL] {
        
        return urlsMatchingSchemes(URLScheme.downloadableSchemes)
    }
    
    fileprivate func urlsMatchingSchemes(_ schemes: [URLScheme]) -> [URL] {
        let urls = self.urls.filter {
            guard let scheme = $0.scheme?.lowercased() else { return false }
            for inScheme in schemes where inScheme.rawValue == scheme {
                return true
            }
            return false
        }
        return urls
    }
}

public extension ShareMediaManager {
    /// Returns whether or not message should be displayed or hidden from collection. Single incoming URLs should be hidden, for example.
        // Hide non-media messages that have no text
        guard let messageText = message.messageText else {
            return false
        }
        
        // Filter out messages that are aesgcm scheme file transfers
        if messageText.contains("aesgcm://"),
            message.messageError == nil {
            return false
        }
        
        // Filter out messages that are just URLs and have downloads
        if messageText.isSingleURLOnly,
           message.hasExistingDownloads() { 
            return false
        }
        
        // so media messages don't show as link in group, maybe remove after OMEMO

        return true
    }*/
}

