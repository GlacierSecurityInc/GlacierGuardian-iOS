//
//  ChatHTMLItem.swift
//  Glacier
//
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import MessageKit
import LinkPresentation
import Kingfisher

@objc open class ChatHTMLItem: ChatMediaItemModel {
    static var htmlCache = NSCache<NSString, LPLinkMetadata>() //HTMLCache
    private static var metadataCache = NSCache<NSString, LPLinkMetadata>()
    private static var failedFetchTimestamps: [String: Date] = [:]
    private static var metadataInFlight: [String: [(LPLinkMetadata?, Error?) -> Void]] = [:]
    private static let metadataLock = DispatchQueue(label: "ChatHTMLItem.metadataLock")
    private static let metadataFailureCooldown: TimeInterval = 120
    static let contentPreviewWidth: CGFloat = 250
    static let contentPreviewHeight: CGFloat = 168
    
    //static let htmlQueue = DispatchQueue(label: "HTML Queue")
    private static var fetching = Set<String>()
    lazy private var provider = LPMetadataProvider()
    private var metadata:LPLinkMetadata?
    var linkView = LPLinkView()
    //let imgSize = CGSize(width: Self.contentPreviewWidth, height: Self.contentPreviewHeight)
    
    //let placeholderImage = UIImage()
    
    //self.grdbRecord?.mediaType = ChatMediaType.htmlItem.rawValue
    required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.curSize = CGSize(width: Self.contentPreviewWidth, height: Self.contentPreviewHeight)
        self.grdbRecord?.mediaType = ChatMediaType.htmlItem.rawValue
    }
    
    public override init(uniqueId: String) {
        super.init(uniqueId: uniqueId)
        self.grdbRecord = ChatMediaItem(uniqueId: self.uniqueId)
        self.curSize = CGSize(width: Self.contentPreviewWidth, height: Self.contentPreviewHeight)
        self.grdbRecord?.mediaType = ChatMediaType.htmlItem.rawValue
    }
    
    convenience init(media:ChatMediaItem) {
        self.init(uniqueId: media.uniqueId)
        self.grdbRecord = media
        self.grdbRecord?.mediaType = ChatMediaType.htmlItem.rawValue
    }
}

extension ChatHTMLItem: MediaItem {
    public var url: URL? {
        if let hstr = self.getFilename(), let hurl = URL(string: hstr.trimmingCharacters(in: .whitespaces)) {
            return hurl
        }
        return nil //self.mediaServerURL()
    }
    
    public var image: UIImage? {
//#if !TARGET_IS_EXTENSION
        guard let parentKey = self.grdbRecord?.parentObjectKey else { return nil }
        let cache = GlacierImageCache.shared()
        
        let thumbnailKey = "\(parentKey)-thumb"
        if let chatImg = cache.retrieveImageInMemoryCache(forKey: thumbnailKey) {
            //print("***** Image is in cache with size \(chatImg.size)")
            return chatImg
        }
        
        return nil
//#endif
//        return nil
    }
    
