//  Glacier
//  Created by andyfriedman on 9/4/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation
import CocoaLumberjack
import XMPPFramework
import DifferenceKit
import MessageKit
import GRDB

public enum ChatRoomMessageState:Int {
    case received = 0 // incoming messages only
    case needsSending = 1
    case pendingSent = 2
    case sent = 3
    case delivered = 4
    
    public func incoming() -> Bool {
        switch self {
        case .received: return true
        default: return false
        }
    }
}

enum ChatRoomMessageType: Int {
    case download = 800
    case regular = 801
}

@objc open class ChatRoomMessageModel: GRDBModel {
    
    var grdbRecord:ChatRoomMessage?
    static var disableHTMLDownload = false
    
    public convenience override init() {
        let chatRoomMsg = ChatRoomMessage()
        self.init(message:chatRoomMsg)
    }
    
    /** This is the "real" JID of the non-anonymous buddy if it can be directly inferred from the message*/
    @objc open var realJID: XMPPJID? {
        get {
            guard let jid = grdbRecord?.realJid else { return nil }
            return XMPPJID(string: jid)
        }
        set {
            grdbRecord?.realJid = newValue?.full
        }
    }
    
    open override var hash: Int {
        get {
            return super.hash
        }
    }
    
    @objc open var memberUpdate: Bool {
        get {
            return self.grdbRecord?.memberUpdate ?? false
        }
        set {
            self.grdbRecord?.memberUpdate = newValue
        }
    }
    
    
    convenience init(message:ChatRoomMessage) {
        self.init(uniqueId: message.uniqueId)
        self.grdbRecord = message
    }
    
    convenience init(message: XMPPMessage, delayed: Date?, room: ChatRoomModel) {
        self.init()
        var grec = ChatRoomMessage(uniqueId: self.uniqueId)
        grec.xmppId = message.elementID
        grec.messageText = message.body
        
        if let date = delayed {
            grec.messageDate = date
        } else if let date = message.delayedDeliveryDate {
            grec.messageDate = date
        }
        grec.senderJid = message.from?.full
        grec.receiverJid = message.to?.full
        grec.roomJid = room.roomJID?.bare
        // compare with lowercase-only because sometimes
        // we get both lowercase and uppercase nicknames?
        if room.ourJID?.full.lowercased() == message.from?.full.lowercased() {
            grec.state = ChatRoomMessageState.sent.rawValue
        } else {
            grec.state = ChatRoomMessageState.received.rawValue
        }
        grec.roomUniqueId = room.uniqueId
        
        
        if let x = message.element(forName: "x", xmlns: XMPPMUCUserNamespace),
            let item = x.element(forName: "item"),
            let jidString = item.attribute(forName: "jid")?.stringValue,
            let jid = XMPPJID(string: jidString) {
            realJID = jid
        } else if let addresses = message.element(forName: "addresses", xmlns: "http:
            let address = addresses.element(forName: "address"),
            let jidString = address.attribute(forName: "jid")?.stringValue,
            let type = address.attribute(forName: "type")?.stringValue,
            let jid = XMPPJID(string: jidString) {
            if (type == "ofrom") {
                realJID = jid
            }
        }
        // first try to scoop out buddy from realJID
        let accountId = room.threadAccountIdentifier
        if let realJID = realJID {
            if let buddy = ChatBuddyModel.fetchBuddy(jid: realJID, accountUniqueId: accountId)  {
                grec.buddyUniqueId = buddy.uniqueId
                let bmodel = ChatBuddyModel(buddy: buddy)
                grec.msgSenderId = buddy.uniqueId
                grec.msgSenderDisplayName = bmodel.displayName
            }
        }
        // if that fails, try to get an existing occupant
        if grdbRecord?.buddyUniqueId == nil,
            let senderJID = message.from,
            let roomJID = room.roomJID,
            let occupant = ChatRoomOccupantModel.occupant(jid: senderJID, realJID: realJID, roomJID: roomJID, accountId: accountId, createIfNeeded: false) {
            grec.buddyUniqueId = occupant.buddyUniqueId
            
            if let budid = occupant.buddyUniqueId {
                grec.msgSenderId = budid
            }
            if let roomname = occupant.roomName {
                grec.msgSenderDisplayName = roomname
            }
        }
        
        grec.read = false
        self.grdbRecord = grec
    }
    
    @objc public var xmppId: String? {
        get {
            return self.grdbRecord?.xmppId
        }
    }
}

extension ChatRoomMessageModel:MessageProtocol {
    
    public func copyMessage() -> MessageProtocol? {
        if let rec = self.grdbRecord {
            return ChatRoomMessageModel(message: rec)
        }
        return nil
    }
    
