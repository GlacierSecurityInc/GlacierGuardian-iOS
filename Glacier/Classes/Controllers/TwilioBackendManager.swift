//
//  TwilioBackendManager.swift
//  Glacier
//
//  Created by andyfriedman on 9/14/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import Foundation
import Alamofire
import Contacts
import TwilioConversationsClient

@objc open class TwilioBackendManager: NSObject, OrgUpdateDel
{
    static let API_ENDPOINT = GlacierInfo.smsAPIEndpoint()
    static let STAGE_ENDPOINT = GlacierInfo.stageAPIEndpoint()
    
    static let deleteVMStatus = "deleted"
    static let readVMStatus = "read"
    
    private static let shared = TwilioBackendManager()
    public var identity:String?
    public var smsToken:String?
    public var pushToken:Data?
    private var pushRegistered = false
    private var conversationsClient:TwilioConversationsClient?
    private var delegate:TwilioConversationsClientDelegate?
    private var dataPopulated = false
    private var org:String?
    var contacts = [PhoneContact]()
    private var waitingForOrgInfo = false
    
    private var smsDelegates = [TwilioAccountDelegateProtocol]()
    var glacierSMS:GlacierSMS?
    private var smsOn = false
    @objc var isStage = false
    
    var currentAccounts: [SMSChatAccountModel] = []
    var selectedAccount: SMSChatAccountModel? {
        didSet {
            DispatchQueue.main.async {
                for smsDelegate in self.smsDelegates {
                    smsDelegate.setSelectedAccount(self.selectedAccount)
                }
            }
            vmInitialized = false
            self.queryForVMInfo()
        }
    }
    var selectedRecordings = [VoicemailRecord]()
    var updatingRecordings = false
    var vmInitialized = false
    var hasNewVM = false
    
    private var callHistoryDelegate:CallHistoryDelegateProtocol?
    
