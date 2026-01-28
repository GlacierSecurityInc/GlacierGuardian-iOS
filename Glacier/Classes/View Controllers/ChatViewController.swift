//
//  ChatViewController.swift
//  Glacier
//
//  Created by andyfriedman on 9/6/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import UIKit
import SwiftUI
import InputBarAccessoryView
import MessageKit
import GRDB
import PureLayout
import MBProgressHUD
import FormatterKit
import GiphyUISDK
import MobileCoreServices
import AVKit
import KVOController
import Floaty
import Kingfisher
import LinkPresentation
import MapKit
import XMPPFramework
import MCEmojiPicker
//import DifferenceKit

@objc open class ChatViewController: MessagesViewController, MessagesDataSource, CallStatusDelegateProtocol, KeyboardObservable {
    
    public var currentSender: MessageKit.SenderType {
        return self.sender
    }
    
    public static var detectorAttributes: [NSAttributedString.Key: Any] = {
      [
        NSAttributedString.Key.foregroundColor: UIColor.label,
        NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue,
        NSAttributedString.Key.underlineColor: UIColor.label,
      ]
    }()
    
    static let kOTRMessageSentDateShowTimeInterval:TimeInterval = 60 * 60 * 12
    static let kOTRMessagePageSize = 50
    
    static let IS_IPHONE = (UIDevice.current.userInterfaceIdiom == .phone)
    static let IS_IPHONE_X = (IS_IPHONE && (UIScreen.main.bounds.size.height >= 812.0))
    static let IPHONE_STATUSBAR_HEIGHT = (IS_IPHONE_X ? 35 : 20)
    
    private var chatMsgCancellable: DatabaseCancellable?
    let dsQueue:DispatchQueue = DispatchQueue(label: "MVCDataSource")
    
    lazy var sender: MessageKit.SenderType = ChatUser(senderId: "", displayName: "")
    var fromAvatar: Avatar?
    var toAvatar: Avatar?
    
    //let supplementaryViewHandler:SupplementaryViewHandler?
    var threadKey:String?
    var xmppMgr:XMPPManager?
    var account:ChatAccountModel?
    var threadOwner:ChatThread?
    var buddy:ChatBuddy?
    var microphoneButton = UIButton(type: .roundedRect)
    var cameraButton = UIButton(type: .roundedRect)
    var attachButton = UIButton(type: .roundedRect)

    var moreOptionsButton = UIButton(type: .roundedRect)
    var hourglassButton = UIButton(type: .roundedRect)

    var state = MessagesViewControllerState.init()
    var automaticURLFetchingDisabled = false
    lazy var floaty = Floaty()
    var zeroTextLayout = ZeroSizeCalculator()

    fileprivate var deviceListUpdateNotificationObject:NSObjectProtocol?

    var attachmentPicker:OTRAttachmentPicker?
    lazy var audioPlaybackController = AudioPlaybackController(messageCollectionView: messagesCollectionView)

    var lastSeenRefreshTimer:Timer?
    
    var keyboardHeight: CGFloat = 0

    fileprivate var loadingMessages = false
    fileprivate var loadingMoreMessages = false
    fileprivate var messagePage = 1
    //fileprivate var currentIndexPath:IndexPath?
    //fileprivate var currentMessage:ChatMessage?
    fileprivate var messagesAdded = 0
    fileprivate var updatedSource = false
    fileprivate var initRequest = false
    fileprivate var justSent = false
    //fileprivate var waitingToObserve = false
    fileprivate let messageSizeCache:NSCache<NSString, GlacierValue> = NSCache.init()
    fileprivate let messageBottomCache:NSCache<NSString, GlacierFloat> = NSCache.init()
    fileprivate let cellTopCache:NSCache<NSString, GlacierFloat> = NSCache.init()
    fileprivate let expiringCache:NSCache<NSString, NSString> = NSCache.init()
    fileprivate var redrawSet:Set<IndexPath> = []
    fileprivate var retriedSet:Set<String> = []
    fileprivate var activelyFetching:Set<String> = []

    fileprivate var longIndex:IndexPath?
    fileprivate var longPressGestureRecognizer:UILongPressGestureRecognizer!
    fileprivate var latestDateDisplayed:Date?
    
    fileprivate var showConnStatus = true
    fileprivate var titleView = OTRTitleSubtitleView(frame: CGRectMake(0, 0, 200, 44))
    fileprivate var expiringRefreshTimer:Timer?
    static fileprivate var exptf:TTTTimeIntervalFormatter = TTTTimeIntervalFormatter()
    fileprivate var statusTimer:Timer?
    var statusCtr = 0
    var statusTapGestureRecognizer:UITapGestureRecognizer!
    var uploadHUD:MBProgressHUD?
    lazy var agrumeVC = ImageViewHelper()

    var phoneButton:UIButton = UIButton(type: .custom)
    var accountAvatarImage:UIImage?
    fileprivate var originalAudioCategory:AVAudioSession.Category?
    
