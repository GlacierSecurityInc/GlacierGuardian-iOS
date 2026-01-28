//  Glacier
//  Created by andyfriedman on 9/12/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation

public class ChatDownloadMessage: ChatMessageModel {
    
}

extension ChatDownloadMessage: DownloadMessage {
    public var parentKey: String? {
        get {
            self.grdbRecord?.parentObjectKey
        }
        set {
            self.grdbRecord?.parentObjectKey = newValue
        }
    }
    
    public var parentCollection: String? {
        get {
            ChatMessageModel.collection()
        }
    }
    
    public func parentMessage() -> MessageProtocol? {
        if let parentKey = self.parentKey {
            return ChatMessageModel.getMessage(with: parentKey)
        }
        return nil
    }
    
    public func touchParentMessage() {
        if let parentMsg = parentMessage() {
            parentMsg.touch()
        }
    }
    
    public static func download(parentMessage: MessageProtocol, url: URL, uniqueId: String?) -> DownloadMessage {
        let download:ChatDownloadMessage
        if let uid = uniqueId {
            download = ChatDownloadMessage(uniqueId: uid)
        } else {
            download = ChatDownloadMessage()
        }
        
        if let parent = parentMessage as? ChatMessageModel, let budid = parent.grdbRecord?.buddyUniqueId {
            download.grdbRecord?.buddyUniqueId = budid
        }
        download.grdbRecord?.url = url.absoluteString
        download.grdbRecord?.parentObjectKey = parentMessage.messageKey
        download.grdbRecord?.text = url.absoluteString
        download.grdbRecord?.originalText = parentMessage.messageOriginalText
        download.grdbRecord?.expires = parentMessage.messageExpires
        download.grdbRecord?.date = parentMessage.messageDate
        download.grdbRecord?.buddyUniqueId = parentMessage.threadId
        return download
    }
}

public extension UIAlertAction  {
    static func actionsFor(chatMediaMessage: MessageProtocol, viewController:UIViewController) -> [UIAlertAction] {
        
        var actions: [UIAlertAction] = []
        var url:URL?
        
        if let messageText = chatMediaMessage.messageText, messageText.count > 0 {
            
            // sometimes the scheme is aesgcm, which can't be shared normally
            if let maybeURL = URL(string: messageText), (maybeURL.scheme == "https" || maybeURL.scheme == "http") {
                url = maybeURL
            }
        }
        
        
        if let url = url {
            return Self.actionsFor(url: url, viewController: viewController)
        }
        
        return actions
    }
    
    static func actionsFor(url: URL, viewController:UIViewController) -> [UIAlertAction] {
        
        var actions: [UIAlertAction] = []
        
        let copyLinkAction = UIAlertAction(title: COPY_LINK_STRING(), style: UIAlertAction.Style.default, handler: { _ in
            UIPasteboard.general.url = url
        })
            
        let openInSafari = UIAlertAction(title: "Open in Default Browser", style: UIAlertAction.Style.default, handler: {  _ in
            //IOSM#7
            let visitURL = UIAlertAction(title: "Open", style: UIAlertAction.Style.default, handler: {  _ in
                UIApplication.shared.open(url)
            })
            let cancel = UIAlertAction(title: CANCEL_STRING(), style: UIAlertAction.Style.cancel, handler: nil)
                
            let warnAlert = UIAlertController(title: "Open external link?", message: "Opening links external to Glacier can be dangerous. It can also affect privacy if not protected with Glacier Core.", preferredStyle: UIAlertController.Style.alert)
                    
            warnAlert.addAction(visitURL)
            warnAlert.addAction(cancel)
            viewController.present(warnAlert, animated: true)
        })
            
        actions.append(copyLinkAction)
        actions.append(openInSafari)
        
        return actions;
    }
}