    let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral)
    let internalQueue = DispatchQueue(label: "SMS Internal Queue")
    
    @objc private override init() {
        if let glacierAcct = ChatAccountModel.firstAccount() {
            identity = glacierAcct.username.components(separatedBy: "@").first ?? ""
            isStage = glacierAcct.useStageConsole
        }
        
        super.init()
        delegate = self
    }
    
    func initTwilioClient(_ conversationsToken:String) {
        let properties = TwilioConversationsClientProperties()
        properties.dispatchQueue = DispatchQueue(label: "GlacierSMSDispatchQueue")
        TwilioConversationsClient.conversationsClient(withToken: conversationsToken,
            properties: properties, delegate: delegate) { [weak self] result, client in
            if result.isSuccessful, let client = client  {
                self?.conversationsClient = client
                
                if let tokenData = self?.pushToken {
                    self?.registerForPushNotifications(tokenData)
                }
            } else {
                print("failed to create twilio conversation client")
                //completion(.failure(result.error!))
            }
        }
    }
    
    @objc func shutdown() {
        if let client = self.conversationsClient {
            self.deregisterFromPushNotifications()
            client.delegate = nil
            client.shutdown()
            self.conversationsClient = nil
        }
        
        self.identity = nil
        self.smsToken = nil
        self.pushToken = nil
        self.contacts.removeAll()
        self.dataPopulated = false
        self.smsOn = false
        self.glacierSMS = nil
        self.pushRegistered = false
    }
    
    func fetchContacts(completion: @escaping (Bool) -> Void) { 
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { (granted, error) in
            if let error = error {
                print("failed to request access", error)
                completion(false)
                return
            }
            if granted {
                self.internalQueue.async {
                    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactThumbnailImageDataKey]
                    let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
                    request.sortOrder = .familyName
                    do {
                        var contacts = [PhoneContact]()
                        let resize = CGSize(width: 60, height: 60)
                        try store.enumerateContacts(with: request, usingBlock: { (contact, stopPointer) in
                            let contactname = contact.givenName + " " + contact.familyName
                            var avatar = OTRImages.avatarImage(withUsername: contactname) //defaultImage
                            do {
                                if let avdata = contact.thumbnailImageData, let avImg = try UIImage(imageData: avdata) {
                                    avatar = avImg.scalePreservingAspectRatio(targetSize: resize)
                                }
                            } catch {}
                            contacts.append(PhoneContact(name: contactname, phoneNumber: contact.phoneNumbers.first?.value.stringValue ?? "", avatar: avatar))
                            //print("***** number: \(contact.phoneNumbers.first?.value.stringValue ?? "")")
                        })
                        self.contacts = contacts
                        self.setNameAndAvatar()
                        completion(true)
                        return
                    } catch let error {
                        print("Failed to enumerate contacts", error)
                    }
                    completion(false)
                    return
                }
            } else {
                print("contacts access denied")
                completion(false)
                return
            }
        }
    }
    
    func getMatchingContact(_ number: String) -> PhoneContact? {
        let cleanNum = CallManager.cleanPhoneNumber(number)
        for contact in self.contacts {
            let contactNum = CallManager.cleanPhoneNumber(contact.phoneNumber)
            if TwilioBackendManager.arePhoneNumbersEqualUS(phone1: cleanNum, phone2: contactNum) {
                return contact
            }
        }
        return nil
    }
    
    @objc func setPushData(_ token:Data) {
        if let curToken = self.pushToken, token != curToken {
            self.pushRegistered = false
        }
        
        self.pushToken = token
        if let tokenData = self.pushToken {
            self.registerForPushNotifications(tokenData)
        }
    }
    
    //assuming GRDB is ready, i should be able to completely transition immediately since our data is coming from the server
    func populateData() {
        
        if let myid = self.identity, let myParticipants = self.conversationsClient?.participants(withIdentity: myid) {
            
            let accts = SMSChatAccountModel.allAccounts()
            let smsmsgs = SMSChatMessageModel.allMessages()
            
            for participant in myParticipants {
                let tconversation = participant.conversation
                
                var identityNumber:String?
                if let cattr = tconversation?.attributes()?.dictionary as? Dictionary<String,Any> {
                    if let idNum = cattr["identity_number"] as? String {
                        identityNumber = idNum
                    }
                }
                
                if let tparticipants = tconversation?.participants(), tparticipants.count > 1 {
                    var tonumber: String?
                    var fromnumber: String?
                    var acctId: String?
                    for tpart in tparticipants {
                        if tpart.identity == self.identity {
                            fromnumber = tconversation?.friendlyName
                        } else { //remote number, parse json
                            if let attr = tpart.attributes()?.dictionary as? Dictionary<String,Any> {
                                if let friendly = attr["friendlyName"] as? String {
                                    tonumber = friendly
                                } else if let parti = attr["participant_number"] as? String {
                                    tonumber = parti
                                    if (identityNumber != nil) {
                                        fromnumber = identityNumber
                                        break
                                    }
                                }
                            }
                        }
                    }
                    
                    for account in accts {
                        if fromnumber != nil, fromnumber == account.grdbRecord?.phoneNumber {
                            acctId = account.uniqueId
                        }
                    }
                    
                    if let toNumber = tonumber, let fromNumber = fromnumber, let acct = acctId, let twilioConv = tconversation, let twilioId = twilioConv.sid {
                        
                        //maybe check against existing conversations here, and then either sync messages or continue this thread
                        var existing = SMSChatConversationModel.existingConversation(with: twilioId)
                        
                        if let smsConv = existing {
                            self.syncMessages(smsConv, twilioConversation: twilioConv, smsmsgs:smsmsgs)
                        } else {
                            let newConversation = SMSChatConversationModel(remoteNumber: toNumber, localNumber: fromNumber, accountId: acct)
                            newConversation.grdbRecord?.preferredName = toNumber
                            newConversation.grdbRecord?.twilioId = twilioId
                            newConversation.save(completion: {})

                            if let conversation = tconversation {
                                self.restoreMessages(conversation, smsConversation: newConversation)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func getEndpoint() -> String {
        isStage ? TwilioBackendManager.STAGE_ENDPOINT : TwilioBackendManager.API_ENDPOINT
    }
    
    func getAvailableNumListUrl() -> String {
        return getEndpoint() + "availableNumList"
    }
    
    func releaseNumUrl() -> String {
        return getEndpoint() + "releaseTwilioNumber"
    }
    
    func purchaseNumUrl() -> String {
        return getEndpoint() + "purchaseTwilioNumber"
    }
    
    func getAccessTokenUrl() -> String {
        return getEndpoint() + "getAccessToken"
    }
    
    func getUserSelectedTwilioNumbers() -> String {
        return getEndpoint() + "getUserSelectedTwilioNumbers"
    }
    
    func voicemailListUrl() -> String {
        return getEndpoint() + "voicemail_list"
    }
    
    func getVoicemailUrl() -> String {
        return getEndpoint() + "getVoicemail"
    }
    
    func updateVoicemailStatusUrl() -> String {
        return getEndpoint() + "updateVoicemailStatus"
    }
    
    func phoneTokenUrl() -> String {
        return getEndpoint() + "getAccessTokenForDial"
    }
    
    func callHistoryUrl() -> String {
        return getEndpoint() + "call-history"
    }
    
    func deleteIndividualCallHistoryUrl() -> String {
        return getEndpoint() + "deleteCallLog"
    }
    
    func deleteAllCallHistoryUrl() -> String {
        return getEndpoint() + "remove-call-history"
    }
    
    func queryForAvailableNumbers(areaCode:String?, contains:String?) {
        if identity == nil, let glacierName = ChatAccountModel.firstAccount()?.username {
            identity = glacierName.components(separatedBy: "@").first ?? ""
        }

        guard let myid = identity, let org = self.getOrg() else {
            return
        }

        var params = ["countryCode":"US", "username": myid, "organization": org]
        if let areaCode = areaCode {
            params["areaCode"] = areaCode
        }
        if let contains = contains {
            params["contains"] = contains
        }
                
        //["areaCode": areaCode, "contains": contains, "countryCode":"US"]
        Task { [weak self] in
            guard let self = self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            self.internalQueue.async {
                self.sessionManager.request(self.getAvailableNumListUrl(), method: .post, parameters: params, encoding: JSONEncoding.default, headers: headers)
                .validate()
                .responseDecodable(of: TwilioResponse.self, queue: self.internalQueue) { response in
                    switch response.result {
                        case .success(let value):
                            let phoneNumbers = value.available_phone_numbers.map { $0.phoneNumber }
                            for smsDelegate in self.smsDelegates {
                                smsDelegate.availableNumbersUpdated(phoneNumbers)
                            }
                            return
                        case .failure(let error):
                            let nums: [String] = []
                            for smsDelegate in self.smsDelegates {
                                smsDelegate.availableNumbersUpdated(nums)
                            }
                            DDLogError("Error accessing available numbers: \(error)")
                            return
                    }
                }
            }
        }
    }
    
    func deleteCallRecord(with callSid:String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            Task { [weak self] in
                guard let self = self, let org = self.getOrg() else {
                    continuation.resume(returning: false)
                    return
                }
                guard let headers = await GlacierAPIHeaders.authHeaders() else {
                    continuation.resume(returning: false)
                    return
                }

                guard let myid = self.identity else {
                    continuation.resume(returning: false)
                    return
                }

                let params = ["organization": org, "username": myid, "callSid": callSid]
                self.sessionManager.request(
                    self.deleteIndividualCallHistoryUrl(),
                    method: .post,
                    parameters: params,
                    encoding: JSONEncoding.default,
                    headers: headers
                )
                .validate()
                .responseDecodable(of: GenericTwilioResponse.self, queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value.message.lowercased() == "success")
                    case .failure(let error):
                        DDLogError("Error accessing available numbers: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    func deleteAllCallRecords(for userName:String, phoneNumber: String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                guard let headers = await GlacierAPIHeaders.authHeaders() else {
                    continuation.resume(returning: false)
                    return
                }

                guard let org = self.getOrg(), let username = self.identity else {
                    continuation.resume(returning: false)
                    return
                }
                let params = ["username": username, "organization": org, "number": phoneNumber]
                self.sessionManager.request(
                    self.deleteAllCallHistoryUrl(),
                    method: .post,
                    parameters: params,
                    encoding: JSONEncoding.default,
                    headers: headers
                )
                .validate()
                .responseDecodable(of: GenericTwilioResponse.self, queue: self.internalQueue) { response in
                    switch response.result {
                    case .success(let value):
                        continuation.resume(returning: value.message.lowercased() == "success")
                    case .failure(let error):
                        DDLogError("Error accessing available numbers: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    func nameANumber(_ selectedNumber:String, selectedName:String?) {
        //self.naming = false
        //self.numAction = nil
        
        if let displayName = selectedName, let smsAcct = getExistingAccount(phoneNumber: selectedNumber) {
            smsAcct.grdbRecord?.displayName = displayName
            smsAcct.save(completion: {
                self.currentAccounts = self.getExistingAccounts()
                for smsDelegate in self.smsDelegates {
                    smsDelegate.accountsUpdated()
                }
            })
        }
    }
    
    func purchaseNumber(_ selectedNumber:String, selectedName:String?) {
        if let username = self.identity, let org = self.getOrg() {
            Task { [weak self] in
                guard let self = self else { return }
                guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
                self.internalQueue.async {
                    self.sessionManager.request(self.purchaseNumUrl(), method: .post, parameters: ["purchaseNum":selectedNumber,"username":username,"organization":org], encoding: JSONEncoding.default, headers: headers)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success(_):
                                let color = SMSChatAccountModel.getNextColor(self.currentAccounts.count)
                                let smsAccount = SMSChatAccountModel(phoneNumber: selectedNumber, smsacctid: "tempid", color:color)
                                if let acctname = selectedName {
                                    smsAccount.grdbRecord?.displayName = acctname
                                }
                                
                                smsAccount.save(completion: {
                                    self.currentAccounts.append(smsAccount)
                                    self.selectedAccount = smsAccount
                                    for smsDelegate in self.smsDelegates {
                                        smsDelegate.accountsUpdated()
                                    }
                                })
                                return
                            case .failure(let error):
                                DDLogError("Error purchasing number: \(error)")
                                return
                            }
                        }
                }
            }
        }
    }
    
    func releaseNumber(_ selectedNumber:String) {
        if let username = self.identity, let org = self.getOrg() {
            Task { [weak self] in
                guard let self = self else { return }
                guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
                self.internalQueue.async {
                    if let acct = self.getExistingAccount(phoneNumber:selectedNumber) {
                        acct.remove(completion: {
                            self.currentAccounts = self.getExistingAccounts()
                            if self.selectedAccount?.grdbRecord?.phoneNumber == selectedNumber {
                                if self.currentAccounts.count > 0 {
                                    self.selectedAccount = self.currentAccounts.first
                                } else {
                                    self.selectedAccount = nil
                                }
                            }
                            self.smsDelegates.forEach({ (smsDel) in
                                smsDel.accountsUpdated()
                            })
                        })
                    }
                    
                    self.sessionManager.request(self.releaseNumUrl(), method: .post, parameters: ["releaseNumber":selectedNumber,"username":username,"organization":org], encoding: JSONEncoding.default, headers: headers)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success(_):
                                //self.queryForNumbers()
                                return
                            case .failure(let error):
                                DDLogError("Error releasing number: \(error)")
                                return
                            }
                        }
                }
            }
        }
    }
    
    func setNameAndAvatar() {
        self.internalQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            var smsConversations = SMSChatConversationModel.allConversations()
            for smsConv in smsConversations {
                for contact in self.contacts {
                    let fContact = self.format(with:"XXXXXXXXXXXX", phone: contact.phoneNumber)
                    if let toNumber = smsConv.grdbRecord?.remoteNumber {
                        let fToNumber = self.format(with:"XXXXXXXXXXXX", phone: toNumber)
                        if TwilioBackendManager.arePhoneNumbersEqualUS(phone1: fContact, phone2: fToNumber) {
                            if smsConv.grdbRecord?.preferredName == fToNumber || smsConv.grdbRecord?.preferredName == toNumber {
                                smsConv.grdbRecord?.preferredName = contact.name
                            }
                            if let avatar = contact.avatar {
                                smsConv.avatar = avatar
                            }
                            smsConv.save()
                            break
                        }
                    }
                }
            }
        }
    }
    
    static func arePhoneNumbersEqualUS(phone1: String, phone2: String) -> Bool {
        if phone1.count < 8 || phone2.count < 8 {
            return false
        }
        
        if phone1 == phone2 {
            return true
        }
        let phone1us = "1" + phone1
        let phone2us = "1" + phone2

        if phone1us == phone2 {
            return true
        }

        if phone1 == phone2us {
            return true
        }

        return false
    }
    
    //populate messages
    func restoreMessages(_ tconversation: TCHConversation, smsConversation: SMSChatConversationModel) {
        tconversation.getLastMessages(withCount: 100) { (result, messages) in
            if let messages = messages {
                for msg in messages {
                    self.saveMessage(smsConversation, twilioMsg:msg)
                }
            }
        }
    }
    
    func saveMessage(_ smsConversation:SMSChatConversationModel, twilioMsg:TCHMessage) {
        if let senderId = smsConversation.grdbRecord?.smsAccountId, let displayName = smsConversation.grdbRecord?.preferredName {
            var isIncoming = false
            var sender = senderId
            var display = displayName
            if let msgAuthor = twilioMsg.author, msgAuthor != self.identity, let partSid = twilioMsg.participantSid {
                sender = partSid
                display = msgAuthor
                isIncoming = true
            }

            let message = SMSChatMessageModel(conversationId: smsConversation.uniqueId, senderId: sender, senderDisplayName: display, text: twilioMsg.body, twilioSid: twilioMsg.sid ,date:twilioMsg.dateCreatedAsDate)
            
            if !isIncoming, let _ = message.refetch() {
                return
            }
            
            message.grdbRecord?.isIncoming = isIncoming
            message.save()
            if let smsConv = smsConversation.refetch() {
                smsConv.grdbRecord?.latestMessageId = message.uniqueId
                smsConv.grdbRecord?.latestMessage = nil
                //if let mdate = message.grdbRecord?.messageDate {
                //    smsConv.grdbRecord?.latestMessageDate = mdate
                //}
                smsConv.save()
            }

            if (!twilioMsg.attachedMedia.isEmpty) { //isIncoming &&
                for media in twilioMsg.attachedMedia {
                    handleMedia(media, smsMessage: message, smsConversation: smsConversation)
                }
            }
        }
    }

    func syncMessages(_ smsConversation: SMSChatConversationModel, twilioConversation:TCHConversation, smsmsgs:[SMSChatMessageModel]) {
        self.internalQueue.async {
            var convmsgs:[SMSChatMessageModel] = []
            for smsmsg in smsmsgs {
                if smsmsg.grdbRecord?.conversationId == smsConversation.uniqueId {
                    convmsgs.append(smsmsg)
                }
            }
            
            let cmsgs = convmsgs
            twilioConversation.getLastMessages(withCount: 5) { (result, messages) in
                if let messages = messages {
                    for msg in messages {
                        var found = false
                        for cmsg in cmsgs {
                            if (msg.attachedMedia.isEmpty && msg.body == cmsg.grdbRecord?.msgText) || (!msg.attachedMedia.isEmpty && cmsg.grdbRecord?.twilioSid == msg.sid) {
                                found = true
                                break
                            }
                        }
                        
                        if found == false {
                            self.saveMessage(smsConversation, twilioMsg: msg)
                            //DDLogDebug("TwilioConversationsClient missing message saved: \(msg) from conversation: \(String(describing: twilioConversation.sid))")
                        }
                    }
                }
            }
        }
    }
    
    @objc public func registerForPushNotifications(_ deviceToken: Data) {
        if let conversationsClient = self.conversationsClient, conversationsClient.user != nil {
            conversationsClient.register(withNotificationToken: deviceToken) { (result) in
                if !result.isSuccessful {
                    self.pushRegistered = true
                    DDLogError("Failure in registerForPushNotifications with \(deviceToken)")
                    // try registration again or verify token?
                    // https://www.twilio.com/docs/conversations/ios/push-notifications-ios?code-sample=code-store-registration&code-language=Swift&code-sdk-version=default
                } else {
                    DDLogInfo("Success in registerForPushNotifications with \(deviceToken)")
                }
            }
        }
    }
    
    private func deregisterFromPushNotifications() {
        if let conversationsClient = conversationsClient, conversationsClient.user != nil, let curToken = self.pushToken {
            conversationsClient.deregister(withNotificationToken: curToken) { (result) in
            }
        }
    }
    
    @objc public class func sharedMgr() -> TwilioBackendManager {
        return shared
    }
    
    public func handleNotification(notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        if let conversationsClient = conversationsClient, conversationsClient.user != nil {
            // If your reference to the Conversations client exists
            // and is initialized, send the notification to it
            conversationsClient.handleNotification(userInfo) { (result) in
                if !result.isSuccessful {
                    print("Handling of notification was not successful")
                    // Handling of notification was not successful, retry?
                }
            }
        } else {
            // Store the notification for later handling
            //receivedNotification = userInfo
            print("No existing conversation client")
        }
    }
    
    func verifyConversation(_ smsConversation: SMSChatConversationModel) {
        self.getTwilioConversation(smsConversation, completion: { (conversation) in
            if let tconv = conversation, tconv.participants().count < 2 {
                print("Conversation does not have 2 participants")
                self.addReceiverToConversation(tconv, smsConversation: smsConversation)
            }
        })
    }
    
    private func getTwilioConversation(_ smsConversation: SMSChatConversationModel, completion: @escaping (_ twilioConversation: TCHConversation?) -> ()) {
        guard let client = self.conversationsClient else {
            //completion(DataFetchError.conversationsClientIsNotAvailable)
            completion(nil)
            return
        }
        
        client.conversation(withSidOrUniqueName: smsConversation.grdbRecord?.twilioId ?? smsConversation.uniqueId, completion: { (result, conversation) in
             completion(conversation)
        })
    }
    
    func createAndJoinConversation(friendlyName: String, smsConversation: SMSChatConversationModel) {
        var attr:TCHJsonAttributes?
        if let myid = self.identity, let pushString = self.pushToken?.toHexString() {
            attr = TCHJsonAttributes(dictionary: ["identity": myid,
                                                  "bindingType": "apn",
                                                  "address": pushString])
            //https://www.twilio.com/docs/notify/api/binding-resource#create-a-binding
        }
        
        let creationOptions: [String: Any] = [
            TCHConversationOptionFriendlyName: friendlyName,
            TCHConversationOptionUniqueName: smsConversation.grdbRecord?.twilioId ?? smsConversation.uniqueId,
            TCHConversationOptionAttributes: attr ?? []
        ]
            
        guard let client = self.conversationsClient else {
            //completion(DataFetchError.conversationsClientIsNotAvailable)
            return
        }
        
        client.conversation(withSidOrUniqueName: smsConversation.grdbRecord?.twilioId ?? smsConversation.uniqueId, completion: { (result, conversation) in
            if result.isSuccessful, let conv = conversation {
                if conv.status != .joined {
                    self.joinConversation(conv, smsConversation: smsConversation)
                }
            } else {
                client.createConversation(options: creationOptions) { result, conversation in
                    guard let conversation = conversation else {
                        return
                    }
                    print("Created conversation and setting twilioId from \(String(describing: smsConversation.grdbRecord?.twilioId)) to \(String(describing: conversation.sid))")
                    //smsConversation.grdbRecord?.twilioId = conversation.sid
                    if let smsConv = smsConversation.refetch() {
                        smsConv.grdbRecord?.twilioId = conversation.sid
                        smsConv.save()
                    }
                        
                    self.joinConversation(conversation, smsConversation: smsConversation)
                }
            }
        })
    }
    
    private func joinConversation(_ conversation: TCHConversation, smsConversation: SMSChatConversationModel) {
        if conversation.status == .joined {
            //print("Current user already exists in conversation")
            if conversation.participants().count < 2 {
                self.addReceiverToConversation(conversation, smsConversation: smsConversation)
            }
            //self.loadPreviousMessages(conversation)
        } else {
            conversation.join(completion: { result in
                //print("Result of conversation join: \(result.resultText ?? "No Result")")
                if result.isSuccessful {
                    //print("Result of me conversation join successful")
                    self.addReceiverToConversation(conversation, smsConversation: smsConversation)
                    //self.loadPreviousMessages(conversation)
                }
            })
        }
    }
    
    func addReceiverToConversation(_ conversation: TCHConversation, smsConversation: SMSChatConversationModel) {
        if let smsNumber = smsConversation.grdbRecord?.remoteNumber, let from = smsConversation.grdbRecord?.localNumber {
            var toNumber = smsNumber
            if !(smsNumber.hasPrefix("+")) {
                toNumber = "+1" + smsNumber
            }
            
            let attributes = [
                "friendlyName": smsNumber
            ]
            let jsonAttr = TCHJsonAttributes(dictionary: attributes)
            
            conversation.addParticipant(byAddress: toNumber, proxyAddress: from, attributes: jsonAttr, completion: { result in
                //print("Result of conversation add participant: \(result.resultText ?? "No Result")")
                if !result.isSuccessful {
                    self.handleAddParticipantFail(result, conversation: conversation, smsConversation: smsConversation)
                }
            })
        }
    }
    
    func handleAddParticipantFail(_ result:TCHResult, conversation: TCHConversation, smsConversation: SMSChatConversationModel) {
        if let rtext = result.resultText, rtext.contains("already exists in Conversation") {
            let sub = rtext.suffix(34)
            if sub.hasPrefix("CH") {
                smsConversation.grdbRecord?.twilioId = String(sub)
                if let smsConv = smsConversation.refetch() {
                    smsConv.save()
                }
            }
        }
    }
    
    func deleteConversation(smsConversation: SMSChatConversationModel, completion: @escaping (_ success: Bool) -> ()) {
        guard let client = self.conversationsClient else {
            //print("Could not find Twilio client")
            completion(false)
            return
        }
        
        client.conversation(withSidOrUniqueName: smsConversation.grdbRecord?.twilioId ?? smsConversation.uniqueId, completion: { (result, conversation) in
            if result.isSuccessful, conversation != nil {
                conversation?.destroy(completion: { (result) in
                    if result.isSuccessful {
                        completion(true)
                        return
                    }
                    //print("Could not delete conversation")
                    completion(false)
                })
            } else {
                //print("Could not find conversation to delete, possibly already deleted, return success")
                completion(true)
            }
        })
    }
    
    func sendMessage(_ smsConversation:SMSChatConversationModel, messageText: String) {
        
        guard let client = self.conversationsClient else {
            //completion(DataFetchError.conversationsClientIsNotAvailable)
            return
        }
        
        let masked = ProfanityFilter.mask(messageText)
        
        client.conversation(withSidOrUniqueName: smsConversation.grdbRecord?.twilioId ?? smsConversation.uniqueId, completion: { (result, conversation) in
            if result.isSuccessful, let twilConversation = conversation, twilConversation.status == .joined {
                twilConversation.prepareMessage()
                   .setBody(masked)
                   .buildAndSend { result, message in
                       //print("Message sent with result \(result)")
                       if let tmesg = message {
                           self.handleSuccessfulSend(smsConversation, message: tmesg, mediaData: nil, originalText: messageText)
                       }
                       //completion(result, message)
                   }
            } else {
                print("Message not sent with result \(result)")
            }
        })
    }
    
    func sendMediaMessage(_ smsConversation:SMSChatConversationModel, mediaData:Data, filename:String?, contentType:String, completion: @escaping (_ uploadSuccess: Bool) -> ()) {
        
        guard let client = self.conversationsClient else {
            //completion(DataFetchError.conversationsClientIsNotAvailable)
            completion(false)
            return
        }
        
        client.conversation(withSidOrUniqueName: smsConversation.grdbRecord?.twilioId ?? smsConversation.uniqueId, completion: { (result, conversation) in
            if result.isSuccessful, let twilConversation = conversation, twilConversation.status == .joined {
                twilConversation.prepareMessage()
                   //.setBody("image")
                   .addMedia(data: mediaData, contentType: contentType, filename: filename, listener: .init(onStarted: {
                       print("Media upload started")
                   }, onProgress: { bytesSent in
                       print("Current progress \(bytesSent)")
                   }, onCompleted: { mediaSid in
                       print("Media uploaded with sid \(mediaSid)")
                       completion(true)
                   }, onFailed: { error in
                       print("Media upload failed with error \(error)")
                       completion(false)
                   }))
                   .buildAndSend { result, message in
                       print("Message sent with result \(result)")
                       if result.isSuccessful {
                           if let tmesg = message {
                               self.handleSuccessfulSend(smsConversation, message: tmesg, mediaData: mediaData, originalText: nil)
                           }
                       }
                       //completion(result, message)
                   }
            } else {
                print("Message not sent with result \(result)")
                completion(false)
            }
        })
    }
    
    public func getOrg() -> String? {
        if self.org == nil {
            if let orgdata = AWSAcctManager.sharedMgr().getGlacierEnablements() {
                self.org = orgdata.organization
            } else if let glacierOrg = ChatAccountModel.firstAccount()?.grdbRecord?.org {
                self.org = glacierOrg
            }
        }
        return self.org
    }
    
    @objc public func getToken() {
        if self.smsToken == nil {
            queryForTwilioTokens()
            queryForNumbers()
        }
    }
    
    public func queryForTwilioTokens() {
        if identity == nil, let glacierName = ChatAccountModel.firstAccount()?.username {
            identity = glacierName.components(separatedBy: "@").first ?? ""
        }
        
        if let myid = identity, let org = self.getOrg()
        {
            Task { [weak self] in
                guard let self = self else { return }
                guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
                self.internalQueue.async {
                    self.sessionManager.request(self.getAccessTokenUrl(), method: .post, parameters: ["username": myid, "devicetype": "ios", "organization": org], encoding: JSONEncoding.default, headers: headers)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success(let value):
                                if let results = String(data: value, encoding: .utf8) {
                                    self.parseToken(tokenString: results)
                                }
                                return
                            case .failure(let error):
                                DDLogError("Error getting chat token: \(error)")
                                return
                            }
                        }
                }
                
                self.internalQueue.async {
                    self.sessionManager.request(self.phoneTokenUrl(), method: .post, parameters: ["username": myid, "devicetype": "ios", "organization": org], encoding: JSONEncoding.default, headers: headers)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success(let value):
                                if let results = String(data: value, encoding: .utf8) {
                                    CallManager.sharedCallManager().tokenReceived(results)
                                }
                                return
                            case .failure(let error):
                                DDLogError("Error getting chat token: \(error)")
                                return
                            }
                        }
                }
            }
        }
    }
    
    func parseToken(tokenString: String) {
        if let data = tokenString.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options : .allowFragments) as? Dictionary<String,Any> {
            
            if let token = json["token"] as? String {
                if (self.smsToken == nil) {
                    initTwilioClient(token)
                } else {
                    self.conversationsClient?.updateToken(token)
                }
                self.smsToken = token
            }
        }
    }
    
    public func orgInfoUpdated() {
        if self.waitingForOrgInfo {
            self.waitingForOrgInfo = false
            self.queryForNumbers()
        }
    }
    
    @objc public func queryForNumbers() {
        guard let org = self.getOrg() else {
            self.waitingForOrgInfo = true
            AWSAcctManager.sharedMgr().addOrgDelegate(self)
            return
        }
        
        if identity == nil, let glacierName = ChatAccountModel.firstAccount()?.username {
            identity = glacierName.components(separatedBy: "@").first ?? ""
        }
        
        if let myid = identity
        {
            Task { [weak self] in
                guard let self = self else { return }
                guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
                self.internalQueue.async {
                    self.sessionManager.request(self.getUserSelectedTwilioNumbers(), method: .post, parameters: ["organization": org, "username": myid], encoding: JSONEncoding.default, headers: headers)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success(let value):
                                if let results = String(data: value, encoding: .utf8) {
                                    self.parseNumbers(response: results)
                                }
                                return
                            case .failure(let error):
                                DDLogError("Error getting chat token: \(error)")
                                return
                            }
                        }
                }
            }
        }
    }
    
    func parseNumbers(response: String) {
        //NSLog("***** parsing info from SMS request")
        if let data = response.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options : .allowFragments) as? Dictionary<String,Any> {
            
            if let jdata = json["data"] as? Dictionary<String,Any>, let isSms = jdata["isSMSEnabled"] as? Bool, let allowPurchase = jdata["allow_user_to_purchase_numbers"] as? Bool, let selectedNumbers = jdata["selected_twilionumber"] as? [Dictionary<String,String>] {
                let gsms = GlacierSMS()
                gsms.addUserToPurchaseNumbers = allowPurchase
                gsms.isSMSEnabled = isSms
                for num in selectedNumbers {
                    gsms.selectedTwilionumber.append(num)
                }
                
                if self.glacierSMS == nil && gsms.isSMSEnabled == true, self.smsToken == nil {
                    queryForTwilioTokens()
                    self.fetchContacts(completion: {_ in })
                }
                
                self.glacierSMS = gsms
                self.processTwilioUserData(gsms)

                DispatchQueue.main.async {
                    OTRAppDelegate.appDelegate.setSMSEnabled(isSms)
                }
            }
        }
    }
    
    private func processTwilioUserData(_ glacierSms: GlacierSMS) {
        var phonenumbers: [String] = []
        var index = 0
        
        self.currentAccounts.removeAll()
        var updated = false
        for item in glacierSms.selectedTwilionumber {
            if let phonenumber = item["text"], let id = item["id"] {
                phonenumbers.append(phonenumber)
                
                //can just change to SMSChatAccount.existingAccount(with: phoneNumber)
                var smsAccount:SMSChatAccountModel?
                if let smsAcct = getExistingAccount(phoneNumber: phonenumber) {
                    smsAccount = smsAcct
                } else {
                    let color = SMSChatAccountModel.getNextColor(index)
                    smsAccount = SMSChatAccountModel(phoneNumber: phonenumber, smsacctid: id, color:color)
                    updated = true
                    
                    if self.selectedAccount == nil {
                        self.selectedAccount = smsAccount
                    }
                    
                    smsAccount?.save(completion: {
                        self.smsDelegates.forEach({ (smsDel) in
                            smsDel.accountsUpdated()
                        })
                    })
                }
                
                currentAccounts.append(smsAccount!)
            }
            index+=1
        }
        
        //remove from our database any numbers removed via console
        for acct in getExistingAccounts() {
            if let acctnum = acct.grdbRecord?.phoneNumber {
                var found = false
                for num in phonenumbers {
                    if acctnum == num {
                        found = true
                    }
                }
                
                if !found {
                    updated = true
                    acct.remove(completion: {
                        if self.selectedAccount?.grdbRecord?.phoneNumber == acctnum {
                            self.currentAccounts = self.getExistingAccounts()
                            if self.currentAccounts.count > 0 {
                                self.selectedAccount = self.currentAccounts.first
                            } else {
                                self.selectedAccount = nil
                            }
                        }
                        self.smsDelegates.forEach({ (smsDel) in
                            smsDel.accountsUpdated()
                        })
                    })
                }
            }
        }
        
        if updated == false {
            if (self.currentAccounts.count > 0 && self.selectedAccount == nil) {
                self.selectedAccount = self.currentAccounts.first
            }
            self.smsDelegates.forEach({ (smsDel) in
                smsDel.accountsUpdated()
            })
        }
    }
    
    @objc func queryForVMInfo() {
        guard let selacct = self.selectedAccount, let selnumber = selacct.grdbRecord?.phoneNumber, let org = self.getOrg(), let myid = identity else {
            return
        }
        
        self.updatingRecordings = true
        Task { [weak self] in
            guard let self = self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                self.updatingRecordings = false
                return
            }
            self.internalQueue.async {
                self.sessionManager.request(self.voicemailListUrl(), method: .post, parameters: ["organization": org, "username": myid, "number":selnumber], encoding: JSONEncoding.default, headers: headers)
                    .validate()
                    .responseData(queue: self.internalQueue) { response in
                        switch response.result {
                        case .success(let value):
                            if let results = String(data: value, encoding: .utf8) {
                                self.handleVMs(response: results)
                            } else {
                                self.updatingRecordings = false
                            }
                            return
                        case .failure(let error):
                            self.updatingRecordings = false
                            DDLogError("Error getting chat token: \(error)")
                            return
                        }
                    }
            }
        }
    }
    
    func handleVMs(response: String) {
        if let data = response.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options : .allowFragments) as? Dictionary<String,Any> {
            var recordings = [VoicemailRecord]()
            var hasUnreadVM = false
            if let jdata = json["recordings"] as? [Dictionary<String,String>] {
                for rec in jdata {
                    let recording = VoicemailRecord()
                    recording.from = rec["from"] ?? ""
                    recording.recordingSid = rec["recordingsid"] ?? ""
                    recording.time = rec["time"] ?? ""
                    recording.duration = rec["duration"] ?? ""
                    recording.callSid = rec["callsid"] ?? ""
                    recording.to = rec["to"] ?? ""
                    recording.url = rec["url"] ?? ""
                    recording.status = rec["status"] ?? "read" //unread, read, deleted
                    
                    if recording.status == "new" {
                        hasUnreadVM = true
                    }
                    
                    if let to = recording.to, let contact = getMatchingContact(to) {
                        recording.contact = contact
                    }
                    
                    recordings.append(recording)
                }
                
                let userInfo = [kOTRNotificationType:kNotificationVoicemailType]
                if recordings.count > self.selectedRecordings.count, vmInitialized {
                    DispatchQueue.main.async {
                        if let navController = OTRAppDelegate.appDelegate.window?.rootViewController as? UINavigationController, let visibleController = navController.visibleViewController {
                            
                            if !(visibleController is VoicemailViewController), !(visibleController is VMPlayerViewController), UIApplication.shared.applicationState == .active {
                                UIApplication.shared.showLocalNotificationWith(identifier: nil, body: "New voicemail", badge: 0, userInfo: userInfo, recurring: false)
                            }
                        } else {
                            UIApplication.shared.showLocalNotificationWith(identifier: nil, body: "New voicemail", badge: 0, userInfo: userInfo, recurring: false)
                        }
                    }
                }
            }
            self.selectedRecordings = recordings
            vmInitialized = true
            self.hasNewVM = hasUnreadVM
            
            DispatchQueue.main.async {
                for smsDelegate in self.smsDelegates {
                    smsDelegate.voicemailUpdated()
                }
            }
        }
        self.updatingRecordings = false
    }
    
    func deleteVM(_ vmsid: String) {
        self.updateVMStatus(vmsid, status: TwilioBackendManager.deleteVMStatus)
    }
    
    func listenedToVM(_ vmsid: String) {
        self.updateVMStatus(vmsid, status: TwilioBackendManager.readVMStatus)
    }
    
    func updateVMStatus(_ vmsid:String, status:String) {
        guard let org = self.getOrg(), let myid = identity else {
            return
        }
        
        Task { [weak self] in
            guard let self = self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            self.internalQueue.async {
                self.sessionManager.request(self.updateVoicemailStatusUrl(), method: .post, parameters: ["organization": org, "username": myid, "recordingSid":vmsid, "status":status], encoding: JSONEncoding.default, headers: headers)
                    .validate()
                    .responseData(queue: self.internalQueue) { response in
                        switch response.result {
                        case .success(_):
                            self.queryForVMInfo()
                            return
                        case .failure(let error):
                            DDLogError("Error updating voicemail status: \(error)")
                            return
                        }
                    }
            }
        }
    }
    
    func getExistingAccount(phoneNumber:String) -> SMSChatAccountModel? {
        return SMSChatAccountModel.existingAccount(with: phoneNumber)
    }
    
    func getExistingAccounts() -> [SMSChatAccountModel] {
        return SMSChatAccountModel.allAccounts()
    }
    
    func getXMPPAccountName() -> String? {
        let account = ChatAccountModel.allXMPPAccounts().first
        return account?.username
    }
    
    func setSMSDelegate(_ smsDelegate:TwilioAccountDelegateProtocol) {
        self.smsDelegates.append(smsDelegate)
    }
    
    func removeLastSMSDelegate() {
        self.smsDelegates.removeLast()
        //let other delegates know this has been dismissed
        for smsDelegate in self.smsDelegates {
            smsDelegate.numbersControllerClosed()
        }
        
    }
    
    func getExistingConversation(localNumber:String, remoteNumber:String) -> SMSChatConversationModel? {
        return SMSChatConversationModel.existingConversation(localPhone: localNumber, remotePhone: remoteNumber)
    }
    
    func initiateSms(_ smsContact:PhoneContact) {
        guard let sendingNum = self.selectedAccount?.grdbRecord?.phoneNumber, let acctid = self.selectedAccount?.grdbRecord?.uniqueId else {
            return
        }
        
        let remoteNumber = CallManager.cleanPhoneNumber(smsContact.phoneNumber)
        let conversation = self.getExistingConversation(localNumber: sendingNum, remoteNumber: remoteNumber)
            
        if let conv = conversation {
            DispatchQueue.main.async {
                if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
                    appDelegate.window?.rootViewController = appDelegate.smsSplitViewCoordinator.splitViewController
                    appDelegate.smsSplitViewCoordinator.enterSMSWithThread(conv, sender: nil)
                }
            }
        } else {
            let newConversation = SMSChatConversationModel(remoteNumber: remoteNumber, localNumber: sendingNum, accountId: acctid)
            newConversation.grdbRecord?.preferredName = smsContact.name
            newConversation.grdbRecord?.isNew = true // janky
                
            if let ava = smsContact.avatar {
                newConversation.avatar = ava
            } else {
                newConversation.avatar = OTRImages.avatarImage(withUsername: smsContact.name)
            }
                
            newConversation.save(completion: {
                self.createAndJoinConversation(friendlyName: sendingNum, smsConversation: newConversation)
                
                let conv = newConversation
                DispatchQueue.main.async {
                    if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
                        appDelegate.window?.rootViewController = appDelegate.smsSplitViewCoordinator.splitViewController
                        appDelegate.smsSplitViewCoordinator.enterSMSWithThread(conv, sender: nil)
                    }
                }
            })
        }
    }
    
    func handleSuccessfulSend(_ smsConversation:SMSChatConversationModel, message:TCHMessage, mediaData:Data?, originalText: String?) {
        if let senderId = smsConversation.grdbRecord?.smsAccountId, let displayName = smsConversation.grdbRecord?.preferredName {
            let textToSave = originalText ?? message.body
            let smsMessage = SMSChatMessageModel(conversationId: smsConversation.uniqueId, senderId: senderId, senderDisplayName: displayName, text: textToSave, twilioSid: message.sid, date:message.dateCreatedAsDate)
            smsMessage.grdbRecord?.isIncoming = false
            smsMessage.save(completion: {
                if let smsConv = smsConversation.refetch() {
                    smsConv.grdbRecord?.latestMessageId = smsMessage.uniqueId
                    smsConv.grdbRecord?.latestMessage = nil
                    //if let mdate = smsMessage.grdbRecord?.messageDate {
                    //    smsConv.grdbRecord?.latestMessageDate = mdate
                    //}
                    smsConv.save()
                }
            })
            
            if let inData = mediaData {
                let mediaRec = SMSChatMediaItem(uniqueId: smsMessage.uniqueId, parentObjectKey: smsMessage.uniqueId, parentThreadKey: smsConversation.uniqueId, transferProgress: 0.0, filename: "\(UUID().uuidString).jpg", modified: nil)
                let mediaItem = SMSChatMediaItemModel(mediaItem: mediaRec)
                
                mediaItem.save(completion: {
                    self.storeData(smsMessage: smsMessage, mediaItem: mediaItem, inData: inData)
                })
            }
        }
    }
    
    func storeData(smsMessage: SMSChatMessageModel, mediaItem: SMSChatMediaItemModel, inData: Data?) {
        self.internalQueue.async {
            if let data = inData, let conversationId = smsMessage.grdbRecord?.conversationId {
                OTRMediaFileManager.sharedInstance().setData(data, forItem: mediaItem, smsUniqueId: conversationId, completion: { (bytesWritten, error) in
                    if let error = error {
                        DDLogError("Error copying data: \(error)")
                        return
                    }
                    
                    let image = UIImage(data: data)
                    mediaItem.grdbRecord?.transferProgress = 1.0
                    if let size = image?.size {
                        mediaItem.setSize(size: size)
                    }
                    mediaItem.save(completion: {
                        self.internalQueue.async {
                            smsMessage.grdbRecord?.mediaItemUniqueId = mediaItem.uniqueId
                            smsMessage.grdbRecord?.modified = Date()
                            smsMessage.grdbRecord?.transferProgress = 1.0
                            smsMessage.save()
                        }
                    })
                }, completionQueue: self.internalQueue)
            }
        }
    }
}

