//
//  SMSChatMediaItem.swift
//  Glacier
//
//  Created by andyfriedman on 8/22/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import MessageKit
import GRDB

@objc open class SMSChatMediaItemModel: GRDBModel {
    var grdbRecord:SMSChatMediaItem?
    var parentObjectCollection = SMSChatMessageModel.collection()
    var curSize = UIDevice.current.userInterfaceIdiom == .pad ? CGSizeMake(315.0, 225.0) : CGSizeMake(210.0, 150.0)
    var smsImage: UIImage?
    
    convenience init(mediaItem:SMSChatMediaItem) {
        self.init(uniqueId: mediaItem.uniqueId)
        self.grdbRecord = mediaItem
    }
    
    @objc public func getUniqueId() -> String {
        return self.uniqueId
    }
    
    @objc public func getFilename() -> String? {
        return self.grdbRecord?.filename
    }
    
#if !TARGET_IS_EXTENSION
    func setSize(size:CGSize) {
        self.curSize = size
    }

    func shouldFetchMediaData() -> Bool {
        return GlacierImageCache.shared().isCached(forKey: self.uniqueId) == false //OTRImages.image(withIdentifier: self.uniqueId) == nil
    }
    
    func fetchMediaData() {
        if !self.shouldFetchMediaData() {
            return
        }
        
        var message:SMSChatMessageModel?
        var conversation:SMSChatConversationModel?
        
        if let msg = self.parentMessage() {
            message = msg
            conversation = msg.conversationOwner()
        }
        
        guard let msg = message, let conv = conversation else {
            DDLogError("Missing parent message or thread for sms media message!")
            return
        }
        
        DispatchQueue.global().async {
            do {
                let data = try OTRMediaFileManager.sharedInstance().smsData(forItem: self, smsUniqueId: conv.uniqueId)
                if self.handle(mediaData:data, message: msg) {
                    msg.save() //touch parent?
                } else {
                    DDLogError("Could not handle display for sms media item")
                }
            } catch let error {
                DDLogError("No data found for sms media item: \(error)")
            }
        }
    }

    func handle(mediaData:Data, message:SMSChatMessageModel) -> Bool {
        if mediaData.count == 0 {
            return false
        }
        
        if let image = UIImage(data: mediaData) {
            self.curSize = ChatMediaItem.normalizeWidth(width: image.size.width, height: image.size.height)
            GlacierImageCache.shared().store(image, forKey: self.uniqueId, options:GlacierImageCache.parsedOptions, toDisk: false)
            //OTRImages.setImage(image, forIdentifier: self.uniqueId)
            return true
        }
        
        return false
    }
#endif
}

extension SMSChatMediaItemModel: MediaItem {
    
    public var url: URL? {
#if !TARGET_IS_EXTENSION
        if let convId = self.grdbRecord?.parentThreadKey, let path = OTRMediaFileManager.path(forSmsMediaItem: self, smsUniqueId: convId, withLeadingSlash:false), let surl = OTRMediaServer.sharedInstance().url(forPath: path) {
            return surl
        }
#endif
        
        return nil
    }
    
    public var image: UIImage? {
#if !TARGET_IS_EXTENSION
        let thumbnailKey = "\(self.uniqueId)-thumb"
        if let smsImg = GlacierImageCache.shared().retrieveImageInMemoryCache(forKey: thumbnailKey) { //OTRImages.image(withIdentifier: thumbnailKey) {
            return smsImg
        }
        
        guard let imageUrl = self.url else {
            return nil
        }
                    
        let uid = self.uniqueId
        self.downloadImage(imageUrl, completion: { (img, url) in
            guard let img = img else {return }
            let mediaSize = ChatMediaItem.normalizeWidth(width: img.size.width, height: img.size.height)
            let resizedImage = img.scaleImageWith(newSize: mediaSize)
            GlacierImageCache.shared().store(resizedImage, forKey: thumbnailKey, options:GlacierImageCache.parsedOptions, toDisk: false)
            //OTRImages.setImage(resizedImage, forIdentifier: thumbnailKey)
            SMSChatMessage.touch(uid)
        })
#endif
        return nil
    }
    
