//
//  ChatAudioItem.swift
//  Glacier
//
//  Created by andyfriedman on 9/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation
import MessageKit

@objc open class ChatAudioItem: ChatMediaItemModel {
    
    var timeLength: TimeInterval?
    public init(filename: String, timeLength: TimeInterval, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.audioItem.rawValue
        self.timeLength = timeLength
        let audiosize = CGSizeMake(150.0, 70.0)
        self.mediaSize = audiosize
        setSize(size: audiosize)
    }
    
    required public init(filename: String, mimetype: String?, isIncoming: Bool) {
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        let audiosize = CGSizeMake(150.0, 70.0)
        self.mediaSize = audiosize
        setSize(size: audiosize)
        self.grdbRecord?.mediaType = ChatMediaType.audioItem.rawValue
        /*if let audioURL = URL(string: filename) {
            let audioAsset = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
            var mimetype:String?
            if audioURL.pathExtension == "m4a" {
                mimetype = "audio/mpeg"
            }
            let length = CMTimeGetSeconds(audioAsset.duration)
            
            super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
            self.grdbRecord?.mediaType = ChatMediaType.audioItem.rawValue
            self.timeLength = length
            return
        }
        
        super.init(filename: filename, mimetype: mimetype, isIncoming: isIncoming)
        self.grdbRecord?.mediaType = ChatMediaType.audioItem.rawValue*/
    }
    
    public convenience init(audioURL: URL, isIncoming: Bool) {
        let audioAsset = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
        var mimetype:String?
        if audioURL.pathExtension == "m4a" {
            mimetype = "audio/mpeg"
        }
        let length = CMTimeGetSeconds(audioAsset.duration)
        self.init(filename: audioURL.lastPathComponent, timeLength: length, mimetype: mimetype, isIncoming: isIncoming)
    }
    
    public override init(uniqueId: String) {
        super.init(uniqueId: uniqueId)
        self.grdbRecord = ChatMediaItem(uniqueId: self.uniqueId)
        setSize(size: CGSizeMake(150.0, 70.0))
        self.grdbRecord?.mediaType = ChatMediaType.audioItem.rawValue
    }
    
    convenience init(media:ChatMediaItem) {
        self.init(uniqueId: media.uniqueId)
        self.grdbRecord = media
    }
    
    func populateFromData(at url: URL) {
        let audioAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
        self.timeLength = CMTimeGetSeconds(audioAsset.duration)
    }
}

extension ChatAudioItem: AudioItem {
    public var url: URL {
        return self.mediaServerURL() ?? OTRMediaServer.sharedInstance().url(forPath: getFilename())
    }
    
    /// The audio file duration in seconds.
    public var duration: Float {
        if let doubledur = self.timeLength {
            return Float(doubledur)
        }
        
        return 0
    }
    
    /// The size of the audio item.
    public var size: CGSize { 
        return self.curSize
    }
}