extension TwilioBackendManager {
    func setCallHistoryDelegate(_ historyDelegate:CallHistoryDelegateProtocol) {
        self.callHistoryDelegate = historyDelegate
    }
    
    func queryCallHistory() {
        self.queryCallHistory(500)
    }
    
    func queryCallHistory(_ limitNum:Int) {
        //auth headers -- number (selected, or all), limit 500
        guard let org = self.getOrg() else {
            self.callHistoryDelegate?.callHistoryUpdated(nil)
            return
        }

        let limit = String(limitNum)
        if let currentNumber = self.selectedAccount?.grdbRecord?.phoneNumber
        {
            Task { [weak self] in
                guard let self = self else { return }
                guard let headers = await GlacierAPIHeaders.authHeaders() else {
                    self.callHistoryDelegate?.callHistoryUpdated(nil)
                    return
                }
                self.internalQueue.async {
                    let req = self.callHistoryUrl()
                    //print("***** \(req)")
                    self.sessionManager.request(req, method: .post, parameters: ["number": currentNumber, "limit": limit, "organization": org], encoding: JSONEncoding.default, headers: headers)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success(let value):
                                self.callHistoryDelegate?.callHistoryUpdated(value)
                                return
                            case .failure(let error):
                                DDLogError("Error getting history: \(error)")
                                self.callHistoryDelegate?.callHistoryUpdated(nil)
                                return
                            }
                        }
                }
            }
        } else {
            self.callHistoryDelegate?.callHistoryUpdated(nil)
        }
    }
}