    //NSAttributedString.Key.font: UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.systemFont(ofSize: 10))
    //UIFont.preferredFont(forTextStyle: .caption2)
    fileprivate let attrs = [NSAttributedString.Key.font: UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.systemFont(ofSize: 10)), NSAttributedString.Key.foregroundColor: UIColor.lightGray]
    fileprivate let faattrs = [NSAttributedString.Key.font:UIFont(name: kFontAwesomeFont, size: 11) ?? UIFont.systemFont(ofSize: 11), NSAttributedString.Key.foregroundColor: UIColor.lightGray]
    
    let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                            .memoryCacheExpiration(.days(14)),
                                             .memoryCacheAccessExtendingExpiration(.cacheTime)]

    //var currentmgr:XMPPManager?
    var loginStatusToken: NSKeyValueObservation?
    
    private var chatMessages:[ChatMessage] = []
    private var latestdata = [ChatMessage]()
    private var shownMessages = [ChatMessage]()
    private var isShowingContextMenu = false
    private var selectedChatAccount: ChatAccountModel?
    private let collectionUpdateQueue = DispatchQueue(label: "com.glacier.chat.collection-updates", target: .main)
    
    override public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        
        self.messageSizeCache.countLimit = 1000
        self.messageBottomCache.countLimit = 1000
        self.cellTopCache.countLimit = 1000
        
        //IOSM#69 setup Giphy
        if let token = Bundle.main.object(forInfoDictionaryKey: "GiphyAPIToken") as? String {
            Giphy.configure(apiKey: token)
        }
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.lastSeenRefreshTimer?.invalidate()
        self.expiringRefreshTimer?.invalidate()
        
        if let deviceList = self.deviceListUpdateNotificationObject {
            NotificationCenter.default.removeObserver(deviceList)
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        configureMessageCollectionView()
        configureMessageInputBar()
        
        let pos = AvatarPosition(vertical: .messageBottom)
        messagesCollectionView.messagesCollectionViewFlowLayout.setMessageIncomingAvatarPosition(pos)
        messagesCollectionView.messagesCollectionViewFlowLayout.setMessageOutgoingAvatarPosition(pos)
        zeroTextLayout = ZeroSizeCalculator(layout: messagesCollectionView.messagesCollectionViewFlowLayout)

        //self.additionalContentInset = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        self.showConnStatus = true
        
        //for expiring message timer
        //self.exptf = TTTTimeIntervalFormatter()
        ChatViewController.exptf.futureDeicticExpression = "left"
        ChatViewController.exptf.usesAbbreviatedCalendarUnits = true
 
        ////// TitleView //////
        self.titleView = OTRTitleSubtitleView(frame: CGRectMake(0, 0, 200, 44))
        self.navigationItem.titleView = self.titleView
        self.refreshTitleView()
        
        // Hide any default or empty left bar button items
        self.navigationItem.leftBarButtonItem = nil
        self.navigationItem.leftBarButtonItems = nil
        self.navigationItem.leftItemsSupplementBackButton = false
        
        /*let backIcon = UIImage(systemName: "chevron.right")
        //self.navigationItem.leftBarButtonItem = UIBarButtonItem(image: backIcon, menu: nil)
        self.navigationItem.backBarButtonItem = UIBarButtonItem(image: backIcon, menu: nil)*/
        
        
        /*let backButtonBackgroundImage = UIImage(systemName: "chevron.right")
        let barAppearance = UINavigationBar.appearance(whenContainedInInstancesOf: [ChatViewController.self])
        barAppearance.backIndicatorImage = backButtonBackgroundImage
        barAppearance.backIndicatorTransitionMaskImage = backButtonBackgroundImage
        let backBarButton = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        navigationItem.backBarButtonItem = backBarButton*/
        
        
        self.titleView.subtitleLabel.text = nil
        //self.inputToolbar.contentView.textView.pasteDelegate = self
        
        self.statusCtr = 0
        self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)

        self.titleView.dynConnectingView.isHidden = true
        
        self.messagesCollectionView.reloadData()
        self.messagesCollectionView.scrollToLastItem(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.messagesCollectionView.scrollToLastItem(animated: false)
        }
        
        ////// Attachment Button //////
        //self.inputToolbar.contentView.leftBarButtonItem = nil
        self.cameraButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 20)
        self.cameraButton.titleLabel?.textAlignment = NSTextAlignment.center
        let cameraIconChar: UniChar = 0xf030
        self.cameraButton.setTitle(String(format: "%C", cameraIconChar), for: .normal)
        self.cameraButton.frame = CGRectMake(0, 0, 32, 32)
        self.cameraButton.tintColor = UIColor.bubbleBlue()
        
        self.moreOptionsButton.frame = CGRectMake(0, 0, 32, 32)
        self.moreOptionsButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 20)
        self.moreOptionsButton.titleLabel?.textAlignment = NSTextAlignment.center
        let chevronRightChar: UniChar = 0xf054
        self.moreOptionsButton.setTitle(String(format: "%C", chevronRightChar), for: .normal)
        self.moreOptionsButton.tintColor = UIColor.bubbleBlue()
        //self.inputToolbar.contentView.leftBarButtonItem = self.moreOptionsButton
        
        self.attachButton.frame = CGRectMake(0, 0, 32, 32)
        self.attachButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 20)
        self.attachButton.titleLabel?.textAlignment = NSTextAlignment.center
        let paperclipIconChar: UniChar = 0xf0c6
        self.attachButton.setTitle(String(format: "%C", paperclipIconChar), for: .normal)
        self.attachButton.tintColor = UIColor.bubbleBlue()
        
        // for expiring messgages
        self.hourglassButton.frame = CGRectMake(32, 0, 32, 32)
        self.hourglassButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 20)
        self.hourglassButton.titleLabel?.textAlignment = NSTextAlignment.center
        let hourglassIconChar: UniChar = 0xf251
        self.hourglassButton.setTitle(String(format: "%C", hourglassIconChar), for: .normal)
        self.hourglassButton.tintColor = UIColor.bubbleBlue()
        
        ////// Microphone Button //////
        self.microphoneButton.frame = CGRectMake(0, 0, 32, 32)
        self.microphoneButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 20)
        self.microphoneButton.titleLabel?.textAlignment = NSTextAlignment.center
        let microphoneIconChar: UniChar = 0xf130
        self.microphoneButton.setTitle(String(format: "%C", microphoneIconChar), for: .normal)
        self.microphoneButton.tintColor = UIColor.bubbleBlue()
        
        self.setupLongPress()
        
        ////// TextViewUpdates //////
        NotificationCenter.default.addObserver(self, selector: #selector(enteringBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(enteringForegroundStatus), name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(becameActiveStatus), name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleLoginSuccess), name: NSNotification.Name(rawValue: kOTRProtocolLoginSuccess), object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(didDeleteAllChatMessages), name: NSNotification.Name(rawValue: kDidDeleteAllChatMessages), object: nil)
        
        registerKeyboardNotifications()
        
        self.statusTapGestureRecognizer = UITapGestureRecognizer.init(target: self, action: #selector(handleStatusGesture))
        self.statusTapGestureRecognizer.numberOfTapsRequired = 1
        
        if xmppManager() != nil {
            //self.xmppMgr = xmpp  //IOSM#22 change to _currentmgr
            loginStatusToken = self.xmppMgr?.observe(\.loginStatus, options: [.new, .old], changeHandler: {[weak self](xmpp, change) in
                self?.setConnectionStatus()
            })
            self.xmppMgr?.callManager.setCallStatusDelegate(self) //IOSM-527b
        }
    }
    
    @objc func didDeleteAllChatMessages() {
        self.shownMessages.removeAll()
        self.chatMessages.removeAll()
        self.messagesCollectionView.reloadData()
        self.updatedSource = true
    }
    
    open override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        self.tryToMarkAllMessagesAsRead()
        //redo RenderNeeded
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.loadingMessages = false
        }
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        audioPlaybackController.stopAnyOngoingPlaying()
        unregisterKeyboardNotifications()
      }
    
    open override func viewWillAppear(_ animated: Bool) {
        //self.currentIndexPath = nil
        super.viewWillAppear(animated)
        
        if let navigationController = self.navigationController {
            for subview in navigationController.view.subviews {
                if let tabBar = subview as? UITabBar {
                    tabBar.isHidden = true
                    break
                }
            }
        }
        
        self.expiringRefreshTimer?.invalidate()
        self.expiringRefreshTimer = nil
        self.expiringRefreshTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateForExpiringMessages), userInfo: nil, repeats: true)
        
        self.lastSeenRefreshTimer?.invalidate()
        self.lastSeenRefreshTimer = nil
        self.lastSeenRefreshTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(refreshTitleTimerUpdate), userInfo: nil, repeats: true)
        
        if self.statusTimer == nil { //IOSM#22
            self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
        }
        
        if let tkey = self.threadKey, tkey.count > 0 {
            self.updateView(with: tkey)
            if self.messageInputBar.inputTextView.text.count == 0 {
                self.moveLastComposingTextForThreadKey()
            }
        } else {
            self.messageInputBar.inputTextView.isEditable = false
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(networkConnectionStatusChange), name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: nil)
        
        self.showConnStatus = true
        self.setConnectionStatus()
        
        //self.messageSizeCache.removeAllObjects()
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.expiringRefreshTimer?.invalidate()
        self.expiringRefreshTimer = nil
        
        self.lastSeenRefreshTimer?.invalidate()
        self.lastSeenRefreshTimer = nil
        
        self.saveCurrentMessageText(self.messageInputBar.inputTextView.text, key: self.threadKey)
        
        self.handleScreenDisappearing() //IOSM#60
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: nil)
        
        self.addStatusGestures(false)
    }
    
    open override func viewWillLayoutSubviews() {
        //self.currentIndexPath = nil
        super.viewWillLayoutSubviews()
    }
    
    open override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        GlacierImageCache.shared().clearMemoryCache()
    }
    
    private func initialRequest() {
        guard let convid = self.threadKey else {return}
        self.loadingMessages = true
        self.initRequest = true
        var asec:[ChatMessage] = []
        self.shownMessages = asec
        let messages = ChatMessage.allChatMessages(for: convid, limit: ChatViewController.kOTRMessagePageSize)
        self.chatMessages = messages
        
        for msg in messages {
            asec.insert(msg, at: 0)
        }
        
        self.shownMessages = asec
        self.messagesCollectionView.reloadData()
        
        self.messagesCollectionView.scrollToLastItem(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.messagesCollectionView.scrollToLastItem(animated: false)
        }
    }
    
    private func observeConversations() {
        guard let convid = self.threadKey else {return}
        
        let request = ChatMessage.all().filter(Column("buddyUniqueId") == convid).order(Column("date").desc)
            
        chatMsgCancellable = ValueObservation
            .tracking(request.fetchAll(_:))
            .start(
                in: DBManager.sharedDB().grdbStorage.pool,
                // Immediate scheduling feeds the data source right on subscription,
                // and avoids an undesired animation when the application starts.
                scheduling: .async(onQueue: dsQueue), //.immediate,
                onError: { error in fatalError("Unexpected error: \(error)") },
                onChange: { [weak self] messages in
                    guard let self else { return }
                    self.updateDataSource(from: messages)
                })
    }
    
    private func updateDataSource(from messages: [ChatMessage]) {
        let diffcnt = messages.count - self.chatMessages.count
        if self.updatedSource, diffcnt > 0 {
            self.messagesAdded += diffcnt
        }
        
        self.chatMessages = messages
        let msgs = messages
        var asec = [ChatMessage]()
        
        var endIndex = messages.count
        let showCount = (ChatViewController.kOTRMessagePageSize * self.messagePage) + self.messagesAdded
        if endIndex > showCount {
            endIndex = showCount
        }
        
        var latestDisplayed:Date = .distantPast
        for i in 0..<endIndex {
            let msg = msgs[i]
            asec.insert(msg, at: 0)
            //check for displayed, set latest
            if let latest = msg.dateDisplayed, latest > latestDisplayed {
                latestDisplayed = latest
            }
        }
        self.latestDateDisplayed = latestDisplayed
        //print("***** showCount \(showCount), endIndex \(endIndex), asec size \(asec.count), first \(asec[0].elements[0].text), final \(asec[asec.count-1].elements[0].text)")
        
        let needsTimer = (self.latestdata.count == 0 && messages.count > 0)
        self.latestdata = asec
        if self.justSent == true {
            self.justSent = false
            self.dsQueue.async {
                self.handleUpdates()
            }
        } else if needsTimer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.dsQueue.async {
                    self.handleUpdates()
                }
            }
        }
        
        
        if self.updatedSource == false {
            //DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.updatedSource = true
            //}
        }
    }
    
    private enum MessagePresentationCategory {
        case text
        case media
        case location
        case custom
    }

    private func messagePresentationCategory(for message: MessageType) -> MessagePresentationCategory {
        if case .location = message.kind {
            return .location
        }
        if case .photo = message.kind {
            return .media
        }
        if case .video = message.kind {
            return .media
        }
        if case .audio = message.kind {
            return .media
        }
        if case .contact = message.kind {
            return .media
        }
        if case .custom = message.kind {
            return .custom
        }
        return .text
    }

    private func handleUpdates() {
        let latestmsgs = self.latestdata
        if latestmsgs.count == 0, self.shownMessages.count > 1 {
            return
        }
        
        let data = self.shownMessages
        self.latestdata.removeAll()

        if data.isEmpty {
            guard latestmsgs.isEmpty == false else { return }

            DispatchQueue.main.async {
                self.initRequest = false
                self.shownMessages = latestmsgs
                if self.loadingMoreMessages {
                    self.loadingMoreMessages = false
                }
                self.messagesCollectionView.reloadData()
                self.scrollIfAppropriate()
            }

            return
        }

        var reload = false
        var reloadIndexSet = IndexSet()
        let dataSet = Set(data.map { $0.uniqueId })
        let latestSet = Set(latestmsgs.map { $0.uniqueId })
        let diffcount = dataSet.subtracting(latestSet).count
        let addcount = latestSet.subtracting(dataSet).count
        
        var shownDict = Dictionary<String, ChatMessage>()
        shownDict = data.reduce(into: shownDict) { result, msg in result[msg.uniqueId] = msg }
        
        if diffcount > 0 {
            reload = true
        }
        var indexstart = 0
        if addcount > 0 {
            reload = true
            indexstart = latestmsgs.count-addcount-1
            if indexstart >= 0, latestmsgs.count > indexstart {
                let msgid = latestmsgs[indexstart].uniqueId
                let cmsgid = msgid as NSString
                self.messageSizeCache.removeObject(forKey: cmsgid)
                self.messageBottomCache.removeObject(forKey: cmsgid)
                self.cellTopCache.removeObject(forKey: cmsgid)
            }
        }
        
        for (index,msg) in latestmsgs.enumerated() {
            if let oldmsg = shownDict[msg.uniqueId] {
                if msg.modified != oldmsg.modified || msg.reactionsCount != oldmsg.reactionsCount {
                    let msgid = msg.uniqueId as NSString
                    self.messageSizeCache.removeObject(forKey: msgid)
                    self.messageBottomCache.removeObject(forKey: msgid)
                    reloadIndexSet.insert(index)
                    
                    if index > 0 {
                        let prevmsg = latestmsgs[index-1]
                        let pmsgid = prevmsg.uniqueId as NSString
                        self.messageSizeCache.removeObject(forKey: pmsgid)
                        self.messageBottomCache.removeObject(forKey: pmsgid)
                        reloadIndexSet.insert(index-1)
                    }
                    if index+1 < latestmsgs.count {
                        let nextmsg = latestmsgs[index+1]
                        let nmsgid = nextmsg.uniqueId as NSString
                        self.messageSizeCache.removeObject(forKey: nmsgid)
                        self.messageBottomCache.removeObject(forKey: nmsgid)
                        reloadIndexSet.insert(index+1)
                    }
                }
            }
        }
        
        if diffcount == 0, addcount == 0, reloadIndexSet.count == 0 {
            return
        }
        
        self.collectionUpdateQueue.async {
            guard self.messagesCollectionView.numberOfSections == data.count || self.messagesCollectionView.numberOfSections == self.shownMessages.count else {
                self.shownMessages = latestmsgs
                self.messagesCollectionView.reloadDataAndKeepOffset()
                return
            }

            let beforeContentSize = self.messagesCollectionView.contentSize
            if self.loadingMoreMessages { //} || (diffcount > 0 && addcount <= 1){
                self.messagesCollectionView.setContentOffset(self.messagesCollectionView.contentOffset, animated: false) // stop scrolling
            }
            self.initRequest = false
            
            self.shownMessages = latestmsgs
            if reload {
                if diffcount > 0 {
                    self.messagesCollectionView.reloadDataAndKeepOffset()
                } else {
                    let indexSet = IndexSet(indexstart+1..<latestmsgs.count)
                    let currentSections = self.messagesCollectionView.numberOfSections
                    if currentSections != data.count || indexSet.isEmpty {
                        self.messagesCollectionView.reloadDataAndKeepOffset()
                        return
                    }

                    self.messagesCollectionView.insertSections(indexSet)

                    var ips:[IndexPath] = []
                    reloadIndexSet.insert(indexstart)
                    var reconfigure = true
                    for idx in reloadIndexSet {
                        let ip = IndexPath(row: 0, section: idx)
                        ips.append(ip)
                        //if new is of different type or timestamp than old, reload instead of reconfigure
                        if latestmsgs.count > idx, data.count > idx, idx >= 0, latestmsgs[idx].uniqueId != data[idx].uniqueId {
                            reconfigure = false
                        } else if latestmsgs.count > idx, data.count > idx {
                            let newCategory = self.messagePresentationCategory(for: latestmsgs[idx])
                            let oldCategory = self.messagePresentationCategory(for: data[idx])
                            if newCategory != oldCategory {
                                reconfigure = false
                            }
                        }
                    }
                    //print("***** reload ips: \(ips)")
                    if reconfigure == true {
                        self.messagesCollectionView.reconfigureItems(at: ips)
                    } else {
                        //print("***** something didn't match, reload sections instead")
                        self.messagesCollectionView.reloadSections(reloadIndexSet)
                    }
                }
            } else {
                var reconfigure = true
                var ips:[IndexPath] = []
                for idx in reloadIndexSet {
                    let ip = IndexPath(row: 0, section: idx)
                    ips.append(ip)
                    if latestmsgs.count > idx, data.count > idx, latestmsgs[idx].uniqueId != data[idx].uniqueId {
                        reconfigure = false
                    } else if latestmsgs.count > idx, data.count > idx {
                        let newCategory = self.messagePresentationCategory(for: latestmsgs[idx])
                        let oldCategory = self.messagePresentationCategory(for: data[idx])
                        if newCategory != oldCategory {
                            reconfigure = false
                        }
                    }

                    if latestmsgs[idx].reactionsCount != data[idx].reactionsCount {
                        reconfigure = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.scrollToCellIfNotFullyVisible(at: ip, keyboardHeight: self.keyboardHeight)
                        }
                    }
                }
                if ips.count > 0 {
                    //print("***** update ips: \(ips)")
                    if reconfigure == true {
                        self.messagesCollectionView.reconfigureItems(at: ips)
                    } else {
                        //print("***** something didn't match, reload sections instead")
                        self.messagesCollectionView.reloadSections(reloadIndexSet)
                    }
                }
            }
            
            if self.loadingMoreMessages { //} || (diffcount > 0 && addcount <= 1) {
                self.loadingMoreMessages = false
                //}
                let afterContentSize = self.messagesCollectionView.contentSize
                let contentOffset = self.messagesCollectionView.contentOffset
                // reset the contentOffset after data is updated
                let newOffset = CGPoint(
                    x: contentOffset.x + (afterContentSize.width - beforeContentSize.width),
                    y: contentOffset.y + (afterContentSize.height - beforeContentSize.height))
                self.messagesCollectionView.setContentOffset(newOffset, animated: false)
            } else if reload, diffcount == 0 {
                if latestmsgs.last?.uniqueId == data.last?.uniqueId { return }
                self.scrollIfAppropriate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.scrollIfAppropriate()
                }
            }
        }
    }
    
    private func scrollIfAppropriate() {
        let animated = self.updatedSource
        let isScrolling: Bool = self.messagesCollectionView.isDragging || self.messagesCollectionView.isDecelerating
        if !isScrolling {
            self.messagesCollectionView.scrollToLastItem(animated: animated)
        }
    }
    
    func loadMoreMessages() {
        let oldpage = (ChatViewController.kOTRMessagePageSize*self.messagePage) + self.messagesAdded
        if oldpage >= self.chatMessages.count { return }
        
        let startIndex = oldpage
        self.messagePage+=1
        
        var asec = [ChatMessage]()
        var cnt = ChatViewController.kOTRMessagePageSize
        let newpage = (ChatViewController.kOTRMessagePageSize*self.messagePage) + self.messagesAdded
        
        if self.chatMessages.count < newpage {
            cnt = self.chatMessages.count - oldpage
        }
        
        let endIndex = startIndex+cnt
        for i in startIndex..<endIndex {
            let msg = self.chatMessages[i]
            asec.insert(msg, at: 0)
        }
        
        let msgid = self.shownMessages[0].uniqueId
        let cmsgid = msgid as NSString
        self.messageSizeCache.removeObject(forKey: cmsgid)
        self.messageBottomCache.removeObject(forKey: cmsgid)
        self.cellTopCache.removeObject(forKey: cmsgid)
        
        //print("***** loadMoreMessages page \(self.messagePage), startIndex \(startIndex), endIndex \(endIndex), asec size \(asec.count), first \(asec[0].elements[0].text), final \(asec[asec.count-1].elements[0].text)")
        
        var latest = [ChatMessage]()
        if self.latestdata.count > 0 {
            latest = self.latestdata
        } else {
            latest = self.shownMessages
        }
        
        latest.insert(contentsOf: asec, at: 0)
            
        self.loadingMoreMessages = true
        self.latestdata = latest
        self.handleUpdates()
    }
    
    func isLastSectionVisible() -> Bool {
        guard !self.shownMessages.isEmpty else { return false }
        
        //let lastIndexPath = IndexPath(item: self.dataInput[0].elements.count - 1, section: 0)
        let lastIndexPath = IndexPath(item: 0, section: self.shownMessages.count - 1)
        return messagesCollectionView.indexPathsForVisibleItems.contains(lastIndexPath)
    }
    
    @objc func networkConnectionStatusChange(_ notification:NSNotification) {
        self.setConnectionStatus()
    }
    
    //* Takes the current value out of the thread object and sets it to the text view and nils out result*/
    func moveLastComposingTextForThreadKey() {
        if var thread = getBuddy(), let oldText = thread.currentMessageText {
            let textView = self.messageInputBar.inputTextView
            if textView.text.count == 0 && oldText.count > 0 {
                textView.text = oldText
                //self.receivedTextViewChanged(textView)
            }
            
            if oldText.count > 0 {
                thread.currentMessageText = nil
                thread.storeInGRDB()
                self.state.hasText = true
            }
        }
    }
    
    func getBuddy() -> ChatBuddy? {
        if let buddy = self.buddy {
            return buddy
        }
        
        if let thread = getThread() {
            if let bud = ChatBuddy.buddyFromThread(thread) {
                self.buddy = bud
                return bud
            } else if let bud2 = ChatBuddy.getBuddy(uniqueId: thread.uniqueId) {
                self.buddy = bud2
                return bud2
            }
        }
        return nil
    }
    
    func setConnectionStatus() {
        if ChatViewController.IS_IPHONE, let account = getAccount() { //IOSM-570
            DispatchQueue.main.async {
                self.addStatusGestures(true)
                if OTRProtocolManager.shared.existsProtocol(forAccountId: account.uniqueId) {
                    if OTRProtocolManager.shared.isAccountIdConnected(account.uniqueId) {
                        if self.showConnStatus == true {
                            self.showConnStatus = false
                            self.titleView.subtitleLabel.text = nil
                        }
                        self.refreshTitleView()
                        self.titleView.dynConnectingView.stopAnimating()
                        self.titleView.dynConnectingView.isHidden = true
                        
                        //if self.chatMsgCancellable == nil, self.waitingToObserve == false {
                            //self.waitingToObserve = true
                            //self.addUploadHUD("Retrieving data...", tapToCancel: false)
                            //DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                //self.removeUploadHUD()
                                //self.observeConversations()
                            //}
                        //}
                    }
                    else {
                        self.handleConnectingStatus(protocolExists: true)
                    }
                } else {
                    // this occurs when in process of trying to create new account
                    // shouldn't happen in this class but just in case
                    self.handleConnectingStatus(protocolExists: false)
                }
            }
        }
    }
    
    func handleConnectingStatus(protocolExists: Bool) {
        //DDLogWarn(@"*** handleConnectingStatus with statusCtr %d", _statusCtr);
        self.showConnStatus = true
        
        if OTRAppDelegate.appDelegate.isProxyDetected() == true {
            self.titleView.subtitleLabel.text = "Proxy Detected"
            return
        }
        
        //if the timer doesn't exist here we need to recreate it. Happens on loss of network conenction.
        if (self.statusTimer == nil && protocolExists) { //IOSM#22
            self.statusCtr = 0
            self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
        }
        
        if (self.statusCtr < 4) {
            //self.titleView.subtitleLabel.text = nil; //IOSM#60
            self.refreshTitleView()
            self.titleView.dynConnectingView.isHidden = true
        } else if (self.statusCtr < 6) {
            self.titleView.subtitleLabel.text = "Connecting" //IOSM#60 nil to Connecting
            self.titleView.dynConnectingView.isHidden = false
            self.titleView.dynConnectingView.startAnimating()
        } else {
            self.removeUploadHUD()
            if (protocolExists) {
                if self.statusCtr >= 14 { //IOSM#60
                    self.titleView.dynConnectingView.stopAnimating()
                    self.titleView.dynConnectingView.isHidden = true
                    self.refreshTitleView()
                        
                    self.statusTimer?.invalidate()
                    self.statusCtr = 0
                    self.statusTimer = nil
                        
                    self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
                    self.titleView.subtitleLabel.text = "Trying again"
                    self.retryLogin()
                }
            } else { // don't think this should be possible, but just in case
                self.titleView.subtitleLabel.text = "Problems initializing account"
            }
        }
    }
    
    func addStatusGestures(_ turnon:Bool) {
        if (turnon) {
            self.titleView.addGestureRecognizer(self.statusTapGestureRecognizer)
            self.titleView.isUserInteractionEnabled = true
        } else {
            self.titleView.removeGestureRecognizer(self.statusTapGestureRecognizer)
            self.titleView.isUserInteractionEnabled = false
        }
    }
    
    @objc func refreshTitleTimerUpdate(_ timer: Timer) {
        self.refreshTitleView()
    }

    /** Updates the title view with the current thread information on this view controller*/
    func refreshTitleView()
    {
        guard let buddy = self.buddy else {
            return
        }
        
        let thread = ChatBuddyModel(buddy: buddy)
        self.titleView.titleLabel.text = thread.threadName
        
        let namecomponents = thread.threadName.components(separatedBy: "@")
        if namecomponents.count == 2 {
            self.titleView.titleLabel.text = namecomponents.first
        }
        
        var statusImage:UIImage?
        if let color = thread.avatarBorderColor {
            statusImage = OTRImages.circle(withRadius: 50.0, lineWidth: 0.0, lineColor: nil, fill: color)
        }
            
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.doRefreshTime()
        }
        
        if let statusImg = statusImage {
            self.titleView.titleImageView.image = statusImg
        } else {
            self.titleView.titleImageView.image = nil
        }
    }

    private func doRefreshTime() {
        if let buddy = self.buddy {
            let lastSeen = BuddyCache.shared().lastSeenDate(buddy: buddy)
            let status = BuddyCache.shared().threadStatus(buddyId: buddy.uniqueId)
            if lastSeen == nil {
                return
            }
            let tf = TTTTimeIntervalFormatter()
            tf.presentTimeIntervalMargin = 60
            tf.usesAbbreviatedCalendarUnits = true
            
            var labelString:String? = nil
            if status != ThreadStatus.available, let lastSeenInterval = lastSeen?.timeIntervalSince(Date()) {
                labelString = ACTIVE_STRING() + " " + tf.string(forTimeInterval: lastSeenInterval)
            }
            
            if !self.showConnStatus {
                titleView.subtitleLabel.text = labelString
            }
        }
    }
    
    func prefersStatusBarHidden() -> Bool {
        return false
    }
    
    @objc func handleStatusGesture() {
        if let statusString = self.titleView.subtitleLabel.text, (statusString.hasSuffix("login") || statusString.hasSuffix("again")) {
            self.statusTimer?.invalidate()
            self.statusCtr = 2
            self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
            
            self.retryLogin()
        }
        
        if let buddyName = self.titleView.titleLabel.text, !buddyName.isEmpty, let chatBuddy = buddy {
            let chatAccount = ChatAccount(uniqueId: chatBuddy.uniqueId, username: chatBuddy.username, domain: nil, resource: "", port: 0, displayName: chatBuddy.displayName, loginDate: nil, lastHistoryFetchDate: nil, pushPubsubEndpoint: nil, pushPubsubNode: nil, org: nil, apiKey: nil, avatarData: chatBuddy.avatarData, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: chatBuddy.photoHash, modified: nil)
            let chatAccountModel = ChatAccountModel(account: chatAccount)
            showSelectedUserProfile(chatAccountModel)
        }
    }
    
    @objc func getAccount() -> ChatAccountModel? {
        if self.account == nil {
            if let thread = getThread(), thread.accountUniqueId >= 0 {
                self.account = ChatAccountModel.getChatAccount(thread.accountUniqueId)
            } else {
                self.account = ChatAccountModel.firstAccount()
            }
        }
        return self.account
    }
    
    func getThread() -> ChatThread? {
        return self.getThread(key: self.threadKey)
    }
    
    func getThread(key:String?) -> ChatThread? {
        if self.threadOwner == nil, let tkey = key {
            self.threadOwner = ChatThread.getChatThread(uniqueId: tkey)
        }
        return self.threadOwner
    }

    func saveCurrentMessageText(_ text: String?, key:String?) {
        if key == nil {
            return
        }
        
        //getThread(key: key, collection: collection)
        if var thread = getBuddy(), ChatRoomModel.getXMPPRoom(uniqueId: thread.uniqueId) != nil {
            thread.currentMessageText = text
            thread.storeInGRDB()
            
            if let xmpp = xmppManager(), let xMessage = xmpp.getInactiveMessage(thread.uniqueId) {
                xmpp.sendChatStateMessage(xMessage)
                //xmpp.sendChatState(.inactive, buddyUniqueId: thread.uniqueId)
            }
        }
    }
    
    @objc func enteringForegroundStatus(_ notification: NSNotification) {
        self.statusTimer?.invalidate()
        self.statusCtr = 0
        
        if !ChatViewController.IS_IPHONE { //IOSM-570
            return
        }
        
        self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
        
        self.setConnectionStatus()
    }

    //IOSM#104
    @objc func becameActiveStatus(_ notification: NSNotification) {
        self.tryToMarkAllMessagesAsRead()
        self.drawCellsIfNeeded()
    }
    
    private func drawCellsIfNeeded() {
        if self.redrawSet.count > 0 {
            var ips:[IndexPath] = []
            //var iset:IndexSet = []
            let reset = self.redrawSet
            self.redrawSet.removeAll()
            let latestCnt = self.shownMessages.count
            for idx in reset {
                if latestCnt > idx.section {
                    ips.append(idx)
                    //iset.insert(idx.section)
                }
            }
            
            self.messagesCollectionView.reconfigureItems(at: ips) // reloadSections(iset)
        }
    }

    //IOSM-338c
    @objc func handleLoginSuccess(_ notification: NSNotification) {
        DispatchQueue.main.async {
            if (self.isViewLoaded && self.view.window != nil) {
                self.dsQueue.async {
                    self.sendPresenceProbe()
                    self.fetchOMEMODeviceList()
                }
            }
        }
    }

    @objc func enteringBackground(_ notification: NSNotification) {
        self.handleScreenDisappearing()
        self.redrawSet.removeAll()
    }

    func handleScreenDisappearing() {
        self.statusTimer?.invalidate()
        self.statusTimer = nil
        self.statusCtr = 0;
        
        self.titleView.dynConnectingView.stopAnimating()
        self.titleView.subtitleLabel.text = nil
    }
    
    @objc func updateStatusTimer()
    {
        //DDLogWarn(@"*** statusCtr %d", _statusCtr);
        if (self.statusCtr < 22 && self.showConnStatus) { //IOSM-395 added &&
            self.statusCtr+=1
        } else {
            self.statusTimer?.invalidate()
            self.statusTimer = nil
        }
        
        if (self.statusCtr % 2 == 0) {
            self.setConnectionStatus()
        }
    }
    
    /*func resetMessageCollectionView() {
        messagesCollectionView.messagesDataSource = nil
        messagesCollectionView.messageCellDelegate = nil
        messagesCollectionView.messagesLayoutDelegate = nil
        messagesCollectionView.messagesDisplayDelegate = nil
        
        messagesCollectionView.messagesDataSource = self
        messagesCollectionView.messageCellDelegate = self
        messagesCollectionView.messagesLayoutDelegate = self
        messagesCollectionView.messagesDisplayDelegate = self
    }*/
    
    func configureMessageCollectionView() {
        messagesCollectionView.register(GlacierAudioMessageCell.self)
        
        messagesCollectionView.messagesDataSource = self
        messagesCollectionView.messageCellDelegate = self

        scrollsToLastItemOnKeyboardBeginsEditing = true // default false
        showMessageTimestampOnSwipeLeft = true // default false
      
        messagesCollectionView.messagesLayoutDelegate = self
        messagesCollectionView.messagesDisplayDelegate = self
    }
    
    func configureMessageInputBar() {
        messageInputBar = AttachmentsInputBarView()
        messageInputBar.delegate = self
        messageInputBar.inputTextView.tintColor = .label
        messageInputBar.sendButton.setTitleColor(UIColor.bubbleBlue(), for: .normal)
        messageInputBar.sendButton.setTitleColor(UIColor.bubbleBlue(), for: .highlighted)
        
        messageInputBar.sendButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        messageInputBar.sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        
        messageInputBar.inputTextView.placeholder = "Send encrypted message"
        inputBarType = .custom(messageInputBar)
        self.layoutFAB()
    }
    
    func saveChatThreadIfNeeded() {
        guard let key = self.threadKey else {return}
        if var buddy = self.buddy {
            let threadId = buddy.chatThreadId
            if threadId >= 0, let _ = ChatThread.getChatThread(threadId: buddy.chatThreadId) {
                return
            } else if let thr = ChatThread.getChatThread(uniqueId: buddy.uniqueId) {
                if let tid = thr.id {
                    self.buddy?.chatThreadId = tid
                    buddy.chatThreadId = tid
                    buddy.save()
                }
                return
            } else {
                var accountid = self.account?.grdbRecord?.id
                if accountid == nil, let me = ChatAccountModel.firstAccount() {
                    accountid = me.grdbRecord?.id
                }
                guard let aid = accountid else {return}
                
                //create new thread with same unique id
                var newThread = ChatThread(uniqueId: key)
                newThread.isGroupThread = false
                newThread.accountUniqueId = aid
                newThread.storeInGRDB(completion: {
                    DispatchQueue.global().async {
                        if let newthread = ChatThread.getChatThread(uniqueId: key), let tid = newthread.id {
                            buddy.chatThreadId = tid
                            buddy.storeInGRDB(completion: {
                                newthread.touch()
                            })
                        }
                    }
                })
            }
        }
    }
    
    func setupTopRightButtons() {
        let lblColor = UIColor.label
        
        phoneButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        self.phoneButton.translatesAutoresizingMaskIntoConstraints = false
        self.phoneButton.frame = CGRectMake(0, 0, 64, 48)
        self.phoneButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 26)
        self.phoneButton.titleLabel?.textAlignment = NSTextAlignment.center
        self.phoneButton.tintColor = lblColor
        self.phoneButton.setTitleColor(lblColor, for: UIControl.State.normal)
        self.phoneButton.setTitleColor(UIColor.lightGray, for: UIControl.State.highlighted)
        self.phoneButton.setTitleColor(UIColor.lightGray, for: UIControl.State.disabled)
        let phoneIconChar: UniChar = 0xf095
        self.phoneButton.setTitle(String(format: "%C", phoneIconChar), for: .normal)
        //self.phoneButton.addTarget(self, action: #selector(didSelectPhoneButton), for: UIControl.Event.touchUpInside)
        
        
        //self.phoneButton.setImage(UIImage(systemName: "phone.fill"), for: .normal)
        
        var actions:[UIAction] = []
        let phoneImage = UIImage(systemName: "phone.fill")
        let videoImage = UIImage(systemName: "video.fill")
        actions.append(UIAction(title: "Audio call", image: phoneImage, handler: {(_) in
            self.didSelectPhoneButton(callType: .audio)
        }))
        actions.append(UIAction(title: "Video call", image: videoImage, handler: {(_) in
            self.didSelectPhoneButton(callType: .video)
        }))
                
        let callMenu = UIMenu(title:"", children:actions)
        //callBarButton.menu = callMenu
        
        self.phoneButton.menu = callMenu
        self.phoneButton.showsMenuAsPrimaryAction = true
        let callBarButton = UIBarButtonItem(customView: self.phoneButton)
        
        self.navigationItem.rightBarButtonItems = nil
        let callWindow = OTRAppDelegate.appDelegate.callWindow
        self.navigationItem.rightBarButtonItem = callBarButton
        if callWindow?.rootViewController != nil {
            self.navigationItem.rightBarButtonItem?.isEnabled = false
        }
    }
    
    func updateState() {
        self.state.canSendMedia = true
        self.state.messageSecurity = .OMEMO
    }
    
    func setThreadKey(_ key: String?) {
        if key != self.threadKey {
            //try to nullify existing MessageContainerView, MediaMessageCell, etc
            self.chatMessages.removeAll()
            //self.currentIndexPath = nil
            let oldKey = self.threadKey
            
            self.threadKey = key
            self.xmppMgr = nil
            self.account = getAccount()
            self.threadOwner = nil
            self.xmppMgr = xmppManager()
            self.messagePage = 1
            self.loadingMoreMessages = false
            self.messagesAdded = 0
            self.latestDateDisplayed = nil
            self.updatedSource = false
            self.retriedSet.removeAll()
            //self.messageSizeCache.removeAllObjects()
            //ChatMediaItemModel.clearMediaCache()
            
            if let bkey = key {
                self.buddy = ChatBuddy.getBuddy(uniqueId: bkey)
            }
            
            guard let account = self.account else {
                self.automaticURLFetchingDisabled = true
                return
            }
            
            self.automaticURLFetchingDisabled = account.grdbRecord?.disableAutomaticURLFetching ?? false
            self.sender = ChatUser(senderId: account.uniqueId, displayName: account.displayName)
            
            chatMsgCancellable?.cancel()
            chatMsgCancellable = nil
            self.chatMessages.removeAll()
            //self.dsQueue.async {
                self.initialRequest()
            //}
            
            self.getAvatarImages()
            //if (self.xmppMgr?.loginStatus == OTRLoginStatus.authenticated) {
                self.observeConversations()
            //} else { //timer or wait for login and then timer
            //    waitingToObserve = false
            //}
            self.saveChatThreadIfNeeded()
            
            // Clear out old state (don't just alloc a new object, we have KVOs attached to this!)
            self.state.reset()
            //self.showTypingIndicator = false
            
            // This is set to nil so the refreshTitleView: method knows to reset username instead of last seen time
            self.titleView.subtitleLabel.text = nil
            self.messageInputBar.inputTextView.placeholder = "Send encrypted message"
            
            if oldKey != key {
                self.saveCurrentMessageText(self.messageInputBar.inputTextView.text, key: oldKey)
                self.messageInputBar.inputTextView.text = nil
                //self.receivedTextViewChanged(self.messageInputBar.inputTextView)
            }
            
            if let key = self.threadKey {
                self.updateView(with: key)
                self.moveLastComposingTextForThreadKey()
                self.messageInputBar.inputTextView.isEditable = true
            } else {
                self.sender = ChatUser(senderId: "", displayName: "")
            }
            
            self.setupTopRightButtons()
            self.updateState()
            
            if self.deviceListUpdateNotificationObject == nil {
                self.deviceListUpdateNotificationObject = NotificationCenter.default.addObserver(forName: OTROMEMOSignalCoordinator.DeviceListUpdateNotificationName, object: nil, queue: OperationQueue.main, using: { [weak self] (notification) in
                    self?.handleDeviceListUpdate(notification: notification)
                })
            }
            
            if self.xmppMgr?.loginStatus == .authenticated {
                dsQueue.async {
                    self.sendPresenceProbe()
                    self.fetchOMEMODeviceList()
                }
            }
        }
        
        //don't try to send this if we aren't logged in yet
        //also check the scroll position thing
        /*if let account = getAccount(), OTRProtocolManager.shared.existsProtocol(forAccountId: account.uniqueId), OTRProtocolManager.shared.isAccountIdConnected(account.uniqueId) {
                self.sendPresenceProbe()
                self.fetchOMEMODeviceList()
        }*/
    }
    
    func findBuddyLocation(_ buddyloc:String, with message:ChatMessage) {
        //override if desired
    }

    public override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let msg = self.shownMessages[indexPath.section]
        
        var collectionViewCell: UICollectionViewCell?
        if case MessageKind.audio(_) = msg.kind {
            collectionViewCell = messagesCollectionView.dequeueReusableCell(GlacierAudioMessageCell.self, for: indexPath)
            if let glacierAudioCell = collectionViewCell as? GlacierAudioMessageCell {
                glacierAudioCell.cellDelegate = self
            }
        } else {
            collectionViewCell = super.collectionView(collectionView, cellForItemAt: indexPath)
        }
        
        guard let cell = collectionViewCell else {
            return UICollectionViewCell()
        }
        
        if let messageContentCell = cell as? MessageContentCell {
            messageContentCell.showReactionsIfAny(
                for: msg,
                isIncomingMessage: isFromCurrentSender(message: msg) == false,
                isShowingTopLabelText: messageTopLabelAttributedText(for: msg, at: indexPath) != nil
            )
        }
        
        if let tcell = cell as? TextMessageCell {
            if let txt = msg.text {
                if txt.starts(with: "Message cannot be decrypted"), let fontDesc = tcell.messageLabel.font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    // making the new font; size:0 means 'keep the size as is'
                    let itFont = UIFont(descriptor: fontDesc, size: 0)
                    tcell.messageLabel.attributedText = NSAttributedString.init(string: txt, attributes: [NSAttributedString.Key.font:itFont])
                } else if txt.starts(with: "geo:") {
                    let cell = messagesCollectionView.dequeueReusableCell(LocationMessageCell.self, for: indexPath)
                    cell.configure(with: msg, at: indexPath, and: messagesCollectionView)
                    return cell
                } else if txt.starts(with: "aesgcm") {
                    let cell = messagesCollectionView.dequeueReusableCell(MediaMessageCell.self, for: indexPath)
                    cell.imageView.image = UIImage.imageWithColor(color: UIColor.lightGray, size: CGSizeMake(210.0, 200.0))
                    cell.playButtonView.isHidden = true
                    cell.configure(with: msg, at: indexPath, and: messagesCollectionView)
                    
                    if let xmpp = xmppManager(), self.retriedSet.contains(msg.uniqueId) == false {
                        self.retriedSet.insert(msg.uniqueId)
                        xmpp.fileTransferManager.retryDownloadMedia(ChatMessageModel(message: msg))
                    }
                    return cell
                }
            }
            return tcell
        } else if let vcell = cell as? MediaMessageCell {
            let message = self.shownMessages[indexPath.section]
            if case MessageKind.video(_) = message.kind {
                if let data = vcell.imageView.image?.jpegData(compressionQuality: 1.0), data.count < 20000 {
                    vcell.playButtonView.isHidden = true
                    vcell.imageView.kf.indicatorType = .activity
                    vcell.imageView.kf.indicator?.startAnimatingView()
                }
            }
        } else if let acell = cell as? GlacierAudioMessageCell {
            acell.configure(with: msg, at: indexPath, and: messagesCollectionView)
            return acell
        }
        
        return cell
    }
    
    public override func collectionView(_: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize
    {
        let message = self.shownMessages[indexPath.section]
        let key = message.uniqueId as NSString
        
        //if message.mediaItemUniqueId == nil
        if indexPath.section < self.shownMessages.count - 2, let sizeValue = self.messageSizeCache.object(forKey: key) {
            return sizeValue.cgsize
        }
        
        guard let messagesFlowLayout = collectionViewLayout as? MessagesCollectionViewFlowLayout else { return .zero }
        var newsize = messagesFlowLayout.sizeForItem(at: indexPath)
        if message.reactionsCount > 0 {
            newsize.height += 25
            if messageTopLabelAttributedText(for: message, at: indexPath) != nil {
                newsize.height += 10
            }
            
            if showDate(at: indexPath, message: message) {
                newsize.height += 10
            }
        }
        
        let sizeValue = GlacierValue.init()
        sizeValue.cgsize = newsize
        self.messageSizeCache.setObject(sizeValue, forKey: key)
        
        return newsize
    }
    
    public override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if self.loadingMessages == false, indexPath.section == 4 {
            dsQueue.async {
                self.loadMoreMessages()
            }
        }
    }
    
    /*public func numberOfItems(inSection _: Int, in _: MessagesCollectionView) -> Int {
        self.dataInput[0].elements.count
    }*/
    public func numberOfSections(in _: MessagesCollectionView) -> Int {
        self.shownMessages.count  //1
    }
    
    public func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessageKit.MessagesCollectionView) -> MessageKit.MessageType {
        //return self.dataInput[0].elements[indexPath.row]
        
        var message = self.shownMessages[indexPath.section]
        /*if let txt = message.text, txt.starts(with: "geo:") {
            message.text = "Location sent"
        }*/
        
        //ALF test
        if message.systemUpdate {
            message.text = nil
        }
        
        let finalMsg = message
        
        return finalMsg//self.dataInput[indexPath.section].elements[indexPath.row]
    }
    
    public func nextMessageForItem(at indexPath: IndexPath) -> MessageKit.MessageType? {
        
        if self.shownMessages.count > indexPath.section+1 {
            return self.shownMessages[indexPath.section+1]
        }
        
        return nil
    }
    
    public func prevMessageForItem(at indexPath: IndexPath) -> MessageKit.MessageType? {
        
        if indexPath.section >= 1, self.shownMessages.count > indexPath.section {
            return self.shownMessages[indexPath.section-1]
        }
        
        return nil
    }

    public func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        let text = NSMutableAttributedString(string: "")
        guard let message = message as? ChatMessage else { return text }
        
        if self.showDate(at: indexPath, message: message) {
            text.append(NSAttributedString(
                string: MessageKitDateFormatter.shared.string(from: message.sentDate),
                attributes: [
                    NSAttributedString.Key.foregroundColor: UIColor.darkGray,
                    NSAttributedString.Key.font: UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.boldSystemFont(ofSize: 10)),
                ]))
        }
        
        if message.systemUpdate {
            if var updateString = message.originalText {
                if text.length > 0 {
                    updateString = "\n" + updateString
                }
                text.append(NSAttributedString(string: updateString, attributes:attrs))
            }
        }
        
        return text
    }

    public func cellBottomLabelAttributedText(for _: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        return nil
        //NSAttributedString(string: "Read", attributes: [
            //NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 10),
            //NSAttributedString.Key.foregroundColor: UIColor.darkGray,
        //])
        
        //let attributedString = NSMutableAttributedString(string: "")
    }

    public func messageTopLabelAttributedText(for message: MessageType, at _: IndexPath) -> NSAttributedString? {
        //let name = message.sender.displayName
        return nil //NSAttributedString(string: name, attributes: [NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .caption1)])
    }

    public func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        //let dateString = MessageKitDateFormatter.shared.string(from: message.sentDate)
        guard let message = message as? ChatMessage else { return nil }
        let attributedString = NSMutableAttributedString(string: "")
        
        //check if is timer/disappearing message. If not, return
        if (message.expires) != nil {
            let expStr = self.getExpiringString(for: message)
            self.expiringCache.setObject(expStr as NSString, forKey: message.uniqueId as NSString)
            attributedString.append(NSAttributedString(string: " " + expStr, attributes: attrs))
        }
            
        if let deliveryString = self.deliveryStatusString(for: message, indexPath: indexPath), deliveryString.length > 0 {
            attributedString.append(deliveryString)
        }
        
        //if let mediaKey = message.mediaItemUniqueId, let mediaItemModel = ChatMediaItemModel.getMediaItem(with: mediaKey), let mediaItem = mediaItemModel.grdbRecord, let progress = mediaItem.transferProgress {
        if message.mediaItemUniqueId != nil, let progress = message.transferProgress, progress < 1.0 {
            let percentProgress = progress * 100
            //print("***** percentProgress \(percentProgress) for IP \(indexPath.section)")
            var progressString:String?
            var insertIndex = 0;
            //let font = UIFont(name: kFontAwesomeFont, size: 12)
            if message.type == ChatMessageType.incoming.rawValue {
                if let merror = message.error{//} as? NSError {
                    let nsErr = NSError(domain: merror.errDomain, code: merror.errCode)
                    if !nsErr.isUserCanceledError, !nsErr.isAutomaticDownloadError {
                        let clockChar: UniChar = 0xf017
                        let progressString = String(format: " %C ", clockChar) //IOSM#57 from WAITING_STRING()
                        
                        let attrStr = NSAttributedString(string: progressString, attributes: attrs)
                        //NSAttributedString(string: progressString, attributes: [NSAttributedString.Key.font:font ?? UIFont.systemFont(ofSize: 12)])
                        attributedString.append(attrStr)
                        return attributedString
                    }
                } else {
                    progressString = String(format: " %@ %.0f%%", INCOMING_STRING(), percentProgress)
                }
                insertIndex = attributedString.length
            } else if message.type == ChatMessageType.outgoing.rawValue {
                if let merror = message.error {
                    let nsErr = NSError(domain: merror.errDomain, code: merror.errCode)
                    if !nsErr.isUserCanceledError, !nsErr.isAutomaticDownloadError {
                        //IOSM#57 handled in deliveryStatus as clockIcon, and below
                    } else if percentProgress > 0 {
                        progressString = String(format: " %@ %.0f%%", SENDING_STRING(), percentProgress)
                    }
                } else if percentProgress > 0 {
                    progressString = String(format: " %@ %.0f%%", SENDING_STRING(), percentProgress)
                }
            }
            
            if let progressStr = progressString {
                let thumbnailKey =  String(format: "%@-thumb", message.uniqueId)
                if GlacierImageCache.shared().isCached(forKey: thumbnailKey) == false {
                    let pString = NSAttributedString(string: progressStr, attributes: attrs)
                    attributedString.insert(pString, at: insertIndex)
                }
            }
        }
        
        
        return attributedString
    }
    
    func getAttachmentPicker() -> OTRAttachmentPicker {
        if self.attachmentPicker == nil {
            self.attachmentPicker = OTRAttachmentPicker.init(parentViewController: self, delegate: self)
        }
        return self.attachmentPicker!
    }

    func updateExpiresState() { //IOSM#6
        
    }
    
    func didUpdateState() { //IOSM#6
        
    }
    
    func retryLogin() {
        let currentStatus = OTRNetworkConnectionStatus.connected
        let userInfo = [NewNetworkStatusKey: currentStatus]
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: self, userInfo: userInfo)
        }
    }
    
    func getThreadName() -> String? {
        return self.titleView.titleLabel.text
    }
    
    func cancelAction() -> UIAlertAction {
        return UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    }

    func resendOutgoingMessage(for messageKey:String, messageCollection:String, title:String) {
        let message = ChatMessageModel.getMessage(with: messageKey)
        
        if let message = message {
            let messageError = message.messageError
            message.messageError = nil
            message.messageSecurity = self.state.messageSecurity
            message.messageDate = Date()
            message.save()
            
            if let mediaKey = message.messageMediaItemKey, (message.messageText?.count == 0 || messageError != nil) {
                if let mediaItem = ChatMediaItemModel.getMediaItem(with: mediaKey) {
                    let data:Data? = nil
                    self.sendMediaItem(mediaItem, data: data, message: message)
                }
            } else if let xmpp = xmppManager() {
                xmpp.enqueueMessage(message)
            }
        }
    }
    
    func sendPhoto(_ photo:UIImage, asJPEG:Bool, shouldResize:Bool, userTypedText: String?, info:[AnyHashable : Any]?){
        var showHUD = false
        if let multi = info?["Multiselect"] as? Bool {
            showHUD = multi
        }
        
        if let xmpp = xmppManager(), let thread = getThread() {
            let threadModel = ChatThreadModel(thread: thread)
            if (showHUD) { //IOSM-602
                DispatchQueue.main.async {
                    self.addUploadHUD()
                    xmpp.fileTransferManager.send(image: photo, thread: threadModel, jpeg: asJPEG, label: self.uploadHUD?.label, isPublic: false) { [weak self] (success:Bool, error:Error?) in
                        guard let strongSelf = self else { return }
                        strongSelf.handleMediaError(error: error)
                        strongSelf.removeUploadHUD()
                        
                        guard let text = userTypedText, !text.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            strongSelf.doSendMessage(text)
                        }
                    }
                }
            } else {
                //IOSM#61 add jpeg
                xmpp.fileTransferManager.send(image: photo, thread: threadModel, jpeg: asJPEG, label: self.uploadHUD?.label, isPublic: false, completion: { [weak self] (success:Bool, error:Error?) in
                    guard let strongSelf = self else { return }
                    strongSelf.handleMediaError(error: error)
                    strongSelf.removeUploadHUD()
                    
                    guard let text = userTypedText, !text.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        strongSelf.doSendMessage(text)
                    }
                })
            }
        }
    }
    
    func sendVideoURL(_ videoURL:URL) {
        if let xmpp = xmppManager(), let thread = getThread() {
            self.removeUploadHUD()
            let threadModel = ChatThreadModel(thread: thread)
            
            xmpp.fileTransferManager.send(videoURL: videoURL, thread: threadModel, label: self.uploadHUD?.label, isPublic: false, completion: { (success:Bool, error:Error?) in
                self.handleMediaError(error: error)
                self.removeUploadHUD()
            })
        }
    }
    
    func sendAudioFileURL(_ audioURL:URL) {
        if let xmpp = xmppManager(), let thread = getThread() {
            DispatchQueue.main.async {
                self.addUploadHUD()
            }
            let threadModel = ChatThreadModel(thread: thread)
            
            xmpp.fileTransferManager.send(audioURL: audioURL, thread: threadModel, label: self.uploadHUD?.label, isPublic: false, completion: { (success:Bool, error:Error?) in
                self.handleMediaError(error: error)
                self.removeUploadHUD()
            })
        }
    }
    
    func sendFileURLs(_ fileURLs:[URL]) {
        if let xmpp = xmppManager(), let thread = getThread() {
            DispatchQueue.main.async {
                self.addUploadHUD()
            }
            
            let threadModel = ChatThreadModel(thread: thread)
            for fileURL in fileURLs {
                xmpp.fileTransferManager.send(fileURL: fileURL, thread: threadModel, label: self.uploadHUD?.label, isPublic: false, completion: { (success:Bool, error:Error?) in
                    self.handleMediaError(error: error)
                    self.removeUploadHUD()
                })
            }
        }
    }

    func sendImageFilePath(_ filePath:String, asJPEG:Bool, shouldResize:Bool) {
        var image:UIImage?
        
        do {
            if (asJPEG) {
                image = UIImage(contentsOfFile: filePath)
                if image == nil, let url = URL(string: filePath) { //IOSM-486, IOSM-557
                    let data = try Data(contentsOf: url)
                    image = UIImage(data: data)
                }
            } else if let url = URL(string: filePath) {
                let data = try Data(contentsOf: url)
                image = GifHelper.getGifImage(data)
            }
        } catch {
            DDLogError("ChatViewController.sendImageFilePath: \(error.localizedDescription)")
        }
        
        if let image = image {
            self.sendPhoto(image, asJPEG: asJPEG, shouldResize: shouldResize, userTypedText: self.messageInputBar.inputTextView.text, info: nil)
            self.messageInputBar.inputTextView.text = nil
        }
    }
    
    func sendMediaItem(_ mediaItem:ChatMediaItemModel, data:Data?, message:MessageProtocol) {
        guard var thread = getThread(), let xmpp = xmppManager() else { return}
        
        if data != nil {
            thread.lastMessageId = message.messageKey
            thread.messageDate = message.messageDate
            thread.storeInGRDB()
        }
        
        DispatchQueue.main.async {
            self.addUploadHUD()
        }
        
        xmpp.fileTransferManager.sendAsync(mediaItem: mediaItem, prefetchedData: data, message: message, label: self.uploadHUD?.label, completion: { [weak self] (success, error) in
            self?.handleMediaError(error: error)
            self?.removeUploadHUD()
        })
    }
    
    func handleMediaError(error:Error?){
        guard let error = error else {
            return
        }
        
        if error.localizedDescription == FILE_EXCEEDS_MAX_SIZE_STRING() {
            let alert = UIAlertController(title: "Unable to Send", message: "Sorry! File exceeds max allowed size.", preferredStyle: .alert)

            let cancelAction = UIAlertAction(title: OK_STRING(), style: .default, handler: nil)
            alert.addAction(cancelAction)
            present(alert, animated: true, completion: nil)
        } else if error.localizedDescription == USER_CANCELED_STRING() {
            if let thread = getThread(), let lastMessageId = thread.lastMessageId {
                ChatMessageModel.deleteMessage(with: lastMessageId)
            }
        }
    }

    func removeUploadHUD() {
        DispatchQueue.main.async {
            if let hud = self.uploadHUD {
                hud.removeFromSuperview()
                self.uploadHUD = nil
            }
        }
    }
    
    @objc func hudTap(sender:UITapGestureRecognizer)
    {
        let alert = UIAlertController(title: "Stop upload?", message: "Are you sure you want to stop sending this?", preferredStyle: .alert)

        let stopAction = UIAlertAction(title: "Stop", style: .default, handler: { alert in
            self.removeUploadHUD()
            if let xmpp = self.xmppManager() {
                xmpp.fileTransferManager.cancelUpload()
            }
        })
        let contAction = UIAlertAction(title: "Continue", style: .cancel, handler: nil)
        alert.addAction(stopAction)
        alert.addAction(contAction)
        present(alert, animated: true, completion: nil)
    }
    
    func xmppManager() -> XMPPManager? {
        if self.xmppMgr == nil {
            if let account = self.getAccount() {
                self.xmppMgr = OTRProtocolManager.shared.xmppManager(forChatAccount: account)
            }
        }
        
        return self.xmppMgr
    }
    
    //IOSM-527b doesn't this depend on what the current conversation is?
    public func joinStatusUpdated(_ join: Bool) {
        //NSString *callname = [xmpp.callManager getCallToJoin];
        /*if (join) {
            //change call button to join button
            _phoneButton.titleLabel.font = [UIFont fontWithName:kFontAwesomeFont size:12];
            [_phoneButton setTitle:@"Join" forState:UIControlStateNormal];
        } else{
            //change to call button
            _phoneButton.titleLabel.font = [UIFont fontWithName:kFontAwesomeFont size:26];
            [_phoneButton setTitle:[NSString fa_stringForFontAwesomeIcon:FAIconPhone] forState:UIControlStateNormal];
        }*/
    }
    
    open override func collectionView( _ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath:IndexPath, withSender sender: Any?) -> Bool {
        return false //overridden for long press
    }
    
    @objc private func didLongPress(_ longGestureRecognizer: UILongPressGestureRecognizer) {
        if (longGestureRecognizer.state == .began) {
            let touchPoint = longGestureRecognizer.location(in: messagesCollectionView)
            if let indexPath = self.messagesCollectionView.indexPathForItem(at: touchPoint) {
                guard let selectedCell = messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell else {
                    return
                }
                
                self.longIndex = indexPath
                selectedCell.becomeFirstResponder()
                
                guard let message = messagesCollectionView.messagesDataSource?.messageForItem(at: indexPath, in: messagesCollectionView) as? any GRDBRecord else {
                    return
                }
                
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.prepare()
                generator.impactOccurred()
                
                let location = longGestureRecognizer.location(in: self.view)
                let contextMenuView = ContextMenuView(message: message, location: location, delegate: self)
                contextMenuView.tag = 12345
                view.addSubview(contextMenuView)
                
                isShowingContextMenu = true
                
                // Animate appearance
                contextMenuView.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                contextMenuView.alpha = 0
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.1, options: .curveEaseInOut) {
                    contextMenuView.transform = .identity
                    contextMenuView.alpha = 1
                }
            }
        }
    }
    
    private func setupLongPress() {
        self.longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))
        self.longPressGestureRecognizer.minimumPressDuration = 0.4 //1.0 second press
        self.longPressGestureRecognizer.delegate = self
        self.longPressGestureRecognizer.cancelsTouchesInView = true
        self.messagesCollectionView.addGestureRecognizer(self.longPressGestureRecognizer)
    }
    
    private func toggleReaction(_ reaction: String, for message: ChatMessage) {
        guard let receiverJid = buddy?.username,
              let xmppManager = xmppManager(),
              let stream = xmppManager.omemoSignalCoordinator?.omemoModule?.xmppStream,
              let senderJid = stream.myJID?.full else {
            return
        }
        
        self.isShowingContextMenu = false
        
        var reactionIcons = [String]()
        var chatMessageReactions = [ChatMessageReaction]()
        
        if var messageReactions = message.reactions {
            if let index = messageReactions.firstIndex(where: { $0.senderJid == senderJid }) {
                var senderReactions = messageReactions[index]
                if let reactionIndex = senderReactions.reactions.firstIndex(where: { $0 == reaction }) {
                    senderReactions.reactions.remove(at: reactionIndex)
                } else {
                    senderReactions.reactions.append(reaction)
                }
                reactionIcons = senderReactions.reactions
                
                messageReactions.remove(at: index)
                if !reactionIcons.isEmpty {
                    messageReactions.insert(senderReactions, at: index)
                }
            } else {
                reactionIcons = [reaction]
                messageReactions.append(ChatMessageReaction(senderJid: senderJid, reactions: [reaction]))
            }
            chatMessageReactions = messageReactions
        } else {
            reactionIcons = [reaction]
            chatMessageReactions = [ ChatMessageReaction(senderJid: senderJid, reactions: [reaction]) ]
        }
        
        let uniqueId = message.xmppId
        ReactionManager.shared.saveReactionsInLocalDatabase(
            xmppId: uniqueId,
            senderJid: senderJid,
            reactions: chatMessageReactions
        ) {
            self.justSent = true
            ReactionManager.shared.sendReactions(
                xmppId: uniqueId,
                stanzaId: message.stanzaId,
                receiverJid: receiverJid,
                senderJid: senderJid,
                isGroup: false,
                reactions: reactionIcons,
                stream: stream
            )
        }
    }
    
    override open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        UIMenuController.shared.menuItems = nil
        if gestureRecognizer == self.longPressGestureRecognizer {
            return true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    
    override open func collectionView(_: UICollectionView, shouldShowMenuForItemAt indexPath: IndexPath) -> Bool {
        return false
        /*guard let _ = messagesCollectionView.messagesDataSource, let _ = messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell else { return false }
        
        if isSectionReservedForTypingIndicator(indexPath.section) {
            return false
        }
        
        return true*/
    }
    
    func deleteMessage(at indexPath: IndexPath) {
        //what if this isn't the last message? The lastMessageId gets removed wrongly
        if let message = self.messageAt(indexPath) {
            if let nextMessage = self.nextMessageForItem(at: indexPath) as? ChatMessage {
                let nextId = nextMessage.uniqueId as NSString
                self.messageSizeCache.removeObject(forKey: nextId)
                self.messageBottomCache.removeObject(forKey: nextId)
                self.cellTopCache.removeObject(forKey: nextId)
            }
            if let prevMessage = self.prevMessageForItem(at: indexPath) as? ChatMessage {
                let prevId = prevMessage.uniqueId as NSString
                self.messageSizeCache.removeObject(forKey: prevId)
                self.messageBottomCache.removeObject(forKey: prevId)
                self.cellTopCache.removeObject(forKey: prevId)
            }
            let msgId = message.uniqueId as NSString
            self.messageSizeCache.removeObject(forKey: msgId)
            self.messageBottomCache.removeObject(forKey: msgId)
            self.cellTopCache.removeObject(forKey: msgId)
            self.justSent = true
            ChatMessageModel.deleteMessage(with: message.uniqueId)
        }
    }

    /*open func didPressAccessoryButton(_ sender: UIButton) {
        if (sender == self.cameraButton || sender == self.attachButton) {
            self.getAttachmentPicker().showAlertController(fromSourceView: sender)
        }
    }*/
    
    func isFailedDecrypt(at indexPath:IndexPath) -> Bool {
        if let message = self.messageAt(indexPath) {
            return self.isFailedDecryptMessage(message)
        }
        return false
        
    }

    func isFailedDecryptMessage(_ message:ChatMessage) -> Bool {
        if let msgText = message.text {
            if msgText.hasPrefix("Couldn't decrypt") || msgText.hasPrefix("Glacierbot") || msgText.hasPrefix("Glacierbot") {
                return true
            }
        }
        return false
    }

    @objc func handleFailedDecryptGesture() {
        let alert = UIAlertController(title: "Reset Sessions", message: "The received message was out of sync and cannot be decrypted. Resetting sessions and sending a message will fix this for future messages. This error does not affect message security.", preferredStyle: .alert)

        let resetAction = UIAlertAction(title: CANCEL_STRING(), style: .default, handler: { alert in
            self.doResetSecureConnections()
        })
        let cancelAction = UIAlertAction(title: CANCEL_STRING(), style: .default, handler: nil)
        alert.addAction(resetAction)
        alert.addAction(cancelAction)
        present(alert, animated: true, completion: nil)
    }

    func doResetSecureConnections() {
        if let xmpp = xmppManager(), let account = self.getAccount() {
            var devices:[NSNumber] = []
            let hud = MBProgressHUD.showAdded(to: self.view, animated: true)
            if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() {
                let idNumber = NSNumber.init(integerLiteral: Int(bundle.deviceId))
                let currentDevice = ChatOmemoDevice(deviceId: idNumber, trustLevel: OMEMOTrustLevel.trustedUser, parentKey: account.uniqueId, parentCollection: ChatAccountModel.collection(), publicIdentityKeyData: bundle.identityKey, lastSeenDate: xmpp.getLastConnected())
                if let acctRec = account.grdbRecord, let bareJid = XMPPJID(string: acctRec.username), var curdevices = xmpp.omemoSignalCoordinator?.fetchDeviceIds(for: bareJid) {
                    //let removedDevices = [currentDevice.deviceId]
                    //let nsDevices:NSArray = devices as NSArray
                    /*let indexSet = (curdevices as NSArray).indexesOfObjects(passingTest: {(obj:Any, idx:Int, stop:UnsafeMutablePointer<ObjCBool>) -> Bool in
                        return removedDevices.contains(obj as! NSNumber)
                    })*/
                    
                    let removeId = NSNumber(value:currentDevice.deviceId)
                    let iset = curdevices.enumerated().lazy
                        .filter {
                            removeId == $0.element
                        }.map{$0.offset}
                    let indexSet = IndexSet(iset)
                    
                    curdevices.remove(atOffsets: indexSet)
                    devices = curdevices
                }
                
                var allDevices = [currentDevice]
                var buddiesArray:[ChatBuddy] = []
                
                if let buddy = self.getBuddy() {
                    buddiesArray.append(buddy)
                    let bdevices = ChatOmemoDevice.allOMEMODevices(for: buddy.uniqueId)
                    allDevices.append(contentsOf: bdevices)
                }
                
                xmpp.omemoSignalCoordinator?.removeDevice(allDevices, localOnly: true, completion: { (success:Bool) in })
                
                ChatAccountSignalIdentity.removeAccountSignalIdKey(for: account.uniqueId)
                ChatSignedPreKey.removeSignalSignedPreKey(for: account.uniqueId)
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle() {
                        xmpp.omemoSignalCoordinator?.omemoModule?.publishBundle(bundle, elementId: nil)
                        let idNumber = NSNumber.init(integerLiteral: Int(bundle.deviceId))
                        devices.append(idNumber)
                        xmpp.omemoSignalCoordinator?.omemoModule?.publishDeviceIds(devices, elementId: nil)
                        
                        DispatchQueue.global().async {
                            for buddy in buddiesArray {
                                xmpp.omemoSignalCoordinator?.prepareSessionForBuddy(buddy.uniqueId, completion: { (success:Bool) in
                                    //
                                })
                            }
                        }
                    }
                    
                    DispatchQueue.main.async {
                        hud.removeFromSuperview()
                    }
                }
            }
        }
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        removeContextMenuIfAvailable()
        messageInputBar.inputTextView.resignFirstResponder()
        
        let touchPoint = touch.location(in: messagesCollectionView)
        if let indexPath = self.messagesCollectionView.indexPathForItem(at: touchPoint),
           let selectedCell = messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell {
            selectedCell.checkIfUserTouchedAnyReaction(touch) { reaction in
                let msg = self.shownMessages[indexPath.section]
                guard reaction != nil, let reactions = msg.reactions, !reactions.isEmpty else { return }
                self.longIndex = indexPath
                self.showReactionDetails(userReactions: reactions)
            }
        }
        
        return true
    }
    
    private func removeContextMenuIfAvailable() {
        guard let contextMenuView = view.viewWithTag(12345) else {
            return
        }
        contextMenuView.removeFromSuperview()
        isShowingContextMenu = false
    }
    
    private func showReactionDetails(userReactions: [ChatMessageReaction]) {
        guard let chatBuddy = self.getBuddy() else { return }
        
        let usersWhoReacted: [(userName: String, reactions: [String])] = userReactions.compactMap {
            guard let userName = $0.senderJid.split(separator: "/").first else { return nil }
            return (userName: userName.description, reactions: $0.reactions)
        }
        
        var chatParticipants: [(isSelf: Bool, userName: String, name: String, avtarImage: Data?)] = [
            (isSelf: false, userName: chatBuddy.username, name: chatBuddy.displayName ?? "", avtarImage: chatBuddy.avatarData)
        ]
        
        if let currentUserAccount = getAccount() {
            chatParticipants.append((isSelf: true, userName: currentUserAccount.username, name: currentUserAccount.displayName, avtarImage: currentUserAccount.avatarData))
        }
        
        var userReactionDetails = [UserReactionDetails]()
        for participant in chatParticipants {
            if let user = usersWhoReacted.first(where: { $0.userName.lowercased() == participant.userName.lowercased()}), !user.reactions.isEmpty {
                let details = UserReactionDetails(isSelf: participant.isSelf, displayName: participant.name, avatarImage: participant.avtarImage, reactions: user.reactions)
                userReactionDetails.append(details)
            }
        }
        
        guard !userReactionDetails.isEmpty else { return }
        let reactionDetailsVC = UserReactionDetailsViewController(reactionDetails: userReactionDetails, delegate: self)
        reactionDetailsVC.modalPresentationStyle = .pageSheet
        if let sheet = reactionDetailsVC.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.preferredCornerRadius = 30
            sheet.prefersGrabberVisible = true
        }
        present(reactionDetailsVC, animated: true)
    }
    
    private func showSelectedUserProfile(_ chatAccount: ChatAccountModel) {
        guard let chatBuddy = getBuddy(),
              var chatThread = ChatThread.getChatThread(threadId: chatBuddy.chatThreadId) else { return }

        let profileView = UserProfileView(
            account: chatAccount,
            shouldShowReadReceiptsSetting: true,
            isReadReceiptsOn: chatThread.isReadReceiptsOn,
            onReadReceiptsSettingChanged: { value in
                chatThread.isReadReceiptsOn = value
                chatThread.save()
            }
        )
        
        let hostingVC = UIHostingController(rootView: profileView)
        hostingVC.modalPresentationStyle = .formSheet
        present(hostingVC, animated: true)
    }
}

