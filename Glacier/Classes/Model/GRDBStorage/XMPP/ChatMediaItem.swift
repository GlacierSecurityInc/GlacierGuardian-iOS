//
//  ChatMediaItem.swift
//  Glacier
//
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import AVFoundation
import MessageKit
import GRDB
import MobileCoreServices
import QuickLookThumbnailing

enum ChatMediaType: Int {
    case htmlItem = 600
    case imageItem = 601
    case videoItem = 602
    case audioItem = 603
    case fileItem = 604
}

@objc open class ChatMediaItemModel: GRDBModel {
    
    static private let mediaItemCache:NSCache<NSString, ChatMediaItemModel> = NSCache.init()
    static let mediaThreadCache:NSCache<NSString, GlacierThreadID> = NSCache.init()
    var grdbRecord:ChatMediaItem?
    //var parentObjectCollection = ChatMessageModel.collection()
    var curSize = UIDevice.current.userInterfaceIdiom == .pad ? CGSizeMake(315.0, 225.0) : CGSizeMake(210.0, 200.0)
    
    convenience init(media:ChatMediaItem) {
        self.init(uniqueId: media.uniqueId)
        self.grdbRecord = media
    }
    
    public override init(uniqueId: String) {
        super.init(uniqueId: uniqueId)
        self.grdbRecord = ChatMediaItem(uniqueId: self.uniqueId)
    }
    
    required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        super.init()
        
        var fname = filename
        if fname.count == 0 {
            fname = "file"
        }
        
        var grec = ChatMediaItem(uniqueId: self.uniqueId)
        grec.filename = fname
        grec.isIncoming = isIncoming
        grec.transferProgress = 0.0
 
        if mimetype == nil || mimetype?.count == 0 {
            grec.mimeType = Self.getMimeType(filename:filename)
        } else {
            let fileext = (filename as NSString).pathExtension
            let ext = Self.getExtensionForMimeType(mimeType: mimetype ?? "")
            if fileext != ext {
                //DDLogWarn(@"Given file extension does not match expected extension from mime type: %@ %@", filename.pathExtension, extension);
                if fileext.count == 0 && ext.count > 0 {
                    grec.filename = fname + "." + ext
                    DDLogInfo("Created new filename with best guess for file extension: \(fname)")
                }
            }
            grec.mimeType = mimetype
        }
        self.grdbRecord = grec
    }
    
    public convenience init(uniqueId: String, filename: String, mimetype: String?, isIncoming: Bool) {
        self.init(uniqueId: uniqueId)
        
        var fname = filename
        if fname.count == 0 {
            fname = "file"
        }
        
        self.grdbRecord?.filename = fname
        self.grdbRecord?.isIncoming = isIncoming
        self.grdbRecord?.transferProgress = 0.0
 
        if mimetype == nil || mimetype?.count == 0 {
            self.grdbRecord?.mimeType = Self.getMimeType(filename:filename)
        } else {
            let fileext = (filename as NSString).pathExtension
            let ext = Self.getExtensionForMimeType(mimeType: mimetype ?? "")
            if fileext != ext {
                //DDLogWarn(@"Given file extension does not match expected extension from mime type: %@ %@", filename.pathExtension, extension);
                if fileext.count == 0 && ext.count > 0 {
                    self.grdbRecord?.filename = fname + "." + ext
                    DDLogInfo("Created new filename with best guess for file extension: \(fname)")
                }
            }
            self.grdbRecord?.mimeType = mimetype
        }
    }
}

extension ChatMediaItemModel {
    
    @objc public static func getMimeType(filename: String) -> String {
        var mimetype = "nil"
        if let fileurl = URL(string: filename) {
            let type = UTType(tag: fileurl.pathExtension, tagClass: .filenameExtension, conformingTo: nil)
            mimetype = type?.preferredMIMEType ?? "nil"
        }
            
        return mimetype
    }
    
    @objc public static func getExtensionForMimeType(mimeType: String) -> String {
        if mimeType.count == 0 { return "" }
        var ext = ""
        
        guard
            let mimeUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimeType as CFString, nil)?.takeUnretainedValue()
        else { return ""}
            
        guard
            let extUTI = UTTypeCopyPreferredTagWithClass(mimeUTI, kUTTagClassFilenameExtension)
        else { return "" }
        ext = extUTI.takeUnretainedValue() as String
        