    public var placeholderImage: UIImage {
        guard let preview = FilePreviewView.glacierViewFromNib() else {
            return UIImage()
        }
        
        //let thumbnailKey =  String(format: "%@-thumb", parentKey)
        preview.setFile(self.grdbRecord!.filename)
        preview.configure(titleText: "", fileName: "", shouldShowIcon: false)
        
        self.curSize = ChatMediaItem.normalizeWidth(width: Self.contentPreviewWidth, height: Self.contentPreviewHeight)
        preview.frame = CGRectMake(0, 0, self.curSize.width, self.curSize.height)
        
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
        
        /*guard let filename = self.grdbRecord?.filename else { //, let preview = FilePreviewView.glacierViewFromNib() else {
            return UIImage()
        }
        
        let metadata = LPLinkMetadata()
        metadata.originalURL = URL(string: filename)
        metadata.url = metadata.originalURL
        metadata.title = " "
        //metadata.imageProvider = NSItemProvider.init(contentsOf: GlacierInfo.resourcesBundle.url(forResource: "Safari", withExtension: "png"))
        
        guard let hurl = metadata.originalURL else { return UIImage() }
            
        self.linkView = LPLinkView(url: hurl)
        self.linkView.metadata = metadata
        let intsize = self.linkView.intrinsicContentSize
        if intsize.width > 0, intsize.height > 0 {
            self.curSize = ChatMediaItem.normalizeWidth(width: intsize.width, height: intsize.height)
            self.linkView.frame = CGRectMake(0, 0, self.curSize.width, self.curSize.height)
        } else {
            self.curSize = ChatMediaItem.normalizeWidth(width: 250.0, height: 70.0)
            self.linkView.frame = CGRectMake(0, 0, 250.0, 70.0)
        }
                
        if self.grdbRecord?.isIncoming == true {
            self.linkView.backgroundColor = UIColor.jsq_messageBubbleLightGray()
            self.linkView.tintColor = UIColor.jsq_messageBubbleLightGray()
        } else {
            self.linkView.backgroundColor = UIColor.jsq_messageBubbleBlue()
            self.linkView.tintColor = UIColor.jsq_messageBubbleBlue()
            //self.linkView.setOutgoing(true)
        }
                
        let renderer = UIGraphicsImageRenderer(size: self.linkView.bounds.size)
        let img = renderer.image { ctx in
            self.linkView.drawHierarchy(in: self.linkView.bounds, afterScreenUpdates: true)
        }
                
        return img*/
        
        /*preview.frame = CGRectMake(0, 0, 250.0, 70.0)
        preview.setFile(filename)
        
        let renderer = UIGraphicsImageRenderer(size: preview.bounds.size)
        let img = renderer.image { ctx in
            preview.drawHierarchy(in: preview.bounds, afterScreenUpdates: true)
        }
        return img*/
    }
    
    public var size: CGSize {
        //print("***** Getting size with cursize \(self.curSize)")
        if let msize = self.mediaSize {
            return msize
        }
        
        guard let parentKey = self.grdbRecord?.parentObjectKey else { return self.curSize }
        let cache = GlacierImageCache.shared()
        let thumbnailKey = "\(parentKey)-thumb"
        
        if let chatImg = cache.retrieveImageInMemoryCache(forKey: thumbnailKey) {
            //print("***** html size for \(parentKey) is \(chatImg.size)")
            return chatImg.size
        }
        
        return self.curSize
    }
    
    /*func setThumbnail(_ url: URL) {
        guard let parentKey = self.grdbRecord?.parentObjectKey else {return}
    }*/
    
    func getThumbnailImage(_ url: URL, metadata:LPLinkMetadata?) -> UIImage? {
        
        self.linkView = LPLinkView(url: url)
        guard let metadata = metadata else {
            return nil
        }
            
        self.linkView.metadata = metadata
        self.curSize = ChatMediaItem.normalizeWidth(width: Self.contentPreviewWidth, height: Self.contentPreviewHeight)
        self.linkView.frame = CGRectMake(0, 0, self.curSize.width, self.curSize.height)
                
        if self.grdbRecord?.isIncoming == true {
            self.linkView.backgroundColor = UIColor.bubbleLightGray()
            self.linkView.tintColor = UIColor.bubbleLightGray()
        } else {
            self.linkView.backgroundColor = UIColor.bubbleBlue()
            self.linkView.tintColor = UIColor.bubbleBlue()
            //self.linkView.setOutgoing(true)
        }
                
        let renderer = UIGraphicsImageRenderer(size: self.linkView.bounds.size)
        let img = renderer.image { ctx in
            self.linkView.drawHierarchy(in: self.linkView.bounds, afterScreenUpdates: true)
        }
                
        return img
    }
    