// MARK: MessageCellDelegate

extension ChatViewController: MessageCellDelegate {
    public func didTapMessage(in cell: MessageCollectionViewCell) {
        guard let indexPath = messagesCollectionView.indexPath(for: cell), let message = self.messageAt(indexPath) else {
            return
        }
        
        if let txt = message.text, txt.starts(with: "geo:") {
            self.findBuddyLocation(txt, with: message)
        }
        
        if let mediaKey = message.mediaItemUniqueId, let item = ChatMediaItemModel.getMediaItem(with: mediaKey) as? ChatHTMLItem {
            if let urlstr = item.getFilename(), let url = URL(string: urlstr) {
                self.didSelectURL(url)
            }
        }
    }

    public func didTapImage(in cell: MessageCollectionViewCell) {
        guard !isShowingContextMenu, let indexPath = messagesCollectionView.indexPath(for: cell),
              let message = messagesCollectionView.messagesDataSource?.messageForItem(at: indexPath, in: messagesCollectionView)
        else {
            return
        }
      
        if let chatMsg = message as? ChatMessage, let mediaKey = chatMsg.mediaItemUniqueId, let mediaItem = ChatMediaItemModel.getMediaItem(with: mediaKey), (chatMsg.transferProgress == 1 || mediaItem.grdbRecord?.transferProgress == 1) {
            if let imgItem = mediaItem as? ChatImageItem, let imgUrl = imgItem.url {
                if let origtext = chatMsg.originalText, origtext.hasPrefix("geo") {
                    self.findBuddyLocation(origtext, with: chatMsg)
                } else {
                    if let prog = chatMsg.transferProgress, prog < 1.0 {
                        self.handleMissingMedia(chatMsg)
                    } else {
                        imgItem.downloadImage(imgUrl, filename: mediaItem.grdbRecord?.filename, completion: {[weak self] (img, url, data) in
                            guard let img = img, let self = self else {return}
                            DispatchQueue.main.async {
                                self.agrumeVC.openImage(img, from: self)
                            }
                        })
                    }
                }
            } else if let vidItem = mediaItem as? ChatVideoItem {
                self.showVideo(vidItem)
            } else if let fileItem = mediaItem as? ChatFileItem {
                self.showFile(fileItem)
            } else if let htmlItem = mediaItem as? ChatHTMLItem {
                if let urlstr = htmlItem.getFilename(), let url = URL(string: urlstr) {
                    self.didSelectURL(url)
                }
            }
        }
    }
    