// MARK: Client delegate methods
extension TwilioBackendManager: TwilioConversationsClientDelegate {

    // MARK: Client changes
    public func conversationsClient(_ client: TwilioConversationsClient, connectionStateUpdated state: TCHClientConnectionState) {
        //self.clientState = state
        DDLogInfo("TwilioConversationsClient connectionStateUpdated: \(state)")
    }
    
    public func conversationsClientTokenWillExpire(_ client: TwilioConversationsClient) {
        //DDLogInfo("TwilioConversationsClient conversationsClientTokenWillExpire")
        self.queryForTwilioTokens()
    }
    
    public func conversationsClientTokenExpired(_ client: TwilioConversationsClient) {
        self.queryForTwilioTokens()
    }
    
    public func conversationsClient(_ client: TwilioConversationsClient, conversationsError errorReceived: TCHError) {
        DDLogInfo("TwilioConversationsClient errorReceived: \(errorReceived)")
        //DispatchQueue.main.async {
            //self.conversationsError = errorReceived
        //}
    }
    
    public func conversationsClient(_ client: TwilioConversationsClient, synchronizationStatusUpdated status: TCHClientSynchronizationStatus) {
        
        DDLogInfo("TwilioConversationsClient synchronizationStatusUpdated: \(status)")
        
        guard status == .completed else {
            return
        }
        
        if !self.dataPopulated {
            self.dataPopulated = true
            self.populateData()
        }
        
        //if !pushRegistered, let token = self.pushToken {
        if let token = self.pushToken {
            self.registerForPushNotifications(token)
        }
    }

