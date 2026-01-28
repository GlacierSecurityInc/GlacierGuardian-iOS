//  Glacier
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.

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
            
            if chatImg.size.width > 0, chatImg.size.height > 0 {
                self.mediaSize = chatImg.size
                self.save {}
                return chatImg.size
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
            
            GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in
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
        
        let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                                 .memoryCacheExpiration(.days(14)),
                                                 .memoryCacheAccessExtendingExpiration(.cacheTime)]
        let options = KingfisherParsedOptionsInfo(optionsInfo)
        
        GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {result in
        })
    }
    
#if !TARGET_IS_EXTENSION
    func downloadImage(_ url: URL, filename: String?, completion: ((_ dimage: UIImage?, _ url: URL?, _ data: Data?) -> Void)?) {
        URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let error = error {
                print("error in downloading image: \(error)")
                completion?(nil, url, nil)
                return
            }
            guard let data = data else {
                completion?(nil, url, nil)
                return
            }
            
            //IOSM#61 gif...
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
            ctx.cgContext.fill(imageRect)
        }
        
        return image
    }
}