    func handleMissingMedia(_ chatMsg:ChatMessage) {
        let alert = UIAlertController(title: "Unable to Open", message: "There was an issue retrieving media. Try again in a few seconds.", preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: "OK", style: .default, handler: {_ in
            if let xmpp = self.xmppManager() {
                DispatchQueue.global().async {
                    let model = ChatMessageModel(message: chatMsg)
                    xmpp.fileTransferManager.retryDownloadMedia(model)
                }
            }
        })
        alert.addAction(cancelAction)
        present(alert, animated: true, completion: nil)
        return
    }
        
    func showFile(_ fileItem: ChatFileItem) {
        if let fileURL = OTRMediaServer.sharedInstance().url(forChatMediaItem: fileItem, buddyUniqueId: self.threadKey) {
            let webview = RoomAttachmentWebViewController.init(url: fileURL, data: nil, baseurl: fileURL.deletingLastPathComponent())
            self.navigationController?.pushViewController(webview, animated: true)
        }
    }

    public func didTapPlayButton(in cell: AudioMessageCell) {
        guard
            let indexPath = messagesCollectionView.indexPath(for: cell),
            let message = messagesCollectionView.messagesDataSource?.messageForItem(at: indexPath, in: messagesCollectionView)
        else {
            print("Failed to identify message when audio cell receive tap gesture")
            return
        }
        
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
        } catch {
            DDLogError("ChatViewController.didTapPlayButton error setting category")
        }
        
