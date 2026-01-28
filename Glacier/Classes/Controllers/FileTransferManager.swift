//
//  FileTransferManager.swift
//  ChatSecure
//
//  Created by Chris Ballinger on 3/28/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import XMPPFramework
import CocoaLumberjack
import Alamofire
import AVFoundation
import Kingfisher
import LinkPresentation

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
        //scaledImageData = UIImageJPEGRepresentation(image, 0.5)
        var sizeInBytes: UInt = 0
        var scaleFactor: CGFloat = resize.initial
        var jpegQuality: CGFloat = jpeg.initial
        let qualityDecrement: CGFloat = jpeg.decrementFactor
        let scaleDecrement: CGFloat = resize.decrementFactor
        var scaledImageData: Data? = nil
        var newSize = CGSize.zero
        let maxTries = 10
        var numTries = 0
        let maxSize = dataSize.numBytes
        while (sizeInBytes == 0 || sizeInBytes > maxSize) &&
            numTries < maxTries {
                numTries = numTries + 1
                newSize = CGSize(width: image.size.width * scaleFactor, height: image.size.height * scaleFactor)
                
                // for larger images, compress even more
                if (image.size.width*image.size.height > 1000000) {
                    var awidth = image.size.width
                    var aheight = image.size.height
                    var atotal = awidth*aheight
                    while (atotal > 1000000) {
                        awidth = awidth * 0.9
                        aheight = aheight * 0.9
                        atotal = awidth*aheight
                    }
                    newSize = CGSize(width: awidth, height: aheight)
                }
                
                let scaledImage = image.scaleImageWith(newSize: newSize)
                scaledImageData = scaledImage.jpegData(compressionQuality: jpegQuality)
                if let imageData = scaledImageData {
                    sizeInBytes = UInt(imageData.count)
                    scaleFactor = scaleFactor * scaleDecrement
                    jpegQuality = jpegQuality * qualityDecrement
                } else {
                    DDLogError("Could not make JPEG out of image!")
                    return nil
                }
        }
        return scaledImageData
    }
}

public enum FileTransferError: LocalizedError, CustomNSError {
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

public class FileTransferManager: NSObject, OTRServerCapabilitiesDelegate {

    let httpFileUpload: XMPPHTTPFileUpload
    let serverCapabilities: OTRServerCapabilities
    let internalQueue = DispatchQueue(label: "FileTransferManager Queue")
    let callbackQueue = DispatchQueue.main
    let sessionManager: Session
    let uploadDomain: String
    private var servers: [HTTPServer] = []
    var uploadCancelled = false
    var retryList: [MessageProtocol] = []

    @objc public var canUploadFiles: Bool {
        return self.servers.first != nil
    }
    
    deinit {
        httpFileUpload.removeDelegate(self)
        serverCapabilities.removeDelegate(self)
    }
    
    @objc public init(serverCapabilities: OTRServerCapabilities,
                sessionConfiguration: URLSessionConfiguration) {
        self.serverCapabilities = serverCapabilities
        self.httpFileUpload = XMPPHTTPFileUpload()
        self.sessionManager = Alamofire.Session(configuration: sessionConfiguration)
        self.uploadDomain = GlacierInfo.defaultHost()
        super.init()
        if let stream = serverCapabilities.xmppStream {
            httpFileUpload.activate(stream)
        }
        httpFileUpload.addDelegate(self, delegateQueue: DispatchQueue.main)
        serverCapabilities.addDelegate(self, delegateQueue: DispatchQueue.main)
        self.refreshCapabilities()
    }
    
    // use self-signed option ONLY in private network
    @objc public init(serverCapabilities: OTRServerCapabilities,
                      sessionConfiguration: URLSessionConfiguration,
                      allowSelfSigned: Bool,
                      uploadDomain: String) {
        self.serverCapabilities = serverCapabilities
        self.httpFileUpload = XMPPHTTPFileUpload()
        self.sessionManager = Alamofire.Session(configuration: sessionConfiguration)
        self.uploadDomain = uploadDomain
        super.init()
        
        if let stream = serverCapabilities.xmppStream {
            httpFileUpload.activate(stream)
        }
        httpFileUpload.addDelegate(self, delegateQueue: DispatchQueue.main)
        serverCapabilities.addDelegate(self, delegateQueue: DispatchQueue.main)
        self.refreshCapabilities()
    }
    
    @objc public func removeDelegates() {
        httpFileUpload.removeDelegate(self)
        serverCapabilities.removeDelegate(self)
    }
    
    // MARK: - Public Methods
    // Resume downloads, i.e. look for media items that are partially downloaded and retry getting them. TODO - use ranges
    @objc public func resumeDownloads() {
        //resumeDownloads should track messages not media because messages are what matters for the UI.
        ChatMediaItemModel.processUnfinishedDownloads(completion: { [weak self] (mediaItems) in
            guard let self = self else {return}
            self.internalQueue.async {
                for mediaItem in mediaItems {
                    if let downloadMessage = mediaItem.parentMessage() {
                        if downloadMessage.messageError == nil {
                            if OTRMediaFileManager.shared.fileExists(forChatMediaItem: mediaItem, buddyUniqueId: downloadMessage.threadId) {
                                mediaItem.grdbRecord?.transferProgress = 1.0
                                mediaItem.save()
                            } else {
                                self.downloadMedia(downloadMessage)
                            }
                        } else if let nsdomain = (downloadMessage.messageError as NSError?)?.domain, nsdomain == "Alamofire.AFError" {
                            if OTRMediaFileManager.shared.fileExists(forChatMediaItem: mediaItem, buddyUniqueId: downloadMessage.threadId) {
                                mediaItem.grdbRecord?.transferProgress = 1.0
                                mediaItem.save()
                            } else {
                                self.downloadMedia(downloadMessage)
                            }
                        }
                    }
                }
            }
        })
        
        self.internalQueue.async {
            self.retryList.forEach({ (retryMsg) in
                if let offlineMsg = retryMsg.refetch(), let mediaItem = ChatMediaItemModel.getMediaItem(for: offlineMsg) {
                    //if let owner = offlineMsg.threadOwner() {
                        do {
                            let data = try OTRMediaFileManager.shared.data(forChatItem: mediaItem, buddyUniqueId: offlineMsg.threadId)
                            self.internalQueue.async {
                                self.send(mediaItem: mediaItem, prefetchedData: data, message: offlineMsg, label: nil, completion: { (success: Bool?, error: Error?) in
                                    //nothing
                                })
                            }
                        } catch let error {
                            DDLogError("Error doing stuff: \(error)")
                        }
                    //}
                }
            })
            self.retryList.removeAll()
        }
    }
    
