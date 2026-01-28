//
//  UIApplication+ChatSecure.swift
//  ChatSecure
//
//  Created by David Chiles on 12/14/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

import Foundation
import MWFeedParser
import UserNotifications

public enum NotificationType {
    case subscriptionRequest
    case approvedBuddy
    case connectionError
    case chatMessage
    case smsMessage
    case voicemail
}

extension NotificationType: RawRepresentable {
    public init?(rawValue: String) {
        if rawValue == kOTRNotificationTypeSubscriptionRequest {
            self = .subscriptionRequest
        } else if rawValue == kOTRNotificationTypeApprovedBuddy {
            self = .approvedBuddy
        } else if rawValue == kOTRNotificationTypeChatMessage {
            self = .chatMessage
        } else if rawValue == kOTRNotificationTypeConnectionError {
            self = .connectionError
        } else if rawValue == kNotificationTwilioType {
            self = .smsMessage
        } else if rawValue == kNotificationVoicemailType {
            self = .voicemail
        } else {
            return nil
        }
    }
    
    public var rawValue: String {
        switch self {
        case .subscriptionRequest:
            return kOTRNotificationTypeSubscriptionRequest
        case .approvedBuddy:
            return kOTRNotificationTypeApprovedBuddy
        case .connectionError:
            return kOTRNotificationTypeConnectionError
        case .chatMessage:
            return kOTRNotificationTypeChatMessage
        case .smsMessage:
            return kNotificationTwilioType
        case .voicemail:
            return kNotificationVoicemailType
        }
    }
    
    public typealias RawValue = String
}

public extension UIApplication {
    
    /// Removes all but one foreground notifications for typing and message events sent from APNS
    @objc func removeExtraForegroundNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            var newMessageIdentifiers: [String] = []
            var typingIdentifiers: [String] = []
                