        var playbackSpeed: Float = 1.0
        if let rate = UserDefaults.standard.value(forKey: kAudioPlaybackSpeed) as? Float {
            playbackSpeed = rate
        }
        
        //let astate = audioPlaybackController.state
        guard audioPlaybackController.state != .stopped else {
            // There is no audio sound playing - prepare to start playing for given audio message
            audioPlaybackController.playSound(for: message, in: cell, speed: playbackSpeed)
            return
        }
        if audioPlaybackController.playingMessage?.messageId == message.messageId {
            // tap occur in the current cell that is playing audio sound
            if audioPlaybackController.state == .playing {
                audioPlaybackController.pauseSound(for: message, in: cell)
            } else {
                audioPlaybackController.resumeSound()
            }
         } else {
             // tap occur in a difference cell that the one is currently playing sound. First stop currently playing and start the sound for given message
             audioPlaybackController.stopAnyOngoingPlaying()
             audioPlaybackController.playSound(for: message, in: cell, speed: playbackSpeed)
         }
    }

    public func didStartAudio(in _: AudioMessageCell) {
        print("Did start playing audio sound")
    }

    public func didPauseAudio(in _: AudioMessageCell) {
        print("Did pause audio sound")
    }

    public func didStopAudio(in _: AudioMessageCell) {
        print("Did stop audio sound")
    }

    public func didTapAccessoryView(in _: MessageCollectionViewCell) {
        print("Accessory view tapped")
    }
}

// MARK: MessageLabelDelegate

extension ChatViewController: MessageLabelDelegate {
    public func didSelectPhoneNumber(_ phoneNumber: String) {
        print("Phone Number Selected: \(phoneNumber)")
    }

    public func didSelectURL(_ url: URL) {
        let alert = UIAlertController(title: "Available Actions", message: nil, preferredStyle: .actionSheet)
        
        let actions = UIAlertAction.actionsFor(url: url, viewController: self)
        for obj in actions {
            alert.addAction(obj)
        }
        
        alert.addAction(self.cancelAction())
        
        // Get the anchor
        alert.popoverPresentationController?.sourceView = self.view
        alert.popoverPresentationController?.sourceRect = self.view.bounds
        
        self.present(alert, animated: true, completion: nil)
    }
}

public extension ChatViewController {
    @objc func handleDeviceListUpdate(notification:Notification) {
        guard let notificationJid = notification.userInfo?["jid"] as? XMPPJID else { return }
        guard let buddy = self.getBuddy() else { return }
        if notificationJid.bare == buddy.username {
            checkDeviceListUpdate(buddy: buddy)
        }
    }
    
    func checkDeviceListUpdate(buddy:ChatBuddy) {
        let buddyModel = ChatBuddyModel(buddy: buddy)
        guard let jid = buddyModel.bareJID, let xmpp = self.xmppManager() else { return }
        let devices: [ChatOmemoDevice] = ChatOmemoDevice.allOMEMODevices(for: buddy.uniqueId)
        let omemo: OMEMOModule? = xmpp.omemoSignalCoordinator?.omemoModule
    
        // Not the right place for this, but we need to fetch missing bundle data
        // to show fingerprints. Hopefully they are fetched in time.
        devices.forEach({ (device) in
            if device.publicIdentityKeyData == nil {
                omemo?.fetchBundle(forDeviceId: UInt32(device.deviceId), jid: jid, elementId: nil)
            }
        })
    }
}