    /// This will fetch capabilities and setup XMPP transfer module if needed
    @objc public func refreshCapabilities() {
        guard let allCapabilities = serverCapabilities.allCapabilities else {
            serverCapabilities.fetchAllCapabilities()
            return
        }
        servers = serversFromCapabilities(capabilities: allCapabilities)
        serverCapabilities.fetchAllCapabilities()
    }
    
    @objc public func getAttachments(muc: XMPPJID, userjid: XMPPJID,
                                       completion: @escaping (_ pinned: XMPPPinned?, _ error: Error?) -> ()) {
        internalQueue.async {
            guard let service = self.servers.first else {
                DDLogWarn("No HTTP upload servers available")
                self.callbackQueue.async {
                    completion(nil, FileTransferError.noServers)
                }
                return
            }
            
            self.httpFileUpload.requestAttachments(fromGroup: muc, from: userjid, completion: { (pinned: XMPPPinned?, iq: XMPPIQ?, error: Error?) in
                guard let pinned = pinned else {
                    let outError = error ?? FileTransferError.serverError
                    DDLogError("\(service) failed to retrieve attachments: \(outError)")
                    self.callbackQueue.async {
                        completion(nil, outError)
                    }
                    return
                }
                    
                self.callbackQueue.async {
                    completion(pinned, nil)
                }
            })
        }
    }
    
    @objc public func downloadAttachment(url: URL, key: String, iv: String, tag: String,
                                       hudprogress: Progress?,
                                       completion: @escaping (_ data: Data?, _ error: Error?) -> ()) {
        internalQueue.async {
            let downloadurl = url
                
            self.sessionManager.request(downloadurl)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                    
                    switch response.result {
                        case .success:
                            DDLogVerbose("Download Successful")
                            guard let data = response.data else {
                                let error = FileTransferError.fileNotFound
                                DDLogError("No data or response \(error)")
                                completion(nil, error)
                                return
                            }
                            
                            //DDLogVerbose("Received response \(response)")
                            let authTagSize = 16
                            if data.count > authTagSize {
                                DDLogVerbose("Received encrypted response, attempting decryption...")
                                
                                let authTag = Data(base64Encoded: tag, options: Data.Base64DecodingOptions.ignoreUnknownCharacters)!
                                //let cryptoData = CryptoData(data: data, authTag: authTag)
                                
                                do {
                                    let keydata = Data(base64Encoded: key, options: Data.Base64DecodingOptions.ignoreUnknownCharacters)!
                                    let ivdata = Data(base64Encoded: iv, options: Data.Base64DecodingOptions.ignoreUnknownCharacters)!
                                    let decdata = try OTRSignalEncryptionHelper.decryptData(data, key: keydata, iv: ivdata, authTag: authTag)
                                    //let data = try CryptoUtility.decryptAESGCMData(cryptoData, key: keydata, iv: ivdata)
                                    completion(decdata, nil)
                                } catch let error {
                                    DDLogError("Error decrypting data: \(error)")
                                    completion(nil, error)
                                }
                                DDLogVerbose("Decryption successful")
                            }
                        case .failure(let error):
                            DDLogError("Error downloading file \(error)")
                            completion(nil, error)
                    }
            }.downloadProgress(queue: self.internalQueue) { progress in
                DDLogVerbose("Download progress \(progress.fractionCompleted)")
                if (hudprogress != nil) {
                    DispatchQueue.main.async {
                        hudprogress?.completedUnitCount = Int64(progress.fractionCompleted*100.0)
                    }
                }
            }
        }
    }
    
    @objc public func uploadAttachment(file: URL,
                        mucname: String,
                        hudprogress: Progress?,
                        completion: @escaping (_ url: URL?, _ error: Error?) -> ()) {
        internalQueue.async {
            guard let service = self.servers.first else {
                DDLogWarn("No HTTP upload servers available")
                self.callbackQueue.async {
                    completion(nil, FileTransferError.noServers)
                }
                return
            }
            
            do {
                let data = try Data(contentsOf: file)
                let type = UTType(tag: file.pathExtension, tagClass: .filenameExtension, conformingTo: nil)
                let contentType = type?.preferredMIMEType ?? "nil"
                
                if UInt(data.count) > service.maxSize {
                    DDLogError("HTTP Upload exceeds max size \(data.count) > \(service.maxSize)")
                    self.callbackQueue.async {
                        completion(nil, FileTransferError.exceedsMaxSize)
                    }
                    return
                }
                
                let newfilename = "attachments/" + mucname + "/" + file.lastPathComponent
                
                self.httpFileUpload.requestSlot(fromService: service.jid, filename: newfilename, size: UInt(data.count), contentType: contentType, completion: { (slot: XMPPSlot?, iq: XMPPIQ?, error: Error?) in
                    guard let slot = slot else {
                        let outError = error ?? FileTransferError.serverError
                        DDLogError("\(service) failed to assign upload slot: \(outError)")
                        self.callbackQueue.async {
                            completion(nil, outError)
                        }
                        return
                    }
                    
                    self.sessionManager.upload(data, to: slot.putURL, method: .put)
                        .validate()
                        .responseData(queue: self.callbackQueue) { response in
                            switch response.result {
                            case .success:
                                completion(slot.getURL, nil)
                            case .failure(let error):
                                completion(nil, error)
                                DDLogError("Upload error: \(error)")
                            }
                        }.uploadProgress(queue: self.internalQueue) { progress in
                            DDLogVerbose("Upload progress \(progress.fractionCompleted)")
                            if (hudprogress != nil) {
                                DispatchQueue.main.async {
                                    hudprogress?.completedUnitCount = Int64(progress.fractionCompleted*100.0)
                                }
                            }
                        }
                    })
            } catch let error {
                DDLogError("Error sending file URL \(file): \(error)")
                completion(nil, error)
            }
        }
    }

    private func upload(mediaItem: ChatMediaItemModel,
                        shouldEncrypt: Bool,
                       prefetchedData: Data?,
                       completion: @escaping (_ url: URL?, _ error: Error?) -> ()) {
        internalQueue.async {
            if let data = prefetchedData, let filename = mediaItem.getFilename() {
                self.upload(media: mediaItem, data: data, shouldEncrypt: shouldEncrypt, filename: filename, contentType: mediaItem.mimeType(), completion: completion)
            } else {
                if let url = mediaItem.mediaServerURL() {
                    self.upload(media: mediaItem, file: url, shouldEncrypt: shouldEncrypt, completion: completion)
                } else {
                    let error = FileTransferError.fileNotFound
                    DDLogError("Upload filed: File not found \(error)")
                    self.callbackQueue.async {
                        completion(nil, error)
                    }
                }
            }
        }
    }
    
