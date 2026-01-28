//  Glacier
//  Created by andyfriedman on 9/7/22.
//  Copyright © 2022 Glacier. All rights reserved.

import Foundation

@objc open class SMSSplitViewCoordinator: NSObject, SMSViewControllerDelegate, SMSComposeViewControllerDelegate {
    @objc open var splitViewController:UISplitViewController? = nil
    
    open func enterSMSWithBuddy(_ conversationId:String) {
        if let conv = SMSChatConversationModel.getConversation(with: conversationId) {
            self.enterSMSWithThread(conv, sender: nil)
        }
    }
    
    @objc open func enterSMSWithThread(_ conversation:SMSChatConversationModel, sender:AnyObject?) {
        guard let splitVC = self.splitViewController else {
            return
        }
        
        let appDelegate = Application.shared.delegate as? OTRAppDelegate
        
        let messagesViewController:SMSChatViewController? = appDelegate?.smsMessagesViewController
        guard let mVC = messagesViewController else {
            return
        }
        
        //Set nav controller root view controller to mVC and then show detail with nav controller
        //changed from uinqueId IOSM#105
        if let tid = conversation.grdbRecord?.twilioId {
            mVC.setConversationKey(tid, collection: SMSChatConversationModel.collection())
        } else {
            mVC.setConversationKey(conversation.uniqueId, collection: SMSChatConversationModel.collection())
        }
        
        //iPad check where there are two navigation controllers and we want the second one
        if splitVC.viewControllers.count > 1 && ((splitVC.viewControllers[1] as? UINavigationController)?.viewControllers.contains(mVC)) ?? false {
            //IOSM#20
            splitVC.showDetailViewController(mVC, sender: nil)
        } else if splitVC.viewControllers.count == 1 && ((splitVC.viewControllers.first as? UINavigationController)?.viewControllers.contains(mVC)) ?? false {
        } else {
            splitVC.showDetailViewController(mVC, sender: sender)
        }
    }
    
    //MARK: SMSConversationViewControllerDelegate Methods
    public func didSelectThread(_ smsConversation: SMSChatConversationModel, smsViewController: SMSViewController) {
        self.enterSMSWithThread(smsConversation, sender: smsViewController)
    }
    
    public func didSelectCompose(_ smsViewController: SMSViewController, with account: String, number: String) {
        let smsComposeViewController = SMSComposeViewController()
        smsComposeViewController.delegate = self
        smsComposeViewController.setAccount(account, myNumber: number)
        let modalNavigationController = UINavigationController(rootViewController: smsComposeViewController)
        modalNavigationController.modalPresentationStyle = .formSheet
        self.splitViewController?.present(modalNavigationController, animated: true, completion: nil)
    }
    
    
    //MARK: SMSComposeViewControllerDelegate Methods
    @objc open func controller(_ viewController: SMSComposeViewController, didSelectBuddies buddies: [String]?, accountId: String?, name: String?) {

        func doClose () -> Void {
            guard let buds = buddies,
                  let _ = accountId else {
                    return
            }
            
            if (buds.count == 1) {
                if let key = buds.first {
                    self.enterSMSWithBuddy(key)
                }
            }
        }
        
        if (self.splitViewController?.presentedViewController == viewController.navigationController) {
            self.splitViewController?.dismiss(animated: true) { doClose() }
        } else {
            doClose()
        }
    }
    
    @objc open func controllerDidCancel(_ viewController: SMSComposeViewController) {
        self.splitViewController?.dismiss(animated: true, completion: nil)
    }
    
    @objc open func showConversationsViewController() {
        if self.splitViewController?.presentedViewController != nil {
            self.splitViewController?.dismiss(animated: true, completion: nil)
        }
    }
}

open class SMSViewControllerDelegateObject: NSObject, UISplitViewControllerDelegate {
    
    open func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController: UIViewController, onto primaryViewController: UIViewController) -> Bool {
        if (UIDevice.current.userInterfaceIdiom == UIUserInterfaceIdiom.pad) {
            return false
        }
        return true
    }

    
}