        return ext
    }
    
    /** Returns the appropriate subclass (ImageItem, etc) for incoming file */
    static func incomingItemWith(filename: String, mimeType: String?) -> ChatMediaItemModel? {
        let mimeTypeForFileName = Self.getMimeType(filename: filename)
        var mimetype = mimeType
        if mimeTypeForFileName != "nil" {
            mimetype = mimeTypeForFileName
        }
        
        guard let mimetype = mimetype else { return nil }
        let fileext = (filename as NSString).pathExtension
        
        var mediaClass:AnyClass?
    #if !TARGET_IS_NOTIFICATION
        if (mimetype.contains("audio") || fileext == "m4a") {
            mediaClass = ChatAudioItem.self
        } else if (mimetype.contains("image") || fileext == "GIF" || fileext == "gif") { //IOSM#61 add gif
            mediaClass = ChatImageItem.self
        } else if (mimetype.contains("video") || fileext == "MOV" || fileext == "mov") {
            mediaClass = ChatVideoItem.self
        } else if mimetype.contains("text/html") {
            mediaClass = ChatHTMLItem.self
        } else {
            mediaClass = ChatFileItem.self //mime type likely starts with application for PDF, doc, or text for plain text
        }
    #endif
        
        if mediaClass != nil {
            let factoryClass = mediaClass as! ChatMediaItemModel.Type
            return factoryClass.init(filename: filename, mimetype: mimetype, isIncoming: true)
        }
        return nil
    }

    
    public var mediaSize: CGSize? {
        get {
            if let msize = self.grdbRecord?.size {
                return NSCoder.cgSize(for: msize)
            }
            return nil
        }
        set {
            if let newsize = newValue {
                self.grdbRecord?.size = NSCoder.string(for: newsize)
            }
        }
    }

    func mimeType() -> String {
        if let mtype = self.grdbRecord?.mimeType {
            return mtype
        } else if let fname = self.grdbRecord?.filename {
            return Self.getMimeType(filename: fname)
        }
        return ""
    }
    
    func getMediaType() -> ChatMediaType {
        if let mtype = self.grdbRecord?.mediaType, let type = ChatMediaType(rawValue:mtype) {
            return type
        }
        
        return ChatMediaType.imageItem
    }
    
    @objc public func touchParentProgress() {
        if self.grdbRecord?.parentObjectCollection == ChatRoomMessageModel.collection() {
            if let key = self.grdbRecord?.parentObjectKey {
                DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                    do {
                        if var record = try ChatRoomMessage
                            .filter(Column("uniqueId") == key)
                            .fetchOne(transaction.database) {
                            record.transferProgress = self.grdbRecord?.transferProgress
                            record.modified = Date()
                            try record.update(transaction.database, columns: [Column("transferProgress"),Column("modified")])
                        }
                    } catch {
                        DDLogDebug("RoomMessage.touch with error: \(error)")
                    }
                })
            }
        } else {
            if let key = self.grdbRecord?.parentObjectKey {
                DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                    do {
                        if var record = try ChatMessage
                            .filter(Column("uniqueId") == key)
                            .fetchOne(transaction.database) {
                            record.transferProgress = self.grdbRecord?.transferProgress
                            record.modified = Date()
                            try record.update(transaction.database, columns: [Column("transferProgress"),Column("modified")])
                        }
                    } catch {
                        DDLogDebug("ChatMessage.touchParent with error: \(error)")
                    }
                })
            }
        }
    }
    
    @objc public func touchParent() {
        if self.grdbRecord?.parentObjectCollection == ChatRoomMessageModel.collection() {
            if let key = self.grdbRecord?.parentObjectKey {
                DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                    do {
                        if var record = try ChatRoomMessage
                            .filter(Column("uniqueId") == key)
                            .fetchOne(transaction.database) {
                            record.modified = Date()
                            try record.update(transaction.database, columns: [Column("modified")])
                        }
                    } catch {
                        DDLogDebug("RoomMessage.touch with error: \(error)")
                    }
                })
            }
        } else {
            if let key = self.grdbRecord?.parentObjectKey {
                DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                    do {
                        if var record = try ChatMessage
                            .filter(Column("uniqueId") == key)
                            .fetchOne(transaction.database) {
                            record.modified = Date()
                            try record.update(transaction.database, columns: [Column("modified")])
                        }
                    } catch {
                        DDLogDebug("ChatMessage.touchParent with error: \(error)")
                    }
                })
            }
        }
    }
    
    static public func touchParent(parentCollection:String, parentKey:String) {
        if parentCollection == ChatRoomMessageModel.collection() {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                do {
                    if var record = try ChatRoomMessage
                        .filter(Column("uniqueId") == parentKey)
                        .fetchOne(transaction.database) {
                        record.modified = Date()
                        try record.update(transaction.database, columns: [Column("modified")])
                    }
                } catch {
                    DDLogDebug("ChatMessage.touch with error: \(error)")
                }
            })
        } else {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                do {
                    if var record = try ChatMessage
                        .filter(Column("uniqueId") == parentKey)
                        .fetchOne(transaction.database) {
                        record.modified = Date()
                        try record.update(transaction.database, columns: [Column("modified")])
                    }
                } catch {
                    DDLogDebug("ChatMessage.touchParent with error: \(error)")
                }
            })
        }
    }
    
    public func parentMessage() -> MessageProtocol? {
        var parentMessage:MessageProtocol?
        guard let key = self.grdbRecord?.parentObjectKey else {return nil}
        if self.grdbRecord?.parentObjectCollection == ChatRoomMessageModel.collection() {
            //parentMessage = ChatRoomMessage.getMessage(with: key)
            
            do {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    if let codableParent = try ChatRoomMessage
                        .filter(Column("uniqueId") == key)
                        .fetchOne(transaction.database) { //this should be DownloadMessage
                        parentMessage = ChatRoomMessageModel(message: codableParent)
                    }
                })
            } catch {
                DDLogError("error: lastMessage \(error)")
            }
        } else {
            do {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    if let codableParent = try ChatMessage
                        .filter(Column("uniqueId") == key)
                        .fetchOne(transaction.database) { //this should be ChatDownloadMessage
                        parentMessage = ChatMessageModel(message: codableParent)
                    }
                })
            } catch {
                DDLogError("error: lastMessage \(error)")
            }
        }
        
        return parentMessage
    }
}

