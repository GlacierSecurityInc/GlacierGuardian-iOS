//
//  MessageProtocol.swift
//  Glacier
//
//  Created by andyfriedman on 9/5/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import Foundation

@objc public protocol DownloadMessageProtocol: AnyObject {
    
    /** Returns an unsaved array of downloadable URLs. */
    func downloads() -> [DownloadMessage]
    /** Checks if edge count > 0 */
    func hasExistingDownloads() -> Bool
}

@objc public protocol DownloadMessage: MessageProtocol, MessageChildProtocol {
    static func download(parentMessage: MessageProtocol, url: URL, uniqueId: String?) -> DownloadMessage
}

@objc public protocol MessageChildProtocol: AnyObject {
    var parentKey: String? { get set }
    var parentCollection: String? { get }
    
    func parentMessage() -> MessageProtocol?
    func touchParentMessage()
}

@objc public protocol MessageProtocol: DownloadMessageProtocol {
    //var uniqueId: String { get }
    var dbId: NSNumber? { get set }
    var uid: String { get }  //uniqueId
    var messageKey: String { get }
    var messageCollection: String { get }
    /** In reality this shouldn't be nil, but could be if something bad happens. */
    var threadId: String { get }
    var threadCollection: String { get }
    var isMessageIncoming: Bool { get }
    var isMessageIncomingOrDifferentDevice: Bool { get }
    var isSystemUpdate: Bool { get }//ALF IOSM-442
    var isMarkable: Bool { get }//ALF IOSM-443
    var messageMediaItemKey: String? { get set }
    var transferProgress: NSNumber? { get set }
    var mediaType: NSNumber? { get set }
    var url: String? { get set }//ALF IOSM#105
    var messageError: NSError? { get set }
    var messageSecurity: OTRMessageTransportSecurity { get set }
    var omemoDeviceKey: String? { get set }
    var messageSecurityInfo:OTRMessageEncryptionInfo { get }
    var messageModified: Date { get set }
    
    var senderId: String? { get set }
    var senderDisplayName: String? { get set }

    /** Only applies to incoming messages */
    var isMessageRead: Bool { get }
    var messageDate: Date { get set }
    var messageReadDate: Date? { get }
    var messageText: String? { get set }
    var messageOriginalText: String? { get set } //used with share location
    var messageExpires: String? { get set }
    /** This should be the same as XMPPMessage.elementId */
    var remoteMessageId: String? { get }
    /** Only applies to outgoing messages */
    var isMessageSent: Bool { get }
    /** Only applies to outgoing messages */
    var isMessageDelivered: Bool { get }

    /** Only applies to outgoing messages */ //ALF IOSM-443
    var isMessageDisplayed: Bool { get }

    /** XEP-0359: origin-id */
    var originId: String? { get }
    /** XEP-0359: stanza-id */
    var stanzaId: String? { get }

    /** This is a ChatRoom for a MUC message, and a ChatBuddy for direct message */
    func threadOwner() -> ChatThreadModel?
    /** This is always a ChatBuddyModel associated with the message */
    func xmppBuddy() -> ChatBuddyModel?
    func save()
    //func saveWithThread:(nonnull id<ThreadOwner>)thread; //used for share
    func save(completion: @escaping () -> Void)
    func save(withThread thread:ChatThreadModel?)
    func touch()
    func finishProgress(with mediaItem:ChatMediaItemModel, completion: @escaping () -> Void)
    func refetch() -> MessageProtocol?
    func copyMessage() -> MessageProtocol?

    /**
     This creates a duplicate message. The only properties that are copied over are
     - text
     - error
     - mediaItemUniqueId
     - buddyUnieqId
     - messageSecurityInfo
     This new object will have a new unique id and message id
     */
    func duplicateMessage() -> MessageProtocol
}

public extension MessageProtocol {
    
    var downloadableURLs: [URL] {
        return self.messageText?.downloadableURLs ?? []
    }
    
    var downloadableURL: URL? {
        guard var downloadableURL = downloadableURLs.first else { return nil }
        if downloadableURL.isAesGcm, var components = URLComponents(url: downloadableURL, resolvingAgainstBaseURL: true) {
            components.scheme = URLScheme.https.rawValue
            if let rawURL = components.url {
                downloadableURL = rawURL
            }
        }
        return downloadableURL
    }
}
