//
//  ChatImageItem.swift
//  Glacier
//
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import MessageKit
import Kingfisher

@objc open class ChatImageItem: ChatMediaItemModel {
    fileprivate var retrieving = false
    lazy var grayPlaceholder = UIImage.imageWithColor(color: UIColor.lightGray, size: curSize)
    
    public init(filename: String, size: CGSize, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.imageItem.rawValue
        self.curSize = size
    }
    
    public override init(uniqueId: String) {
        super.init(uniqueId: uniqueId)
        self.grdbRecord = ChatMediaItem(uniqueId: self.uniqueId)
        self.grdbRecord?.mediaType = ChatMediaType.imageItem.rawValue
    }
    
    required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.imageItem.rawValue
    }
    
    /*public convenience init() {
        self.init(uniqueId: UUID().uuidString)
    }*/
}

extension ChatImageItem {
    func isGifImage() -> Bool {
        if let fname = (self.grdbRecord?.filename) as? NSString {
            if fname.pathExtension.lowercased() == "gif" {
                return true
            }
        }
        return false
    }
}

extension ChatImageItem: MediaItem {
    public var url: URL? {
        if let threadCache = Self.mediaThreadCache.object(forKey: self.uniqueId as NSString) {
            return self.mediaServerURL(threadCache.threadId)
        }
        
        return self.mediaServerURL()
    }
    
    public var image: UIImage? {
//#if !TARGET_IS_EXTENSION
        guard let parentKey = self.grdbRecord?.parentObjectKey else {
            return nil
        }
        let cache = GlacierImageCache.shared()
        
        let thumbnailKey = "\(parentKey)-thumb"
        if let chatImg = cache.retrieveImageInMemoryCache(forKey: thumbnailKey) {
            return chatImg
        }
        
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
        //#if !TARGET_IS_EXTENSION
        if let chatImg = GlacierImageCache.shared().retrieveImageInMemoryCache(forKey: thumbnailKey) {
            //return Self.normalizeWidth(width: chatImg.size.width, height: chatImg.size.height)
            //print("***** image exists \(self.getFilename()) for Key \(thumbnailKey) with size width \(chatImg.size.width), height \(chatImg.size.height)")
            
            if chatImg.size.width > 0, chatImg.size.height > 0 {
                self.mediaSize = chatImg.size
                self.save {}
                return chatImg.size//CGSizeMake(chatImg.size.width, chatImg.size.height)
            }
        }
        //#endif
        
        return curSize
    }
    
    func setThumbnail(_ url: URL) {
        guard let parentKey = self.grdbRecord?.parentObjectKey, let imageUrl = self.url else {return }
        
        self.downloadImage(imageUrl, filename: self.grdbRecord!.filename ?? "", completion: { (img, url, data) in
            guard let img = img else {return }
            var resizedImage = img
            var idata = data
            if self.isGifImage() == false {
                let mediaSize = Self.normalizeWidth(width: img.size.width, height: img.size.height)
                resizedImage = img.scaleImageWith(newSize: mediaSize)
                idata = resizedImage.jpegData(dataSize: .unlimited)
                if mediaSize != self.mediaSize {
                    self.mediaSize = mediaSize
                    self.save{}
                }
            }
            
            let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                .memoryCacheExpiration(.days(14)),
                .memoryCacheAccessExtendingExpiration(.cacheTime)]
            let options = KingfisherParsedOptionsInfo(optionsInfo)
            let thumbnailKey = "\(parentKey)-thumb"
            
            //let myuidstr = self.uniqueId
            //let parentColl = self.grdbRecord?.parentObjectCollection
            GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in
                //self.removeFromCache()
                /*if parentColl == ChatRoomMessageModel.collection() {
                    ChatRoomMessage.touch(parentKey)
                } else {
                    ChatMessage.touch(parentKey)
                }*/
            })
        })
    }
    
    func setThumbnail(_ img: UIImage, data:Data?) {
        guard let parentKey = self.grdbRecord?.parentObjectKey else {return }
        let thumbnailKey = "\(parentKey)-thumb"
        
        var resizedImage = img
        var idata = data
        if self.isGifImage() == false {
            let mediaSize = Self.normalizeWidth(width: img.size.width, height: img.size.height)
            resizedImage = img.scaleImageWith(newSize: mediaSize)
            idata = resizedImage.jpegData(dataSize: .unlimited)
            if mediaSize != self.mediaSize {
                self.mediaSize = mediaSize
                self.save{}
            }
        }
        //self.grdbRecord?.transferProgress = 1.0
        //self.save{}
        
        let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                                 .memoryCacheExpiration(.days(14)),
                                                 .memoryCacheAccessExtendingExpiration(.cacheTime)]
        let options = KingfisherParsedOptionsInfo(optionsInfo)
        
        //let myuidstr = self.uniqueId// as NSString
        //let mycoll = self.grdbRecord?.parentObjectCollection
        GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {result in
            //let dt = Date.timeIntervalSinceReferenceDate
            //print("***** \(dt) done setting image thumbnail for \(parentKey)")
            /*self.removeFromCache()
            if mycoll == ChatRoomMessageModel.collection() {
                ChatRoomMessage.touch(parentKey)
            } else {
                ChatMessage.touch(parentKey)
            }*/
        })
    }
    
#if !TARGET_IS_EXTENSION
    //func downloadImage(_ url: URL, completion: ((_ dimage: UIImage?, _ url: URL?) -> Void)?) {
    func downloadImage(_ url: URL, filename: String?, completion: ((_ dimage: UIImage?, _ url: URL?, _ data: Data?) -> Void)?) {
        /*guard let url = urlString else {
            completion?(nil, urlString)
            return
        }*/
        URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let error = error {
                print("error in downloading image: \(error)")
                completion?(nil, url, nil)
                return
            }
            /*guard let httpResponse = response as? HTTPURLResponse,(200...299).contains(httpResponse.statusCode) else {
                completion?(nil, urlString)
                return
            }*/
            guard let data = data else {
                completion?(nil, url, nil)
                return
            }
            
            // gif...
            var image:UIImage?
            if (filename as? NSString)?.pathExtension.lowercased() == "gif" {
                image = GifHelper.getGifImage(data)
            } else {
                image = UIImage(data: data)
            }
            
            completion?(image, url, data)
            return
        }.resume()
    }
#endif
}

extension ChatImageItem {
    static func normalizeWidth(width:CGFloat, height:CGFloat) -> CGSize {
        var maxWidth: Double = 450
        var maxHeight: Double = 321
        
        if UIDevice.current.userInterfaceIdiom == UIUserInterfaceIdiom.pad {
            maxWidth = 506
            maxHeight = 361
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

extension UIImage {
    class func imageWithColor(color: UIColor, size: CGSize=CGSize(width: 1, height: 1)) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let imageRect = CGRect(origin: .zero, size: size)

        let image = renderer.image { ctx in
            color.setFill()
            //UIRectFill(CGRect(origin: CGPoint.zero, size: size))
            ctx.cgContext.fill(imageRect)
        }
        
        /*UIGraphicsBeginImageContextWithOptions(size, false, 0)
        color.setFill()
        UIRectFill(CGRect(origin: CGPoint.zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()*/
        return image
    }
}