    /// Currently just a wrapper around sendData
    private func upload(media: ChatMediaItemModel,
                        file: URL,
                        shouldEncrypt: Bool,
                     completion: @escaping (_ url: URL?, _ error: Error?) -> ()) {
        internalQueue.async {
            do {
                let data = try Data(contentsOf: file)
                let type = UTType(tag: file.pathExtension, tagClass: .filenameExtension, conformingTo: nil)
                let mimeType = type?.preferredMIMEType ?? "nil"
 
                self.upload(media: media, data: data, shouldEncrypt: shouldEncrypt, filename: file.lastPathComponent, contentType: mimeType, completion: completion)
            } catch let error {
                DDLogError("Error sending file URL \(file): \(error)")
                self.callbackQueue.async {
                    completion(nil, error)
                }
            }
        }
        
    }
    
    private func upload(media: ChatMediaItemModel,
                        data inData: Data,
                        shouldEncrypt: Bool,
                 filename: String,
                 contentType: String,
                 completion: @escaping (_ url: URL?, _ error: Error?) -> ()) {
        internalQueue.async {
            guard let service = self.servers.first else {
                DDLogWarn("No HTTP upload servers available")
                self.callbackQueue.async {
                    completion(nil, FileTransferError.noServers)
                }
                return
            }
            var data = inData
            
            // When resending images, sometimes we need to recompress them
            // to fit the max upload limit
            if UInt(data.count) > service.maxSize,
               media.getMediaType() == ChatMediaType.imageItem,
                let image = UIImage(data: inData),
                let imageData = image.jpegData(dataSize: .maxBytes(service.maxSize), resize: UIImage.Quality.medium, jpeg: UIImage.Quality.medium, maxTries: 10)
                {
                    data = imageData
            }
            
            if UInt(data.count) > service.maxSize {
                DDLogError("HTTP Upload exceeds max size \(data.count) > \(service.maxSize)")
                self.callbackQueue.async {
                    completion(nil, FileTransferError.exceedsMaxSize)
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
                        completion(nil, FileTransferError.keyGenerationError)
                    }
                    return
                }
                outKeyIv = iv + key
                do {
                    let crypted = try OTRSignalEncryptionHelper.encryptData(data, key: key, iv: iv)
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
            
            if (self.uploadCancelled) {
                self.callbackQueue.async {
                    completion(nil, FileTransferError.userCanceled)
                }
                self.uploadCancelled = false
                return
            }
            
            self.httpFileUpload.requestSlot(fromService: service.jid, filename: filename, size: UInt(outData.count), contentType: contentType, completion: { (slot: XMPPSlot?, iq: XMPPIQ?, error: Error?) in
                guard let slot = slot else {
                    let outError = error ?? FileTransferError.serverError
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
                                        completion(nil, FileTransferError.urlFormatting)
                                    }
                                } else {
                                    completion(nil, FileTransferError.urlFormatting)
                                }
                            } else {
                                // The plaintext case
                                completion(slot.getURL, nil)
                            }
                        case .failure(let error):
                            if (self.uploadCancelled) {
                                self.uploadCancelled = false
                                completion(nil, FileTransferError.userCanceled)
                            } else {
                                completion(nil, error)
                            }
                            DDLogError("Upload error: \(error)")
                        }
                    }.uploadProgress(queue: self.internalQueue) { progress in
                        //DDLogVerbose("Upload progress \(progress.fractionCompleted)")
                        if let media = ChatMediaItemModel.getMediaItem(with: media.uniqueId) {
                            media.grdbRecord?.transferProgress = progress.fractionCompleted
                            media.save(completion: {
                                media.touchParentProgress()
                            })
                        }
                        
                        if (self.uploadCancelled) {
                            self.doCancelUpload(url: slot.putURL)
                        }
                }
            })
        }
    }
    
    private func doCancelUpload(url: URL) {
        self.internalQueue.async {
            self.sessionManager.session.getTasksWithCompletionHandler { (_, uploadTasks, _) in
                for task in uploadTasks where task.originalRequest?.url == url {
                    DDLogWarn("Stopping upload task: \(task)")
                    task.cancel()
                    break
                }
            }
        }
    }
    
    private var exporter: AVAssetExportSession? = nil
    private func compressVideo(_ url: URL, thread: ChatThreadModel, label: UILabel?, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        let filename = FileTransferManager.getFileName(url.path)
        let compressionName = filename + "_compressed"
        let newpath = url.path.replacingOccurrences(of: filename, with: compressionName)
        
        let sourceVideoUrl = FileTransferManager.getPathUrl(url.path)
        let sourceVideoAsset = self.getVideoAsset(sourceVideoUrl)
        let sourceVideoTrack = self.getTrack(sourceVideoAsset)
        let compressionUrl = FileTransferManager.getPathUrl(newpath)
            
        let timescale = sourceVideoAsset.duration.timescale
        let videoDuration = sourceVideoAsset.duration.seconds
        
        let cmStartTime = CMTimeMakeWithSeconds(0, preferredTimescale: timescale)
        let cmDurationTime = CMTimeMakeWithSeconds(videoDuration, preferredTimescale: timescale)
        let timeRange: CMTimeRange = CMTimeRangeMake(start: cmStartTime, duration: cmDurationTime)
            
        let exporter = AVAssetExportSession(asset: sourceVideoTrack!.asset!, presetName: AVAssetExportPresetMediumQuality)!
            
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = true
        
        let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
        exporter.videoComposition = videoComposition
        exporter.timeRange = timeRange
            
        FileTransferManager.deleteFile(compressionUrl.absoluteString)
            
        exporter.exportAsynchronously(completionHandler: {
            //just for logging, can remove later
            do {
                let resources = try url.resourceValues(forKeys:[.fileSizeKey])
                let initialSize = resources.fileSize!
                let compresources = try compressionUrl.resourceValues(forKeys:[.fileSizeKey])
                let compSize = compresources.fileSize!
                DDLogInfo("Size before \(initialSize) after \(compSize)")
            } catch {
                print("Error: \(error)")
            }
            
            if exporter.status == AVAssetExportSession.Status.completed {
                self.send(url: compressionUrl, thread: thread, type: .video, label: label, isPublic:isPublic, completion: completion)
                FileTransferManager.deleteFile(url.absoluteString)
            } else if exporter.status == AVAssetExportSession.Status.cancelled {
                self.callbackQueue.async {
                    completion(false, FileTransferError.userCanceled)
                }
                self.uploadCancelled = false
            } else {
                self.send(url: url, thread: thread, type: .video, label: label, isPublic:isPublic, completion: completion)
            }
            self.exporter = nil
        })
    }
    
    public func getVideoAsset(_ url:URL)->AVURLAsset {
        return AVURLAsset(url: url)
    }
        
    public func getTrack(_ asset: AVURLAsset)->AVAssetTrack? {
        var track : AVAssetTrack? = nil
        let group = DispatchGroup()
        group.enter()
        asset.loadValuesAsynchronously(forKeys: ["tracks"], completionHandler: {
            var error: NSError? = nil;
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            if (status == .loaded) {
                track = asset.tracks(withMediaType: AVMediaType.video).first
            }
            group.leave()
        })
        group.wait()
        return track
    }
    
    static let fileManager = FileManager.default
        
    static func stripFileExtension(_ fileName:String)->String {
        var components = fileName.components(separatedBy: ".")
        if components.count > 1 {
            components.removeLast()
            return components.joined(separator: ".")
        } else {
            return fileName
        }
    }
    static func getFileName(_ path: String)->String {
        return stripFileExtension((path as NSString).lastPathComponent)
    }
        
    static func getPathUrl(_ path: String)->URL {
        return URL(fileURLWithPath: excludeFileProtocol(path))
    }
        
    static func excludeFileProtocol(_ path: String)->String {
        return path.replacingOccurrences(of: "file://", with: "")
    }
    
    static func deleteFile(_ path: String) {
        let url = getPathUrl(path)
        if fileManager.fileExists(atPath: url.absoluteString) {
            try? fileManager.removeItem(at: url)
        }
    }
    
    @objc public func send(videoURL url: URL, thread: ChatThreadModel, label: UILabel?, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        internalQueue.async {
            self.compressVideo(url, thread: thread, label: label, isPublic:isPublic, completion: completion)
        }
    }
    
    @objc public func send(htmlURL url: URL, thread: ChatThreadModel, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        internalQueue.async {
            let mediaItem = ChatHTMLItem(filename: url.absoluteString, mimetype: nil, isIncoming: false)
            
            guard let message = self.newOutgoingMessage(to: thread, mediaItem: mediaItem) else {
                DDLogError("No message could be created for \(thread) \(mediaItem)")
                self.callbackQueue.async {
                    completion(false, nil)
                }
                return
            }
            
            if isPublic, message is ChatRoomMessageModel {
                message.messageSecurity = .plaintext
            }
            
            mediaItem.grdbRecord?.parentObjectKey = message.messageKey
            mediaItem.grdbRecord?.parentObjectCollection = message.messageCollection
            message.messageMediaItemKey = mediaItem.uniqueId
            message.mediaType = (ChatMediaType.htmlItem.rawValue) as NSNumber
            
            mediaItem.grdbRecord?.transferProgress = 1.0
            message.transferProgress = NSNumber(value: 1.0)
            message.messageText = url.absoluteString
            message.messageModified = Date()
            mediaItem.save(completion: {
                mediaItem.removeFromCache()
                /*mediaItem.setThumbnail(url)
                mediaItem.getMetadata(url, completion: { (metadata:LPLinkMetadata?, error:Error?) in
                    DispatchQueue.main.async { [weak self] in
                        guard let _ = self, let metadata = metadata else {
                            return
                        }
                    
                })*/
            })
            message.save(withThread: thread)
            //thread.saveThread()
            
            self.callbackQueue.async {
                completion(true, nil)
            }
            self.queueOutgoingMessage(message: message)
        }
    }
    
    public func sizeOfImageAt(url: URL) -> CGSize? {
        // with CGImageSource we avoid loading the whole image into memory
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, propertiesOptions) as? [CFString: Any] else {
            return nil
        }

        if let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            return CGSize(width: width, height: height)
        } else {
            return nil
        }
    }
    
    private enum MediaURLType {
        case audio
        case video
        case file
    }
    
    private func send(url: URL, thread: ChatThreadModel, type: MediaURLType, label: UILabel?, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        internalQueue.async {
            self.uploadCancelled = false
            do {
                let resources = try url.resourceValues(forKeys:[.fileSizeKey])
                let fileSize2 = resources.fileSize!
                if let service = self.servers.first, fileSize2 > service.maxSize {
                    self.callbackQueue.async {
                        completion(false, FileTransferError.exceedsMaxSize)
                    }
                    return
                }
            } catch {
                print("Error: \(error)")
            }
            
            var item: ChatMediaItemModel? = nil
            switch type {
            case .audio:
                item = ChatAudioItem(audioURL: url, isIncoming: false)
            case .video:
                item = ChatVideoItem(videoURL: url, isIncoming: false)
            case .file:
                item = ChatFileItem(fileURL: url, isIncoming: false)
            }
            guard let mediaItem = item else {
                DDLogError("No media item to share for URL: \(url)")
                self.callbackQueue.async {
                    completion(false, nil)
                }
                return
            }
            
            guard let message = self.newOutgoingMessage(to: thread, mediaItem: mediaItem) else {
                DDLogError("No message could be created for \(thread) \(mediaItem)")
                self.callbackQueue.async {
                    completion(false, nil)
                }
                return
            }
            
            if isPublic, message is ChatRoomMessageModel {
                message.messageSecurity = .plaintext
            }
            
            switch type {
            case .audio:
                message.mediaType = (ChatMediaType.audioItem.rawValue) as NSNumber
            case .video:
                message.mediaType = (ChatMediaType.videoItem.rawValue) as NSNumber
            case .file:
                message.mediaType = (ChatMediaType.fileItem.rawValue) as NSNumber
            }
            
            mediaItem.grdbRecord?.parentObjectKey = message.messageKey
            mediaItem.grdbRecord?.parentObjectCollection = message.messageCollection
            message.save(withThread: thread)
            mediaItem.save()
            
            if let newPath = OTRMediaFileManager.path(forChatMediaItem: mediaItem, buddyUniqueId: message.threadId) {
                OTRMediaFileManager.shared.copyData(fromFilePath: url.path, toEncryptedPath: newPath, completion: { (result, copyError: Error?) in
                    var prefetchedData: Data? = nil
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            if let size = attributes[FileAttributeKey.size] as? NSNumber, size.uint64Value < 1024 * 1024 * 1 {
                                prefetchedData = try Data(contentsOf: url)
                            }
                        } catch let error {
                            DDLogError("Error prefetching data: \(error)")
                        }
                        do {
                            try FileManager.default.removeItem(atPath: url.path)
                        } catch let error {
                            DDLogError("Error removing file: \(error)")
                        }
                    }
                    
                    mediaItem.save(completion: {
                        self.internalQueue.async {
                            if let vidItem = mediaItem as? ChatVideoItem, let vurl = vidItem.mediaServerURL(message.threadId) {
                                vidItem.setThumbnail(vurl)
                            } else {
                                message.touch()
                            }
                        }
                    })
                    
                    if let err = copyError as? NSError {
                        message.messageError = err
                        message.save()
                    }
                    
                    self.send(mediaItem: mediaItem, prefetchedData: prefetchedData, message: message, label: label, completion: completion)
                }, completionQueue: self.internalQueue)
            }
        }
    }
    
    @objc public func send(audioURL url: URL, thread: ChatThreadModel, label: UILabel?, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        internalQueue.async {
            self.send(url: url, thread: thread, type: .audio, label: label, isPublic:isPublic, completion: completion)
        }
    }
    
    @objc public func send(image: UIImage, thread: ChatThreadModel, jpeg:Bool, label: UILabel?, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        internalQueue.async {
            self.uploadCancelled = false
            guard let service = self.servers.first, service.maxSize > 0 else {
                DDLogError("No HTTP upload service available!")
                self.callbackQueue.async {
                    completion(false, nil)
                }
                return
            }
            
            let imageItem:ChatImageItem
            let imageSize = image.size
            var normalSize = imageSize
            if imageSize != .zero {
                normalSize = ChatMediaItem.normalizeWidth(width: imageSize.width, height: imageSize.height)
            }
            if (jpeg) {
                let filename = "\(UUID().uuidString).jpg"
                imageItem = ChatImageItem(filename: filename, size: normalSize, mimetype: "image/jpeg", isIncoming: false)
            } else {
                let filename = "\(UUID().uuidString).gif"
                imageItem = ChatImageItem(filename: filename, size: normalSize, mimetype: "image/gif", isIncoming: false)
            }
            if normalSize != .zero {
                imageItem.mediaSize = normalSize
            }
            
            guard let message = self.newOutgoingMessage(to: thread, mediaItem: imageItem) else {
                DDLogError("No message could be created")
                self.callbackQueue.async {
                    completion(false, nil)
                }
                return
            }
            
            if isPublic, message is ChatRoomMessageModel {
                message.messageSecurity = .plaintext
            }
            
            imageItem.grdbRecord?.parentObjectKey = message.messageKey
            imageItem.grdbRecord?.parentObjectCollection = message.messageCollection
            
            message.mediaType = (ChatMediaType.imageItem.rawValue) as NSNumber
            //message.save(withThread: thread)
            imageItem.save(completion: {
                self.internalQueue.async {
                    if !jpeg {
                        if let gifdata = GifHelper.getImageData(image) {
                            OTRMediaFileManager.shared.setData(gifdata, forChatItem: imageItem, buddyUniqueId: message.threadId, completion: { (bytesWritten: Int, error: Error?) in
                                //imageItem.touchParent()
                                if let error = error as? NSError {
                                    message.messageError = error
                                }
                                
                                //imageItem.setThumbnail(image, data: gifdata)
                                //Not setting thumbnail because it doesn't show up if do it here
                                
                                message.save(withThread: thread)
                                self.send(mediaItem: imageItem, prefetchedData: gifdata, message: message, label: label, completion: completion)
                                
                            }, completionQueue: self.internalQueue)
                        } else {
                            self.callbackQueue.async {
                                completion(false, nil)
                            }
                        }
                    } else {
                        guard let ourImageData = image.jpegData(dataSize: .unlimited, resize: UIImage.Quality.low, jpeg: UIImage.Quality.low, maxTries: 10) else {
                            DDLogError("Could not make JPEG out of image!")
                            self.callbackQueue.async {
                                completion(false, nil)
                            }
                            return
                        }
                        OTRMediaFileManager.shared.setData(ourImageData, forChatItem: imageItem, buddyUniqueId: message.threadId, completion: { (bytesWritten: Int, error: Error?) in
                            //imageItem.touchParent()
                            if let error = error { //sync?
                                message.messageError = error as NSError
                            }
                            
                            imageItem.setThumbnail(image, data: ourImageData)
                            message.save(withThread: thread)
                            
                            if let imageData = image.jpegData(dataSize: .maxBytes(service.maxSize), resize: UIImage.Quality.medium, jpeg: UIImage.Quality.medium, maxTries: 10) {
                                self.send(mediaItem: imageItem, prefetchedData: imageData, message: message, label: label, completion: completion)
                            } else {
                                DDLogError("Could not make JPEG out of image! Bad size")
                                message.messageError = FileTransferError.exceedsMaxSize as NSError
                                message.save()
                                self.callbackQueue.async {
                                    completion(false, nil)
                                }
                            }
                        }, completionQueue: self.internalQueue)
                    }
                }
            })
        }
    }
    
    public func send(fileURL url: URL, thread: ChatThreadModel, label: UILabel?, isPublic:Bool, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        internalQueue.async {
            self.send(url: url, thread: thread, type: .file, label: label, isPublic: isPublic, completion: completion)
        }
    }
    
    private func newOutgoingMessage(to thread: ChatThreadModel, mediaItem: ChatMediaItemModel) -> MessageProtocol? {
        if thread.isGroupThread() {
            if let room = ChatRoom.roomFromThread(thread.grdbRecord!) {
                let roomModel = ChatRoomModel(room: room)
                let message = roomModel.outgoingMessage(text: "")
                message.messageMediaItemKey = mediaItem.uniqueId
                if let account = thread.getChatAccount() {
                    message.senderId = account.uniqueId
                    message.senderDisplayName = account.displayName
                }
                return message
            }
        } else {
            if let bud = ChatBuddy.buddyFromThread(thread.grdbRecord!) {
                let buddy = ChatBuddyModel(buddy: bud)
                let message = OutgoingChatMessage()
                message.grdbRecord?.chatBuddyId = bud.id!
                let security: OTRMessageTransportSecurity = .OMEMO
                message.grdbRecord?.buddyUniqueId = buddy.uniqueId
                message.grdbRecord?.mediaItemUniqueId = mediaItem.uniqueId
                message.messageSecurity = security
                
                if let account = thread.getChatAccount() {
                    message.senderId = account.uniqueId
                    message.senderDisplayName = account.displayName
                }

                let gtimer = OTRSettingsManager.string(forOTRSettingKey: "globalTimer")

                if (buddy.expiresIn == nil && gtimer != nil && gtimer != "Off") {
                    message.grdbRecord?.expires = gtimer
                } else if (buddy.expiresIn != nil) {
                    message.grdbRecord?.expires = buddy.expiresIn
                }
                return message
            }
        }
 
        return nil
    }
    
    @objc public func sendAsync(mediaItem: ChatMediaItemModel, prefetchedData: Data?, message: MessageProtocol, label: UILabel?, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        self.internalQueue.async {
            self.send(mediaItem: mediaItem, prefetchedData: prefetchedData, message: message, label: label, completion: completion)
        }
    }
    
    // added progress, completion to ALL send functions
    @objc public func send(mediaItem: ChatMediaItemModel, prefetchedData: Data?, message: MessageProtocol, label: UILabel?, completion: @escaping (_ success: Bool, _ error: Error?) -> ()) {
        let shouldEncrypt = message.messageSecurity == .OMEMO//true
        
        //self.copy() as? Self
        
        // if not online, put this in a queue
        let owner = message.threadOwner()
        if let towner = owner, let account = ChatAccountModel.getChatAccount(towner.threadAccountIdentifier), !OTRProtocolManager.sharedInstance().isAccountIdConnected(account.uniqueId), let offlineMsg = message.copyMessage() {
            
            self.retryList.append(offlineMsg)
            self.callbackQueue.async {
                completion(false, nil)
            }
            return
        }
        
        if (uploadCancelled) {
            self.callbackQueue.async {
                completion(false, FileTransferError.userCanceled)
            }
            uploadCancelled = false
            return
        }
        self.callbackQueue.async {
            label?.text = "Uploading, tap to cancel..."
        }
        
        self.upload(mediaItem: mediaItem, shouldEncrypt: shouldEncrypt, prefetchedData: prefetchedData, completion: { (_url: URL?, error: Error?) in
            guard let url = _url else {
                if let error = error {
                    DDLogError("Error uploading: \(error)")
                    if error is Alamofire.AFError, let offlineMsg = message.copyMessage() {
                        self.retryList.append(offlineMsg)
                        self.callbackQueue.async {
                            completion(false, nil)
                        }
                        return
                    }
                }
                
                message.messageError = error as? NSError
                message.save()
                self.callbackQueue.async {
                    completion(false, error)
                }
                return
            }

            mediaItem.grdbRecord?.transferProgress = 1.0
            message.transferProgress = NSNumber(value: 1.0)
            message.messageText = url.absoluteString
            message.messageModified = Date()
            mediaItem.save(completion:  {
                mediaItem.removeFromCache()
            })
            
            if let towner = owner {
                message.save(withThread: towner)
            } else {
                message.save()
            }
            // mediaItem.touchParent() // doesn't make sense because message is being saved
            self.callbackQueue.async {
                completion(true, nil) // delegate to turn off HUD here
            }
            self.queueOutgoingMessage(message: message)
        })
    }
    
    @objc public func cancelUpload() {
        self.uploadCancelled = true
        exporter?.cancelExport()
    }
    
    private func queueOutgoingMessage(message: MessageProtocol) {
        message.save(completion: {
            self.internalQueue.async {
                if let thread = message.threadOwner(), let account = thread.getChatAccount(), let xmppMgr = OTRProtocolManager.shared.xmppManager(forChatAccount: account) {
                    xmppMgr.messageQueueHandler?.addMessage(message)
                }
            }
        })
        
        if let thread = message.threadOwner(){
            thread.lastMessageIdentifier = message.uid
            thread.threadDate = message.messageDate
            thread.saveThread()
            //ChatThread.touch(uniqueId: buddy.uniqueId)
        }
    }
    
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

    // MARK: - OTRServerCapabilitiesDelegate
    
    public func serverCapabilities(_ sender: OTRServerCapabilities, didDiscoverCapabilities capabilities: [XMPPJID : XMLElement]) {
        servers = serversFromCapabilities(capabilities: capabilities)
    }
}