    // MARK: Conversation changes
    public func conversationsClient(_ client: TwilioConversationsClient, conversationAdded conversation: TCHConversation) {
        
        if conversation.createdBy == self.identity {
            return
        }
        
        var tonumber: String?
        var fromnumber: String?
        var acctId: String?
        
        tonumber = conversation.friendlyName
        if let attr = conversation.attributes()?.dictionary as? Dictionary<String,Any> {
            fromnumber = attr["identity_number"] as? String
        }
        
        let tparticipants = conversation.participants()
        if tparticipants.count > 1 {
            var accts:[SMSChatAccountModel] = SMSChatAccountModel.allAccounts()
            for account in accts {
                if fromnumber != nil, fromnumber == account.grdbRecord?.phoneNumber {
                    acctId = account.uniqueId
                }
            }
            
            //DDLogInfo("TwilioConversationsClient Conversation added tonumber: \(String(describing: tonumber))) fromnumber \(String(describing:fromnumber)), and acctid \(String(describing:acctId))")
            
            if let toNumber = tonumber, let fromNumber = fromnumber, let acct = acctId {
                let newConversation = SMSChatConversationModel(remoteNumber: toNumber, localNumber: fromNumber, accountId: acct)
                newConversation.grdbRecord?.preferredName = toNumber
                newConversation.grdbRecord?.twilioId = conversation.sid
                
                //check for existence of toNumber in Contacts, set preferred name
                for contact in self.contacts {
                    let fContact = self.format(with:"XXXXXXXXXXXX", phone: contact.phoneNumber)
                    let fToNumber = self.format(with:"XXXXXXXXXXXX", phone: toNumber)
                    if TwilioBackendManager.arePhoneNumbersEqualUS(phone1: fContact, phone2: fToNumber) {
                        newConversation.grdbRecord?.preferredName = contact.name
                        if let avatar = contact.avatar {
                            newConversation.avatar = avatar
                        }
                        break;
                    }
                }
                
                if newConversation.avatar == nil {
                    let lasttwo = String(toNumber.suffix(2)).insertingSpace(every: 1)
                    newConversation.avatar = OTRImages.avatarImage(withUsername: lasttwo)
                }
                
                newConversation.save()
                
                self.restoreMessages(conversation, smsConversation: newConversation)
            }
        }
    }
    