extension ChatMediaItemModel {
    public func save(completion: @escaping () -> Void) {
        self.grdbRecord?.storeInGRDB(completion: completion)
    }
    
    public func save() {
        self.grdbRecord?.storeInGRDB()
    }
    
    public func remove(completion: @escaping () -> Void) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            self.grdbRecord?.grdbRemove(transaction: transaction)
        }, completion: completion)
    }
    
    @objc public func getFilename() -> String? {
        return self.grdbRecord?.filename
    }

#if !TARGET_IS_EXTENSION
    func mediaServerURL(_ threadId:String) -> URL? {
        if let path = OTRMediaFileManager.path(forChatMediaItem: self, buddyUniqueId: threadId, withLeadingSlash:false), let surl = OTRMediaServer.sharedInstance().url(forPath: path) {
                return surl
        }
        
        return nil
    }
    
    func mediaServerURL() -> URL? {
        let message = self.parentMessage()
        guard let threadId = message?.threadId else {
            return nil
        }
        
        let threadCache = GlacierThreadID.init()
        threadCache.threadId = threadId
        Self.mediaThreadCache.setObject(threadCache, forKey: self.uniqueId as NSString)
        
        return self.mediaServerURL(threadId)
    }
    
    func setSize(size:CGSize) {
        self.curSize = size
    }
    
#endif
}

extension ChatMediaItemModel {
    
    @objc public func getMediaDisplayText() -> String {
        var item = "📁 \(FILE_MESSAGE_STRING())"
    #if !TARGET_IS_EXTENSION
        if self is ChatImageItem {
            item = self.getImageItemDisplayText()
        } else if self is ChatVideoItem {
            item = "🎥 \(VIDEO_MESSAGE_STRING())"
        } else if self is ChatAudioItem {
            item = "🔊 \(AUDIO_MESSAGE_STRING())"
        } else if self is ChatFileItem {
            item = "📁 \(FILE_MESSAGE_STRING())"
        } else {
            if let fname = self.getFilename(), let url = URL(string: fname) {
                item = "🔗 \(url.absoluteString)"
            }
        }
    #else
        if let filename = self.getFilename(), let url = URL(string: filename) {
            item = "🔗 \(url.absoluteString)"
        }
    #endif
        return item
    }

    #if !TARGET_IS_EXTENSION
    func getImageItemDisplayText() -> String {
        if self is ChatImageItem {
            let otrd = self.parentMessage() //downloadMessage()
            if let origtext = otrd?.messageOriginalText, origtext.hasPrefix("geo") {
                let mapIconChar: UniChar = 0xf3c5
                if let mapIcon = UnicodeScalar(mapIconChar) {
                    return "\(String(mapIcon)) Location received"
                }
                return "Location received"
            }
        }
        
        return "📷 \(PICTURE_MESSAGE_STRING())"
    }
    #endif
    
    public static func clearMediaCache() {
        Self.mediaItemCache.removeAllObjects()
        Self.mediaThreadCache.removeAllObjects()
    }
    
    public func removeFromCache() {
        let uidstr = self.uniqueId as NSString
        Self.mediaItemCache.removeObject(forKey: uidstr)
    }
    
