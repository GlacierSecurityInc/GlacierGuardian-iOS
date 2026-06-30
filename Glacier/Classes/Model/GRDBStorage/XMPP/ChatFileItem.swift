//
//  ChatFileItem.swift
//  Glacier
//
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import MessageKit
import Kingfisher

@objc open class ChatFileItem: ChatMediaItemModel {
    let imgSize = CGSize(width: 250.0, height: 70.0)
    
    public init(fileURL: URL, isIncoming: Bool) {
        super.init(filename: fileURL.lastPathComponent, mimetype: nil, isIncoming: isIncoming)
        self.mediaSize = imgSize
        self.grdbRecord?.mediaType = ChatMediaType.fileItem.rawValue
    }
    
    required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.mediaSize = imgSize
        self.grdbRecord?.mediaType = ChatMediaType.fileItem.rawValue
    }
    
    public override init(uniqueId: String) {
        super.init(uniqueId: uniqueId)
        self.grdbRecord = ChatMediaItem(uniqueId: self.uniqueId)
        self.mediaSize = imgSize
        self.grdbRecord?.mediaType = ChatMediaType.fileItem.rawValue
    }
    
    convenience init(media:ChatMediaItem) {
        self.init(uniqueId: media.uniqueId)
        self.grdbRecord = media
        self.mediaSize = imgSize
        self.grdbRecord?.mediaType = ChatMediaType.fileItem.rawValue
    }
}

extension ChatFileItem: MediaItem {
    public var url: URL? {
        if let threadCache = Self.mediaThreadCache.object(forKey: self.uniqueId as NSString) {
            return self.mediaServerURL(threadCache.threadId)
        }
        
        return self.mediaServerURL()
    }
    
    public var image: UIImage? {
//#if !TARGET_IS_EXTENSION
        guard let parentKey = self.grdbRecord?.parentObjectKey else { return nil }
        let cache = GlacierImageCache.shared()
        
        let thumbnailKey = "\(parentKey)-thumb"
        if let chatImg = cache.retrieveImageInMemoryCache(forKey: thumbnailKey) {
            return chatImg
        }
        
        return nil
        
        /*guard let fileUrl = self.url else {
            return nil
        }
        
        self.setThumbnail(fileUrl)
        
        return nil*/
//#endif
//        return nil
    }
    
    public var placeholderImage: UIImage {
        guard let preview = FilePreviewView.glacierViewFromNib() else {
            return UIImage()
        }
        
        //self.curSize = Self.normalizeWidth(width: 250.0, height: 70.0)
        preview.frame = CGRectMake(0, 0, 250.0, 70.0)
        
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: preview.bounds.size, format: fmt)
        let img = renderer.image { ctx in
            preview.drawHierarchy(in: preview.bounds, afterScreenUpdates: true)
        }
        return img
    }
    
    public var size: CGSize {
        return imgSize
    }
    
    func setThumbnail(_ url: URL) {
        guard let parentKey = self.grdbRecord?.parentObjectKey, let img = getThumbnailImage(url) else {return}
            
        DispatchQueue.global().async {
            let thumbnailKey = "\(parentKey)-thumb"
            
            let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                                     .memoryCacheExpiration(.days(14)),
                                                     .memoryCacheAccessExtendingExpiration(.cacheTime)]
            let options = KingfisherParsedOptionsInfo(optionsInfo)
            
            //self.mediaSize = img.size
            self.save()
            
            GlacierImageCache.shared().store(img, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in
                if self.grdbRecord?.parentObjectCollection == ChatRoomMessageModel.collection() {
                    ChatRoomMessage.touch(parentKey)
                } else {
                    ChatMessage.touch(parentKey)
                }
            })
        }
    }
    
    func getThumbnailImage(_ url: URL) -> UIImage? {
        //guard let parentKey = self.grdbRecord?.parentObjectKey else {return nil}
        
        guard let preview = FilePreviewView.glacierViewFromNib() else {
            return nil
        }
        
        //let thumbnailKey =  String(format: "%@-thumb", parentKey)
        preview.setFile(self.grdbRecord!.filename)
        self.curSize = ChatMediaItem.normalizeWidth(width: 250.0, height: 70.0)
        preview.frame = CGRectMake(0, 0, 250.0, 70.0)
        
        if self.grdbRecord?.isIncoming == true {
            preview.backgroundColor = UIColor.bubbleLightGray()
        } else {
            preview.backgroundColor = UIColor.bubbleBlue()
            preview.setOutgoing(true)
        }
        
        let renderer = UIGraphicsImageRenderer(size: preview.bounds.size)
        let img = renderer.image { ctx in
            preview.drawHierarchy(in: preview.bounds, afterScreenUpdates: true) 
        }
        
        return img
    }
}
