//  Glacier
//  Created by Andy Friedman on 12/7/20.
//  Copyright © 2020 Glacier. All rights reserved.

import Kingfisher
import GRDB

@objc class GlacierImageCache: NSObject {
    
    public static let options:KingfisherOptionsInfo = [.cacheMemoryOnly,
        .memoryCacheExpiration(.days(14)), .memoryCacheAccessExtendingExpiration(.cacheTime)]
    public static let parsedOptions = KingfisherParsedOptionsInfo(options)
    private static let glacierCache = GlacierImageCache.setupImageCache()
    
    public class func shared() -> ImageCache {
        return glacierCache
    }
    
    private static func setupImageCache() -> ImageCache {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let costLimit = totalMemory / 4
        var memConfig = MemoryStorage.Config(totalCostLimit: (costLimit > Int.max) ? Int.max : Int(costLimit), cleanInterval: 3600)
        memConfig.expiration = .days(14)
        memConfig.keepWhenEnteringBackground = true
        let memoryStorage = MemoryStorage.Backend<KFCrossPlatformImage>(config: memConfig)
        
        let diskConfig = DiskStorage.Config(
            name: "Glacier",
            sizeLimit: 0,
            directory: nil
        )
        do {
            let diskStorage = try DiskStorage.Backend<Data>(config: diskConfig)
            return ImageCache.init(memoryStorage: memoryStorage, diskStorage: diskStorage)
        } catch {}
        
        return ImageCache.default
    }
    
    @objc public static func image(_ identifier:String) -> UIImage? {
        return Self.glacierCache.retrieveImageInMemoryCache(forKey: identifier)
    }

    @objc public static func removeImage(_ identifier:String) {
        Self.glacierCache.removeImage(forKey: identifier)
    }

    @objc public static func setImage(_ image:UIImage, identifier:String) {
        Self.glacierCache.store(image, forKey: identifier, options: Self.parsedOptions, toDisk: false)
    }
    
    @objc public static func setImage(_ image:UIImage, identifier:String, toDisk: Bool) {
        Self.glacierCache.store(image, forKey: identifier, options: Self.parsedOptions, toDisk: toDisk)
    }
    
    @objc public static func removeImagesForAllMessages(for accountId:String) {
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let chatRooms = try ChatRoom
                    .filter(Column("accountUniqueId") == accountId)
                    .fetchAll(transaction.database)
                
                for room in chatRooms {
                    let query: QueryInterfaceRequest<ChatRoomMessage> = ChatRoomMessage
                        .filter(Column("roomUniqueId") == room.uniqueId)
                    let chatMessages = try query.fetchAll(transaction.database)
                    for message in chatMessages {
                        let thumbnailKey = "\(message.uniqueId)-thumb"
                        Self.removeImage(thumbnailKey)
                    }
                }
            })
        } catch {
            DDLogError("Error removing images for all messages: \(error)")
        }
    }

}