    func format(with mask: String, phone: String) -> String {
        let numbers = phone.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        var result = ""
        var index = numbers.startIndex // numbers iterator
        // iterate over the mask characters until the iterator of numbers ends
        for ch in mask where index < numbers.endIndex {
            if ch == "X" {
                // mask requires a number in this place, so take the next one
                result.append(numbers[index])

                // move numbers iterator to the next index
                index = numbers.index(after: index)

            } else {
                result.append(ch) // just append a mask character
            }
        }
        return result
    }

    public func conversationsClient(_ client: TwilioConversationsClient, conversationDeleted conversation: TCHConversation) {
        
        if let cid = conversation.sid, let smsconv = SMSChatConversationModel.existingConversation(with: cid) {
                smsconv.remove(completion: {})
        } else {
            print("Conversation deleted from server, but can't find locally to delete \(String(describing: conversation.sid))")
        }
    }

    // MARK: Typing changes
    public func conversationsClient(_ client: TwilioConversationsClient, typingStartedOn conversation: TCHConversation, participant: TCHParticipant) {
        //let conversation = TCHAdapter.transform(from: conversation)
        //let participant =  TCHAdapter.transform(from: participant)
        //typingPublisher.send(.startedTyping(conversation, participant))
    }

    public func conversationsClient(_ client: TwilioConversationsClient, typingEndedOn conversation: TCHConversation, participant: TCHParticipant) {
        //let conversation = TCHAdapter.transform(from: conversation)
        //let participant =  TCHAdapter.transform(from: participant)
        //typingPublisher.send(.stoppedTyping(conversation, participant))
    }
    