// MARK: - Scanning and downloading incoming media
extension FileTransferManager {
    
    /** creates downloadmessages and then downloads if needed. parent message should already be saved! @warn Do not call from within an existing db transaction! */
    @objc public func createAndDownloadItemsIfNeeded(message: MessageProtocol, force: Bool) {
        if message.messageMediaItemKey != nil || message.messageText?.count == 0 || message.downloadableURLs.count == 0 {
            //DDLogVerbose("Download of message not needed \(message.messageKey)")
            return
        } else if let thread = message.threadOwner(), let account = thread.getChatAccount(), account.disableLinkFetching {
            if let firsturl = message.downloadableURLs.first?.absoluteString, !firsturl.hasPrefix("aesgcm") {
                return
            }
        } else if let firsturl = message.downloadableURLs.first?.absoluteString, !firsturl.hasPrefix("aesgcm"), message.messageText?.count != firsturl.count {
            // if it's text with a link. Only download for preview if its just a link
            return
        }

        downloadMedia(message)
    }
    
    /** Downloads media for a single downloadmessage */
    public func downloadMediaIfNeeded(_ downloadMessage: MessageProtocol) {
        // Bail out if we've already downloaded the media
        if downloadMessage.messageMediaItemKey != nil &&
            downloadMessage.messageError == nil {
            // DDLogWarn("Already downloaded media for this item")
            return
        }
        downloadMedia(downloadMessage)
    }
    
