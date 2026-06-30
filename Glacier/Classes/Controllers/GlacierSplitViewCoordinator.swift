//
//  GlacierSplitViewCoordinator.swift
//  ChatSecure
//
//  Created by David Chiles on 11/30/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

import Foundation

open class GlacierSplitViewCoordinator: NSObject, ConversationViewControllerDelegate, ChatComposeViewControllerDelegate, ComposeGroupViewControllerDelegate {
    
    @objc open var splitViewController:UISplitViewController? = nil
    
    open func enterConversationWithBuddies(_ buddyKeys:[String], accountKey:String, name:String?) {
        guard let splitVC = self.splitViewController else {
            return
        }
        
        if let appDelegate = Application.shared.delegate as? GlacierAppDelegate {
            let messagesVC = appDelegate.chatRoomViewController
            // Pass messagesVC directly (no new UINavigationController wrapper) so
            // that on iPhone showDetailViewController pushes it onto the master nav
            // controller. This keeps self.navigationController pointing at the master
            // nav controller, which owns the GlacierTabs tab bar view, allowing
            // viewWillAppear's subview search to find and hide it correctly.
            messagesVC.navigationItem.leftBarButtonItem = splitVC.displayModeButtonItem
            messagesVC.navigationItem.leftItemsSupplementBackButton = true
            splitVC.showDetailViewController(messagesVC, sender: nil)
            messagesVC.setup(with: buddyKeys, accountId: accountKey, name:name)
        }
    }

    public func enterConversation(withName name:String, isPublic:Bool) {
        self.splitViewController?.dismiss(animated: true)
        guard let splitVC = self.splitViewController else {
            return
        }

        if let appDelegate = Application.shared.delegate as? GlacierAppDelegate {
            let messagesVC = appDelegate.chatRoomViewController
            // See enterConversationWithBuddies: pass directly so viewWillAppear's
            // tab bar search works against the master nav controller's subviews.
            messagesVC.navigationItem.leftBarButtonItem = splitVC.displayModeButtonItem
            messagesVC.navigationItem.leftItemsSupplementBackButton = true
            splitVC.showDetailViewController(messagesVC, sender: nil)
            messagesVC.setupGroup(with:name, isPublic:isPublic)
        }
    }
    
    open func enterConversationWithBuddy(_ buddyKey:String) {
        if let buddy = ChatBuddyModel.getBuddy(uniqueId: buddyKey) {
            guard let appDelegate = Application.shared.delegate as? GlacierAppDelegate else {
                return
            }
            let mVC = appDelegate.chatViewController
            mVC.setThreadKey(buddy.uniqueId)
            self.setNavigation(mVC, sender: nil)
        }
    }
    
    open func enterConversationWithBuddy(_ buddy:ChatBuddy, sender:AnyObject?) {
        guard let appDelegate = Application.shared.delegate as? GlacierAppDelegate else {
            return
        }
        let mVC = appDelegate.chatViewController
        mVC.setThreadKey(buddy.uniqueId)
        self.setNavigation(mVC, sender: sender)
    }
    
    open func enterConversationWithRoom(_ room:ChatRoom, sender:AnyObject?) {
        guard let appDelegate = Application.shared.delegate as? GlacierAppDelegate else {
            return
        }
        let mVC = appDelegate.chatRoomViewController
        mVC.setThreadKey(room.uniqueId)
        self.setNavigation(mVC, sender: nil)
    }
    
    open func enterConversationWithThread(_ threadOwner:ChatThread, sender:AnyObject?) {
        let appDelegate = Application.shared.delegate as? GlacierAppDelegate
        
        if threadOwner.isGroupThread {
            guard let mVC = appDelegate?.chatRoomViewController, let room = ChatRoom.roomFromThread(threadOwner) else {
                return
            }
            //probably need to remove other viewController if was room
            
            //Set nav controller root view controller to mVC and then show detail with nav controller
            mVC.setThreadKey(room.uniqueId)
            self.setNavigation(mVC, sender: sender)
        } else {
            var bud = ChatBuddy.buddyFromThread(threadOwner)
            if bud == nil {
                bud = ChatBuddy.getBuddy(uniqueId: threadOwner.uniqueId)
            }
            
            guard let mVC = appDelegate?.chatViewController, let buddy = bud else {
                return
            }
            
            //Set nav controller root view controller to mVC and then show detail with nav controller
            mVC.setThreadKey(buddy.uniqueId)
            
            self.setNavigation(mVC, sender: sender)
        }
    }
    