    public func duplicateMessage() -> MessageProtocol {
        let newMessage = ChatRoomMessageModel()
        newMessage.grdbRecord?.messageText = self.grdbRecord?.messageText
        newMessage.grdbRecord?.originalText = self.grdbRecord?.originalText
        newMessage.grdbRecord?.expires = self.grdbRecord?.expires
        newMessage.grdbRecord?.error = self.grdbRecord?.error
        newMessage.grdbRecord?.mediaItemId = self.grdbRecord?.mediaItemId
        newMessage.grdbRecord?.roomUniqueId = self.grdbRecord?.roomUniqueId
        newMessage.grdbRecord?.roomJid = self.grdbRecord?.roomJid
        newMessage.grdbRecord?.senderJid = self.grdbRecord?.senderJid
        newMessage.grdbRecord?.messageSecurity = self.grdbRecord?.messageSecurity
        newMessage.grdbRecord?.state = ChatRoomMessageState.needsSending.rawValue
        newMessage.grdbRecord?.xmppId = UUID().uuidString
        newMessage.grdbRecord?.originId = newMessage.grdbRecord?.xmppId
        return newMessage
    }
    
    public func refetch() -> MessageProtocol? {
        self.refetchRoomMessage()
    }
    
    public var dbId: NSNumber? {
        get {
            return NSNumber(value: (self.grdbRecord?.id)!)
        }
        set {
            self.grdbRecord?.id = newValue?.int64Value
        }
    }
    
    public var uid: String {
        return self.uniqueId
    }
    
    public var url: String? {
        get {
            return self.grdbRecord?.url
        }
        set {
            self.grdbRecord?.url = newValue
        }
    }
    
    public var messageModified: Date {
        get {
            return self.grdbRecord?.modified ?? Date.distantPast
        }
        set {
            self.grdbRecord?.modified = newValue
        }
    }
    
    public var messageDate: Date {
        get {
            return self.grdbRecord?.messageDate ?? Date.distantPast
        }
        set {
            self.grdbRecord?.messageDate = newValue
        }
    }
    
    public var messageReadDate: Date? {
        return self.grdbRecord?.messageReadDate
    }
    
    public var messageText: String? {
        get {
            return self.grdbRecord?.messageText
        }
        set {
            self.grdbRecord?.messageText = newValue
        }
    }
    
    public var originId: String? {
        return self.grdbRecord?.originId
    }
    
    public var stanzaId: String? {
        return self.grdbRecord?.stanzaId
    }
    
    public var isMessageSent: Bool {
        return grdbRecord?.state == ChatRoomMessageState.pendingSent.rawValue
        || grdbRecord?.state == ChatRoomMessageState.sent.rawValue
        || grdbRecord?.state == ChatRoomMessageState.delivered.rawValue
    }
    
    public var isMessageDelivered: Bool {
        if let ddate = self.grdbRecord?.deliveredDate {
            return ddate > NSDate.distantPast
        }
        return false
    }
    
    public var isMessageDisplayed: Bool {
        if let displayed = self.grdbRecord?.isDisplayed {
            return displayed
        }
        return false
        //return false //change this when we figure out how
    }
    
    public var messageError: NSError? {
        get {
            if let err = self.grdbRecord?.error {
                return NSError(domain: err.errDomain, code: err.errCode, userInfo: [NSLocalizedDescriptionKey : err.errDescription ?? ""])
            }
            return nil
        }
        set(messageError) {
            if let err = messageError  {
                let nsError = err as NSError
                let gerr = GlacierError.init(domain: nsError.domain, code: nsError.code, description: nsError.description)
                self.grdbRecord?.error = gerr
            } else {
                self.grdbRecord?.error = nil
            }
        }
    }

    //MARK: MessageProtocol
    public var senderId: String? {
        get {
            return self.grdbRecord?.msgSenderId
        }
        set {
            self.grdbRecord?.msgSenderId = newValue ?? ""
        }
    }
    
    public var senderDisplayName: String? {
        get {
            return self.grdbRecord?.msgSenderDisplayName
        }
        set {
            self.grdbRecord?.msgSenderDisplayName = newValue ?? ""
        }
    }
    
    public var messageOriginalText: String? {
        get {
            return self.grdbRecord?.originalText
        }
        set {
            self.grdbRecord?.originalText = newValue
        }
    }
    
    public var messageExpires: String? {
        get {
            return self.grdbRecord?.expires
        }
        set {
            self.grdbRecord?.expires = newValue
        }
    }
    
    public var isMessageRead: Bool {
        return self.grdbRecord?.read ?? false
    }
    
    public var isSystemUpdate: Bool {
        return self.grdbRecord?.systemUpdate ?? false
    }
    
    public var isMarkable: Bool {
        return self.grdbRecord?.markable ?? false
    }
    
    public var messageKey: String {
        return self.uniqueId
    }
    
    public var messageCollection: String {
        return ChatRoomMessageModel.collection()
    }
    
    public var threadId: String {
        if let threadId = self.grdbRecord?.roomUniqueId {
            return threadId
        } else {
            DDLogError("RoomMessage is orphaned and not attached to a room! \(self.uniqueId)")
            // Returning empty string may prevent a crash, but is not ideal...
            return ""
        }
    }
    
    public var threadCollection: String {
        return ChatRoomModel.collection()
    }
    
    public var isMessageIncoming: Bool {
        return self.grdbRecord?.state == ChatRoomMessageState.received.rawValue
    }
    