            notifications.forEach { notification in
                if notification.request.content.body == NEW_MESSAGE_STRING() {
                    newMessageIdentifiers.append(notification.request.identifier)
                } else if notification.request.content.body == SOMEONE_IS_TYPING_STRING() {
                    typingIdentifiers.append(notification.request.identifier)
                }
                //DDLogVerbose("notification delivered: \(notification)")
            }
            if newMessageIdentifiers.count > 1 {
                _ = newMessageIdentifiers.popLast()
            }
            if typingIdentifiers.count > 1 {
                _ = typingIdentifiers.popLast()
            }
            let allIdentifiers = newMessageIdentifiers + typingIdentifiers
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: allIdentifiers)
        }
    }
    
    @objc func showLocalNotification(_ message:MessageProtocol) {
        guard let thread = message.threadOwner(), OTRAppDelegate.appDelegate.silentUpdate == false else {
            return
        }
        
        DispatchQueue.main.async {
            
            if UIDevice.current.userInterfaceIdiom != .phone {
                return
            }
            
            let mediaItem = ChatMediaItemModel.getMediaItem(for: message)
            
            var threadName = ""
            var threadIdentifier:String?
            var threadCollection:String?
            if thread.isGroupThread() {
                if let room = ChatRoom.roomFromThread(thread.grdbRecord!) {
                    let roomModel = ChatRoomModel(room: room)
                    threadName = roomModel.threadName
                    threadIdentifier = roomModel.threadIdentifier
                    threadCollection = roomModel.threadCollection
                }
            } else {
                if let bud = ChatBuddy.buddyFromThread(thread.grdbRecord!) {
                    let budModel = ChatBuddyModel(buddy: bud)
                    threadName = budModel.threadName
                    threadIdentifier = budModel.threadIdentifier
                    threadCollection = budModel.threadCollection
                }
            }
            
            var text = "\(threadName)"
            
            // Show author of group messages
            if thread.isGroupThread() {
                //text = "#"+text
                if let displayName = message.xmppBuddy()?.displayName,
                   displayName.count > 0 {
                    text += " (\(displayName))"
                }
            }
            
            if mediaItem != nil, let mediaText = mediaItem?.getMediaDisplayText() {
                
                if let range = mediaText.range(of: "Location received") {
                    let locmsg = String(mediaText[range.lowerBound...])
                    text += ": \(locmsg)"
                } else {
                    text += ": \(mediaText)"
                }
                OTRAppDelegate.appDelegate.unreadMessageCount(completion: { [weak self] (unreadCount) in
                    self?.showLocalNotificationFor(threadIdentifier, threadCollection: threadCollection, text: text, unreadCount: unreadCount)
                })
                return
            } else if let msgTxt = message.messageText,
                      let rawMessageString = msgTxt.convertingHTMLToPlainText() {
                // Bail out of notification if this is an incoming encrypted file transfer
                if msgTxt.contains("aesgcm://") {
                    return
                }
                // for unencrypted media messages in group, was showing a link
                // likely not necessary when group has OMEMO
                if msgTxt.contains("https://") {//},
                   //message.downloads().count > 0 {
                    return
                }
                
                if rawMessageString.starts(with: "geo:") {
                    text += ": Location received"
                } else {
                    text += ": \(rawMessageString)"
                }
            } else {
                return
            }
            
            OTRAppDelegate.appDelegate.unreadMessageCount(completion: { [weak self] (unreadCount) in
                self?.showLocalNotificationFor(threadIdentifier, threadCollection: threadCollection, text: text, unreadCount: unreadCount)
            })
        }
    }
    
    @objc func showLocalNotificationForSubscriptionRequestFrom(_ jid:String?) {
        DispatchQueue.main.async {
            var name = SOMEONE_STRING()
            if let jidName = jid {
                name = jidName
                
                let namecomponents = name.components(separatedBy: "@")
                if (namecomponents.count == 2 && namecomponents[0].count > 0) {
                    name = namecomponents[0]
                }
            }
            
            let chatString = WANTS_TO_CHAT_STRING()
            let text = "\(name) \(chatString)"
            let unreadCount = self.applicationIconBadgeNumber + 1
            self.showLocalNotificationWith(identifier: nil, body: text, badge: unreadCount, userInfo: [kOTRNotificationType:kOTRNotificationTypeSubscriptionRequest], recurring: false)
        }
    }
    
    @objc func showLocalNotificationForApprovedBuddy(_ thread:ChatBuddyModel?) {
        guard let thread = thread else { return } // , !thread.isMuted No notifications for muted
        DispatchQueue.main.async {
            var name = SOMEONE_STRING()
            if thread.displayName.count > 0 {
                name = thread.displayName
            } else if !thread.threadName.isEmpty {
                name = thread.threadName
            }
            
            let message = String(format: BUDDY_APPROVED_STRING(), name)
            let unreadCount = self.applicationIconBadgeNumber + 1
            let identifier = thread.threadIdentifier
            let userInfo:[AnyHashable:Any] = [kOTRNotificationThreadKey:identifier,
                                              kOTRNotificationThreadCollection:thread.threadCollection,
                                              kOTRNotificationType: kOTRNotificationTypeApprovedBuddy]
            self.showLocalNotificationWith(identifier: identifier, body: message, badge: unreadCount, userInfo: userInfo, recurring: false)
        }
    }
    
    internal func showLocalNotificationFor(_ threadId:String?, threadCollection:String?, text:String, unreadCount:Int) {
        //if let threadId = threadId { return } // , !thread.isMuted No notifications for muted
        DispatchQueue.main.async {
            var identifier:String? = threadId
            var userInfo:[AnyHashable:Any]? = nil
            if let tid = threadId, let tcoll = threadCollection {
                identifier = tid
                userInfo = [kOTRNotificationThreadKey:tid,
                            kOTRNotificationThreadCollection:tcoll,
                            kOTRNotificationType: kOTRNotificationTypeChatMessage]
            }
            self.showLocalNotificationWith(identifier: identifier, body: text, badge: unreadCount, userInfo: userInfo, recurring: false)
        }
    }
    
    @objc func showLocalNotificationWith(identifier:String?, body:String, badge:Int, userInfo:[AnyHashable:Any]?, recurring:Bool) {
        DispatchQueue.main.async {
            if recurring, self.hasRecurringLocalNotificationWith(identifier: identifier) {
                return // Already pending
            }
            
            guard OTRAppDelegate.appDelegate.silentUpdate == false else {
                return
            }
            
            // message from user display name without domain/address
            var bodyslim = body
            let msgparts = body.components(separatedBy: ":")
            if (msgparts.count >= 2) {
                let namecomponents = msgparts[0].components(separatedBy: "@")
                if (namecomponents.count == 2) {
                    if let range = body.range(of: ":") {
                        //let msgtext = body.substring(from: range.lowerBound)
                        let msgtext = String(body[range.lowerBound...])
                        bodyslim = namecomponents[0] + msgtext;
                    }
                }
            }
            
            if bodyslim.contains(" - tap to reset") {
                bodyslim = bodyslim.components(separatedBy: " - tap to")[0]
            }
            
            let localNotification = UNMutableNotificationContent()
            localNotification.body = bodyslim
            localNotification.badge = NSNumber(integerLiteral: badge)
                
            // use non-default alert sound
            let sound = UNNotificationSoundName(rawValue: "NewMessageAlert.wav")
            localNotification.sound = UNNotificationSound(named: sound)
                
            if let identifier = identifier {
                localNotification.threadIdentifier = identifier
            }
            if let userInfo = userInfo {
                localNotification.userInfo = userInfo
            }
            var trigger:UNNotificationTrigger? = nil
            if recurring {
                var date = DateComponents()
                date.hour = 11
                date.minute = 0
                trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: localNotification, trigger: trigger) // Schedule the notification.
            let center = UNUserNotificationCenter.current()
            center.add(request, withCompletionHandler: { (error: Error?) in
                if let error = error as NSError? {
                    #if DEBUG
                        NSLog("Error scheduling notification! %@", error)
                    #endif
                }
            })
        }
    }
    
    @objc func hasRecurringLocalNotificationWith(identifier:String?) -> Bool {
        return hasRecurringLocalNotificationWith(identifier:identifier, cancelIfFound:false)
    }

    @objc @discardableResult func cancelRecurringLocalNotificationWith(identifier:String?) -> Bool {
        return hasRecurringLocalNotificationWith(identifier:identifier, cancelIfFound:true)
    }

    func hasRecurringLocalNotificationWith(identifier:String?, cancelIfFound:Bool) -> Bool {
            guard let identifier = identifier else { return false }

        var found = false
        
        UNUserNotificationCenter.current().getPendingNotificationRequests(completionHandler:{ (requests:[UNNotificationRequest]) in
            for request in requests {
                let userInfo = request.content.userInfo
                if let threadKey =
                    userInfo[kOTRNotificationThreadKey] as? String, threadKey == identifier {
                    found = true
                    if cancelIfFound {
                        let center = UNUserNotificationCenter.current()
                        center.removePendingNotificationRequests(withIdentifiers:[request.identifier])
                    }
                }
            }
        })
        
        return found
    }
    
    @objc func showRebootNotification() {
        //DispatchQueue.main.async {
            let localNotification = UNMutableNotificationContent()
            localNotification.title = "Reminder to reboot"
            localNotification.body = "Rebooting your device helps maintain iOS security and protects against potential threats."
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: localNotification, trigger: nil) // Schedule the notification.
            let center = UNUserNotificationCenter.current()
            center.add(request, withCompletionHandler: { (error: Error?) in
                if let error = error as NSError? {
#if DEBUG
                    NSLog("Error scheduling notification! %@", error)
#endif
                }
            })
        //}
    }
    
    /// show a notification when there is an issue connecting, for instance expired certificate
    @objc func showConnectionErrorNotification(account: ChatAccountModel, error: NSError) {
        let username = account.displayName
        var body = "\(CONNECTION_ERROR_STRING()) \(username)."
        
        if error.domain == GCDAsyncSocketErrorDomain,
           let code = GCDAsyncSocketError.Code(rawValue: error.code) {
            
            switch code {
            case .noError,
                    .connectTimeoutError,
                    .readTimeoutError,
                    .writeTimeoutError,
                    .readMaxedOutError,
                    .closedError:
                return
            case .badConfigError, .badParamError:
                body = body + " \(error.localizedDescription)."
            case .otherError:
                // this is probably a SSL error
                body = body + " \(CONNECTION_ERROR_CERTIFICATE_VERIFY_STRING())"
                if let certData = error.userInfo[OTRXMPPSSLCertificateDataKey] as? Data,
                   let hostname = error.userInfo[OTRXMPPSSLHostnameKey] as? String,
                   OTRCertificatePinning.publicKey(withCertData: certData) != nil {
                    OTRCertificatePinning.addCertificateData(certData, withHostName: hostname)
                    return
                }
            }
        } else if error.domain == "kCFStreamErrorDomainSSL" {
            body = body + " \(CONNECTION_ERROR_CERTIFICATE_VERIFY_STRING())"
            let osStatus = OSStatus(error.code)
            
            // Ignore a few SSL error codes that might be more annoying than useful
            //                errSSLClosedGraceful         = -9805,    /* connection closed gracefully */
            //                errSSLClosedAbort             = -9806,    /* connection closed via error */
            let codesToIgnore = [errSSLClosedAbort, errSSLClosedGraceful]
            if codesToIgnore.contains(osStatus) {
                return
            }
            
            if let certData = error.userInfo[OTRXMPPSSLCertificateDataKey] as? Data,
                let hostname = error.userInfo[OTRXMPPSSLHostnameKey] as? String,
                OTRCertificatePinning.publicKey(withCertData: certData) != nil {
                OTRCertificatePinning.addCertificateData(certData, withHostName: hostname)
                return
            }
            
            // SSL error occurs when connection closes
            // but without any data and so causes alert. Often this is at the
            // same time as the certificate is being added from another place
            if (OTRCertificatePinning.isAddingCert()) {
                return
            }
            
            if let sslString = OTRXMPPError.errorString(withSSLStatus: osStatus) {
                body = body + " \"\(sslString)\""
            }
        } else if error.domain == "com.glaciersecurity" && error.code == 1005 {
            //body = body + " Notify Glacier admin."
        } else {
            // unrecognized error domain... ignoring
            return
        }
        
        let accountKey = account.uniqueId
        let badge = Application.shared.applicationIconBadgeNumber + 1
        
        let userInfo = [kOTRNotificationType: kOTRNotificationTypeConnectionError,
                        kOTRNotificationAccountKey: accountKey]
        
        UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler: { (notifications) in
            // FIXME: this deduplication code doesn't seem to work
            // if we are already showing a notification, let's not spam the user too much with more of them
            for notification in notifications {
                if notification.request.identifier == accountKey {
                    return
                }
            }
            self.showLocalNotificationWith(identifier: accountKey, body: body, badge: badge, userInfo: userInfo, recurring: false)
        })
    }
}

@objc open class Application: NSObject {
  @objc static var shared: UIApplication {
    let sharedSelector = NSSelectorFromString("sharedApplication")
    guard UIApplication.responds(to: sharedSelector) else {
      fatalError("[Extensions cannot access Application]")
    }
    let shared = UIApplication.perform(sharedSelector)
    return shared?.takeUnretainedValue() as! UIApplication
  }
}