    public func retryDownloadMedia(_ downloadMessage:MessageProtocol) {
        downloadMedia(downloadMessage)
    }
    
    private func downloadMedia(_ downloadMessage: MessageProtocol) {
        guard let tempurl = downloadMessage.downloadableURL, let url = normalizeURL(tempurl) else {
            DDLogWarn("Attempted to download message but couldn't parse a URL \(downloadMessage)")
            return
        }
        
        self.sessionManager.session.getTasksWithCompletionHandler { (tasks, _, _) in
            // Bail out if we've already got a task for this
            for task in tasks where task.originalRequest?.url == url {
                DDLogWarn("Already have outstanding task: \(task)")
                return
            }
            self.sessionManager.request(url, method: .head)
                .validate()
                .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success:
                    DDLogInfo("HEAD response: \(String(describing: response.response?.allHeaderFields))")
                    if let headers = response.response?.allHeaderFields {
                        let contentType = headers["Content-Type"] as? String
                        let contentLengthStr = headers["Content-Length"] as? String
                        var contentLength:UInt = 0
                        if let length = contentLengthStr, let conlen = UInt(length) {
                            contentLength = conlen
                        }
                        self.continueDownloading(downloadMessage: downloadMessage, url: url, contentType: contentType, contentLength: contentLength)
                    }
                case .failure(let error):
                    // not sure why we need validation
                    if let headers = response.response?.allHeaderFields, let contentType = headers["Content-Type"] as? String, let contentLength = headers["Content-Length"] as? UInt {
                        if contentType.contains("text/html") {
                            self.continueDownloading(downloadMessage: downloadMessage, url: url, contentType: contentType, contentLength: contentLength)
                            return
                        }
                    } else {
                        DDLogError("HEAD error, but continuing: \(error)")
                        let contentType = "text/html;charset=utf-8" //this is a guess and could backfire
                        self.continueDownloading(downloadMessage: downloadMessage, url: url, contentType: contentType, contentLength: 0)
                        return
                    }
                        
                    self.setError(error, onMessage: downloadMessage)
                    DDLogError("HEAD error, but continuing: \(error)")
                }
            }
        }
    }
    
    func normalizeURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url}
        
        // Lowercase scheme and host
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        
        return components.url
    }
    
    // bad link, don't download
    @objc public func setOutgoingHtmlError(_ message: MessageProtocol) {
        if let outmessage = message.refetch() {
            outmessage.messageError = FileTransferError.automaticDownloadsDisabled as NSError
            outmessage.save()
        }
    }
    
    private func setError(_ error: Error, onMessage downloadMessage: MessageProtocol) {
        if let message = downloadMessage.refetch() {
            // If we have no media item, add one so we can retry
            if message.messageMediaItemKey == nil, let filename = message.downloadableURL?.absoluteString {
                if var media = ChatMediaItemModel.incomingItemWith(filename: filename, mimeType: nil)?.grdbRecord {
                    media.parentObjectKey = message.uid
                    media.parentObjectCollection = message.messageCollection
                    media.storeInGRDB()
                    message.messageMediaItemKey = media.uniqueId
                }
            }

            // If user canceled, keep that error
            if let error = (message.messageError as NSError?), error.isUserCanceledError {
                return
            }
                        
            message.messageError = error as NSError
            message.save()
        }
    }
    
    private func continueDownloading(downloadMessage: MessageProtocol, url: URL, contentType: String?, contentLength: UInt) {
        // Remove placeholder media item
        var mediaItem = ChatMediaItemModel.getMediaItem(for: downloadMessage)
        //mediaItem?.remove(completion: {})
            
        if mediaItem != nil {
            //do nothing, keep exiting just redownload
        } else if url.absoluteString.contains("abnb.me") || url.absoluteString.contains(".airbnb.") {
            mediaItem = ChatHTMLItem(filename: url.lastPathComponent, mimetype: contentType, isIncoming: true)
        } else if (url.lastPathComponent.hasSuffix(".null")) {
            let fullPathComponent = url.lastPathComponent
            let end = fullPathComponent.index(fullPathComponent.endIndex, offsetBy: -5)
            let range = fullPathComponent.startIndex..<end
            let newFilename = String(fullPathComponent[range])
            mediaItem = ChatMediaItemModel.incomingItemWith(filename: newFilename, mimeType: contentType)
        } else {
            mediaItem = ChatMediaItemModel.incomingItemWith(filename: url.lastPathComponent, mimeType: contentType)
        }
            // cherry picked update, why is this needed?
            // If the file is encrypted, the server might not know its type
            /*if url.aesGcmKey != nil && contentType == "application/octet-stream" {
                mediaItem = ChatMediaItemModel.incomingItem(withFilename: url.lastPathComponent, mimeType: nil)
            } else {
                mediaItem = ChatMediaItemModel.incomingItem(withFilename: url.lastPathComponent, mimeType: contentType)
            }*/
            
        if let mitem = mediaItem {
            if mitem is ChatAudioItem {
                downloadMessage.mediaType = (ChatMediaType.audioItem.rawValue) as NSNumber
            } else if mitem is ChatImageItem {
                downloadMessage.mediaType = (ChatMediaType.imageItem.rawValue) as NSNumber
            } else if mitem is ChatVideoItem {
                downloadMessage.mediaType = (ChatMediaType.videoItem.rawValue) as NSNumber
            } else if mitem is ChatFileItem {
                downloadMessage.mediaType = (ChatMediaType.fileItem.rawValue) as NSNumber
            } else if mitem is ChatHTMLItem {
                downloadMessage.mediaType = (ChatMediaType.htmlItem.rawValue) as NSNumber
                mediaItem?.grdbRecord?.filename = url.absoluteString
                self.finishHTML(downloadMessage: downloadMessage, mediaItem: mediaItem, url: url)
                return
            }
            
            mediaItem?.grdbRecord?.parentObjectKey = downloadMessage.uid
            mediaItem?.grdbRecord?.parentObjectCollection = downloadMessage.messageCollection
            mediaItem?.save {}
            downloadMessage.messageMediaItemKey = mediaItem?.uniqueId
        }
        
        downloadMessage.url = url.absoluteString
        downloadMessage.messageError = nil
        downloadMessage.messageModified = Date()
        downloadMessage.save()
        ChatThread.touch(uniqueId: downloadMessage.threadId)

        guard let media = mediaItem else {
            DDLogError("Could not unwrap media item")
            self.setError(FileTransferError.fileNotFound, onMessage: downloadMessage)
            return
        }
        DDLogVerbose("Downloading media item at URL: \(url)")
        self.sessionManager.request(url)
            .validate()
            .responseData(queue: self.internalQueue) { response in
                //self.finishDownload(downloadMessage: downloadMessage, mediaItem: media, inData: response.data, urlResponse: response.response, error: response.error)
                switch response.result {
                case .success:
                    DDLogVerbose("Download Successful")
                    self.internalQueue.async {
                        self.finishDownload(downloadMessage: downloadMessage, mediaItem: media, inData: response.data, urlResponse: response.response, error: response.error)
                    }
                case .failure(let error):
                    // //error.isResponseValidationError, error.isSessionTaskError
                    if media is ChatHTMLItem {
                        self.setError(FileTransferError.automaticDownloadsDisabled, onMessage: downloadMessage)
                        DDLogError("Don't download just pass link through \(error)")
                        return
                    }
                    self.setError(error, onMessage: downloadMessage)
                    DDLogError("Download Error \(error)")
                }
            }.downloadProgress(queue: self.internalQueue) { progress in
                //DDLogVerbose("Download progress \(progress.fractionCompleted)")
                let prog = progress.fractionCompleted
                let newModified = Date()
                if prog < 1.0, newModified > downloadMessage.messageModified.addingTimeInterval(0.3) {
                    downloadMessage.transferProgress = NSNumber(value: prog)
                    downloadMessage.messageModified = newModified
                    downloadMessage.save()
                }
            }
    }
    
    private func finishHTML(downloadMessage: MessageProtocol, mediaItem: ChatMediaItemModel?, url: URL) {
        guard let media = mediaItem else {
            DDLogError("Could not unwrap media item")
            //self.setError(FileTransferError.fileNotFound, onMessage: downloadMessage)
            return
        }
        
        media.grdbRecord?.parentObjectKey = downloadMessage.uid
        media.grdbRecord?.parentObjectCollection = downloadMessage.messageCollection
        media.grdbRecord?.transferProgress = 1.0
        media.save(completion:  {
            media.removeFromCache()
        })
        
        downloadMessage.messageMediaItemKey = media.uniqueId
        downloadMessage.url = url.absoluteString
        downloadMessage.messageError = nil
        downloadMessage.messageModified = Date()
        downloadMessage.transferProgress = NSNumber(value: 1.0)
        downloadMessage.save()
        
        var cthread:ChatThreadModel?
        if let thread = downloadMessage.threadOwner()  {
            thread.grdbRecord?.modified = Date()
            thread.saveThread()
            cthread = thread
        }
        
        DispatchQueue.main.async {
            if let htmlItem = media as? ChatHTMLItem {
                let messagesVC = OTRAppDelegate.appDelegate.chatViewController
                
                if UIApplication.shared.applicationState != .active || messagesVC.isViewLoaded == false || messagesVC.view.window == nil || (cthread != nil && cthread?.uniqueId != messagesVC.threadKey){
                    htmlItem.getMetadata(htmlItem.url!, completion: { (metadata:LPLinkMetadata?, error:Error?) in
                        DispatchQueue.main.async {
                            if UIApplication.shared.applicationState == .active && (messagesVC.isViewLoaded == false || messagesVC.view.window == nil || (cthread != nil && cthread?.uniqueId != messagesVC.threadKey)){
                                if let htmlImg = htmlItem.getThumbnailImage(htmlItem.url!, metadata: metadata) {
                                    
                                    if let data = htmlImg.jpegData(compressionQuality: 1.0), data.count > 10000 { //didn't really
                                        self.internalQueue.async {
                                            let thumbnailKey = "\(downloadMessage.uid)-thumb"
                                            htmlItem.storeInCache(htmlImg, thumbnailKey: thumbnailKey, messageId: downloadMessage.uid, buddyId: cthread?.uniqueId, found:false, completion: {_ in 
                                                if downloadMessage.messageCollection == ChatRoomMessageModel.collection() {
                                                    ChatRoomMessage.touch(downloadMessage.uid)
                                                } else {
                                                    ChatMessage.touch(downloadMessage.uid)
                                                }
                                            })
                                        }
                                    }
                                }
                            }
                        }
                    })
                } 
            }
            Application.shared.showLocalNotification(downloadMessage)
        }
    }
    
    private func finishDownload(downloadMessage: MessageProtocol, mediaItem: ChatMediaItemModel, inData: Data?, urlResponse: URLResponse?, error: Error?) {
        if let error = error {
            self.setError(error, onMessage: downloadMessage)
            DDLogError("Error downloading file \(error)")
            return
        }
        guard var data = inData, let response = urlResponse, let url = response.url else {
            let error = FileTransferError.fileNotFound
            self.setError(error, onMessage: downloadMessage)
            DDLogError("No data or response \(error)")
            return
        }
        //DDLogVerbose("Received response \(response)")
        let authTagSize = 16 // i'm not sure if this can be assumed, but how else would we know the size?
        var decryptedData:Data?
        if let (key, iv) = url.aesGcmKey, data.count > authTagSize {
            //DDLogVerbose("Received encrypted response, attempting decryption...")
            
            let cryptedData = data.subdata(in: 0..<data.count - authTagSize)
            let authTag = data.subdata(in: data.count - authTagSize..<data.count)
            //let cryptoData = CryptoData(data: cryptedData, authTag: authTag)
            do {
                decryptedData = try OTRSignalEncryptionHelper.decryptData(cryptedData, key: key, iv: iv, authTag: authTag)
                //data = try CryptoUtility.decryptAESGCMData(cryptoData, key: key, iv: iv)
            } catch let error {
                self.setError(error, onMessage: downloadMessage)
                DDLogError("Error decrypting data: \(error)")
                return
            }
            //DDLogVerbose("Decrpytion successful")
        } else if url.anchorData == nil, data.count > 0 {
            decryptedData = data
        }
        
        guard let decryptedData = decryptedData else {
            DDLogError("Error decrypting data")
            return
        }
        
        OTRMediaFileManager.sharedInstance().setData(decryptedData, forChatItem: mediaItem, buddyUniqueId: downloadMessage.threadId, completion: { (bytesWritten, error) in
            
            var updatedMediaItem = mediaItem
            let url = OTRMediaServer.sharedInstance().url(forChatMediaItem: mediaItem, buddyUniqueId: downloadMessage.threadId)
            if let url = url {
                if let audioItem = mediaItem as? ChatAudioItem {
                    audioItem.populateFromData(at: url)
                    updatedMediaItem = audioItem
                } else if let imgItem = mediaItem as? ChatImageItem {
                    if imgItem.isGifImage() == false {
                        if let image = UIImage(data: data) {
                            imgItem.mediaSize = ChatMediaItem.normalizeWidth(width: image.size.width, height: image.size.height)
                            updatedMediaItem = imgItem
                            imgItem.setThumbnail(image, data: data)
                        }
                    }
                } 
            }
            
            if downloadMessage is ChatMessageModel {
                if let reMessage = ChatMessageModel.getMessage(with: downloadMessage.uid) {
                    reMessage.finishProgress(with: updatedMediaItem, completion: {})
                }
            } else if let reMessage = ChatRoomMessageModel.getMessage(with: downloadMessage.uid) {
                reMessage.finishProgress(with: updatedMediaItem, completion: {})
            }
            
            if let error = error {
                self.internalQueue.async {
                    self.setError(error, onMessage: downloadMessage)
                    DDLogError("Error copying data: \(error)")
                    return
                }
            }
            
            DispatchQueue.main.async {
                Application.shared.showLocalNotification(downloadMessage)
            }
        }, completionQueue: self.internalQueue)
    }
    
    @objc public func cancelDownload(mediaItem: ChatMediaItemModel) {
        self.internalQueue.async {
            if let downloadMessage = mediaItem.parentMessage() {
                self.setError(FileTransferError.userCanceled, onMessage: downloadMessage)
                if let url = downloadMessage.downloadableURL {
                    self.sessionManager.session.getTasksWithCompletionHandler { (tasks, _, _) in
                        // Bail out if we've already got a task for this
                        for task in tasks where task.originalRequest?.url == url {
                            DDLogWarn("Stopping download task: \(task)")
                            task.cancel()
                            break
                        }
                    }
                }
            }
        }
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

@objc public extension NSString { // added objc
    @objc var isSingleURLOnly: Bool {
        return (self as String).isSingleURLOnly
    }
    
    @objc var urls: [URL] {
        return (self as String).urls
    }
}

public extension String {
    
    // check things like espn.com as links
    private var urlRanges: ([URL], [NSRange]) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return ([], [])
        }
        var urls: [URL] = []
        var ranges: [NSRange] = []
        
        let matches = detector.matches(in: self, options: NSRegularExpression.MatchingOptions(rawValue: 0), range: NSRange(location: 0, length: self.utf16.count))
        
        for match in matches where match.resultType == .link {
            if let url = match.url {
                if (!url.absoluteString.hasPrefix("mailto")) {
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

public extension FileTransferManager {
    /// Returns whether or not message should be displayed or hidden from collection. Single incoming URLs should be hidden, for example.
    @objc static func shouldDisplayMessage(_ message: MessageProtocol) -> Bool {
        // Always show media messages
        if message.messageMediaItemKey != nil {
            return true
        }
        // Always show downloads
        if message.url != nil {
            return true
        }
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
        /*if messageText.isSingleURLOnly,
           message.downloads().count > 0, message.isMessageIncomingOrDifferentDevice { // added incoming
            return false
        }*/

        return true
    }
}