extension ChatViewController { //call stuff
    //this should spawn a menu of audio/video
    func didSelectPhoneButton(callType: CallType) {
        //var owner:ChatThread?
        var callBuddies:[String] = []
        if let xmppMgr = xmppManager(), let buddy = self.getBuddy() {
            callBuddies.append(buddy.username)
            //owner = buddy
            
            if callBuddies.count == 0 {
                return
            }
            
            //IOSM-464 verify
            if xmppMgr.callManager.checkAudioPermissions() == true {
                AVAudioSession.sharedInstance().requestRecordPermission({ [weak self] (granted) in
                    DispatchQueue.main.async {
                        if (granted) { return }
                        let alert = UIAlertController(title: "Allow Audio", message: "Whoops! It looks like you have not permitted Glacier to access your Microphone. To use Glacier calling, please enable the Microphone in the Glacier settings on your device. For a video call, make sure Camera is enabled also.", preferredStyle: .alert)
                        let enableAction = UIAlertAction(title: "Enable", style: .default, handler: { alert in
                            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settingsURL)
                            }
                        })
                        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
                        alert.addAction(enableAction)
                        alert.addAction(cancelAction)
                        self?.present(alert, animated: true, completion: nil)
                    }
                })
            } else if callType == .video, xmppMgr.callManager.checkVideoPermissions() == true {
                handleVideoDenied()
                return
            } else {
                if xmppMgr.callManager.makeCall(callBuddies, name:self.getThreadName()!, callType: callType) == true { //IOSM#70 if
                    // add "outgoing" message to thread
                    let message = "\(ChatRoomMessage.StringConstants.outgoingCall.text) - \(Date().formattedAsShortWeekdayTime())"
                    self.addCallUpdate(message, mgr: xmppMgr, buddy: buddy)

                    DispatchQueue.main.async {
                        guard let currentCall = xmppMgr.callManager.currentCall,
                              OTRAppDelegate.appDelegate.callWindow?.rootViewController == nil,
                              let title = currentCall.calltitle else { return }
                        OTRAppDelegate.appDelegate.openVideoCallController(title)
                    }
                }
            }
            
            //IOSM-509 prevent accidental hot mic
            //let alert = UIAlertController(title: "Start Call?", message: nil, preferredStyle: .alert)
            //let callAction = UIAlertAction(title: "Call", style: .default, handler: { alert in
                //if xmppMgr.callManager.makeCall(callBuddies, name:self.getThreadName()!) == true { //IOSM#70 if
                    // add "outgoing" message to thread
                    //self.addCallUpdate("You called", mgr: xmppMgr, buddy: buddy)
                //}
            //})
            //let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
            //alert.addAction(callAction)
            //alert.addAction(cancelAction)
            //self.present(alert, animated: true, completion: nil)
        }
    }
    
    func handleVideoDenied() {
        handlePermissionDenied("Allow Video", message: "Whoops! It looks like you have not permitted Glacier to access your Camera. To use Glacier video calling, please enable the Camera in the Glacier settings on your device. Note: You cannot do this during the call or the call will drop.", includeEnable: false)
    }
    
    func handlePermissionDenied(_ title: String, message: String, includeEnable: Bool) {
        DispatchQueue.main.async {
            let permissionAlert = UIAlertController(title: title, message: message, preferredStyle: .alert)

            if (includeEnable) {
                permissionAlert.addAction(UIAlertAction(title: "Enable", style: .default, handler: { (action) -> Void in
                    if let appSettings = URL(string: UIApplication.openSettingsURLString) {
                        Application.shared.open(appSettings, options: [:], completionHandler: nil)
                    }
                }))
                permissionAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { (action) -> Void in
                    //do nothing
                }))
            } else {
                permissionAlert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { (action) -> Void in
                    //do nothing
                }))
            }
            
            self.present(permissionAlert, animated: true, completion: nil)
        }
    }

    // added msg, owner
    func addCallUpdate(_ updateMsg:String, mgr:XMPPManager, buddy:ChatBuddy) {
        let budModel = ChatBuddyModel(buddy: buddy)
        let message = budModel.outgoingMessage(text: updateMsg)
        message.messageSecurity = OTRMessageTransportSecurity.plaintext //omemo not needed
        
        if let systemMsgModel = message as? OutgoingChatMessage, var systemMsg = systemMsgModel.grdbRecord {
            
            if let acct = getAccount() {
                systemMsg.msgSenderId = acct.uniqueId
                systemMsg.msgSenderDisplayName = acct.displayName
            }
            
            systemMsg.systemUpdate = true
            systemMsg.dateSent = Date()
            systemMsg.readDate = Date()
            systemMsg.originalText = updateMsg
            systemMsg.storeInGRDB()
            
            if var owner = self.getThread() {
                owner.lastMessageId = message.messageKey
                owner.messageDate = message.messageDate
                owner.storeInGRDB()
            }
        }
    }

    func enablePhoneButton(_ enable:Bool) {
        //IOSM-503 handle this when not just a single bar button
        let navitem = self.navigationItem
        if let rightNav = navitem.rightBarButtonItem {
            rightNav.isEnabled = enable
        }
        
        UIApplication.shared.isIdleTimerDisabled = !enable
    }
}

extension ChatViewController { //XMPP stuff
    func sendPresenceProbe() {
        if let xmpp = xmppManager(), let chatbuddy = getBuddy() {
            let buddy = ChatBuddyModel(buddy: chatbuddy)
            xmpp.sendPresenceProbe(forBuddy: buddy)
        }
    }
    
    // Hack to manually re-fetch OMEMO devicelist because PEP sucks
    // TODO: Ideally this should be moved to some sort of manual refresh in the Profile view
    func fetchOMEMODeviceList() {
        if let xmpp = xmppManager(), let buddy = getBuddy(), let jid = XMPPJID(string: buddy.username) {
            xmpp.omemoSignalCoordinator?.omemoModule?.fetchDeviceIds(for: jid, elementId: nil)
        }
    }
    
    func updateView(with key: String) {
        if let buddy = self.getBuddy() {
            let buddyModel = ChatBuddyModel(buddy: buddy)
            // Update Buddy Status
            //let previousState = self.state.isThreadOnline
            self.state.isThreadOnline = (buddyModel.status != ThreadStatus.offline)
                    
            /*if (self.state.isThreadOnline && (buddyModel.chatState == ChatState.composing || buddyModel.chatState == ChatState.paused)) {
                self.showTypingIndicator = true
            } else {
                self.showTypingIndicator = false
            }*/
                    
            self.refreshTitleView()
        }
        self.tryToMarkAllMessagesAsRead()
    }
    
    func tryToMarkAllMessagesAsRead() {
        // Set all messages as read
        if self.otr_isVisible() {
            if let xmpp = xmppManager(), let buddy = self.getBuddy(), let chatThread = ChatThread.getChatThread(threadId: buddy.chatThreadId) {
                ChatMessageModel.markAllUnreadMessages(for: buddy.uniqueId, completion: { (messagesUpdated:[ChatMessageModel]) in
                    //these should all be markable, thus needing receipt
                    guard chatThread.shouldShowReadReceipts else { return }
                    for msg in messagesUpdated {
                        xmpp.sendReadReceipt(msg)
                    }
                })
            }
        }
    }
    
    private func indexPathForNextToLastItem() -> IndexPath? {
        let numsecs = self.messagesCollectionView.numberOfSections
        guard numsecs > 1 else { return nil }

        for offset in 2 ... numsecs {
            let section = numsecs - offset
            let lastItem = self.messagesCollectionView.numberOfItems(inSection: section) - 1
            if lastItem >= 0 {
                return IndexPath(item: lastItem, section: section)
            }
        }
        return nil
    }
    
    @objc func updateForExpiringMessages(_ timer:Timer) {
        var expiring = false
        var expiringPath:[IndexPath] = []
        var expiredpath:IndexPath?
        
        let msgs = self.shownMessages
        for (index, message) in msgs.enumerated() {
            if let expires = message.expires {
                let ipath = IndexPath(row: 0, section: index)
                if let tint:TimeInterval = Double(expires), let rdate = message.readDate, rdate.addingTimeInterval(tint).timeIntervalSinceNow <= 0 {
                    expiredpath = ipath
                    continue
                }
                    
                let expstr = self.getExpiringString(for: message)
                if let cachestr = self.expiringCache.object(forKey: message.uniqueId as NSString) as? String, cachestr == expstr {
                    //no need for redoing
                    continue
                }

                expiringPath.append(ipath)
                expiring = true
            }
        }
        
        if (expiring) {
            self.messagesCollectionView.reconfigureItems(at: expiringPath)
        }
        if let expPath = expiredpath {
            dsQueue.async {
                self.deleteMessage(at: expPath)
            }
        }
    }
    
    func showDate(at indexPath:IndexPath, message:ChatMessage) -> Bool {
        if (indexPath.section == 0) {
            return true
        }
        
        if let prev = self.prevMessageForItem(at: indexPath) as? ChatMessage {
            let timediff = message.date.timeIntervalSince(prev.date)
            if (timediff > ChatViewController.kOTRMessageSentDateShowTimeInterval) {
                return true
            }
        }
        
        /*let previp = IndexPath(row: 0, section: indexPath.section-1)
        if let prev = self.messageAt(previp) {
            let timediff = message.date.timeIntervalSince(prev.date)
            if (timediff > ChatViewController.kOTRMessageSentDateShowTimeInterval) {
                return true
            }
        }*/
        
        return false
    }
    
    /** Currently uses clock for queued, and checkmark for delivered. */
    func deliveryStatusString(for message:ChatMessage, indexPath: IndexPath) -> NSAttributedString? {
        guard message.type == ChatMessageType.outgoing.rawValue else { return nil }
        let deliveryStatusString = NSMutableAttributedString(string: "")
        
        //var deliveryStatusString:String?
        if message.dateSent == nil { //} && ![message messageMediaItemKey]) { //IOSM#57
            // Waiting to send message. This message is in the queue.
            let clockChar: UniChar = 0xf017
            let clockString = String(format: " %C", clockChar)
            deliveryStatusString.append(NSAttributedString(string: clockString, attributes: faattrs))
        } else if message.displayed {//}&& !(message is RoomMessage) { //IOSM-443 and IOSM#8
            //let checkChar: UniChar = 0xf00c
            if let buddy = getBuddy(),
               let dateDisplayed = message.dateDisplayed, dateDisplayed == self.latestDateDisplayed {
                if let chatThread = ChatThread.getChatThread(threadId: buddy.chatThreadId), chatThread.shouldShowReadReceipts {
                    deliveryStatusString.append(NSAttributedString(string: " Read ", attributes: attrs))
                    let dateString = MessageKitDateFormatter.shared.string(from: dateDisplayed)
                    deliveryStatusString.append(NSAttributedString(string: dateString, attributes: attrs))
                } else {
                    deliveryStatusString.append(NSAttributedString(string: " Delivered", attributes: attrs))
                }
            }
        } else if message.delivered {//}&& !(message is RoomMessage){
            deliveryStatusString.append(NSAttributedString(string: " Delivered", attributes: attrs))
            //let checkChar: UniChar = 0xf00c
            //let checkString = String(format: " %C", checkChar)
            //deliveryStatusString.append(NSAttributedString(string: checkString, attributes: faattrs))
        }
        
        return deliveryStatusString
        
        /*if let deliveryStatus = deliveryStatusString {
            let font = UIFont(name: kFontAwesomeFont, size: 11)
            return NSAttributedString(string: deliveryStatus, attributes:[NSAttributedString.Key.font:font ?? UIFont.systemFont(ofSize: 12)])
        }
        return nil*/
    }
    
    func getExpiringString(for message:ChatMessage) -> String {
        if message.expires != nil {
            let timeLeft = self.getTimeUntilExpires(message)
            if timeLeft > 0, let secLeft = ChatViewController.exptf.string(for: timeLeft) {
                return secLeft
            }
        }
        
        return ""
    }
    
    func getTimeUntilExpires(_ message:ChatMessage) -> TimeInterval {
        let rdate = message.readDate ?? Date()
        if message.readDate == nil {
            var msg = message
            msg.readDate = Date()
            msg.modified = Date()
            msg.save()
        }
        
        if let expires = message.expires, let tint:TimeInterval = Double(expires) {
            return rdate.addingTimeInterval(tint).timeIntervalSinceNow
        }
        
        return 0.0
    }
    
    func getAvatarImages() {
        if self.fromAvatar == nil {
            if let account = ChatAccountModel.firstAccount() {
                let initials = account.displayName.prefix(2)
                self.fromAvatar = Avatar(image: account.avatarImage, initials: String(initials))
            }
        }
        if let buddy = self.getBuddy() {
            var binitials:String = ""
            if let dname = buddy.displayName?.prefix(2) {
                binitials = String(dname)
            }
            let bmodel = ChatBuddyModel(buddy: buddy)
            let avImage = bmodel.avatarImage
            self.toAvatar = Avatar(image: avImage, initials: binitials)
        }
    }
    
    func messageAt(_ indexPath:IndexPath) -> ChatMessage? {
        if self.shownMessages.count > indexPath.section {
            return self.shownMessages[indexPath.section]
        }

        return nil
    }
}

extension ChatViewController: OTRAttachmentPickerDelegate{
    public func addUploadHUD() {
        self.addUploadHUD("Preparing upload, tap to cancel...", tapToCancel: true)
    }
    
    public func addUploadHUD(_ message: String, tapToCancel: Bool) {
        if self.uploadHUD == nil { //IOSM-601
            self.uploadHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
            self.uploadHUD?.label.text = message
            if tapToCancel == true {
                let hudSingleTap = UITapGestureRecognizer(target: self, action: #selector(self.hudTap(sender:)))
                self.uploadHUD?.addGestureRecognizer(hudSingleTap)
            }
        }
    }
    
    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, gotPhoto photo: UIImage, withInfo info: [AnyHashable : Any]) {
        self.sendPhoto(photo, asJPEG: true, shouldResize: true, userTypedText: self.messageInputBar.inputTextView.text, info: info)
        self.messageInputBar.inputTextView.text = nil
    }
    
    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, gotVideoURL videoURL: URL) {
        self.sendVideoURL(videoURL)
    }
    
    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, gotGif photo: UIImage, withInfo info: [AnyHashable : Any]) {
        self.sendPhoto(photo, asJPEG: false, shouldResize: false, userTypedText: self.messageInputBar.inputTextView.text, info: info)
        self.messageInputBar.inputTextView.text = nil
    }

    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, preferredMediaTypesFor source: UIImagePickerController.SourceType) -> Array<String>
    {
        return [UTType.image.identifier, UTType.movie.identifier]
    }

    public func attachmentPicker(_ attachmentPicker: OTRAttachmentPicker, gotFileURLs fileURLs: Array<URL>) {
        self.sendFileURLs(fileURLs)
    }
}

extension ChatViewController: UIPopoverPresentationControllerDelegate{
    public func prepareForPopoverPresentation(_ popoverPresentationController: UIPopoverPresentationController) {
        // Without setting this, there will be a crash on iPad
        // This delegate is set in the OTRAttachmentPicker
        popoverPresentationController.sourceView = self.attachButton
    }
}

//#pragma - mark Media Display Methods
extension ChatViewController: AVPlayerViewControllerDelegate {
    
    func showVideo(_ videoItem: ChatVideoItem) {
        if let videoURL = videoItem.mediaServerURL() {
            let player = AVPlayer.init(url: videoURL)
            let moviePlayerViewController = AVPlayerViewController()
            moviePlayerViewController.player = player
            
            //IOSM-467
            moviePlayerViewController.delegate = self
            self.originalAudioCategory = AVAudioSession.sharedInstance().category as AVAudioSession.Category
            do {
                try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
            } catch {
                DDLogError("ChatViewController.showVideo error setting category")
            }
            present(moviePlayerViewController, animated: true, completion: nil)
        }
    }
    
    //IOSM-467
    public func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        if playerViewController.isBeingDismissed, let audioCat = self.originalAudioCategory {
            do {
                try AVAudioSession.sharedInstance().setCategory(audioCat)
            } catch {
                DDLogError("ChatViewController.playerViewController error setting category")
            }
        }
    }
}

// MARK: AttachmentsInputBarViewDelegate

extension ChatViewController: AttachmentsInputBarViewDelegate {
    func didPressPlus(with inputBar: InputBarAccessoryView) {
        self.messageInputBar.inputTextView.resignFirstResponder()
        floaty.open()
    }
    
    func didChooseVideo(with url: URL) {
        self.handleVideoPicked(url)
    }
    