    func getMetadata(_ url: URL, completion: @escaping (LPLinkMetadata?, Error?) -> Void) {
        guard LinkPreviewHelper.isPermittedLinkPreviewUrl(url) else {
            completion(nil, LinkPreviewError.nonPermittedUrl)
            return
        }

        let cacheKey = Self.normalizedCacheKey(for: url)

        if let meta = Self.metadataCache.object(forKey: cacheKey as NSString) {
            completion(meta, nil)
            return
        }

        if let meta = Self.htmlCache.object(forKey: self.uniqueId as NSString) {
            completion(meta, nil)
            return
        }

        var shouldStartFetch = false
        var cachedResult: (LPLinkMetadata?, Error?)?

        Self.metadataLock.sync {
            if let meta = Self.metadataCache.object(forKey: cacheKey as NSString) {
                cachedResult = (meta, nil)
                return
            }

            if let lastFailed = Self.failedFetchTimestamps[cacheKey], Date().timeIntervalSince(lastFailed) < Self.metadataFailureCooldown {
                cachedResult = (nil, LinkPreviewError.fetchFailure)
                return
            }

            if var callbacks = Self.metadataInFlight[cacheKey] {
                callbacks.append(completion)
                Self.metadataInFlight[cacheKey] = callbacks
            } else {
                Self.metadataInFlight[cacheKey] = [completion]
                shouldStartFetch = true
            }
        }

        if let cachedResult {
            completion(cachedResult.0, cachedResult.1)
            return
        }

        guard shouldStartFetch else { return }

        provider.glacier_startFetchingMetadata(for: url) { metadata, error in
            var callbacks = [((LPLinkMetadata?, Error?) -> Void)]()
            Self.metadataLock.sync {
                callbacks = Self.metadataInFlight[cacheKey] ?? []
                Self.metadataInFlight[cacheKey] = nil

                if let meta = metadata {
                    Self.metadataCache.setObject(meta, forKey: cacheKey as NSString)
                    Self.htmlCache.setObject(meta, forKey: self.uniqueId as NSString)
                    Self.failedFetchTimestamps[cacheKey] = nil
                } else {
                    Self.failedFetchTimestamps[cacheKey] = Date()
                }
            }

            for callback in callbacks {
                callback(metadata, error ?? (metadata == nil ? LinkPreviewError.fetchFailure : nil))
            }
        }
    }

    private static func normalizedCacheKey(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
    
    func storeInCache(_ htmlImg:UIImage, thumbnailKey:String, messageId:String, buddyId:String?, found:Bool, completion: ((CacheStoreResult) -> Void)? = nil) {
        let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                                     .memoryCacheExpiration(.days(14)),
                                                     .memoryCacheAccessExtendingExpiration(.cacheTime)]
        let options = KingfisherParsedOptionsInfo(optionsInfo)
        let hdata = htmlImg.jpegData(compressionQuality: 1.0)
        
        if found == false, let data = htmlImg.jpegData(compressionQuality: 0.5) {
            self.mediaSize = htmlImg.size
            self.grdbRecord?.transferProgress = 1.0
            self.save {}
            if let budid = buddyId {
                OTRMediaFileManager.sharedInstance().setData(data, forChatItem: self, buddyUniqueId: budid, completion: { (bytesWritten, error) in
                    //print("***** html stored in mediaServer with bytesWritten \(bytesWritten)")
                    Self.htmlCache.removeObject(forKey: self.uniqueId as NSString)
                }, completionQueue: nil)
            }
        }
        
        GlacierImageCache.shared().store(htmlImg, original: hdata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {result in
            if let completion = completion {
                completion(result)
            }
            /*if self.grdbRecord?.parentObjectCollection == ChatRoomMessageModel.collection() {
                ChatRoomMessage.touch(messageId)
            } else {
                ChatMessage.touch(messageId)
            }*/
        })
    }
}

extension ChatHTMLItem {
    
    // next 3 and commented above, and all HTMLCache references
    static func metadataWithIdentifier(_ identifier: String) -> HTMLCache?
    {
        if let hcache = self.htmlCache.object(forKey: identifier as NSString) {
            return nil//hcache
        } else {
            return nil
        }
    }

    static func removeHtmlItemWithIdentifier(_ identifier: String ) {
        self.htmlCache.removeObject(forKey: identifier as NSString)
    }

    static func setHtmlCacheItem(title: String?, url:URL?, identifier:String) {
        if identifier.isEmpty {
            return
        }
        
        if let title = title, let url = url {
            let cacheImage = HTMLCache.init()
            cacheImage.title = title
            cacheImage.url = url
            
            //self.htmlCache.setObject(cacheImage, forKey: identifier as NSString)
            
        } else {
            self.removeHtmlItemWithIdentifier(identifier)
        }
    }
}

extension LPLinkMetadata: NSDiscardableContent {
    public func beginContentAccess() -> Bool { true }
    public func endContentAccess() { }
    public func discardContentIfPossible() { }
    public func isContentDiscarded() -> Bool { false }
}
