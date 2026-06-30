//
//  ChatVideoItem.swift
//  Glacier
//
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import MessageKit
import AVFoundation
import Kingfisher

@objc open class ChatVideoItem: ChatMediaItemModel {
    lazy var grayPlaceholder = UIImage.imageWithColor(color: UIColor.clear, size: curSize)
    
    public init(filename: String, size: CGSize, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.videoItem.rawValue
        self.curSize = size
    }
    
    required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.videoItem.rawValue
    }
    
    public init(videoURL: URL, isIncoming: Bool) {
        super.init(filename: videoURL.lastPathComponent, mimetype: nil, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.videoItem.rawValue
        /*let asset = AVURLAsset(url: videoURL)
        let videoTrack = asset.tracks(withMediaType: AVMediaType.video).first
        let videoSize = videoTrack?.naturalSize
        let transform = videoTrack?.preferredTransform
        
        if ((videoSize?.width == transform?.tx && videoSize?.height == transform?.ty) || (transform?.tx == 0 && transform?.ty == 0))
        {
            _width = videoSize.width
            _height = videoSize.height
        }
        else
        {
            _width = videoSize.height
            _height = videoSize.width
        }*/
    }
    
    public override init(uniqueId: String) {
        super.init(uniqueId: uniqueId)
        self.grdbRecord = ChatMediaItem(uniqueId: self.uniqueId)
        self.grdbRecord?.mediaType = ChatMediaType.videoItem.rawValue
    }
    
    convenience init(media:ChatMediaItem) {
        self.init(uniqueId: media.uniqueId)
        self.grdbRecord = media
        self.grdbRecord?.mediaType = ChatMediaType.videoItem.rawValue
    }
    
    /*required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        fatalError("init(filename:mimetype:isIncoming:) has not been implemented")
    }*/
}
    
extension ChatVideoItem: MediaItem {
    public var url: URL? {
        if let threadCache = Self.mediaThreadCache.object(forKey: self.uniqueId as NSString) {
            return self.mediaServerURL(threadCache.threadId)
        }
        return self.mediaServerURL()
    }
    
    public var image: UIImage? {
#if !TARGET_IS_EXTENSION
        guard let parentKey = self.grdbRecord?.parentObjectKey else { return nil }
        let cache = GlacierImageCache.shared()
        
        let thumbnailKey = "\(parentKey)-thumb"
        if let chatImg = cache.retrieveImageInMemoryCache(forKey: thumbnailKey) {
            return chatImg
        }
        
        guard let videoUrl = self.url else {
            return nil
        }
                    
        //let uid = self.uniqueId
        self.setThumbnail(videoUrl)
#endif
        return nil
    }
    
    public var placeholderImage: UIImage {
        grayPlaceholder ?? UIImage()
    }
    
    public var size: CGSize {
        if let msize = self.mediaSize {
            return msize
        }
        
        guard let parentKey = self.grdbRecord?.parentObjectKey else { return curSize }
        let thumbnailKey = "\(parentKey)-thumb"
        /*if let chatImg = GlacierImages.image(withIdentifier: thumbnailKey) {
            return chatImg.size
        }*/
        
        if let chatImg = GlacierImageCache.shared().retrieveImageInMemoryCache(forKey: thumbnailKey) {
            if chatImg.size.width > 0, chatImg.size.height > 0 {
                self.mediaSize = chatImg.size
                self.save {}
                return chatImg.size
            }
        }
        
        return curSize
    }
    
    func setThumbnail(_ url: URL) {
        guard let parentKey = self.grdbRecord?.parentObjectKey else {return }
        self.downloadVideo(url, completion: { (img, url) in
            guard let img = img else {return }
            let mediaSize = ChatMediaItem.normalizeWidth(width: img.size.width, height: img.size.height)
            //print("***** setThumbnail video \(self.uniqueId) normalized size \(mediaSize), but downloaded width \(img.size.width), height \(img.size.height)")
            
            let resizedImage = img.scaleImageWith(newSize: mediaSize)
            
            if mediaSize != self.mediaSize {
                self.mediaSize = mediaSize
                self.save{}
            }
            
            let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                .memoryCacheExpiration(.days(14)),
                .memoryCacheAccessExtendingExpiration(.cacheTime)]
            let options = KingfisherParsedOptionsInfo(optionsInfo)
            let thumbnailKey = "\(parentKey)-thumb"
            
            GlacierImageCache.shared().store(resizedImage, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in 
                self.removeFromCache()
                if self.grdbRecord?.parentObjectCollection == ChatRoomMessageModel.collection() {
                    ChatRoomMessage.touch(parentKey)
                } else {
                    ChatMessage.touch(parentKey)
                }
            })
        })
    }
    
//#if !TARGET_IS_EXTENSION
    func downloadVideo(_ url: URL, completion: ((_ dimage: UIImage?, _ url: URL?) -> Void)?) {
        AVAsset(url: url).generateThumbnail { (image) in
            DispatchQueue.global().async {
                guard let image = image else {
                    completion?(nil, url)
                    return
                }
                
                completion?(image, url)
                return
            }
        }
    }
//#endif
}

extension AVAsset {
    func generateThumbnail(completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.global().async {
            let imageGenerator = AVAssetImageGenerator(asset: self)
            let time = CMTime(seconds: 0.0, preferredTimescale: 600)
            let times = [NSValue(time: time)]
            imageGenerator.generateCGImagesAsynchronously(forTimes: times, completionHandler: { _, image, _, _, _ in
                if let image = image {
                    completion(UIImage(cgImage: image))
                } else {
                    completion(nil)
                }
            })
        }
    }
}