    public func inputBar(_ inputBar: InputBarAccessoryView, didPressSendButtonWith attachments: [AttachmentManager.Attachment]) {
        if handleProxy() {
            return
        }
        var shouldResetInputTextView = false
        for (index, item) in attachments.enumerated() {
            switch item {
            case .image(let image):
                let isLastImage = index == attachments.count - 1
                let userTypedText: String? = isLastImage ? self.messageInputBar.inputTextView.text : nil
                self.sendPhoto(image, asJPEG: true, shouldResize: true, userTypedText: userTypedText, info: nil)
                shouldResetInputTextView = shouldResetInputTextView || isLastImage
            case .url(let url):
                self.handleVideoPicked(url)
            case .data(_):
                continue
                //self.sendPhoto(image, asJPEG: true, shouldResize: true, info: nil)
            case .other(_):
                continue
            }
            //if case .image(let image) = item {
           //     self.sendPhoto(image, asJPEG: true, shouldResize: true, info: nil)
            //}
        }
        
        inputBar.invalidatePlugins()
        if shouldResetInputTextView {
            inputBar.resetText()
            inputBar.resetSize()
        }
    }
    
    @objc public func inputBar(_: InputBarAccessoryView, didPressSendButtonWith _: String) {
        if handleProxy() == false {
            processInputBar(messageInputBar)
        }
    }
    
    private func handleProxy() -> Bool {
        if OTRAppDelegate.appDelegate.isProxyDetected() == true {
            let warningMessage = "Device Proxy Detected, will not send messages for security reasons."
            let okAction = UIAlertAction(title: "OK", style: .default)
            let alert = UIAlertController(title: "Security Warning", message: warningMessage, preferredStyle: .alert)
            alert.addAction(okAction)
            self.present(alert, animated: true)
            return true
        }
        
        return false
    }
    
    func processInputBar(_ inputBar: InputBarAccessoryView) {
        // Here we can parse for which substrings were autocompleted
        /*let attributedText = inputBar.inputTextView.attributedText!
        let range = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(.autocompleted, in: range, options: []) { _, range, _ in

            //let substring = attributedText.attributedSubstring(from: range)
            //let context = substring.attribute(.autocompletedContext, at: 0, effectiveRange: nil)
            //print("Autocompleted: `", substring, "` with context: ", context ?? [])
        }*/
        
        guard let text = inputBar.inputTextView.text, text.count > 0, OTRAppDelegate.appDelegate.isProxyDetected() == false else {
            inputBar.sendButton.image = nil
            inputBar.sendButton.title = "Send"
            inputBar.inputTextView.placeholder = "Send encrypted message"
            inputBar.sendButton.isEnabled = false
            (self as? ChatViewControllerExt)?.removePush2TalkButton()
            return
        }

        //let components = inputBar.inputTextView.components
        inputBar.inputTextView.text = String()
        inputBar.invalidatePlugins()
        // Send button activity animation
        inputBar.sendButton.startAnimating()
      
        self.navigationController?.providesPresentationContextTransitionStyle = true
        self.navigationController?.definesPresentationContext = true
      
        // Resign first responder for iPad split view
        if ChatViewController.IS_IPHONE == false {
            inputBar.inputTextView.resignFirstResponder()
        }
        
        //IOSM-486, IOSM-557 check for links
        //IOSM-579
        let sendtxt = self.convertBadLinksText(text)
        let msgurls = sendtxt.urls
        if msgurls.count > 0, self.automaticURLFetchingDisabled == false {
            self.handleTextWithLinks(sendtxt, msgurls:msgurls)
        } else {
            self.doSendMessage(text)
        }
    
        inputBar.sendButton.stopAnimating()
        inputBar.inputTextView.placeholder = "Send encrypted message"
        //self.insertMessages(components)
        self.messagesCollectionView.scrollToLastItem(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.messagesCollectionView.scrollToLastItem(animated: true)
        }
    }
    
    public func inputBar(_ inputBar: InputBarAccessoryView, textViewTextDidChangeTo text: String) {
        /*
        let hasText = textView.text.count > 0
        if (hasText != self.state.hasText) {
            self.state.hasText = hasText
        }*/
        
        //Everytime the textview has text and a notification comes through we are 'typing' otherwise we are done typing
        let textView = self.messageInputBar.inputTextView
        let hasText = textView.text.count > 0
        if (hasText) {
            messageInputBar.sendButton.image = nil
            //self.isTyping()
        } else {
            (self as? ChatViewControllerExt)?.updateTimeButton()
            //self.didFinishTyping()
        }
        
        if let untrimmed = self.messageInputBar.inputTextView.text, untrimmed.hasSuffix("\n"), OTRSettingsManager.bool(forOTRSettingKey: "kOTREnterToSendKey") {
            self.messageInputBar.inputTextView.text = text
            processInputBar(messageInputBar)
        }
    }
    
    func handleVideoPicked(_ url:URL) {
        let fileManager = FileManager.default
        let temporaryPath = NSTemporaryDirectory()
        let tmpPath = temporaryPath.appending(url.lastPathComponent)
            
        if fileManager.fileExists(atPath: tmpPath) {
            do {
                try fileManager.removeItem(atPath: tmpPath)
            } catch { }
        }
            
        DispatchQueue.main.async {
            self.addUploadHUD()
        }
          
        do {
            let vidurl = URL(fileURLWithPath: tmpPath)
            try fileManager.copyItem(at: url, to:vidurl)
            //let newurl = URL(fileURLWithPath: tmpPath)
            DispatchQueue.main.async {
                self.sendVideoURL(vidurl)
            }
        } catch {
            DDLogError("ChatViewController.handleVideoPicked error copying video item")
        }
    }
    
    //IOSM-486, IOSM-557
    func doSendMessage(_ text: String) {
        if let xmpp = xmppManager(), let buddy = getBuddy() {
            let budModel = ChatBuddyModel(buddy: buddy)
            let outMsg = budModel.outgoingMessage(text: text)
            
            //let outMsg = thread.outgoingOMEMOMessage(withText: text)
            if let chatMsg = outMsg as? ChatMessageModel {
                if let expires = buddy.expiresIn {
                    chatMsg.messageExpires = expires
                } else if let gtime = OTRSettingsManager.string(forOTRSettingKey: "globalTimer"), gtime != "Off" {
                    chatMsg.messageExpires = gtime
                }
                
                if let acct = getAccount() {
                    chatMsg.grdbRecord?.msgSenderId = acct.uniqueId
                    chatMsg.grdbRecord?.msgSenderDisplayName = acct.displayName
                }
                
                self.justSent = true
                xmpp.enqueueMessage(chatMsg)
            }
        }
    }
    
    //IOSM-579
    func convertBadLinksText(_ text: String) -> String {
        //let newtext = text.replacingOccurrences(of: "http://", with: "https://")
        //check out espn.com and suntrust.com and let me know
        let types: NSTextCheckingResult.CheckingType = [.link]
        let detector = try! NSDataDetector(types: types.rawValue)
        var badurls = true
        var newText = text
        while badurls == true {
            badurls = false
            
            let matches = detector.matches(in: newText, range: NSMakeRange(0, text.count))
            for match in matches {
                guard let matchrange = Range(match.range, in: newText) else { continue }
                if match.resultType == NSTextCheckingResult.CheckingType.link {
                    if let urlstr = match.url?.absoluteString, urlstr.lowercased().hasPrefix("http://"), let rangescheme = urlstr.lowercased().range(of: "http:") {
                        badurls = true
                        let newurl = urlstr.replacingCharacters(in: rangescheme, with: "https:")
                        newText = newText.replacingCharacters(in: matchrange, with: newurl)
                    }
                }
            }
        }

        return newText;
    }

    //IOSM-486, IOSM-557
    func handleTextWithLinks(_ text: String, msgurls: [URL]) {
        if !msgurls.isEmpty, let firsturl = msgurls.first {
            Task {
                let isLinkReachable = await LinkReachabilityChecker.shared.isReachable(firsturl.absoluteString)
                guard isLinkReachable else {
                    self.doSendMessage(text)
                    return
                }
                
                self.send(htmlURL: firsturl)
                if text.trimmingCharacters(in: .whitespacesAndNewlines) != firsturl.absoluteString {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.doSendMessage(text)
                    }
                }
            }
        } else {
            self.doSendMessage(text)
        }
        
        /*if let firsturl = msgurls.first, text.hasPrefix(firsturl.absoluteString) {
            self.send(htmlURL: firsturl)
            if let newtext = text.components(separatedBy: firsturl.absoluteString).last {
                if (newtext.count < 1) {
                    return
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.doSendMessage(newtext)
                }
            }
        } else if let lasturl = msgurls.last, (msgurls.count < 2 && text.hasSuffix(lasturl.absoluteString)) {
            if let newtext = text.components(separatedBy: lasturl.absoluteString).first {
                self.doSendMessage(newtext)
                self.send(htmlURL: lasturl)
            }
        } else {
            self.doSendMessage(text)
            for msgurl in msgurls {
                self.send(htmlURL: msgurl)
            }
        }*/
    }
    
    //IOSM-486, IOSM-557
    func send(htmlURL:URL) {
        //guard let htmlURL = htmlURL else { return; }
        //check urls for jpg, etc, if so use sendImageFilePath
        let ustr = htmlURL.absoluteString.lowercased()
        if ustr.hasSuffix("jpg") || ustr.hasSuffix("jpeg") || ustr.hasSuffix("png") {
            self.sendImageFilePath(htmlURL.absoluteString, asJPEG:true, shouldResize:true)
            return
        } else if ustr.hasSuffix("gif") { //IOSM#61
            self.sendImageFilePath(htmlURL.absoluteString, asJPEG:false, shouldResize:false)
            return
        } else if ustr.hasSuffix("mp4") || ustr.hasSuffix(".mov") { //IOSM#71
            DispatchQueue.global().async {
                DispatchQueue.main.async {
                    self.addUploadHUD()
                }
                
                let data = NSData(contentsOf: htmlURL)
                let fileManager = FileManager.default
                let temporaryPath = NSTemporaryDirectory()
                let tmpPath = temporaryPath.appending(htmlURL.lastPathComponent)
                
                if fileManager.fileExists(atPath: tmpPath) {
                    do {
                        try fileManager.removeItem(atPath: tmpPath)
                    } catch {
                        DDLogError("ChatViewController.sendHTMLURL error removing file item")
                    }
                }
                
                if let newdata = data, newdata.write(toFile: tmpPath, atomically: true) {
                    let newurl = URL(fileURLWithPath: tmpPath)
                    DispatchQueue.main.async {
                        self.sendVideoURL(newurl)
                    }
                } else {
                    self.removeUploadHUD()
                }
            }
            return
        }
        
        if let xmpp = xmppManager(), let thread = getThread() {
            let threadModel = ChatThreadModel(thread: thread)
            xmpp.fileTransferManager.send(htmlURL: htmlURL, thread: threadModel, isPublic: false, completion: { [weak self] (success:Bool, error:Error?) in
                self?.handleMediaError(error: error)
            })
        }
    }
}

extension ChatViewController: MessagesDisplayDelegate {
  // MARK: - Text Messages