    public var isMessageIncomingOrDifferentDevice: Bool {
        if (self.isMessageIncoming) {
            return true
        } else if (self.grdbRecord?.receiverJid != nil && self.realJID?.full != nil && self.grdbRecord?.receiverJid != self.realJID?.full) {
            return true
        }
        
        return false
    }
    
    public var messageMediaItemKey: String? {
        get {
            return self.grdbRecord?.mediaItemId
        }
        set(messageMediaItemKey) {
            self.grdbRecord?.mediaItemId = messageMediaItemKey
        }
    }
    
    public var transferProgress: NSNumber? {
        get {
            return NSNumber(value: self.grdbRecord!.transferProgress ?? 0)
        }
        set {
            self.grdbRecord?.transferProgress = newValue?.doubleValue
        }
    }
    
    public var mediaType: NSNumber? {
        get {
            return NSNumber(value: self.grdbRecord!.mediaType)
        }
        set {
            self.grdbRecord?.mediaType = newValue?.intValue ?? -1
        }
    }
    
    @objc public var senderJID: String? {
        get {
            return self.grdbRecord?.senderJid
        }
        set {
            self.grdbRecord?.senderJid = newValue
        }
    }
    
    @objc public var roomJID: String? {
        get {
            return self.grdbRecord?.roomJid
        }
        set {
            self.grdbRecord?.roomJid = newValue
        }
    }
    
    public var messageSecurity: OTRMessageTransportSecurity {
        get {
            if let msgsec = self.grdbRecord?.messageSecurity, let transsec = OTRMessageTransportSecurity(rawValue: UInt(msgsec)) {
                return transsec
            }
            return .plaintext
        }
        set {
            self.grdbRecord?.messageSecurity = Int(newValue.rawValue)
        }
    }
    
    public var omemoDeviceKey: String? {
        get {
            return self.grdbRecord?.omemoDeviceKey
        }
        set {
            self.grdbRecord?.omemoDeviceKey = newValue
        }
    }
    
    public var messageSecurityInfo: OTRMessageEncryptionInfo {
        return OTRMessageEncryptionInfo(messageSecurity: self.messageSecurity)
    }
    
    public var remoteMessageId: String? {
        return self.grdbRecord?.xmppId
    }
    
    public func threadOwner() -> ChatThreadModel? {
        var threadModel:ChatThreadModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let thread = try self.grdbRecord!.chatThread.fetchOne(transaction.database) {
                    threadModel = ChatThreadModel(thread: thread)
                }
            })
        } catch {
            DDLogDebug("ChatRoomMessageModel.threadOwner with error: \(error)")
        }
        
        return threadModel
    }
    
    public func xmppBuddy() -> ChatBuddyModel? {
        if let buddyId = self.grdbRecord?.buddyUniqueId {
            return ChatBuddyModel.getBuddy(uniqueId: buddyId)
        }
        return nil
    }
    
    public func addDisplayedJid(_ jid:String) {
        if jid.count == 0 {
            return
        }
        
        if let dj = self.grdbRecord?.displayedJids?.components(separatedBy: ", ") {
            var set = Set(dj)
            set.insert(jid)
            self.displayedJids = set
        } else {
            self.grdbRecord?.displayedJids = jid
        }
    }
    
    public var displayedJids: Set<String>? {
        get {
            if let dj = self.grdbRecord?.displayedJids?.components(separatedBy: ", ") {
                return Set(dj)
            }
            return nil
        }
        set {
            self.grdbRecord?.displayedJids = newValue?.joined(separator: ", ")
        }
    }
    
    @objc public func save() {
        guard self.messageText != nil else { return }
        self.grdbRecord?.storeInGRDB()
    }
    
    public func save(withThread thread:ChatThreadModel?) {
        self.save(completion: {
            if let trec = thread?.grdbRecord {
                ChatThread.update(with: trec, message: self)
            }
        })
    }
    
    @objc public func save(completion completionBlock: @escaping ()->Void ) {
        self.grdbRecord?.storeInGRDB(completion: completionBlock)
    }
    
    @objc public func touch() {
        self.touchRoomMessage()
    }
    
    public func finishProgress(with mediaItem:ChatMediaItemModel, completion: @escaping () -> Void) {
        if var grdbmsg = self.grdbRecord {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                let nowdate = Date()
                do {
                    grdbmsg.modified = nowdate
                    grdbmsg.transferProgress = 1.0
                    grdbmsg.error = nil
                    try grdbmsg.update(transaction.database, columns: [Column("modified"), Column("transferProgress"), Column("error")])
                } catch {
                    DDLogDebug("ChatRoomMessage.finishProgress with error: \(error)")
                }
                
                if var mediaRec = mediaItem.grdbRecord {
                    do {
                        if mediaRec.id == nil {
                            if let mrec = try ChatMediaItem
                                .filter(Column("uniqueId") == mediaRec.uniqueId)
                                .fetchOne(transaction.database) {
                                mediaRec = mrec
                            }
                        }
                        mediaRec.transferProgress = 1.0
                        try mediaRec.update(transaction.database, columns: [Column("transferProgress")])
                    } catch {
                        DDLogDebug("ChatRoomMessage.finishProgress for mediaRec with error: \(error)")
                    }
                }
                
                do {
                    if var thread = try grdbmsg.chatThread.fetchOne(transaction.database) {
                        thread.modified = nowdate
                        thread.save()
                    } else {
                        print("***** Houston we have a problem")
                    }
                } catch {
                    DDLogDebug("ChatRoomMessageModel.finishProgress threadOwner with error: \(error)")
                }
            }, completion: completion)
        }
    }
}