    func setNavigation(_ cvc: UIViewController, sender:AnyObject?) {
        guard let splitVC = self.splitViewController else {
            return
        }
        
        //iPad check where there are two navigation controllers and we want the second one
        if splitVC.viewControllers.count > 1 && ((splitVC.viewControllers[1] as? UINavigationController)?.viewControllers.contains(cvc)) ?? false {
            //let navController = UINavigationController(rootViewController: cvc)
            //navController.topViewController!.navigationItem.leftBarButtonItem = splitVC.displayModeButtonItem;
            //navController.topViewController!.navigationItem.leftItemsSupplementBackButton = true;
            //splitVC.viewControllers[1] = navController
            //redo this for current!
            splitVC.showDetailViewController(cvc, sender: nil)
        } else if splitVC.viewControllers.count == 1 && ((splitVC.viewControllers.first as? UINavigationController)?.viewControllers.contains(cvc)) ?? false {
        } else {
            splitVC.showDetailViewController(cvc, sender: sender)
        }
    }
    
    //MARK: ConversationViewControllerDelegate Methods
    public func didSelectThread(_ threadOwner: ChatThreadModel, conversationViewController: ConversationViewController) {
        self.enterConversationWithThread(threadOwner.grdbRecord!, sender: conversationViewController)
    }
    
    public func didSelectCompose(_ conversationViewController: ConversationViewController) {
        let composeViewController = GlobalTheme.shared.composeViewController()
        if let composeViewController = composeViewController as? ChatComposeViewController {
            composeViewController.delegate = self
        }
        let modalNavigationController = UINavigationController(rootViewController: composeViewController)
        modalNavigationController.modalPresentationStyle = .formSheet
        
        //May need to use conversationViewController
        self.splitViewController?.present(modalNavigationController, animated: true, completion: nil)
    }
    
    //MARK:  ComposeGroupViewControllerDelegate
    public func groupSelectionCancelled(_ composeViewController: ComposeGroupViewController) {
        self.splitViewController?.dismiss(animated: true, completion: nil)
    }
    
    public func groupBuddiesSelected(_ composeViewController: ComposeGroupViewController, buddyUniqueIds: [String], groupName: String) {
        
        var accountId:String? = nil
        //let randomItem = Int(arc4random() % UInt32(buddyUniqueIds.count))
        let buddyKey = buddyUniqueIds[0]
        accountId = ChatBuddyModel.getBuddy(uniqueId: buddyKey)?.accountUniqueId
        
        func doClose () -> Void {
            let buds = buddyUniqueIds
            guard let accountKey = accountId else {
                return
            }
            
            if (buds.count == 1) {
                if let key = buds.first {
                    self.enterConversationWithBuddy(key)
                }
            } else if (buds.count > 1) {
                self.enterConversationWithBuddies(buds, accountKey: accountKey, name:groupName)
            }
        }
        
        
        if (self.splitViewController?.presentedViewController == composeViewController.navigationController) {
            self.splitViewController?.dismiss(animated: true) { doClose() }
        } else {
            doClose()
        }
    }
    
    //MARK: ChatComposeViewControllerDelegate Methods
    open func controller(_ viewController: ChatComposeViewController, didSelectBuddies buddies: [String], accountId: String?, name: String?) {

        func doClose () -> Void {
            guard buddies.count > 0,
                let accountKey = accountId else {
                    return
            }
            
            if (buddies.count == 1) {
                if let key = buddies.first {
                    self.enterConversationWithBuddy(key)
                }
            } else if buddies.count > 1 {
                let buds = buddies
                self.enterConversationWithBuddies(buds, accountKey: accountKey, name:name)
            }
        }
        
        if (self.splitViewController?.presentedViewController == viewController.navigationController) {
            self.splitViewController?.dismiss(animated: true) { doClose() }
        } else {
            doClose()
        }
    }
    
    open func controllerDidCancel(_ viewController: ChatComposeViewController) {
        self.splitViewController?.dismiss(animated: true, completion: nil)
    }
    
    @objc open func showConversationsViewController() {
        if self.splitViewController?.presentedViewController != nil {
            self.splitViewController?.dismiss(animated: true, completion: nil)
        }
    }
}

open class GlacierSplitViewControllerDelegateObject: NSObject, UISplitViewControllerDelegate {
    
    open func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController: UIViewController, onto primaryViewController: UIViewController) -> Bool {
        if (UIDevice.current.userInterfaceIdiom == UIUserInterfaceIdiom.pad) {
            return false
        }
        return true
    }

    
}