    public func textColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        isFromCurrentSender(message: message) ? .white : .label//.darkText
    }

    public func detectorAttributes(for detector: DetectorType, and _: MessageType, at _: IndexPath) -> [NSAttributedString.Key: Any] {
        //switch detector {
        //case .hashtag, .mention: return [.foregroundColor: UIColor.blue]
        //default: return MessageLabel.defaultAttributes
        //}
        return ChatViewController.detectorAttributes
    }

    public func enabledDetectors(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> [DetectorType] {
        [.url]//, .address, .phoneNumber, .date, .transitInformation, .mention, .hashtag]
    }

  // MARK: - All Messages

    public func backgroundColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        isFromCurrentSender(message: message) ? UIColor.bubbleBlue() : UIColor.bubbleLightGray()
    }

    public func messageStyle(for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView) -> MessageStyle {
        if let msg = message as? ChatMessage, msg.systemUpdate {
            return .none
        }
        
        let tail: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft
        return .bubbleTail(tail, .curved)
    }

    public func configureAvatarView(_ avatarView: AvatarView, for message: MessageType, at ip: IndexPath, in mcv: MessagesCollectionView) {
        if let next = nextMessageForItem(at: ip), message.sender.senderId == next.sender.senderId {
            avatarView.isHidden = true
            return
        }
        
        if let msg = message as? ChatMessage, msg.systemUpdate {
            avatarView.isHidden = true
            return
        }
        
        avatarView.isHidden = false
        if isFromCurrentSender(message: message) {
            if let avatar = self.fromAvatar {
                avatarView.set(avatar: avatar)
            }
        } else if let avatar = self.toAvatar {
            avatarView.set(avatar: avatar)
        }
    }

    public func configureMediaMessageImageView(_ imageView: UIImageView, for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView)
    {
        guard case MessageKind.photo(let media) = message.kind, let chatMsg = message as? ChatMessage else {
            imageView.kf.cancelDownloadTask()
            return
        }
        
        var imageURL:URL?
        let thrId = chatMsg.buddyUniqueId
        if let chatimg = media as? ChatImageItem {
            imageURL = chatimg.mediaServerURL(thrId)
        } else if let chatfile = media as? ChatFileItem {
            imageURL = chatfile.mediaServerURL(thrId)
        } else if let htmlfile = media as? ChatHTMLItem {
            imageURL = htmlfile.mediaServerURL(thrId)
        }
        
        if let imageURL = imageURL {
            imageView.kf.indicatorType = .activity
            let thumbnailKey =  String(format: "%@-thumb", chatMsg.uniqueId)
            //print("***** imageURL: \(imageURL) and message: \(chatMsg.text)")
            let resource = KF.ImageResource(downloadURL: imageURL, cacheKey: thumbnailKey)
            if GlacierImageCache.shared().isCached(forKey: thumbnailKey) {
                imageView.kf.setImage(with: resource, options: optionsInfo)
            } else if let chatimg = media as? ChatImageItem {
                imageView.kf.indicator?.startAnimatingView()
                
                if let prog = chatimg.grdbRecord?.transferProgress, prog < 1.0 {
                    imageView.image = chatimg.placeholderImage
                    return
                }
                //var ops = optionsInfo
                //ops.append(.callbackQueue(.dispatch(self.dsQueue)))
                
                KingfisherManager.shared.retrieveImage(with: resource, options: optionsInfo) { result in
                    //if is not gif
                    switch result {
                    case .success(let img):
                        var resizedImage = img.image
                        var idata:Data? = img.data()
                        if chatimg.isGifImage() == false {
                            let mediaSize = ChatImageItem.normalizeWidth(width: img.image.size.width, height: img.image.size.height)
                            resizedImage = img.image.scaleImageWith(newSize: mediaSize)
                            idata = resizedImage.jpegData(dataSize: .unlimited)
                            
                            var resetSize = false
                            if let csize = chatimg.mediaSize {
                                if csize.width > mediaSize.width || csize.height > mediaSize.height {
                                    resetSize = true
                                }
                            } else {
                                resetSize = true
                            }
                            
                            if resetSize {
                                self.dsQueue.async {
                                    chatimg.mediaSize = resizedImage.size
                                    chatimg.grdbRecord?.transferProgress = 1.0
                                    chatimg.save {}
                                }
                            }
                        } else if chatimg.grdbRecord?.transferProgress != 1.0 {
                            chatimg.grdbRecord?.transferProgress = 1.0
                            chatimg.save {}
                        }
                        
                        let options = KingfisherParsedOptionsInfo(self.optionsInfo)
                        
                        GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in
                            //ChatMessage.touch(chatMsg.uniqueId)
                            
                            imageView.kf.setImage(with: resource, options: self.optionsInfo) { result in
                                switch result {
                                case .success(_):
                                    ChatMessage.touch(chatMsg.uniqueId)
                                    //if self.shownMessages.count > ip.section {
                                    //    self.messagesCollectionView.reconfigureItems(at: [ip])
                                    //}
                                case .failure(_):
                                    break
                                }
                            }
                        })
                        
                    case .failure(let error):
                        imageView.image = media.placeholderImage
                        imageView.kf.indicator?.stopAnimatingView()
                        print(error)
                    }
                }
            } else if let chatfile = media as? ChatFileItem {
                imageView.kf.indicator?.startAnimatingView()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let fileimage = chatfile.getThumbnailImage(imageURL) {
                        imageView.image = fileimage
                        if let data = fileimage.jpegData(compressionQuality: 1.0) {
                            if data.count < 10000 { //didn't really render, retry
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    //print("***** about to reconfigure")
                                    imageView.kf.indicator?.stopAnimatingView()
                                    if self.shownMessages.count > ip.section {
                                        self.messagesCollectionView.reconfigureItems(at: [ip])
                                    }
                                }
                                return
                            }
                        }
                        
                        let options = KingfisherParsedOptionsInfo(self.optionsInfo)
                        GlacierImageCache.shared().store(fileimage, forKey: thumbnailKey, options: options, toDisk: false)
                        imageView.kf.indicator?.stopAnimatingView()
                    }
                }
            } else if let htmlfile = media as? ChatHTMLItem {
                imageView.image = htmlfile.placeholderImage
                htmlfile.grdbRecord?.parentObjectKey = chatMsg.uniqueId
                htmlfile.grdbRecord?.parentObjectCollection = ChatMessageModel.collection()
                imageView.kf.indicator?.startAnimatingView()
                
                if activelyFetching.contains(chatMsg.uniqueId) == false {
                    activelyFetching.insert(chatMsg.uniqueId)
                    
                    //check for img in MediaServer first
                    KingfisherManager.shared.retrieveImage(with: imageURL, options: self.optionsInfo) { result in
                        switch result {
                        case .success(let img):
                            let himg = img.image
                            let mediaSize = ChatMediaItem.normalizeWidth(width: ChatHTMLItem.contentPreviewWidth, height: ChatHTMLItem.contentPreviewHeight)
                            let resizedImage = himg.scaleImageWith(newSize: mediaSize)
                                
                            imageView.image = resizedImage
                            imageView.kf.indicator?.stopAnimatingView()
                                
                            self.dsQueue.async {
                                htmlfile.storeInCache(resizedImage, thumbnailKey: thumbnailKey, messageId: chatMsg.uniqueId, buddyId: chatMsg.buddyUniqueId, found:true)
                                self.activelyFetching.remove(chatMsg.uniqueId)
                            }
                        case .failure(_):
                            htmlfile.getMetadata(media.url!, completion: { (metadata:LPLinkMetadata?, error:Error?) in
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self else { return }

                                    guard let metadata = metadata else {
                                        self.activelyFetching.remove(chatMsg.uniqueId)
                                        imageView.kf.indicator?.stopAnimatingView()
                                        imageView.image = htmlfile.placeholderImage
                                        return
                                    }
                                    
                                    guard Application.shared.applicationState == .active else {
                                        self.activelyFetching.remove(chatMsg.uniqueId)
                                        self.redrawSet.insert(ip)
                                        return
                                    }
                                    
                                    if let htmlImg = htmlfile.getThumbnailImage(media.url!, metadata: metadata) {
                                        let mediaSize = ChatMediaItem.normalizeWidth(width: ChatHTMLItem.contentPreviewWidth, height: ChatHTMLItem.contentPreviewHeight)
                                        let resizedImage = htmlImg.scaleImageWith(newSize: mediaSize)

                                        imageView.image = resizedImage

                                        if let data = resizedImage.jpegData(compressionQuality: 1.0), data.count < 10000 { //didn't really render, retry
                                            //print("***** try to re-get html image")
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                if self.shownMessages.count > ip.section {
                                                    self.messagesCollectionView.reconfigureItems(at: [ip])
                                                }
                                            }
                                            self.activelyFetching.remove(chatMsg.uniqueId)
                                            return
                                        }

                                        self.dsQueue.async {
                                            htmlfile.storeInCache(resizedImage, thumbnailKey: thumbnailKey, messageId: chatMsg.uniqueId, buddyId: chatMsg.buddyUniqueId, found:false, completion: {_ in
                                                ChatMessage.touch(chatMsg.uniqueId)
                                            })
                                            self.activelyFetching.remove(chatMsg.uniqueId)
                                        }
                                    } else {
                                        self.activelyFetching.remove(chatMsg.uniqueId)
                                        imageView.kf.indicator?.stopAnimatingView()
                                    }
                                }
                            })
                        }
                    }
                }
            }
        } else {
            imageView.kf.cancelDownloadTask()
        }
    }
    
    /*private func addActivityIndicator() {
        /// The activity indicator to be displayed while the map image is loading.
        open var activityIndicator = UIActivityIndicatorView(style: .medium)

        open override func setupSubviews() {
            messageContainerView.addSubview(activityIndicator)
            super.setupSubviews()
            //messageContainerView.addSubview(activityIndicator)
            setupConstraints()
        }
    }*/

    // MARK: - Location Messages

    public func annotationViewForLocation(message _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> MKAnnotationView? {
        let annotationView = MKAnnotationView(annotation: nil, reuseIdentifier: nil)
        if let pinImage = UIImage(systemName: "mappin")?.withTintColor(UIColor.red, renderingMode: .alwaysOriginal){
            annotationView.image = pinImage
            annotationView.centerOffset = CGPoint(x: 0, y: -pinImage.size.height / 2)
        }
        return annotationView
    }

    public func snapshotOptionsForLocation(message _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> LocationMessageSnapshotOptions
  {
      LocationMessageSnapshotOptions(
        showsBuildings: true,
        showsPointsOfInterest: true,
        span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
  }

  // MARK: - Audio Messages

    public func audioTintColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        isFromCurrentSender(message: message) ? .white : UIColor(red: 15 / 255, green: 135 / 255, blue: 255 / 255, alpha: 1.0)
    }

    public func configureAudioCell(_ cell: AudioMessageCell, message: MessageType) {
        audioPlaybackController.configureAudioCell(cell, message: message) 
        
        guard case MessageKind.audio(let media) = message.kind, let chatMsg = message as? ChatMessage else {
            return
        }
        
        if audioPlaybackController.audioPlayer?.isPlaying == true { return }
        
        if let audioItem = media as? ChatAudioItem {
            let dtext = cell.durationLabel.text
            if audioItem.duration > 0.0 {
                cell.durationLabel.text = self.audioProgressTextFormat(audioItem.duration, for: cell, in: self.messagesCollectionView)
            } else {
                if let url = OTRMediaServer.sharedInstance().url(forChatMediaItem: audioItem, buddyUniqueId: chatMsg.buddyUniqueId) {
                    let audioAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
                    let tlength = Float(CMTimeGetSeconds(audioAsset.duration))
                    cell.durationLabel.text = self.audioProgressTextFormat(tlength, for: cell, in: self.messagesCollectionView)
                }
            }
        }
    }
}

// MARK: MessagesLayoutDelegate

extension ChatViewController: MessagesLayoutDelegate {
    public func cellTopLabelHeight(for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        guard let message = message as? ChatMessage else { return 5 }
        
        let strId = message.uniqueId as NSString
        if let cachedHeight = self.cellTopCache.object(forKey: strId) {
            return cachedHeight.float
        }
        
        var height:CGFloat = 5
        if self.showDate(at: ip, message: message) {
            height = 18
            if message.systemUpdate {
                height = 31
            }
        } else if message.systemUpdate {
            height = 18
        }
        
        let gfloat = GlacierFloat.init()
        gfloat.float = height
        self.cellTopCache.setObject(gfloat, forKey: strId)
        
        return height
    }

    public func cellBottomLabelHeight(for mtype: MessageType, at ip: IndexPath, in mcv: MessagesCollectionView) -> CGFloat {
        if let next = nextMessageForItem(at: ip), mtype.sender.senderId == next.sender.senderId {
            return 0
        }
        return 5//17
    }

    public func messageTopLabelHeight(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        0//20
    }

    public func messageBottomLabelHeight(for mtype: MessageType, at ip: IndexPath, in mcv: MessagesCollectionView) -> CGFloat {
        
        guard let message = mtype as? ChatMessage else { return 0 }
        
        if message.expires != nil {
            return 16
        }
        
        let strId = message.uniqueId as NSString
        if let cachedHeight = self.messageBottomCache.object(forKey: strId) {
            return cachedHeight.float
        }
        
        var height:CGFloat = 0
        if let next = nextMessageForItem(at: ip), mtype.sender.senderId == next.sender.senderId {
            //let nextip = IndexPath(item: ip.row, section: ip.section+1)
            if let nextmessage = next as? ChatMessage, let cur = mtype as? ChatMessage, let at = messageBottomLabelAttributedText(for: mtype, at: ip), at.length > 0 {
                if (cur.displayed && !nextmessage.displayed) || (cur.delivered && !nextmessage.delivered) {
                    height = 16
                }
            }
        } else if let at = messageBottomLabelAttributedText(for: mtype, at: ip), at.length > 0 {
            height = 16
        }
        
        let gfloat = GlacierFloat.init()
        gfloat.float = height
        self.messageBottomCache.setObject(gfloat, forKey: strId)
        
        return height
    }
    
    public func textCellSizeCalculator(for message: MessageType, at indexPath: IndexPath, in    messagesCollectionView: MessagesCollectionView) -> CellSizeCalculator? {
        
        if let msg = message as? ChatMessage, msg.systemUpdate {
            return zeroTextLayout
        }
        return nil
    }
}

extension ChatViewController: FloatyDelegate {
    // MARK: - Floaty Delegate Methods
    public func floatyWillOpen(_ floaty: Floaty) {
        if floaty.frame.minX < 0 {
            floaty.frame = CGRect(x: 0, y: floaty.frame.minY, width: floaty.frame.width, height: floaty.frame.height)
        }
        floaty.isHidden = false
    }
    
    public func floatyDidOpen(_ floaty: Floaty) {
        
    }
    
    public func floatyWillClose(_ floaty: Floaty) {
        floaty.isHidden = true
    }
    
    public func floatyDidClose(_ floaty: Floaty) {
        
    }
    
    func layoutFAB() {
        let cameraItem = FloatyItem()
        cameraItem.icon = UIImage(systemName: "camera.fill")?.withRenderingMode(.alwaysTemplate)
        cameraItem.tintColor = UIColor.label
        cameraItem.buttonColor = UIColor.bubbleBlue()
        cameraItem.titleLabelPosition = .right
        cameraItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        cameraItem.title = "Camera"
        cameraItem.handler = { item in
            (self.messageInputBar as? AttachmentsInputBarView)? .showImagePickerController(sourceType: .camera)
        }
        
        let photoItem = FloatyItem()
        photoItem.icon = UIImage(systemName: "photo")?.withRenderingMode(.alwaysTemplate)
        photoItem.tintColor = UIColor.label
        photoItem.buttonColor = UIColor.bubbleBlue()
        photoItem.titleLabelPosition = .right
        photoItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        photoItem.title = "Photos"
        photoItem.handler = { item in
            (self.messageInputBar as? AttachmentsInputBarView)? .showImagePickerController(sourceType: .photoLibrary)
        }
        
        let gifItem = FloatyItem()
        gifItem.icon = UIImage(systemName: "livephoto")?.withRenderingMode(.alwaysTemplate)
        gifItem.tintColor = UIColor.label
        gifItem.buttonColor = UIColor.bubbleBlue()
        gifItem.titleLabelPosition = .right
        gifItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        gifItem.title = "GIF"
        gifItem.handler = { item in
            self.getAttachmentPicker().showGifController()
        }
        
        let audioItem = FloatyItem()
        audioItem.icon = UIImage(systemName: "mic.fill")?.withRenderingMode(.alwaysTemplate)
        audioItem.tintColor = UIColor.label
        audioItem.buttonColor = UIColor.bubbleBlue()
        audioItem.titleLabelPosition = .right
        audioItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        audioItem.title = "Audio"
        audioItem.handler = { item in
            (self as? ChatViewControllerExt)?.microphoneButtonTouched(self)
        }
        
        let fileItem = FloatyItem()
        fileItem.icon = UIImage(systemName: "doc.fill")?.withRenderingMode(.alwaysTemplate)
        fileItem.tintColor = UIColor.label
        fileItem.buttonColor = UIColor.bubbleBlue()
        fileItem.titleLabelPosition = .right
        fileItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        fileItem.title = "File"
        fileItem.handler = { item in
            self.getAttachmentPicker().showFilePicker()
        }
        
        let locItem = FloatyItem()
        locItem.icon = UIImage(systemName: "mappin")?.withRenderingMode(.alwaysTemplate)
        locItem.tintColor = UIColor.label
        locItem.buttonColor = UIColor.bubbleBlue()
        locItem.titleLabelPosition = .right
        locItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        locItem.title = "Location"
        locItem.handler = { item in
            self.getAttachmentPicker().showShareLocation()
        }
        
        let timerItem = FloatyItem()
        timerItem.icon = UIImage(systemName: "hourglass.bottomhalf.filled")?.withRenderingMode(.alwaysTemplate)
        timerItem.tintColor = UIColor.label
        timerItem.buttonColor = UIColor.bubbleBlue()
        timerItem.titleLabelPosition = .right
        timerItem.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: UIFont.systemFont(ofSize: 20))
        timerItem.title = "Timer"
        timerItem.handler = { item in
            (self as? ChatViewControllerExt)?.hourglassButtonTouched(sender: self)
        }
        
        floaty.addItem(item: timerItem)
        floaty.addItem(item: locItem)
        floaty.addItem(item: fileItem)
        floaty.addItem(item: audioItem)
        floaty.addItem(item: gifItem)
        floaty.addItem(item: photoItem)
        floaty.addItem(item: cameraItem)
        floaty.hasShadow = false
        
        floaty.paddingX = self.view.frame.width - floaty.frame.width
        floaty.buttonColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
        floaty.plusColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
        floaty.animationSpeed = 0.03
        floaty.fabDelegate = self
        floaty.overlayColor = UIColor.black.withAlphaComponent(0.8)
      
        self.view.addSubview(floaty)
        floaty.isHidden = true
    }
}

// MARK: - ContextMenuDelegate methods

extension ChatViewController: ContextMenuDelegate {
    func addReaction(_ emoji: String, to message: any GRDBRecord) {
        guard let chatMessage = message as? ChatMessage else {
            return
        }
        toggleReaction(emoji, for: chatMessage)
    }
    
    func handleAction(_ menuItem: ContextMenuItem, for message: any GRDBRecord) {
        guard let idx = self.longIndex, let chatMessage = message as? ChatMessage else {
            return
        }
        
        switch menuItem {
        case .copy:
            if case MessageKind.photo(_) = chatMessage.kind, let txt = chatMessage.text, txt.starts(with: "https:") {
                UIPasteboard.general.string = txt
            } else {
                self.collectionView(self.messagesCollectionView, performAction: NSSelectorFromString("copy:"), forItemAt: idx, withSender: nil)
            }
        case .delete:
            self.deleteMessage(at: idx)
        case .resend:
            let messageProtocol = ChatMessageModel(message: chatMessage)
            self.resendOutgoingMessage(
                for: messageProtocol.messageKey,
                messageCollection: messageProtocol.messageCollection,
                title: RESEND_STRING()
            )
        case .cancelDownload:
            let messageProtocol = ChatMessageModel(message: chatMessage)
            if let xmpp = xmppManager(),
               let mediaKey = messageProtocol.messageMediaItemKey,
               let mediaItem = ChatMediaItemModel.getMediaItem(with: mediaKey) {
                if mediaItem.grdbRecord?.isIncoming == true, (mediaItem.grdbRecord?.transferProgress ?? 1) < 1 {
                    xmpp.fileTransferManager.cancelDownload(mediaItem: mediaItem)
                }
            }
        case .viewProfile:
            guard let chatBuddy = buddy else { return }
            if chatBuddy.uniqueId == chatMessage.msgSenderId {
                let chatAccount = ChatAccount(uniqueId: chatBuddy.uniqueId, username: chatBuddy.username, domain: nil, resource: "", port: 0, displayName: chatBuddy.displayName, loginDate: nil, lastHistoryFetchDate: nil, pushPubsubEndpoint: nil, pushPubsubNode: nil, org: nil, apiKey: nil, avatarData: chatBuddy.avatarData, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: chatBuddy.photoHash, modified: nil)
                showSelectedUserProfile(ChatAccountModel(account: chatAccount))
            } else if let myAccount = getAccount(), myAccount.uniqueId == chatMessage.msgSenderId {
                showSelectedUserProfile(myAccount)
            }
        }
    }
    
    func showMoreEmojis(for message: any GRDBRecord) {
        isShowingContextMenu = false
        
        let emojiPickerVC = MCEmojiPickerViewController()
        emojiPickerVC.delegate = self
        emojiPickerVC.sourceView = self.view
        emojiPickerVC.customHeight = self.view.bounds.height - 80
        emojiPickerVC.arrowDirection = .up
        emojiPickerVC.presentationController?.delegate = self
        present(emojiPickerVC, animated: true)
    }
}

// MARK: - MCEmojiPickerDelegate methods

extension ChatViewController: MCEmojiPickerDelegate {
    public func didGetEmoji(emoji: String) {
        guard let idx = self.longIndex,
              let message = self.messageAt(idx) else {
            return
        }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        
        toggleReaction(emoji, for: message)
    }
}

// MARK: - UserReactionDetailsViewDelegate methods

extension ChatViewController: UserReactionDetailsViewDelegate {
    func didTapOn(reaction: String, completion: @escaping () -> Void) {
        guard let index = self.longIndex, let message = self.messageAt(index) else {
            return
        }
        self.toggleReaction(reaction, for: message)
        completion()
    }
}

// MARK: - Audio message cell delegate methods

extension ChatViewController: GlacierAudioMessageCellDelegate {
    func didChangeAudioPlaybackSpeed(_ speed: Float) {
        UserDefaults.standard.set(speed, forKey: kAudioPlaybackSpeed)
        audioPlaybackController.setPlaybackSpeed(speed)
    }
}