public class RoomDownloadMessage: ChatRoomMessageModel, DownloadMessage {
    public var parentKey: String?
    public var parentCollection: String?
    @objc private var downloadURL: URL?
    
    public static func download(parentMessage: MessageProtocol, url: URL, uniqueId: String?) -> DownloadMessage {
        
        let download:RoomDownloadMessage
        if let uid = uniqueId {
            download = RoomDownloadMessage(uniqueId: uid)
        } else {
            download = RoomDownloadMessage()
        }
        
        if let parent = parentMessage as? ChatRoomMessageModel {
            download.grdbRecord?.buddyUniqueId = parent.grdbRecord?.buddyUniqueId
        }
        download.downloadURL = url
        download.parentKey = parentMessage.messageKey
        download.parentCollection = parentMessage.messageCollection
        download.grdbRecord?.messageText = url.absoluteString
        download.grdbRecord?.originalText = parentMessage.messageOriginalText
        download.grdbRecord?.expires = parentMessage.messageExpires
        download.grdbRecord?.messageDate = parentMessage.messageDate
        download.grdbRecord?.roomUniqueId = parentMessage.threadId
        if let groupMessage = parentMessage as? ChatRoomMessageModel {
            download.grdbRecord?.senderJid = groupMessage.grdbRecord?.senderJid
            download.grdbRecord?.roomJid = groupMessage.grdbRecord?.roomJid
        }
        return download
    }
    
    public func parentMessage() -> MessageProtocol? {
        if let parentKey = self.parentKey {
            return ChatRoomMessageModel.getMessage(with: parentKey)
        }
        return nil
    }
    
    public func touchParentMessage() {
        if let parentMsg = parentMessage() {
            parentMsg.touch()
        }
    }
}

extension ChatRoomMessageModel: DownloadMessageProtocol {
    
    public func downloads() -> [DownloadMessage] {
        
        var downloads: [DownloadMessage] = []
#if !TARGET_IS_EXTENSION
        for url in self.downloadableURLs {
            let download = RoomDownloadMessage.download(parentMessage: self, url: url, uniqueId: nil)
            downloads.append(download)
        }
#endif
        return downloads
    }
    
    public func hasExistingDownloads() -> Bool {
        guard self.isMessageIncomingOrDifferentDevice else {
            return false
        }
        
        return self.url != nil
        
    }
}

public extension ChatRoomMessageModel {
    
    @objc static func setHTMLDownload(_ allowed:Bool) {
        disableHTMLDownload = !allowed
    }
    
    func room() -> ChatRoomModel? {
        guard let uid = self.grdbRecord?.roomUniqueId else {
            return nil
        }
        return ChatRoomModel.getXMPPRoom(uniqueId: uid)
    }
    
    func room(_ transaction:GRDBReadTransaction) throws -> ChatRoomModel? {
        guard let uid = self.grdbRecord?.roomUniqueId else {
            return nil
        }
        
        return try ChatRoomModel.getXMPPRoom(uniqueId: uid, transaction: transaction)
    }
    
    /// Getting all buddies for a room message to faciliate OMEMO group encryption
    func allBuddyKeysForOutgoingMessage(_ transaction:GRDBWriteTransaction?) -> [String] {
        guard let roomId = self.grdbRecord?.roomUniqueId else {
            return []
        }
        
        var buddyKeys:[String] = []
        if let transaction = transaction {
            buddyKeys = ChatRoomOccupantModel.allXMPPRoomOccupants(for: roomId, transaction: transaction).compactMap { $0.buddyUniqueId }
        } else {
            buddyKeys = ChatRoomOccupantModel.allXMPPRoomOccupants(for: roomId).compactMap { $0.buddyUniqueId }
        }
        
        return buddyKeys
    }
}

#if !TARGET_IS_EXTENSION
// MARK: Delivery receipts
public extension ChatRoomMessageModel {
    /// Marks our sent messages as delivered when we receive a matching receipt
    @objc static func handleDeliveryReceiptResponse(message: XMPPMessage) {
        guard message.isGroupChatMessage,
            message.hasReceiptResponse,
            !message.isErrorMessage,
            let messageId = message.receiptResponseID else {
            return
        }
        
        ChatRoomMessageModel.setDelivered(elementId: messageId, originId: message.originId, stanzaId: nil)
    }
    
    /// Sends a response receipt when receiving a delivery receipt request
    @objc static func handleDeliveryReceiptRequest(message: XMPPMessage, xmppStream:XMPPStream) {
        guard message.hasReceiptRequest,
            !message.hasReceiptResponse,
        let response = message.generateReceiptResponse else {
            return
        }
        // Don't send receipts for messages that you've sent
        if message.mucUserJID == xmppStream.myJID?.bareJID {
            return
        }
        
        xmppStream.send(response)
    }

}