    // MARK: User changes
    public func conversationsClient(_ client: TwilioConversationsClient, user: TCHUser, updated update: TCHUserUpdate) {
        //if user.identity == myIdentity {
        //    myUser = user
        //}
    }
    
    // MARK: Message changes
    public func conversationsClient(_ client: TwilioConversationsClient, conversation: TCHConversation, messageAdded message: TCHMessage) {
        
        //DDLogInfo("TwilioConversationsClient messageAdded: \(message) from conversation: \(String(describing: conversation.sid))")
        
        var conv:SMSChatConversationModel?
        if let tid = conversation.sid {
            conv = SMSChatConversationModel.existingConversation(with: tid)
        }
        
        var senderId = conv?.grdbRecord?.smsAccountId
        var displayName = conv?.grdbRecord?.preferredName
        var isIncoming = false
        let author = message.author
        if author != self.identity {
            senderId = message.participantSid
            displayName = message.author
            isIncoming = true
        }
        
        //DDLogInfo("TwilioConversationsClient messageAdded \(isIncoming), conversation: \(String(describing: conv?.uniqueId)) sender \(String(describing: senderId)) displayname \(String(describing: displayName))")
        if isIncoming, let smsConversation = conv, let senderId = senderId, let displayName = displayName {
            let smsMessage = SMSChatMessageModel(conversationId: smsConversation.uniqueId, senderId: senderId, senderDisplayName: displayName, text: message.body, twilioSid: message.sid, date:message.dateCreatedAsDate)
            smsMessage.grdbRecord?.isIncoming = isIncoming
            
            smsConversation.grdbRecord?.latestMessageId = smsMessage.uniqueId
            smsConversation.grdbRecord?.latestMessage = nil
            smsMessage.save(completion: {
                if let smsConv = smsConversation.refetch() {
                    smsConv.grdbRecord?.latestMessageId = smsMessage.uniqueId
                    smsConv.grdbRecord?.latestMessage = nil
                    //if let mdate = smsMessage.grdbRecord?.messageDate {
                    //    smsConv.grdbRecord?.latestMessageDate = mdate
                    //}
                    smsConv.save()
                }
            })
                
            //DDLogInfo("TwilioConversationsClient messageAdded stored in DB")
            
            if (isIncoming && !message.attachedMedia.isEmpty) {
                for media in message.attachedMedia {
                    handleMedia(media, smsMessage: smsMessage, smsConversation: smsConversation)
                }
            }
        }
    }
    