    @objc public static func getMediaItem(with uniqueId:String) -> ChatMediaItemModel? {
        let uidstr = uniqueId as NSString
        if let mitem = Self.mediaItemCache.object(forKey: uidstr) {
            return mitem
        }
        
        var media:ChatMediaItemModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatMediaItem
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
#if !TARGET_IS_EXTENSION
                    let mtype = ChatMediaType(rawValue: record.mediaType)
                    switch mtype {
                    case .imageItem:
                        media = ChatImageItem(media: record)
                    case .htmlItem:
                        media = ChatHTMLItem(media: record)
                    case .audioItem:
                        media = ChatAudioItem(media: record)
                    case .videoItem:
                        media = ChatVideoItem(media: record)
                    case .fileItem:
                        media = ChatFileItem(media: record)
                    default:
                        media = ChatMediaItemModel(media: record)
                    }
#else
                    media = ChatMediaItemModel(media: record)
#endif
                }
            })
        } catch {
            DDLogDebug("getMediaItem error: \(error)")
        }
        
        if let media = media, media.grdbRecord?.transferProgress == 1.0 {
#if !TARGET_IS_EXTENSION
            if media is ChatAudioItem {
                if media.grdbRecord?.timeLength != nil {
                    Self.mediaItemCache.setObject(media, forKey: uidstr)
                }
            } else {
                Self.mediaItemCache.setObject(media, forKey: uidstr)
            }
#endif
        }
        
        return media
    }
    
    @objc public static func processUnfinishedDownloads(queue: DispatchQueue = .global(), completion: @escaping ([ChatMediaItemModel]) -> Void) {
        var mediaItems:[ChatMediaItemModel] = []
        DBManager.sharedDB().grdbStorage.asyncRead(block: { transaction in
            do {
                let codables = try ChatMediaItem
                    .filter(Column("transferProgress") < 1)
                    .filter(Column("isIncoming") == true)
                    .fetchAll(transaction.database)
                for codable in codables {
                    mediaItems.append(ChatMediaItemModel(media: codable))
                }
            } catch {
                DDLogDebug("getMediaItem error: \(error)")
            }
        }, completionQueue: queue, completion: {
            completion(mediaItems)
        })
    }
    
    public static func getMediaItem(for message:MessageProtocol) -> ChatMediaItemModel? {
        if let mediaKey = message.messageMediaItemKey {
            return ChatMediaItemModel.getMediaItem(with: mediaKey)
        }
        return nil
    }
    
    func generateThumbnailRepresentations() {
        // Set up the parameters of the request.
        guard let url = (self as? MediaItem)?.url else {
            return
        }
        let size: CGSize = CGSize(width: 60, height: 90)
        let scale = UIScreen.main.scale
        
        // Create the thumbnail request.
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: size,
                                                   scale: scale,
                                                   representationTypes: .all)
        
        // Retrieve the singleton instance of the thumbnail generator and generate the thumbnails.
        let generator = QLThumbnailGenerator.shared
        generator.generateRepresentations(for: request) { (thumbnail, type, error) in
            DispatchQueue.main.async {
                if thumbnail == nil || error != nil {
                    // Handle the error case gracefully.
                } else {
                    // Display the thumbnail that you created.
                }
            }
        }
    }
}

extension ChatMediaItemModel: NSDiscardableContent {
    public func beginContentAccess() -> Bool { true }
    public func endContentAccess() { }
    public func discardContentIfPossible() { }
    public func isContentDiscarded() -> Bool { false }
}

struct ChatMediaItem: GRDBRecord {
    var id: Int64?
    var uniqueId: String
    
    var parentObjectKey: String?
    var parentObjectCollection: String?
    var mimeType: String?
    var filename: String?
    var isIncoming = true
    var transferProgress: Double?
    var size: String?
    var gifsize: String?
    var imageUrl: String?
    var linkTitle: String?
    var timeLength: Double?
    var mediaType: Int

    public static var databaseTableName: String {
        "chatMediaItem"
    }
    
    public init(uniqueId: String) {
        self.uniqueId = uniqueId
        self.mediaType = -1
    }
}

extension ChatMediaItem {
    static func normalizeWidth(width:CGFloat, height:CGFloat) -> CGSize {
        var maxWidth = 280.0
        var maxHeight = 200.0
        
        if UIDevice.current.userInterfaceIdiom == UIUserInterfaceIdiom.pad {
            maxWidth = 315.0
            maxHeight = 225.0
        }
        
        if (width <= maxWidth && height <= maxHeight) {
            return CGSizeMake(width, height)
        }
        
        let aspectRatio = width / height
        
        if (aspectRatio <= 1) {
            //Taller then wider then use max height and resize width
            let newWidth = floorf(Float(maxHeight * aspectRatio))
            return CGSizeMake(CGFloat(newWidth), maxHeight)
        }
        else {
            //Wider than taller then use max width and resize height
            let newHeight = floorf(Float(maxWidth * 1/aspectRatio))
            return CGSizeMake(maxWidth, CGFloat(newHeight))
        }
    }
}

@objc public class GlacierThreadID: NSObject, NSDiscardableContent {
    var threadId: String = ""
    
    public func beginContentAccess() -> Bool { true }
    public func endContentAccess() { }
    public func discardContentIfPossible() { }
    public func isContentDiscarded() -> Bool { false }
}