public extension XMPPRoom {
    internal func sendRoomMessage(_ message: ChatRoomMessage) {
        let elementId = message.xmppId ?? message.uniqueId
        let body = XMLElement(name: "body", stringValue: message.messageText)
        let xmppMessage = XMPPMessage(messageType: nil, to: nil, elementID: elementId, child: body)
        xmppMessage.addReceiptRequest()
        let originId = message.originId ?? message.xmppId ?? message.uniqueId
        xmppMessage.addOriginId(originId)
        send(xmppMessage)
    }
}
#endif

public extension XMPPMessage {
    /// Gets the non-anonymous user JID from MUC message
    var mucUserJID: XMPPJID? {
        let x = element(forName: "x", xmlns: "http:
        let item = x?.element(forName: "item")
        guard let jidString = item?.attributeStringValue(forName: "jid") else {
            return nil
        }
        return XMPPJID(string: jidString)
    }
}

extension ChatRoomMessageModel {
    
    @objc public static func getUnreadMessages() -> [ChatRoomMessageModel]{
        var roommsgs:[ChatRoomMessageModel] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                let records = try ChatRoomMessage
                    .filter(Column("read") == false)
                    .fetchAll(transaction.database)
                for rec in records {
                    roommsgs.append(ChatRoomMessageModel(message: rec))
                }
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return roommsgs
    }
    