    func handleMedia(_ media:Media, smsMessage:SMSChatMessageModel, smsConversation:SMSChatConversationModel) {
        self.internalQueue.async {
            media.getTemporaryContentUrl(completion: { result, url in
                guard result.isSuccessful else {
                    print("Couldn't get temporary urls with error: \(String(describing: result.error))")
                    return
                }

                if let mediaUrl = url {
                    let mediaRec = SMSChatMediaItem(uniqueId: smsMessage.uniqueId, parentObjectKey: smsMessage.uniqueId, parentThreadKey: smsConversation.uniqueId, transferProgress: 0.0, filename: "\(UUID().uuidString).jpg", modified: nil)
                    let mediaItem = SMSChatMediaItemModel(mediaItem: mediaRec)
                    
                    smsMessage.grdbRecord?.mediaItemUniqueId = mediaItem.uniqueId
                    //smsMessage.grdbRecord?.twilioSid = media.sid
                    mediaItem.save()
                    smsMessage.save()
                    
                    self.sessionManager.request(mediaUrl)
                        .validate()
                        .responseData(queue: self.internalQueue) { response in
                            switch response.result {
                            case .success:
                                self.finishDownload(smsMessage: smsMessage, mediaItem: mediaItem, inData: response.data, urlResponse: response.response, error: response.error)
                                return
                            case .failure(let error):
                                DDLogError("Error getting chat token: \(error)")
                                return
                            }
                        }.downloadProgress(queue: self.internalQueue) { progress in
                            
                            if let remedia = mediaItem.refetch() {
                                remedia.grdbRecord?.transferProgress = progress.fractionCompleted
                                remedia.save(completion: {
                                    smsMessage.touch()
                                })
                            }
                        }
                }
            })
        }
    }
    
    private func finishDownload(smsMessage: SMSChatMessageModel, mediaItem: SMSChatMediaItemModel, inData: Data?, urlResponse: URLResponse?, error: Error?) {
        
        if let error = error {
            DDLogError("Error downloading file \(error)")
            return
        }
        guard var _ = inData, let response = urlResponse, let _ = response.url else {
            DDLogError("SMS Media download No data or response")
            return
        }
        
        self.storeData(smsMessage: smsMessage, mediaItem: mediaItem, inData: inData)
    }
}

@objc public class GlacierSMS:NSObject {
    @objc public var selectedTwilionumber: [Dictionary<String,String>] = []
    @objc public var addUserToPurchaseNumbers:Bool = false
    @objc public var isSMSEnabled:Bool = false
    
    @objc public func getJson() -> String {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(self.selectedTwilionumber)
            if let jsonString = String(data: data, encoding: .utf8) {
                return jsonString
            }
        } catch {
          print(error)
        }
        
        return ""
    }
}

public protocol TwilioAccountDelegateProtocol:AnyObject {
    func availableNumbersUpdated(_ availableNumbers: [String])
    func setSelectedAccount(_ account: SMSChatAccountModel?)
    func accountsUpdated()
    func voicemailUpdated()
    func numbersControllerClosed()
}

public extension TwilioAccountDelegateProtocol {
    func availableNumbersUpdated(_ availableNumbers: [String]) {}
    func setSelectedAccount(_ account: SMSChatAccountModel?) {}
    func accountsUpdated() {}
    func voicemailUpdated() {}
    func numbersControllerClosed() {}
}

public protocol CallHistoryDelegateProtocol:AnyObject {
    func callHistoryUpdated(_ historyData: Data?)
    //func handleToken(_ token: String)
}

extension String {
    func insertingSpace(every n: Int) -> String {
        var result: String = ""
        let characters = Array(self)
        stride(from: 0, to: characters.count, by: n).forEach {
            result += String(characters[$0..<min($0+n, characters.count)])
            if $0+n < characters.count {
                result += " "
            }
        }
        return result
    }
}

public class VoicemailRecord:AnyObject {
    public var from:String?
    public var recordingSid:String?
    public var time:String?
    public var duration:String?
    public var callSid:String?
    public var to:String?
    public var url:String?
    public var status:String?
    var contact:PhoneContact?
}

struct TwilioResponse: Codable {
    let available_phone_numbers: [TwilioNumber]
}

struct TwilioNumber: Codable {
    let friendlyName: String
    let phoneNumber: String
    let region: String
}

struct GenericTwilioResponse: Codable {
    let message: String
}