    public var placeholderImage: UIImage {
        UIImage()
    }
    
    public var size: CGSize {
        let thumbnailKey = "\(self.uniqueId)-thumb"
        if let smsImg = GlacierImageCache.shared().retrieveImageInMemoryCache(forKey: thumbnailKey) {// OTRImages.image(withIdentifier: thumbnailKey) {
            return ChatMediaItem.normalizeWidth(width: smsImg.size.width, height: smsImg.size.height)
        }
        
        return curSize
    }
    
    func downloadImage(_ url: URL, completion: ((_ dimage: UIImage?, _ url: URL?) -> Void)?) {
        /*guard let url = urlString else {
            completion?(nil, urlString)
            return
        }*/
        URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let error = error {
                print("error in downloading image: \(error)")
                completion?(nil, url)
                return
            }
            /*guard let httpResponse = response as? HTTPURLResponse,(200...299).contains(httpResponse.statusCode) else {
                completion?(nil, urlString)
                return
            }*/
            if let data = data, let image = UIImage(data: data) {
                completion?(image, url)
                return
            }
            completion?(nil, url)
            return
        }.resume()
    }
}

#if !TARGET_IS_EXTENSION
extension SMSChatMediaItemModel {
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
    
    @objc public func mediaHash() -> UInt {
        if let fname = self.grdbRecord?.filename {
            return UInt(bitPattern: fname.hash)
        }
        return 0
    }
}
#endif

extension SMSChatMediaItemModel {
    
    public func parentMessage() -> SMSChatMessageModel? {
        var message:SMSChatMessageModel?
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let parentKey = self.grdbRecord?.parentObjectKey, let record = try SMSChatMessage
                    .filter(Column("uniqueId") == parentKey)
                    .fetchOne(transaction.database) {
                    message = SMSChatMessageModel(message: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return message
    }
    
    public func refetch() -> SMSChatMediaItemModel? {
        var mediaItem:SMSChatMediaItemModel?
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatMediaItem
                    .filter(Column("uniqueId") == self.uniqueId)
                    .fetchOne(transaction.database) {
                    mediaItem = SMSChatMediaItemModel(mediaItem: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return mediaItem
    }
    
    public static func mediaItem(for message:SMSChatMessageModel) -> SMSChatMediaItemModel? {
        var mediaItem:SMSChatMediaItemModel?
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let mediaId = message.grdbRecord?.mediaItemUniqueId, let record = try SMSChatMediaItem //mediaItemUniqueId
                    .filter(Column("uniqueId") == mediaId)
                    .fetchOne(transaction.database) {
                    mediaItem = SMSChatMediaItemModel(mediaItem: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return mediaItem
    }
    
    public static func mediaItem(for key:String) -> SMSChatMediaItemModel? {
        var mediaItem:SMSChatMediaItemModel?

        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try SMSChatMediaItem
                    .filter(Column("uniqueId") == key)
                    .fetchOne(transaction.database) {
                    mediaItem = SMSChatMediaItemModel(mediaItem: record)
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
            return nil
        }
        
        return mediaItem
    }
}

struct SMSChatMediaItem: GRDBRecord, TableRecord {
    var id: Int64?
    var uniqueId: String
    var parentObjectKey: String?
    var parentObjectCollection = SMSChatMessageModel.collection()
    var parentThreadKey: String?
    var transferProgress = 0.0
    var filename: String?
    var modified: Date?

    public static var databaseTableName: String {
        "SMSMediaItem"
    }
    
    public init(uniqueId:String, parentObjectKey:String?, parentThreadKey:String?, transferProgress:Double?, filename:String?, modified:Date?) {
        self.uniqueId = uniqueId
        self.parentObjectKey = parentObjectKey
        self.parentThreadKey = parentThreadKey
        if let progress = transferProgress {
            self.transferProgress = progress
        }
        self.filename = filename
        self.modified = modified ?? Date()
    }
    
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
    }
}