    @objc public static func markAllUnreadMessages(for threadId:String, completion: @escaping (_ updatedMessages: [ChatRoomMessageModel]) -> ()) {
        var markable:[ChatRoomMessageModel] = []
        var messages:[ChatRoomMessage] = []
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                let now = Date()
                let req = ChatRoomMessage
                    .filter(Column("roomUniqueId") == threadId)
                    .filter(Column("read") == false)
                try req.updateAll(transaction.database, [Column("read").set(to: true), Column("messageReadDate").set(to: now), Column("modified").set(to: now)])
                messages = try req.fetchAll(transaction.database)
            } catch {
                DDLogDebug("error: \(error)")
            }
        }, completionQueue: DispatchQueue.global(), completion: {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                let nowdate = Date()
                
                do {
                    if var rrecord = try ChatRoom
                    .filter(Column("uniqueId") == threadId)
                    .fetchOne(transaction.database) {
                        rrecord.modified = nowdate
                        try rrecord.update(transaction.database, columns: [Column("modified")])
                    }
                } catch {
                    DDLogDebug("ChatRoom.touch with error: \(error)")
                }
                
                do {
                    if var xrecord = try ChatThread
                    .filter(Column("uniqueId") == threadId)
                    .fetchOne(transaction.database) {
                        xrecord.modified = nowdate
                        try xrecord.update(transaction.database, columns: [Column("modified")])
                    }
                } catch {
                    DDLogDebug("ChatThread.touch with error: \(error)")
                }
            })
            
            for codable in messages {
                if codable.markable {
                    markable.append(ChatRoomMessageModel(message: codable))
                }
            }
            completion(markable)
        })
    }
    
    public func buddy() -> ChatBuddyModel? {
        guard let uid = self.grdbRecord?.buddyUniqueId else {
            return nil
        }
        return ChatBuddyModel.getBuddy(uniqueId: uid)
    }
    
    @objc public func touchRoomMessage() {
        if var roommsg = self.grdbRecord {
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                let nowdate = Date()
                do {
                    roommsg.modified = nowdate
                    try roommsg.update(transaction.database, columns: [Column("modified")])
                } catch {
                    DDLogDebug("ChatRoomMessage.touch with error: \(error)")
                }
            })
        }
    }
    
    public func refetchRoomMessage() -> MessageProtocol? {
        var message:ChatRoomMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatRoomMessage
                    .filter(Column("uniqueId") == self.uniqueId)
                    .fetchOne(transaction.database) {
                    message = ChatRoomMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("ChatRoomMessageModel.refetch error: \(error)")
        }
        
        return message
    }
    
    @objc static func removeAll() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatRoomMessage
                    .deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatRoomMessage.removeAll: \(error)")
            }
        })
    }
    
    @objc public static func deleteAllMessages(for accountId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                let chatRooms = try ChatRoom
                    .filter(Column("accountUniqueId") == accountId)
                    .fetchAll(transaction.database)
                
                for room in chatRooms {
                    try ChatRoomMessage
                        .filter(Column("roomUniqueId") == room.uniqueId)
                        .deleteAll(transaction.database)
                    
                    do {
                        var chatRoom = room
                        chatRoom.lastRoomMessageId = nil
                        chatRoom.modified = Date()
                        try chatRoom.update(transaction.database, columns: [Column("lastRoomMessageId"), Column("modified")])
                        
                        let chatThread = try ChatThread
                            .filter(Column("id") == chatRoom.chatThreadId)
                            .fetchOne(transaction.database)
                        if var thread = chatThread {
                            thread.lastMessageId = nil
                            thread.modified = Date()
                            try thread.update(transaction.database, columns: [Column("lastMessageId"), Column("modified")])
                        }
                    } catch {
                        DDLogDebug("ChatRoomMessage.removeAllMessages failed with error: \(error)")
                    }
                    
                    try ChatMediaItem
                        .filter(Column("parentObjectKey") == room.uniqueId)
                        .filter(Column("parentObjectCollection") == ChatRoomModel.collection())
                        .deleteAll(transaction.database)
                }
            } catch {
                DDLogDebug("ChatRoomMessage.removeAllMessages failed with error: \(error)")
            }
        })
    }
    
    private static func getRoomMessage(record: ChatRoomMessage) -> ChatRoomMessageModel? {
        switch record.type {
        case ChatRoomMessageType.download.rawValue:
            break
        case ChatRoomMessageType.regular.rawValue:
            return ChatRoomMessageModel(uniqueId: record.uniqueId)
        default:
            break
        }
        
        return nil
    }
    
    func lastMessage(completion: @escaping (_ msg: ChatRoomMessageModel?) -> ())
    {
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let ruid = self.grdbRecord?.roomUniqueId, let record = try ChatRoomMessage
                    .filter(Column("roomUniqueId") == ruid)
                    .order(Column("messageDate").desc)
                    .fetchOne(transaction.database) {
                    let message = ChatRoomMessageModel(message: record)
                    completion(message)
                } else {
                    completion(nil)
                }
            })
        } catch {
            completion(nil)
            DDLogError("error: lastMessage \(error)")
        }
    }
    
    @objc public static func getLastMessage(for threadId:String) -> ChatRoomMessageModel? {
        var message:ChatRoomMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatRoomMessage
                    .filter(Column("roomUniqueId") == threadId)
                    .order(Column("messageDate").desc)
                    .fetchOne(transaction.database) {
                    message = ChatRoomMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func getMessage(with key:String) -> ChatRoomMessageModel? {
        var message:ChatRoomMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatRoomMessage
                    .filter(Column("uniqueId") == key)
                    .fetchOne(transaction.database) {
                    message = ChatRoomMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func getMessage(withXmppId id:String) -> ChatRoomMessageModel? {
        var message:ChatRoomMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatRoomMessage
                    .filter(Column("xmppId") == id)
                    .fetchOne(transaction.database) {
                    message = ChatRoomMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func getMessage(withStanzaId id:String) -> ChatRoomMessageModel? {
        var message:ChatRoomMessageModel?
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                if let record = try ChatRoomMessage
                    .filter(Column("stanzaId") == id)
                    .fetchOne(transaction.database) {
                    message = ChatRoomMessageModel(message: record)
                }
            })
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func getMessage(elementId:String?, originId: String?, stanzaId:String?, transaction:GRDBWriteTransaction?) -> ChatRoomMessageModel? {
        
        var parameters: [String] = []
        var queryString = ""
        let addQuery: ((_ column: String, _ value: String?) -> Void) = { (column, value) in
            guard let value = value else { return }
            var stringStart = "WHERE"
            if parameters.count > 0 {
                stringStart = " OR"
            }
            queryString += "\(stringStart) \(column) = ?"
            parameters.append(value)
        }
        addQuery("xmppId", elementId)
        addQuery("originId", originId)
        addQuery("stanzaId", stanzaId)
        guard parameters.count > 0, queryString.count > 0 else {
            return nil
        }
        
        let sql = "SELECT * FROM ChatRoomMessage " + queryString
        let args = StatementArguments(parameters)
        var message:ChatRoomMessageModel?
        do {
            if let trans = transaction {
                if let record = try ChatRoomMessage
                    .fetchOne(trans.database, sql: sql, arguments: args) {
                    message = ChatRoomMessageModel(message: record)
                }
            } else {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    if let record = try ChatRoomMessage
                        .fetchOne(transaction.database, sql: sql, arguments: args) {
                        message = ChatRoomMessageModel(message: record)
                    }
                })
            }
        } catch {
            DDLogError("error: lastMessage \(error)")
        }
        
        return message
    }
    
    @objc public static func setDelivered(elementId:String?, originId: String?, stanzaId:String?) {
        
        var parameters: [String] = []
        var queryString = ""
        let addQuery: ((_ column: String, _ value: String?) -> Void) = { (column, value) in
            guard let value = value else { return }
            var stringStart = "WHERE"
            if parameters.count > 0 {
                stringStart = " OR"
            }
            queryString += "\(stringStart) \(column) = ?"
            parameters.append(value)
        }
        addQuery("xmppId", elementId)
        addQuery("originId", originId)
        addQuery("stanzaId", stanzaId)
        guard parameters.count > 0, queryString.count > 0 else {
            return
        }
        
        let sql = "SELECT * FROM ChatRoomMessage " + queryString
        let args = StatementArguments(parameters)
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                if var roomMessage = try ChatRoomMessage
                    .fetchOne(transaction.database, sql: sql, arguments: args) {
                    if !(roomMessage.state == ChatRoomMessageState.received.rawValue) {
                        do {
                            roomMessage.state = ChatRoomMessageState.delivered.rawValue
                            roomMessage.deliveredDate = Date()
                            try roomMessage.update(transaction.database, columns: [Column("state"), Column("deliveredDate")])
                        } catch {
                            DDLogDebug("ChatRoomMessageModel.setDelivered with error: \(error)")
                        }
                    }
                }
            
            } catch {
                DDLogError("error: lastMessage \(error)")
            }
        })
    }
    
    @objc public static func deleteMessage(with messageId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                
                let msg = try ChatRoomMessage
                    .filter(Column("uniqueId") == messageId)
                    .fetchOne(transaction.database)
                try ChatRoomMessage
                    .filter(Column("uniqueId") == messageId)
                    .deleteAll(transaction.database)
                
                if var room = try ChatRoom
                    .filter(Column("uniqueId") == msg?.roomUniqueId)
                    .fetchOne(transaction.database) {
                    do {
                        room.lastRoomMessageId = nil
                        try room.update(transaction.database, columns: [Column("lastRoomMessageId")])
                    } catch {
                        DDLogDebug("ChatRoomMessageModel.deleteMessage with error: \(error)")
                    }
                }
            } catch {
                DDLogDebug("ChatRoomMessageModel.deleteMessage: \(error)")
            }
        })
    }
    
    @objc public static func countParentMessages(_ threadId: String) -> Int {
        var count = 0
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatRoomMessage
                    .filter(Column("roomUniqueId") == threadId)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return count
    }
    
    @objc public static func countAllMessages() -> Int {
        var count = 0
        
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatRoomMessage
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return count
    }
    
    @objc public static func countAllUnreadMessages() -> UInt {
        var count = 0
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                count = try ChatRoomMessage
                    .filter(Column("read") == false)
                    .fetchCount(transaction.database)
            })
        } catch {
            DDLogDebug("error: \(error)")
        }
        
        return UInt(count)
    }
}

struct ChatRoomMessage: GRDBRecord {
    var id: Int64?
    var uniqueId: String
    var roomJid: String?
    var senderJid: String?
    var realJid: String?
    var receiverJid: String?
    var state: Int?
    var deliveredDate: Date?
    var messageText: String?
    var originalText: String?
    var expires: String?
    var memberUpdate = false
    var systemUpdate = false
    var markable = false
    var isDisplayed = false
    var displayedJids: String?
    var displayedUpdate = false
    var messageDate: Date
    var messageReadDate: Date?
    var xmppId: String? = UUID().uuidString
    var read = true
    var error: GlacierError?
    var mediaItemId: String?
    var mediaType = -1
    var transferProgress: Double?
    var roomUniqueId: String?
    var originId: String?
    var stanzaId: String?
    var buddyUniqueId: String?
    var messageSecurity: Int?
    var omemoDeviceKey: String?
    var modified: Date?
    var type = ChatMessageType.incoming.rawValue
    var chatRoomId: Int64
    var reactions: [ChatMessageReaction]?
    
    var reactionsCount: Int {
        guard let reactions = reactions else {
            return 0
        }
        let count = reactions.reduce(0) { $0 + $1.reactions.count }
        return count
    }
    
    var msgSenderId: String
    var msgSenderDisplayName: String
    
    //download message
    var url: String?

    public static var databaseTableName: String {
        "chatRoomMessage"
    }
    
    public init() {
        self.uniqueId = UUID().uuidString
        self.messageDate = Date()
        self.chatRoomId = -1
        self.msgSenderId = ""
        self.msgSenderDisplayName = ""
    }
    
    public init(uniqueId:String) {
        self.uniqueId = uniqueId
        self.messageDate = Date()
        self.chatRoomId = -1
        self.msgSenderId = ""
        self.msgSenderDisplayName = ""
    }
    
    public static func getPlaceholder() -> ChatRoomMessage {
        var newmsg = ChatRoomMessage()
        newmsg.messageText = ""
        return newmsg
    }
    
    public static func allChatRoomMessages(for roomId:String, limit:Int) -> [ChatRoomMessage] {
        var messages:[ChatRoomMessage] = []
        do {
            try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                messages = try ChatRoomMessage
                    .filter(Column("roomUniqueId") == roomId)
                    .order(Column("messageDate").desc)
                    .limit(limit)
                    .fetchAll(transaction.database)
            })
        } catch {
            DDLogError("error: allChatRoomMessages \(error)")
        }
        
        return messages
    }
    
    static func touch(_ uniqueId:String) {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            let nowdate = Date()
            do {
                if var msg = try ChatRoomMessage
                    .filter(Column("uniqueId") == uniqueId)
                    .fetchOne(transaction.database) {
                    msg.modified = nowdate
                    try msg.update(transaction.database, columns: [Column("modified")])
                }
            } catch {
                DDLogDebug("ChatRoomMessage.touch with error: \(error)")
            }
        })
    }
}

extension ChatRoomMessage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(uniqueId)
    }

    public static func == (lhs: ChatRoomMessage, rhs: ChatRoomMessage) -> Bool {
        lhs.uniqueId == rhs.uniqueId
    }
}

extension ChatRoomMessage {
    static let room = belongsTo(ChatRoom.self)
    var room: QueryInterfaceRequest<ChatRoom> {
        request(for: ChatRoomMessage.room)
    }
    
    static let chatThread = hasOne(ChatThread.self, through: room, using: ChatRoom.thread)
    var chatThread: QueryInterfaceRequest<ChatThread> {
        request(for: ChatRoomMessage.chatThread)
    }
}

public extension ChatRoomMessageModel {
    @objc var downloadableNSURLs: [NSURL] {
        return self.downloadableURLs as [NSURL]
    }
}

extension ChatRoomMessage: MessageType {
    /// The sender of the message.
    public var sender: SenderType {
        get {
            return ChatUser(senderId: self.msgSenderId, displayName: self.msgSenderDisplayName)
        }
        
    }

    /// The unique identifier for the message.
    public var messageId: String {
        get {return uniqueId}
    }

    /// The date the message was sent.
    public var sentDate: Date {
        get {return self.messageDate}
    }

    /// The kind of message and its underlying kind.
    public var kind: MessageKind {
        get {
#if !TARGET_IS_EXTENSION
            if let mediaId = self.mediaItemId {
                if let item = ChatMediaItemModel.getMediaItem(with: mediaId), let mediaRec = item.grdbRecord, mediaRec.mediaType >= 0 {
                    if mediaRec.mediaType == ChatMediaType.imageItem.rawValue, let imageRec = item as? ChatImageItem {
                        return MessageKind.photo(imageRec)
                    } else if mediaRec.mediaType == ChatMediaType.videoItem.rawValue, let videoRec = item as? ChatVideoItem {
                        return MessageKind.video(videoRec)
                    } else if mediaRec.mediaType == ChatMediaType.audioItem.rawValue, let audioRec = item as? ChatAudioItem {
                        return MessageKind.audio(audioRec)
                    } else if mediaRec.mediaType == ChatMediaType.htmlItem.rawValue, let htmlRec = item as? ChatHTMLItem, ChatRoomMessageModel.disableHTMLDownload == false {
                        return MessageKind.photo(htmlRec)
                    } else if mediaRec.mediaType == ChatMediaType.fileItem.rawValue, let fileRec = item as? ChatFileItem {
                        return MessageKind.photo(fileRec)
                    }
                }
            }
#endif
            let txt = self.messageText ?? " "
            if txt.starts(with: "geo:") {
                let geoless = txt.replacingOccurrences(of: "geo:", with: "", options: .regularExpression)
                if geoless.contains(",") {
                    let latlon = geoless.components(separatedBy: ",")
                    let latd = (latlon.first! as NSString).doubleValue
                    let lond = (latlon.last! as NSString).doubleValue
                    let clloc = CLLocation(latitude: latd, longitude: lond)
                    let locItem = ChatLocationItem(location: clloc)
                    return MessageKind.location(locItem)
                }
            } else if txt.starts(with: "aesgcm:") {
#if !TARGET_IS_EXTENSION
                if let item = ChatMediaItemModel.incomingItemWith(filename: txt, mimeType: nil), let mediaRec = item.grdbRecord, mediaRec.mediaType >= 0 {
                    if mediaRec.mediaType == ChatMediaType.imageItem.rawValue, let imageRec = item as? ChatImageItem {
                        return MessageKind.photo(imageRec)
                    } else if mediaRec.mediaType == ChatMediaType.videoItem.rawValue, let videoRec = item as? ChatVideoItem {
                        return MessageKind.video(videoRec)
                    } else if mediaRec.mediaType == ChatMediaType.audioItem.rawValue, let audioRec = item as? ChatAudioItem {
                        return MessageKind.audio(audioRec)
                    } else if mediaRec.mediaType == ChatMediaType.htmlItem.rawValue, let htmlRec = item as? ChatHTMLItem, ChatRoomMessageModel.disableHTMLDownload == false {
                        return MessageKind.photo(htmlRec)
                    } else if mediaRec.mediaType == ChatMediaType.fileItem.rawValue, let fileRec = item as? ChatFileItem {
                        return MessageKind.photo(fileRec)
                    }
                }
#endif
            } else if txt.starts(with: "https:"), ChatRoomMessageModel.disableHTMLDownload == false, let url = URL(string: txt) {
#if !TARGET_IS_EXTENSION
                Task {
                    let isLinkReachable = await LinkReachabilityChecker.shared.isReachable(url.absoluteString)
                    return await MainActor.run {
                        guard isLinkReachable else {
                            return MessageKind.text(txt)
                        }
                        let htmlRec = ChatHTMLItem.init(filename: txt, mimetype: nil, isIncoming: true)
                        return MessageKind.photo(htmlRec)
                    }
                }
#endif
            }

            return MessageKind.text(txt)
        }
    }
}


/**
 Defines string constants for the chat room messages
 */
extension ChatRoomMessage {
    enum StringConstants: String {
        case missedCall
        case incomingCall
        case outgoingCall
        
        var text: String {
            switch self {
            case .missedCall: return "Missed call"
            case .incomingCall: return "Incoming call"
            case .outgoingCall: return "You called"
            }
        }
    }
}
