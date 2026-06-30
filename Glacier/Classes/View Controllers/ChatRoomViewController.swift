//
//  ChatRoomViewController.swift
//  Glacier
//
//  Created by andyfriedman on 10/13/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

import UIKit
import SwiftUI
import InputBarAccessoryView
import MessageKit
import GRDB
import PureLayout
import MBProgressHUD
import GiphyUISDK
import MobileCoreServices
import AVKit
import KVOController
import Floaty
import Kingfisher
import LinkPresentation
import MapKit
import MCEmojiPicker

@objc open class ChatRoomViewController: MessagesViewController, MessagesDataSource, RoomOccupantsViewControllerDelegate, KeyboardObservable {
    
    public var currentSender: MessageKit.SenderType {
        return self.sender
    }
    
    static let kGlacierMessageSentDateShowTimeInterval:TimeInterval = 60 * 60 * 12
    static let kGlacierMessagePageSize = 50
    
    static let IS_IPHONE = (UIDevice.current.userInterfaceIdiom == .phone)
    static let IS_IPHONE_X = (IS_IPHONE && (UIScreen.main.bounds.size.height >= 812.0))
    static let IPHONE_STATUSBAR_HEIGHT = (IS_IPHONE_X ? 35 : 20)
    
    private var roomMsgCancellable: DatabaseCancellable?
    let dsQueue:DispatchQueue = DispatchQueue(label: "CRVCDataSource")
    private let uiQueue = OperationQueue()
    
    lazy var sender: MessageKit.SenderType = ChatUser(senderId: "", displayName: "")
    var fromAvatar: Avatar?
    var toAvatars:[String:Avatar] = [:]
    
    //let supplementaryViewHandler:SupplementaryViewHandler?
    var threadKey:String?
    var xmppMgr:XMPPManager?
    var account:ChatAccountModel?
    var threadOwner:ChatThread?
    var room:ChatRoom?
    var microphoneButton = UIButton(type: .roundedRect)
    var cameraButton = UIButton(type: .roundedRect)
    var attachButton = UIButton(type: .roundedRect)

    var moreOptionsButton = UIButton(type: .roundedRect)

    var state = MessagesViewControllerState.init()
    var automaticURLFetchingDisabled = false
    
    var keyboardHeight: CGFloat = 0
    
    lazy var floaty = Floaty()
    var zeroTextLayout = ZeroSizeCalculator()

    fileprivate var deviceListUpdateNotificationObject:NSObjectProtocol?

    var attachmentPicker:AttachmentPicker?
    lazy var audioPlaybackController = AudioPlaybackController(messageCollectionView: messagesCollectionView)

    fileprivate var loadingMessages = false
    fileprivate var loadingMoreMessages = false
    fileprivate var messagePage = 1
    fileprivate var messagesAdded = 0
    fileprivate var curMessagesAdded = 0
    //fileprivate var currentIndexPath:IndexPath?
    //fileprivate var currentMessage:ChatRoomMessage?
    fileprivate var displayedJidsTimer:Timer?
    fileprivate var displayUpdateNeeded = false
    fileprivate var reloadNeeded = true
    fileprivate var justSent = false
    fileprivate var updatedRoomSource = false
    fileprivate var initRequest = false
    //fileprivate var waitingToObserve = false
    fileprivate let messageSizeCache:NSCache<NSString, GlacierValue> = NSCache.init()
    fileprivate let messageBottomCache:NSCache<NSString, GlacierFloat> = NSCache.init()
    fileprivate let cellTopCache:NSCache<NSString, GlacierFloat> = NSCache.init()
    fileprivate let cellBottomCache:NSCache<NSString, GlacierFloat> = NSCache.init()
    fileprivate var retriedSet:Set<String> = []
    fileprivate var redrawSet:Set<IndexPath> = []
    fileprivate var activelyFetching:Set<String> = []
    
    fileprivate var longIndex:IndexPath?
    var longPressGestureRecognizer:UILongPressGestureRecognizer!

    fileprivate var showConnStatus = true
    fileprivate var titleView = TitleSubtitleView(frame: CGRectMake(0, 0, 200, 44))
    fileprivate var statusTimer:Timer?
    
    /// Per-occupant auto-clear timers: JID -> timer
    private var occupantTypingTimers: [String: Timer] = [:]
    
    private var lastFloatyLayoutBounds: CGRect = .zero
    private var lastFloatyLayoutSafeAreaInsets: UIEdgeInsets = .zero
    private var isFloatyPositionUpdateScheduled = false
    var statusCtr = 0
    var statusTapGestureRecognizer:UITapGestureRecognizer!
    var uploadHUD:MBProgressHUD?

    //var phoneButton:UIButton = UIButton(type: .custom)
    var accountAvatarImage:UIImage?
    lazy var agrumeVC = ImageViewHelper()
    
    fileprivate var originalAudioCategory:AVAudioSession.Category?
    
    fileprivate let attrs = [NSAttributedString.Key.font: UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.systemFont(ofSize: 10)), NSAttributedString.Key.foregroundColor: UIColor.lightGray]
    fileprivate let faattrs = [NSAttributedString.Key.font:UIFont(name: kFontAwesomeFont, size: 11) ?? UIFont.systemFont(ofSize: 11), NSAttributedString.Key.foregroundColor: UIColor.lightGray]

    fileprivate var lastDisplayed = Set<String>()
    fileprivate var displayedTextAttributes = [NSAttributedString.Key:AnyObject]()
    fileprivate var displayedNeedsUpdate = false
    fileprivate var nameTextAttributes = [NSAttributedString.Key:AnyObject]()
    
    let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                            .memoryCacheExpiration(.days(14)),
                                            .memoryCacheAccessExtendingExpiration(.cacheTime)]

    //var currentmgr:XMPPManager?
    var loginStatusToken: NSKeyValueObservation?
    
    private var chatRoomMessages:[ChatRoomMessage] = []
    private var latestdata = [ChatRoomMessage]()
    private var shownMessages = [ChatRoomMessage]()
    private var isShowingContextMenu = false
    private var selectedChatAccount: ChatAccountModel?
    private let collectionUpdateQueue = DispatchQueue(label: "com.glacier.chatroom.collection-updates", target: .main)
    
    override public init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        
        self.uiQueue.maxConcurrentOperationCount = 1
        self.messageSizeCache.countLimit = 1000
        self.messageBottomCache.countLimit = 1000
        self.cellTopCache.countLimit = 1000
        self.cellBottomCache.countLimit = 1000
        
        if let token = Bundle.main.object(forInfoDictionaryKey: "GiphyAPIToken") as? String {
            Giphy.configure(apiKey: token)
        }
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let deviceList = self.deviceListUpdateNotificationObject {
            NotificationCenter.default.removeObserver(deviceList)
        }
        NotificationCenter.default.removeObserver(self)
        self.displayedJidsTimer?.invalidate()
    }
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        configureMessageCollectionView()
        configureMessageInputBar()

        let paragraphStyleLeft = NSMutableParagraphStyle()
        paragraphStyleLeft.alignment = NSTextAlignment.left
        self.displayedTextAttributes = [NSAttributedString.Key.font: UIFont.italicSystemFont(ofSize: 10.0), NSAttributedString.Key.foregroundColor: UIColor.lightGray, NSAttributedString.Key.paragraphStyle: paragraphStyleLeft]
        self.nameTextAttributes = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 10.0), NSAttributedString.Key.foregroundColor: UIColor.lightGray, NSAttributedString.Key.paragraphStyle: paragraphStyleLeft]
        
        //messagesCollectionView.messagesCollectionViewFlowLayout.setMessageOutgoingCellBottomLabelAlignment(T##newAlignment: LabelAlignment##LabelAlignment)
        //let lal:NSTextAlignment = .left
        
        let pos = AvatarPosition(vertical: .messageBottom)
        messagesCollectionView.messagesCollectionViewFlowLayout.setMessageIncomingAvatarPosition(pos)
        messagesCollectionView.messagesCollectionViewFlowLayout.setMessageOutgoingAvatarPosition(pos)
        zeroTextLayout = ZeroSizeCalculator(layout: messagesCollectionView.messagesCollectionViewFlowLayout)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.displayedJidsTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(self.checkDisplayedJids), userInfo: nil, repeats: true)
            self.displayedJidsTimer?.tolerance = 0.5
        }
        
        //self.additionalContentInset = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        self.showConnStatus = true
        self.displayedNeedsUpdate = false
 
        ////// TitleView //////
        self.titleView = TitleSubtitleView(frame: CGRectMake(0, 0, 200, 44))
        self.navigationItem.titleView = self.titleView
        self.refreshTitleView()
        
        // Hide any default or empty left bar button items
        self.navigationItem.leftBarButtonItem = nil
        self.navigationItem.leftBarButtonItems = nil
        self.navigationItem.leftItemsSupplementBackButton = false
        
        self.titleView.subtitleLabel.text = nil
        
        self.statusCtr = 0
        self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)

        self.titleView.dynConnectingView.isHidden = true
        
        //if reloadNeeded {
            self.messagesCollectionView.reloadData()
            //self.messagesCollectionView.layoutIfNeeded()
            
            self.messagesCollectionView.scrollToLastItem(animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.messagesCollectionView.scrollToLastItem(animated: false)
            }
        //}
        
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
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleLoginSuccess), name: NSNotification.Name(rawValue: kGlacierProtocolLoginSuccess), object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(didDeleteAllChatMessages), name: NSNotification.Name(rawValue: kDidDeleteAllChatMessages), object: nil)
        
        registerKeyboardNotifications()
        
        self.statusTapGestureRecognizer = UITapGestureRecognizer.init(target: self, action: #selector(handleStatusGesture))
        self.statusTapGestureRecognizer.numberOfTapsRequired = 1
        
        if xmppManager() != nil {
            //self.currentmgr = xmpp
            loginStatusToken = self.xmppMgr?.observe(\.loginStatus, options: [.new, .old], changeHandler: {[weak self](xmpp, change) in
                self?.setConnectionStatus()
            })
        }
    }

    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleFloatyPositionUpdate()
    }
    
    @objc func didDeleteAllChatMessages() {
        self.shownMessages.removeAll()
        self.chatRoomMessages.removeAll()
        self.messagesCollectionView.reloadData()
        self.updatedRoomSource = true
    }
    
    open override func viewDidAppear(_ animated:Bool) {
        super.viewDidAppear(animated)
        self.tryToMarkAllMessagesAsRead()
        
        //self.updateDisplayedMessage()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.loadingMessages = false
        }
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        audioPlaybackController.stopAnyOngoingPlaying()
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
        
        if self.statusTimer == nil {
            self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
        }
        
        if self.displayedJidsTimer == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.displayedJidsTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(self.checkDisplayedJids), userInfo: nil, repeats: true)
                self.displayedJidsTimer?.tolerance = 0.5
            }
        }
        
        if let tkey = self.threadKey, tkey.count > 0 {
            self.updateView(with: tkey)
            if self.messageInputBar.inputTextView.text.count == 0 {
                self.moveLastComposingTextForThreadKey()
            }
            self.messageInputBar.inputTextView.isEditable = true
        }

        NotificationCenter.default.addObserver(self, selector: #selector(networkConnectionStatusChange), name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRoomTypingChange(_:)), name: .GlacierRoomTypingOccupantsDidChange, object: nil)
        
        self.showConnStatus = true
        self.setConnectionStatus()
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.saveCurrentMessageText(self.messageInputBar.inputTextView.text, key: self.threadKey)
        
        // Send inactive state and clear indicator when leaving
        if let xmpp = xmppManager(), let room = getRoom() {
            xmpp.sendRoomChatState(.inactive, roomUniqueId: room.uniqueId)
        }
        self.occupantTypingTimers.values.forEach { $0.invalidate() }
        self.occupantTypingTimers.removeAll()
        self.titleView.subtitleLabel.text = nil

        self.handleScreenDisappearing()
        
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: NetworkStatusNotificationName), object: nil)
        NotificationCenter.default.removeObserver(self, name: .GlacierRoomTypingOccupantsDidChange, object: nil)
        
        self.unregisterKeyboardNotifications()
    }
    
    /*open override func viewWillLayoutSubviews() {
        self.currentIndexPath = nil
        super.viewWillLayoutSubviews()
    }*/
    
    private func initialRequest() {
        guard let convid = self.threadKey else {return}
        self.loadingMessages = true
        self.initRequest = true
        var asec:[ChatRoomMessage] = []
        self.shownMessages = asec
        let messages = ChatRoomMessage.allChatRoomMessages(for: convid, limit: ChatRoomViewController.kGlacierMessagePageSize)
        self.chatRoomMessages = messages
        
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

        let roomRequest = ChatRoomMessage.all().filter(Column("roomUniqueId") == convid).order(Column("messageDate").desc)//.filter(Column("messageText") != nil)
            
        roomMsgCancellable = ValueObservation
            .tracking(roomRequest.fetchAll(_:))
            .start(
                in: DBManager.sharedDB().grdbStorage.pool,
                // Immediate scheduling feeds the data source right on subscription,
                // and avoids an undesired animation when the application starts.
                scheduling: .async(onQueue: dsQueue),//.immediate,
                onError: { error in fatalError("Unexpected error: \(error)") },
                onChange: { [weak self] messages in
                    guard let self else { return }
                    self.updateRoomDataSource(from: messages)
        })
    }
    
    private func updateRoomDataSource(from messages: [ChatRoomMessage]) {
        //curMessagesAdded = 0
        let diffcnt = messages.count - self.chatRoomMessages.count
        if self.updatedRoomSource, diffcnt > 0 {
            self.messagesAdded += diffcnt
        }
        
        self.chatRoomMessages = messages
        let msgs = messages
        var asec = [ChatRoomMessage]()
            
        var endIndex = messages.count
        let showCount = (ChatViewController.kGlacierMessagePageSize * self.messagePage) + self.messagesAdded
        if endIndex > showCount {
            endIndex = showCount
        }
            
        for i in 0..<endIndex {
            let msg = msgs[i]
            asec.insert(msg, at: 0)
        }
            
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
        
        if self.updatedRoomSource == false {
            //DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.updatedRoomSource = true
            //}
        }
        
        //dsQueue.async {
        //    self.checkDisplayedJids()//maybe only if legit changes
        //}
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
                self.displayUpdateNeeded = true
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
        
        var shownDict = Dictionary<String, ChatRoomMessage>()
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
                self.cellBottomCache.removeObject(forKey: cmsgid)
                self.cellTopCache.removeObject(forKey: cmsgid)
            }
        }
        
        for (index,msg) in latestmsgs.enumerated() {
            if let oldmsg = shownDict[msg.uniqueId] {
                if msg.modified != oldmsg.modified || msg.reactionsCount != oldmsg.reactionsCount {
                    let msgid = msg.uniqueId as NSString
                    self.messageSizeCache.removeObject(forKey: msgid)
                    self.messageBottomCache.removeObject(forKey: msgid)
                    self.cellBottomCache.removeObject(forKey: msgid)
                    reloadIndexSet.insert(index)
                    
                    if index > 0 {
                        let prevmsg = latestmsgs[index-1]
                        let pmsgid = prevmsg.uniqueId as NSString
                        self.messageSizeCache.removeObject(forKey: pmsgid)
                        self.messageBottomCache.removeObject(forKey: pmsgid)
                        self.cellBottomCache.removeObject(forKey: pmsgid)
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

            self.displayUpdateNeeded = true
            let beforeContentSize = self.messagesCollectionView.contentSize
            if self.loadingMoreMessages {
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
                        self.safeReconfigureItems(at: ips)
                    } else {
                        //print("***** something didn't match, reload sections instead")
                        self.messagesCollectionView.reloadSections(reloadIndexSet)
                    }
                }
                //self.messagesCollectionView.reloadData()
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
                        self.safeReconfigureItems(at: ips)
                    } else {
                        //print("***** something didn't match, reload sections instead")
                        self.messagesCollectionView.reloadSections(reloadIndexSet)
                    }
                }
            }
            
            if self.loadingMoreMessages {
                self.loadingMoreMessages = false
                //}
                let afterContentSize = self.messagesCollectionView.contentSize
                let contentOffset = self.messagesCollectionView.contentOffset
                // reset the contentOffset after data is updated
                let newOffset = CGPoint(
                    x: contentOffset.x + (afterContentSize.width - beforeContentSize.width),
                    y: contentOffset.y + (afterContentSize.height - beforeContentSize.height))
                self.messagesCollectionView.setContentOffset(newOffset, animated: false)
            } else if reload, addcount > 0 {
                if latestmsgs.last?.uniqueId == data.last?.uniqueId { return }
                self.scrollIfAppropriate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.scrollIfAppropriate()
                }
            }
        }
    }
    
    private func scrollIfAppropriate() {
        let animated = self.updatedRoomSource
        let isScrolling: Bool = self.messagesCollectionView.isDragging || self.messagesCollectionView.isDecelerating
        if !isScrolling {
            self.messagesCollectionView.scrollToLastItem(animated: animated)
        }
    }
    
    @objc func checkDisplayedJids() {
        let cnt = self.chatRoomMessages.count
        if (cnt < 2 || self.displayUpdateNeeded == false) { return }
        self.displayUpdateNeeded = false
        
        dsQueue.async {
            var jidset = Set<String>()
            var i = 0
            
            var changedMsgs:[ChatRoomMessage] = []
            for roomMsg in self.chatRoomMessages { //}.reversed() {
                i+=1
                let msgModel = ChatRoomMessageModel(message: roomMsg)
                if i >= ChatRoomViewController.kGlacierMessagePageSize {
                    break
                } else if i == 1 {
                    if let newset = msgModel.displayedJids {
                        jidset = newset
                    }
                } else if let djids = msgModel.displayedJids {
                    let cnt = djids.count
                    let newset = djids.subtracting(jidset)
                    if newset.count != cnt, !(djids.count == 1 && djids.first == "" && newset.count == 0) {
                        var modded = roomMsg
                        modded.displayedJids = newset.joined(separator: ", ")
                        modded.modified = Date()
                        changedMsgs.append(modded)
                    }
                    
                    if newset.count > 0 {
                        jidset.formUnion(newset)
                    }
                }
            }
            
            DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
                for change in changedMsgs {
                    change.grdbSave(transaction: transaction)
                }
            })
        }
    }
    
    func loadMoreMessages() {
        let oldpage = (ChatRoomViewController.kGlacierMessagePageSize*self.messagePage) + self.messagesAdded
        if oldpage >= self.chatRoomMessages.count { return }
            
        let startIndex = oldpage
        self.messagePage+=1
        
        var asec = [ChatRoomMessage]()
        var cnt = ChatRoomViewController.kGlacierMessagePageSize
        let newpage = (ChatRoomViewController.kGlacierMessagePageSize*self.messagePage) + self.messagesAdded
        
        if self.chatRoomMessages.count < newpage {
            cnt = self.chatRoomMessages.count - oldpage
        }
        
        let endIndex = startIndex+cnt
        for i in startIndex..<endIndex {
            let msg = self.chatRoomMessages[i]
            asec.insert(msg, at: 0)
        }
        
        let msgid = self.shownMessages[0].uniqueId
        let cmsgid = msgid as NSString
        self.messageSizeCache.removeObject(forKey: cmsgid)
        self.messageBottomCache.removeObject(forKey: cmsgid)
        self.cellBottomCache.removeObject(forKey: cmsgid)
        self.cellTopCache.removeObject(forKey: cmsgid)
            
            
        var latest = [ChatRoomMessage]()
        if self.latestdata.count > 0 {
            latest = self.latestdata
        } else {
            latest = self.shownMessages
        }
        
        latest.insert(contentsOf: asec, at: 0)
            
        self.loadingMoreMessages = true
        self.latestdata = latest
        self.handleUpdates()
            
        
        
        
        /*var asec = [ChatRoomMessage]()
        var cnt = ChatRoomViewController.kGlacierMessagePageSize
        let newpage = (ChatRoomViewController.kGlacierMessagePageSize*self.messagePage) + self.messagesAdded
        
        if self.chatRoomMessages.count < newpage {
            cnt = self.chatRoomMessages.count - oldpage
        }
        
        let endIndex = startIndex+cnt
        for i in startIndex..<endIndex {
            let msg = self.chatRoomMessages[i]
            asec.insert(msg, at: 0)
        }
        
        let msgid = self.shownMessages[0].uniqueId
        let cmsgid = msgid as NSString
        self.messageSizeCache.removeObject(forKey: cmsgid)
        self.messageBottomCache.removeObject(forKey: cmsgid)
        self.cellBottomCache.removeObject(forKey: cmsgid)
        self.cellTopCache.removeObject(forKey: cmsgid)
        
        DispatchQueue.main.async {
            let beforeContentSize = self.messagesCollectionView.contentSize
            self.messagesCollectionView.setContentOffset(self.messagesCollectionView.contentOffset, animated: false)
            //self.loadingMoreMessages = true
            self.shownMessages.insert(contentsOf: asec, at: 0)
            self.messagesCollectionView.reloadData()
            let afterContentSize = self.messagesCollectionView.contentSize
            let contentOffset = self.messagesCollectionView.contentOffset
            // reset the contentOffset after data is updated
            let newOffset = CGPoint(
                x: contentOffset.x + (afterContentSize.width - beforeContentSize.width),
                y: contentOffset.y + (afterContentSize.height - beforeContentSize.height))
            self.messagesCollectionView.setContentOffset(newOffset, animated: false)
        }*/
    }
    
    func isLastSectionVisible() -> Bool {
        guard !self.shownMessages.isEmpty else { return false }
        
        let lastIndexPath = IndexPath(item: 0, section: self.shownMessages.count - 1)
        return messagesCollectionView.indexPathsForVisibleItems.contains(lastIndexPath)
    }

    func prefersStatusBarHidden() -> Bool {
        return false
    }
    
    @objc func enteringForegroundStatus(_ notification: NSNotification) {
        self.statusTimer?.invalidate()
        self.statusCtr = 0
        
        if !ChatRoomViewController.IS_IPHONE {
            return
        }
        
        self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
        
        self.setConnectionStatus()
    }

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

            self.safeReconfigureItems(at: ips) // reloadSections(iset)
        }
    }

    // Mirrors ChatViewController.safePathsForReconfigure — drops paths that would crash
    // reconfigureItems (typing-indicator section, out-of-bounds section/row) and falls back
    // to reloadSections for sections still present in shownMessages. Must run on main.
    private func safePathsForReconfigure(_ paths: [IndexPath]) -> (reconfigure: [IndexPath], reload: IndexSet) {
        let sectionCount = self.messagesCollectionView.numberOfSections
        let shownCount = self.shownMessages.count
        var safe: [IndexPath] = []
        var fallback = IndexSet()
        for ip in paths {
            guard ip.section >= 0, ip.section < sectionCount else { continue }
            if isSectionReservedForTypingIndicator(ip.section) { continue }
            if ip.row >= self.messagesCollectionView.numberOfItems(inSection: ip.section) {
                if ip.section < shownCount { fallback.insert(ip.section) }
                continue
            }
            safe.append(ip)
        }
        return (safe, fallback)
    }

    private func safeReconfigureItems(at paths: [IndexPath]) {
        let (safe, fallback) = self.safePathsForReconfigure(paths)
        if !safe.isEmpty {
            self.messagesCollectionView.reconfigureItems(at: safe)
        }
        if !fallback.isEmpty {
            self.messagesCollectionView.reloadSections(fallback)
        }
    }

    @objc func handleLoginSuccess(_ notification: NSNotification) {
        DispatchQueue.main.async {
            if (self.isViewLoaded && self.view.window != nil) {
                self.dsQueue.async {
                    self.fetchOMEMODeviceListForRoom()
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
        
        self.displayedJidsTimer?.invalidate()
        self.displayedJidsTimer = nil
        
        self.titleView.dynConnectingView.stopAnimating()
        self.titleView.subtitleLabel.text = nil
        //self.resetOptionsButton()
    }
    
    func setThreadKey(_ key: String?) {
        if self.deviceListUpdateNotificationObject == nil {
            self.deviceListUpdateNotificationObject = NotificationCenter.default.addObserver(forName: OMEMOSignalCoordinator.DeviceListUpdateNotificationName, object: nil, queue: OperationQueue.main, using: { [weak self] (notification) in
                self?.handleDeviceListUpdate(notification: notification)
            })
        }
        
        if key != self.threadKey {
            //self.currentIndexPath = nil
            let oldKey = self.threadKey
            
            self.threadKey = key
            self.xmppMgr = nil
            self.account = getAccount()
            self.threadOwner = nil
            self.xmppMgr = xmppManager()
            self.messagePage = 1
            self.messagesAdded = 0
            self.loadingMoreMessages = false
            self.updatedRoomSource = false
            self.retriedSet.removeAll()
            
            if let bkey = key {
                self.room = ChatRoom.getRoom(uniqueId: bkey)
            }
            
            guard let account = self.account else {
                self.automaticURLFetchingDisabled = true
                return
            }
            
            self.automaticURLFetchingDisabled = account.grdbRecord?.disableAutomaticURLFetching ?? false
            self.sender = ChatUser(senderId: account.uniqueId, displayName: account.displayName)
            
            roomMsgCancellable?.cancel()
            roomMsgCancellable = nil
            self.chatRoomMessages.removeAll()
            
            //self.dsQueue.async {
                self.initialRequest()
            //}
            
            self.getAvatarImages()
            //DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            //if (self.xmppMgr?.loginStatus == GlacierLoginStatus.authenticated) {
                self.observeConversations()
            //} else { //timer or wait for login and then timer
            //    waitingToObserve = false
            //}
            
            //self.resetDataSource()
            self.saveChatThreadIfNeeded()
            
            // Clear out old state (don't just alloc a new object, we have KVOs attached to this!)
            self.state.reset()
            self.titleView.subtitleLabel.text = nil
            self.occupantTypingTimers.values.forEach { $0.invalidate() }
            self.occupantTypingTimers.removeAll()
            
            // This is set to nil so the refreshTitleView: method knows to reset username instead of last seen time
            self.titleView.subtitleLabel.text = nil
            self.messageInputBar.inputTextView.placeholder = "Send encrypted message"
            if self.room?.isPublic == true {
                self.messageInputBar.inputTextView.placeholder = "Send message"
            }
            
            if oldKey != key {
                self.saveCurrentMessageText(self.messageInputBar.inputTextView.text, key: oldKey)
                self.messageInputBar.inputTextView.text = nil
                //self.receivedTextViewChanged(self.messageInputBar.inputTextView)
            }
            
            if let key = self.threadKey {
                self.updateView(with: key)
                self.moveLastComposingTextForThreadKey()
                self.messageInputBar.inputTextView.isEditable = true

                // setThreadKey can fire asynchronously after the view is already
                // visible (new group creation via setup(...)'s completion). Force
                // a layout/input-views refresh so the MessageKit input bar is
                // redrawn now that the thread is ready.
                if self.isViewLoaded {
                    self.messageInputBar.setNeedsLayout()
                    self.messageInputBar.layoutIfNeeded()
                    if self.view.window != nil {
                        self.reloadInputViews()
                    }
                }
            } else {
                self.sender = ChatUser(senderId: "", displayName: "")
            }
            
            //self.messagesCollectionView.reloadData()
            //self.messagesCollectionView.layoutIfNeeded()
            
            //self.resetOptionsButton()
            self.setupTopRightButtons()
            self.updateState()
            
            if self.xmppMgr?.loginStatus == .authenticated {
                dsQueue.async {
                    self.fetchOMEMODeviceListForRoom()
                }
            }
        }
        
        //don't try to send this if we aren't logged in yet
        //also check the scroll position thing
        /*if let account = getAccount(), GlacierProtocolManager.shared.existsProtocol(forAccountId: account.uniqueId), GlacierProtocolManager.shared.isAccountIdConnected(account.uniqueId) {
            //self.fetchOMEMODeviceListForRoom()
        }*/
    }
    
    @objc func resetRoom() {
        if let oldroom = self.room, let updatedroom = ChatRoom.getRoom(uniqueId: oldroom.uniqueId) {
            self.room = updatedroom
            self.refreshTitleView()
        }
    }
    
    func saveChatThreadIfNeeded() {
        guard let key = self.threadKey else {return}
        if var room = self.room {
            let threadId = room.chatThreadId
            if threadId >= 0, let _ = ChatThread.getChatThread(threadId: threadId) {
                return
            } else if let thr = ChatThread.getChatThread(uniqueId: room.uniqueId) {
                if let tid = thr.id {
                    self.room?.chatThreadId = tid
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
                newThread.isGroupThread = true
                newThread.accountUniqueId = aid
                newThread.storeInGRDB(completion: {
                    DispatchQueue.global().async {
                        if let newthread = ChatThread.getChatThread(uniqueId: key), let tid = newthread.id {
                            room.chatThreadId = tid
                            room.storeInGRDB(completion: {
                                newthread.touch()
                            })
                        }
                    }
                })
            }
        }
    }
    
    func getAvatarImages() {
        if self.fromAvatar == nil {
            if let account = ChatAccountModel.firstAccount() {
                let initials = account.displayName.prefix(2)
                self.fromAvatar = Avatar(image: account.avatarImage, initials: String(initials))
            }
        }
            
        if let room = self.room {
            let roomModel = ChatRoomModel(room: room)
            let roomBuddies = roomModel.allBuddies()
            for buddy in roomBuddies {
                let dname = buddy.displayName.prefix(2)
                let binitials = String(dname)
                let budImage = buddy.avatarImage
                toAvatars[buddy.uniqueId] = Avatar(image: budImage, initials: binitials)
            }
        }
    }
    
    func setupTopRightButtons() {
        let lblColor = UIColor.label
        
        /*phoneButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
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
        self.phoneButton.addTarget(self, action: #selector(didSelectPhoneButton), for: UIControl.Event.touchUpInside)
        
        let phoneItem = UIBarButtonItem(customView: self.phoneButton)
        let callWindow = GlacierAppDelegate.appDelegate.callWindow
        if callWindow.rootViewController != nil {
            self.phoneButton.isEnabled = false
        }*/
 
        let groupButton = UIButton(type: .custom)
        groupButton.translatesAutoresizingMaskIntoConstraints = false
        groupButton.frame = CGRectMake(0, 0, 64, 42)
            
        let origImage = UIImage(named: "112-group", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        if let normalImage = origImage?.imageMasked(with: lblColor), let highlightedImage = origImage?.imageMasked(with: UIColor.lightGray) {
            groupButton.setImage(normalImage, for: UIControl.State.normal)
            groupButton.setImage(highlightedImage, for: UIControl.State.highlighted)
        }
        groupButton.addTarget(self, action: #selector(didSelectOccupantsButton), for: UIControl.Event.touchUpInside)
        let groupItem = UIBarButtonItem(customView: groupButton)
        groupItem.style = UIBarButtonItem.Style.plain
            
        self.navigationItem.rightBarButtonItem = groupItem //nil
        //let items = [groupItem, phoneItem]
        //self.navigationItem.rightBarButtonItems = items
    }
    
    func resetOptionsButton() {
        self.microphoneButton.removeFromSuperview()
        self.attachButton.removeFromSuperview()
        //self.inputToolbar?.contentView.leftBarButtonItem = self.moreOptionsButton
    }
    
    func getAttachmentPicker() -> AttachmentPicker {
        if self.attachmentPicker == nil {
            self.attachmentPicker = AttachmentPicker.init(parentViewController: self, delegate: self)
        }
        return self.attachmentPicker!
    }
    
    func updateState() {
        self.state.canSendMedia = true
        self.state.messageSecurity = .OMEMO
    }
    
    func saveCurrentMessageText(_ text: String?, key:String?) {
        if key == nil {
            return
        }
        
        //getThread(key: key, collection: collection)
        if var thread = getRoom(), ChatRoomModel.getXMPPRoom(uniqueId: thread.uniqueId) != nil {
            thread.currentMessageText = text
            thread.storeInGRDB()
            
            if let xmpp = xmppManager() {
                xmpp.sendRoomChatState(.inactive, roomUniqueId: thread.uniqueId)
            }
        }
    }
    
    //* Takes the current value out of the thread object and sets it to the text view and nils out result*/
    func moveLastComposingTextForThreadKey() {
        if var thread = getRoom(), let oldText = thread.currentMessageText {
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

    /** Updates the title view with the current thread information on this view controller*/
    func refreshTitleView()
    {
        guard let room = getRoom() else {
            return
        }
        
        let thread = ChatRoomModel(room: room)
        self.titleView.titleLabel.text = thread.threadName
        
        let namecomponents = thread.threadName.components(separatedBy: "@")
        if namecomponents.count == 2 {
            self.titleView.titleLabel.text = namecomponents.first
        }
        
        //if let title = titleView.titleLabel.text {
            //self.titleView.titleLabel.text = "#" + title
        //}
        
        self.titleView.titleImageView.image = nil
    }
    
    @objc func updateStatusTimer()
    {
        //DDLogWarn(@"*** statusCtr %d", _statusCtr);
        if (self.statusCtr < 22 && self.showConnStatus) {
            self.statusCtr+=1
        } else {
            self.statusTimer?.invalidate()
            self.statusTimer = nil
        }
        
        if (self.statusCtr % 2 == 0) {
            self.setConnectionStatus()
        }
        
        //self.updateForDisplayedMessages()
    }
    
    func configureMessageCollectionView() {
        messagesCollectionView.register(GlacierAudioMessageCell.self)
        messagesCollectionView.register(LocationMessageCell.self)
        messagesCollectionView.register(MediaMessageCell.self)
        
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
        if self.room?.isPublic == true {
            messageInputBar.inputTextView.placeholder = "Send message"
        }
        inputBarType = .custom(messageInputBar)
        self.layoutFAB()
    }
    
    func retryLogin() {
        let currentStatus = GlacierNetworkConnectionStatus.connected
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
        let message = ChatRoomMessageModel.getMessage(with: messageKey)
        
        if let message = message {
            let messageError = message.messageError
            message.messageError = nil
            message.messageSecurity = self.room?.isPublic == true ? .plaintext : .OMEMO
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
            let ispub = self.room?.isPublic ?? false
            let threadModel = ChatThreadModel(thread: thread)
            if (showHUD) {
                DispatchQueue.main.async {
                    self.addUploadHUD()
                    xmpp.fileTransferManager.send(image: photo, thread: threadModel, jpeg: asJPEG, label: self.uploadHUD?.label, isPublic: ispub) { [weak self] (success:Bool, error:Error?) in
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
                xmpp.fileTransferManager.send(image: photo, thread: threadModel, jpeg: asJPEG, label: self.uploadHUD?.label, isPublic: ispub) { [weak self] (success:Bool, error:Error?) in
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
        }
    }
    
    func sendVideoURL(_ videoURL:URL) {
        if let xmpp = xmppManager(), let thread = getThread() {
            self.removeUploadHUD()
            let threadModel = ChatThreadModel(thread: thread)
            let ispub = self.room?.isPublic ?? false
            
            xmpp.fileTransferManager.send(videoURL: videoURL, thread: threadModel, label: self.uploadHUD?.label, isPublic: ispub, completion: { (success:Bool, error:Error?) in
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
            let ispub = self.room?.isPublic ?? false
            
            xmpp.fileTransferManager.send(audioURL: audioURL, thread: threadModel, label: self.uploadHUD?.label, isPublic: ispub, completion: { (success:Bool, error:Error?) in
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
            
            let ispub = self.room?.isPublic ?? false
            
            let threadModel = ChatThreadModel(thread: thread)
            for fileURL in fileURLs {
                xmpp.fileTransferManager.send(fileURL: fileURL, thread: threadModel, label: self.uploadHUD?.label, isPublic:ispub ,completion: { (success:Bool, error:Error?) in
                    self.handleMediaError(error: error)
                    self.removeUploadHUD()
                })
            }
        }
    }

    func sendImageFilePath(_ filePath:String, asJPEG:Bool, shouldResize:Bool) {
        let userTypedText = self.messageInputBar.inputTextView.text
        self.messageInputBar.inputTextView.text = nil
        if let localImage = UIImage(contentsOfFile: filePath) {
            self.sendPhoto(localImage, asJPEG: asJPEG, shouldResize: shouldResize, userTypedText: userTypedText, info: nil)
            return
        }

        guard let url = URL(string: filePath) else {
            DDLogError("ChatRoomViewController.sendImageFilePath: invalid URL \(filePath)")
            return
        }

        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let image: UIImage?
                if asJPEG {
                    image = UIImage(data: data)
                } else {
                    image = GifHelper.getGifImage(data)
                }

                guard let image else { return }
                await MainActor.run {
                    self?.sendPhoto(image, asJPEG: asJPEG, shouldResize: shouldResize, userTypedText: userTypedText, info: nil)
                }
            } catch {
                DDLogError("ChatRoomViewController.sendImageFilePath: \(error.localizedDescription)")
            }
        }
    }
    
    func sendMediaItem(_ mediaItem:ChatMediaItemModel, data:Data?, message:MessageProtocol) {
        guard var thread = getThread(), let xmpp = xmppManager() else { return}
        
        if data != nil {
            thread.lastMessageId = message.messageKey
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
                ChatRoomMessageModel.deleteMessage(with: lastMessageId)
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
                self.xmppMgr = GlacierProtocolManager.shared.xmppManager(forChatAccount:account)
            }
        }
        
        return self.xmppMgr
    }
    
    func getThread() -> ChatThread? {
        return self.getThread(key: self.threadKey)
    }
    
    func getThread(key:String?) -> ChatThread? {
        if self.threadOwner == nil, let threadKey = key {
            self.threadOwner = ChatThread.getChatThread(uniqueId: threadKey)
        }
        return self.threadOwner
    }

    func getRoom() -> ChatRoom? {
        if let room = self.room {
            return room
        }
        
        if let thread = getThread() {
            if let roomie = ChatRoom.roomFromThread(thread) {
                self.room = roomie
                return roomie
            } else if let roomie2 = ChatRoom.getRoom(uniqueId: thread.uniqueId) {
                self.room = roomie2
                return roomie2
            }
        }
        return nil
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

    func lastMessage() -> MessageProtocol? {
        if let threadKey = self.threadKey {
            return ChatRoomMessageModel.getLastMessage(for: threadKey)
        }
        return nil
    }
    
    @objc func networkConnectionStatusChange(_ notification:NSNotification) {
        self.setConnectionStatus()
    }
    
    func setConnectionStatus() {
        if ChatRoomViewController.IS_IPHONE, let account = getAccount() {
            DispatchQueue.main.async {
                self.addStatusGestures(false)
                if GlacierProtocolManager.shared.existsProtocol(forAccountId: account.uniqueId) {
                    if GlacierProtocolManager.shared.isAccountIdConnected(account.uniqueId) {
                        self.showConnStatus = false
                        self.titleView.subtitleLabel.text = nil
                        self.refreshTitleView()
                        self.titleView.dynConnectingView.stopAnimating()
                        self.titleView.dynConnectingView.isHidden = true
                        
                        //observeConversations if needed
                        //if self.roomMsgCancellable == nil, self.waitingToObserve == false {
                        //    self.waitingToObserve = true
                        //    self.addUploadHUD("Retrieving data...", tapToCancel: false)
                        //    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        //        self.removeUploadHUD()
                        //        self.observeConversations()
                        //    }
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
        
        if GlacierAppDelegate.appDelegate.isProxyDetected() == true {
            self.titleView.subtitleLabel.text = "Proxy Detected"
            return
        }
        
        //if the timer doesn't exist here we need to recreate it. Happens on loss of network conenction.
        if (self.statusTimer == nil && protocolExists) {
            self.statusCtr = 0
            self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
        }
        
        if (self.statusCtr < 4) {
            //self.titleView.subtitleLabel.text = nil;
            self.refreshTitleView()
            self.titleView.dynConnectingView.isHidden = true
        } else if (self.statusCtr < 6) {
            self.titleView.subtitleLabel.text = "Connecting"
            self.titleView.dynConnectingView.isHidden = false
            self.titleView.dynConnectingView.startAnimating()
        } else {
            self.removeUploadHUD()
            if (protocolExists) {
                if self.statusCtr >= 14 {
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

    @objc func handleStatusGesture() {
        if let statusString = self.titleView.subtitleLabel.text, (statusString.hasSuffix("login") || statusString.hasSuffix("again")) {
            self.statusTimer?.invalidate()
            self.statusCtr = 2
            self.statusTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateStatusTimer), userInfo: nil, repeats: true)
            
            self.retryLogin()
        }
    }

    func isUpdateMessage(_ message: ChatRoomMessage) -> Bool {
        return message.memberUpdate || message.systemUpdate
    }

    //#pragma - mark RoomOccupantsViewControllerDelegate
    public func didLeaveRoom(_ roomOccupantsViewController: RoomOccupantsViewController) {
        if let room = self.getRoom() {
            self.setThreadKey(nil)
            room.remove {}
        }
            
        self.navigationController?.popViewController(animated: false)
        if let cnt = self.navigationController?.viewControllers.count, cnt > 1 {
            self.navigationController?.popViewController(animated: true)
        } else {
            self.navigationController?.navigationController?.popViewController(animated:
                                                                                    true)
        }
    }
    
    func findBuddyLocation(_ buddyloc:String, with message:ChatRoomMessage) {
        //override if desired
    }

    open override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        if messagesCollectionView.messagesDataSource == nil {
            DDLogError("ChatRoomViewController.collectionView missing messagesDataSource for indexPath: \(indexPath). Reconfiguring message collection view.")
            configureMessageCollectionView()
        }

        guard messagesCollectionView.messagesDataSource != nil else {
            DDLogError("ChatRoomViewController.collectionView still missing messagesDataSource after reconfiguration. Returning empty cell to avoid crash.")
            return UICollectionViewCell()
        }

        // Very important to check this when overriding `cellForItemAt`
        // Super method will handle returning the typing indicator cell
        guard !isSectionReservedForTypingIndicator(indexPath.section) else {
            return super.collectionView(collectionView, cellForItemAt: indexPath)
        }

        guard indexPath.section < shownMessages.count else {
            DDLogWarn("ChatRoomViewController.collectionView received indexPath: \(indexPath) but shownMessages count is only \(shownMessages.count). Returning empty cell.")
            return UICollectionViewCell()
        }

        let msg = self.shownMessages[indexPath.section]
        var collectionViewCell: UICollectionViewCell?
        if case MessageKind.audio(_) = msg.kind {
            collectionViewCell = messagesCollectionView.dequeueReusableCell(GlacierAudioMessageCell.self, for: indexPath)
            if let audioMessageCell = collectionViewCell as? GlacierAudioMessageCell {
                audioMessageCell.cellDelegate = self
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
            //let msg = self.shownMessages[indexPath.section]
            if let txt = msg.messageText {
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
                        xmpp.fileTransferManager.retryDownloadMedia(ChatRoomMessageModel(message: msg))
                    }
                    return cell
                }
            }
            
            return tcell
        } else if let vcell = cell as? MediaMessageCell {
            var message = self.shownMessages[indexPath.section]
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
        guard !isSectionReservedForTypingIndicator(indexPath.section) else {
            return super.collectionView(messagesCollectionView, layout: collectionViewLayout, sizeForItemAt: indexPath)
        }
        let message = self.shownMessages[indexPath.section]
        let key = message.uniqueId as NSString
        //if message.mediaItemUniqueId == nil
        if indexPath.section < self.shownMessages.count - 2, let sizeValue = self.messageSizeCache.object(forKey: key) {
            return sizeValue.cgsize// cgSizeValue
        }
        
        guard let messagesFlowLayout = collectionViewLayout as? MessagesCollectionViewFlowLayout else { return .zero }
        var newsize = messagesFlowLayout.sizeForItem(at: indexPath)
        if message.reactionsCount > 0 {
            newsize.height += 25
            if messageTopLabelAttributedText(for: message, at: indexPath) != nil {
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
    
    public func numberOfSections(in _: MessagesCollectionView) -> Int {
        self.shownMessages.count
    }
    
    public func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessageKit.MessagesCollectionView) -> MessageKit.MessageType {
        guard !isSectionReservedForTypingIndicator(indexPath.section),
              indexPath.section < self.shownMessages.count else {
            return self.shownMessages[self.shownMessages.count - 1]
        }
        return self.shownMessages[indexPath.section]
    }
    
    public func nextMessageForItem(at indexPath: IndexPath) -> MessageKit.MessageType? {
        
        if self.shownMessages.count > indexPath.section+1 {
            //let nextip = IndexPath(item: indexPath.row, section: indexPath.section+1)
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
    
    func messageAt(_ indexPath:IndexPath) -> ChatRoomMessage? {
        if self.shownMessages.count > indexPath.section {
            return self.shownMessages[indexPath.section]
        }

        return nil
    }

    public func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        let text = NSMutableAttributedString(string: "")
        guard let message = message as? ChatRoomMessage else { return text }
        
        if self.showDate(at: indexPath, message:message) {
            text.append(NSAttributedString(
                string: MessageKitDateFormatter.shared.string(from: message.sentDate),
                attributes: [
                    NSAttributedString.Key.font: UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.systemFont(ofSize: 10)),
                    NSAttributedString.Key.foregroundColor: UIColor.darkGray,
                ]))
        }
        
        if self.isUpdateMessage(message) {
            if var updateString = message.originalText {
                updateString = self.getFormattedSystemOrMemberUpdate(updateString: updateString)
                if text.length > 0 {
                    text.append(NSAttributedString(string: "\n"))
                    //updateString = "\n" + updateString
                }
                text.append(NSAttributedString(string: updateString, attributes:attrs))
            }
        }
        
        return text
    }
    
    func getFormattedSystemOrMemberUpdate(updateString:String) -> String {
        if updateString.count < 50 {
            return updateString
        }
        
        var lineLength = 45
        if updateString.contains("read up to this point") {
            lineLength = 60
        }
        
        var resultString = ""
        var currentLine = ""
        let scanner = Scanner(string: updateString)
        while let scannedStr: String = scanner.scanUpToCharacters(from: CharacterSet.whitespaces) {
            if (currentLine.count + scannedStr.count) <= lineLength {
                currentLine.append(scannedStr + " ")
            } else { // Need to break line and start new one
                resultString.append(currentLine + "\n")
                currentLine = scannedStr + " "
            }
            //let nunya = scanner.scanCharacters(from: CharacterSet.whitespaces)
        }
        
        if currentLine.count > 0 {
            resultString.append(contentsOf: currentLine)
        }
        return resultString
    }

    public func cellBottomLabelAttributedText(for msg: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        guard let message = msg as? ChatRoomMessage,
              let djids = message.displayedJids,
              !djids.isEmpty,
              let chatRoom = getRoom(),
              let chatThread = ChatThread.getChatThread(threadId: chatRoom.chatThreadId),
              chatThread.shouldShowReadReceipts else {
            return nil
        }
        
        let namesarray = djids.components(separatedBy: ", ")
        var hasRead = " has read up to this point"
        if namesarray.count > 1 {
            hasRead = " have read up to this point"
        }
        
        var msgText = djids.appending(hasRead)
        msgText = self.getFormattedSystemOrMemberUpdate(updateString: msgText)
        
        let attributedString = NSAttributedString(string: msgText, attributes: self.displayedTextAttributes)
        return attributedString
    }
    
    public func messageTopLabelAttributedText(for message: MessageType, at ip: IndexPath) -> NSAttributedString? {
        
        // this is an outgoing message
        if message.sender.senderId == self.sender.senderId { return nil }
        
        // previous message sent by same person
        if let prev = prevMessageForItem(at: ip), prev.sender.senderId == message.sender.senderId { return nil }
        
        let name = message.sender.displayName
        guard name.count > 0 else {
            return nil
        }
        
        return NSAttributedString(string: name, attributes: attrs)
    }

    public func messageBottomLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        guard let message = message as? ChatRoomMessage else { return nil }
        let attributedString = NSMutableAttributedString(string: "")
        
        if let deliveryString = self.deliveryStatusString(for: message), deliveryString.length > 0 {
            attributedString.append(deliveryString)
        }
        
        if let progress = message.transferProgress {
            let percentProgress = progress * 100
            var progressString:String?
            var insertIndex = 0;
            //let font = UIFont(name: kFontAwesomeFont, size: 12)
            
            if message.state == ChatRoomMessageState.received.rawValue, progress < 1 {
                if let merror = message.error{//} as? NSError {
                    let nsErr = NSError(domain: merror.errDomain, code: merror.errCode)
                    if !nsErr.isUserCanceledError, !nsErr.isAutomaticDownloadError {
                        let clockChar: UniChar = 0xf017
                        let progressString = String(format: " %C ", clockChar)
                        
                        let attrStr = NSAttributedString(string: progressString, attributes: attrs)
                        //NSAttributedString(string: progressString, attributes: [NSAttributedString.Key.font:font ?? UIFont.systemFont(ofSize: 12)])
                        attributedString.append(attrStr)
                        return attributedString
                    }
                } else {
                    progressString = String(format: " %@ %.0f%%", INCOMING_STRING(), percentProgress)
                }
                insertIndex = attributedString.length
            } else if message.state != ChatRoomMessageState.received.rawValue, progress < 1 {
                if let merror = message.error {
                    let nsErr = NSError(domain: merror.errDomain, code: merror.errCode)
                    if !nsErr.isUserCanceledError, !nsErr.isAutomaticDownloadError {
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

    public func textCell(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UICollectionViewCell? {
        nil
    }
    
    open override func collectionView( _ collectionView: UICollectionView, canPerformAction action: Selector, forItemAt indexPath:IndexPath, withSender sender: Any?) -> Bool {
        return false //overridden for long press
    }
    
    @objc private func didLongPress(_ longGestureRecognizer: UILongPressGestureRecognizer) {
        if (longGestureRecognizer.state == UIGestureRecognizer.State.began) {
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
    
    private func getBuddy(forUniqueId: String) -> ChatBuddyModel? {
        guard let room = self.getRoom() else { return nil }
        let roomModel = ChatRoomModel(room: room)
        let roomBuddies = roomModel.allBuddies()
        
        for buddy in roomBuddies {
            if buddy.uniqueId == forUniqueId {
                return buddy
            }
        }
        return nil
    }
    
    private func toggleReaction(_ reaction: String, for message: ChatRoomMessage) {
        guard let account = getAccount(),
              let receiverJid = message.roomJid,
              let xmppManager = xmppManager(),
              let stream = xmppManager.omemoSignalCoordinator?.omemoModule?.xmppStream,
              let senderJid = stream.myJID?.full else {
            return
        }
        
        self.isShowingContextMenu = false
        
        var reactionIcons = [String]()
        var reactions: [ChatMessageReaction] = []
        
        let senderJidWithName = "\(receiverJid)/\(account.displayName)"
        if var messageReactions = message.reactions {
            if let index = messageReactions.firstIndex(where: { $0.senderJid == senderJidWithName }) {
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
                messageReactions.append(ChatMessageReaction(senderJid: senderJidWithName, reactions: [reaction]))
            }
            reactions = messageReactions
        } else {
            reactionIcons = [reaction]
            reactions = [ChatMessageReaction(senderJid: senderJidWithName, reactions: reactionIcons)]
        }
        
        guard let xmppId = message.xmppId else { return }
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        
        ReactionManager.shared.saveReactionsInLocalDatabase(
            xmppId: xmppId,
            senderJid: senderJidWithName,
            reactions: reactions
        ) {
            self.justSent = true
            ReactionManager.shared.sendReactions(
                xmppId: xmppId,
                stanzaId: message.stanzaId,
                receiverJid: receiverJid,
                senderJid: senderJid,
                isGroup: true,
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
        return false //overridden for long press
    }
    
    func deleteMessage(at indexPath: IndexPath) {
        //what if this isn't the last message? The lastMessageId gets removed wrongly
        if let message = self.messageAt(indexPath) {
            if let nextMessage = self.nextMessageForItem(at: indexPath) as? ChatRoomMessage {
                let nextId = nextMessage.uniqueId as NSString
                self.messageSizeCache.removeObject(forKey: nextId)
                self.messageBottomCache.removeObject(forKey: nextId)
                self.cellTopCache.removeObject(forKey: nextId)
                self.cellBottomCache.removeObject(forKey: nextId)
            }
            if let prevMessage = self.prevMessageForItem(at: indexPath) as? ChatRoomMessage {
                let prevId = prevMessage.uniqueId as NSString
                self.messageSizeCache.removeObject(forKey: prevId)
                self.messageBottomCache.removeObject(forKey: prevId)
                self.cellTopCache.removeObject(forKey: prevId)
                self.cellBottomCache.removeObject(forKey: prevId)
            }
            let msgId = message.uniqueId as NSString
            self.messageSizeCache.removeObject(forKey: msgId)
            self.messageBottomCache.removeObject(forKey: msgId)
            self.cellTopCache.removeObject(forKey: msgId)
            self.cellBottomCache.removeObject(forKey: msgId)
            ChatRoomMessageModel.deleteMessage(with: message.uniqueId)
        }
    }

    /** Currently uses clock for queued, and checkmark for delivered. */
    func deliveryStatusString(for message:ChatRoomMessage) -> NSAttributedString? {
        let deliveryStatusString = NSMutableAttributedString(string: "")
        if message.sentDate == nil { //} && ![message messageMediaItemKey]) {
            // Waiting to send message. This message is in the queue.
            let clockChar: UniChar = 0xf017
            let clockString = String(format: " %C", clockChar)
            deliveryStatusString.append(NSAttributedString(string: clockString, attributes: faattrs))
        }
        
        return deliveryStatusString
    }
    
    func send(htmlURL:URL) {
        //guard let htmlURL = htmlURL else { return; }
        //check urls for jpg, etc, if so use sendImageFilePath
        let ustr = htmlURL.absoluteString.lowercased()
        if ustr.hasSuffix("jpg") || ustr.hasSuffix("jpeg") || ustr.hasSuffix("png") {
            self.sendImageFilePath(htmlURL.absoluteString, asJPEG:true, shouldResize:true)
            return
        } else if ustr.hasSuffix("gif") {
            self.sendImageFilePath(htmlURL.absoluteString, asJPEG:false, shouldResize:false)
            return
        } else if ustr.hasSuffix("mp4") || ustr.hasSuffix(".mov") {
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
                        DDLogError("ChatRoomViewController.sendHTMLURL error removing file item")
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
        
        let ispub = self.room?.isPublic ?? false
        
        if let xmpp = xmppManager(), let thread = getThread() {
            let threadModel = ChatThreadModel(thread: thread)
            xmpp.fileTransferManager.send(htmlURL: htmlURL, thread: threadModel, isPublic: ispub, completion: { [weak self] (success:Bool, error:Error?) in
                self?.handleMediaError(error: error)
            })
        }
    }

    /*open override func didPressAccessoryButton(_ sender: UIButton) {
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

    func isFailedDecryptMessage(_ message:ChatRoomMessage) -> Bool {
        if let msgText = message.messageText {
            if msgText.hasPrefix("Couldn't decrypt") || msgText.hasPrefix("Guardianbot") || msgText.hasPrefix("Guardianbot") {
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

    func setup(with buddies:[String], accountId:String, name:String?) {
        
        guard let xmpp = self.xmppManager(), let account = self.getAccount() else {return}
        
        if let service = xmpp.roomManager.conferenceServicesJID?.first, let jidName = name?.replacingOccurrences(of: " ", with: "-") {
            let jidString = jidName + "@" + service
            if let roomJID = XMPPJID(string: jidString) {
                xmpp.roomManager.startGroupChat(withBuddies: buddies, roomJID: roomJID, nickname: account.displayName, subject: name, isPublic: false, completion: { [weak self] (key: String?) in
                    guard let self, let key else { return }
                    DispatchQueue.main.async {
                        self.setThreadKey(key)
                    }
                })
            }
        } else {
            DDLogError("No conference server for account: \(account.username)")
        }
    }
    
    // used only for public rooms
    func setupGroup(with name:String?, isPublic:Bool) {
        guard let xmpp = self.xmppManager(), let account = self.getAccount() else {return}
        
        if let service = xmpp.roomManager.conferenceServicesJID?.first, let jidName = name?.replacingOccurrences(of: " ", with: "-") {
            let jidString = jidName + "@" + service
            if let roomJID = XMPPJID(string: jidString) {
                // Only announce "added to the group" for a brand-new group. When
                // rejoining a group we were already a member of (e.g. after a
                // re-login), the room already exists locally, so suppress the join
                // message to avoid spamming other members with a join notice or an
                // undecryptable message. (#454)
                let roomKey = ChatRoomModel.createUniqueId(account.uniqueId, jid: roomJID.bare)
                let roomAlreadyExists = ChatRoomModel.getXMPPRoom(uniqueId: roomKey) != nil
                xmpp.roomManager.startGroupChat(withBuddies: [], roomJID: roomJID, nickname: account.displayName, subject: name, isPublic: isPublic, completion: { [weak self] (key: String?) in
                    guard let self = self, let key = key else { return }
                    DispatchQueue.main.async {
                        self.setThreadKey(key)
                    }
                    if !roomAlreadyExists {
                        xmpp.roomManager.publishJoinedRoom(roomJID, withName: account.displayName)
                    }
                })
            }
        } else {
            DDLogError("No conference server for account: \(account.username)")
        }
    }

    func doResetSecureConnections() {
        if let xmpp = xmppManager(), let account = self.getAccount() {
            var devices:[NSNumber] = []
            var buddiesArray:[ChatBuddyModel] = []
            let hud = MBProgressHUD.showAdded(to: self.view, animated: true)
            do {
                try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                    if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle(transaction) {
                        let idNumber = NSNumber.init(integerLiteral: Int(bundle.deviceId))
                        let currentDevice = ChatOmemoDevice(deviceId: idNumber, trustLevel: OMEMOTrustLevel.trustedUser, parentKey: account.uniqueId, parentCollection: ChatAccountModel.collection(), publicIdentityKeyData: bundle.identityKey, lastSeenDate: xmpp.getLastConnected())
                        if let bareJid = account.bareJID, var curdevices = xmpp.omemoSignalCoordinator?.fetchDeviceIds(for: bareJid, transaction: transaction) {
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
                        
                        if let room = self.getRoom() {
                            let allOccs = ChatRoomOccupantModel.allXMPPRoomOccupants(for: room.uniqueId, transaction: transaction)
                            for occ in allOccs {
                                if let budId = occ.buddyUniqueId, let roomBuddy = ChatBuddyModel.getBuddy(uniqueId: budId, transaction: transaction), roomBuddy.username != account.username {
                                    buddiesArray.append(roomBuddy)
                                    let bdevices = ChatOmemoDevice.allOMEMODevices(for: budId, collection: ChatBuddyModel.collection(), transaction: transaction)
                                    allDevices.append(contentsOf: bdevices)
                                }
                            }
                        }
                        
                        ChatAccountSignalIdentity.removeAccountSignalIdKey(for: account.uniqueId, transaction: transaction)
                        ChatSignedPreKey.removeSignalSignedPreKey(for: account.uniqueId, transaction: transaction)
                        
                        xmpp.omemoSignalCoordinator?.removeDevice(allDevices, localOnly: true, completion: { (success:Bool) in })
                    }
                })
            } catch {
                DDLogError("doResetSecureConnections error \(error)")
            }
                
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
}

extension ChatRoomViewController: MessageCellDelegate {
    public func didTapMessage(in cell: MessageCollectionViewCell) {
        guard let indexPath = messagesCollectionView.indexPath(for: cell), let message = self.messageAt(indexPath) else {
            return
        }
        
        if let txt = message.messageText, txt.starts(with: "geo:") {
            self.findBuddyLocation(txt, with: message)
        }
        
        if let mediaKey = message.mediaItemId, let item = ChatMediaItemModel.getMediaItem(with: mediaKey) as? ChatHTMLItem {
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
        
        if let chatMsg = message as? ChatRoomMessage, let mediaKey = chatMsg.mediaItemId, let mediaItem = ChatMediaItemModel.getMediaItem(with: mediaKey), (chatMsg.transferProgress == 1 || mediaItem.grdbRecord?.transferProgress == 1) {
            if let imgItem = mediaItem as? ChatImageItem, let imgUrl = imgItem.url {
                if let origtext = chatMsg.originalText, origtext.hasPrefix("geo") {
                    self.findBuddyLocation(origtext, with: chatMsg)
                } else {
                    if let prog = chatMsg.transferProgress, prog < 1.0 {
                        self.handleMissingMedia(chatMsg)
                    } else {
                        imgItem.downloadImage(imgUrl, filename: mediaItem.grdbRecord?.filename, completion: {[weak self] (img, url, data) in
                            guard let img = img, let self = self else {return }
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
    
    func handleMissingMedia(_ chatMsg:ChatRoomMessage) {
        let alert = UIAlertController(title: "Unable to Open", message: "There was an issue retrieving media. Try again in a few seconds.", preferredStyle: .alert)
        let cancelAction = UIAlertAction(title: "OK", style: .default, handler: {_ in
            if let xmpp = self.xmppManager() {
                DispatchQueue.global().async {
                    let model = ChatRoomMessageModel(message: chatMsg)
                    xmpp.fileTransferManager.retryDownloadMedia(model)
                }
            }
        })
        alert.addAction(cancelAction)
        present(alert, animated: true, completion: nil)
        return
    }
    
    func showFile(_ fileItem: ChatFileItem) {
        if let fileURL = MediaServer.sharedInstance().url(forChatMediaItem: fileItem, buddyUniqueId: self.threadKey) {
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

extension ChatRoomViewController: MessageLabelDelegate {
    public func didSelectPhoneNumber(_ phoneNumber: String) {
        print("Phone Number Selected: \(phoneNumber)")
    }

    public func didSelectURL(_ url: URL) {
        print("URL Selected: \(url)")
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

public extension ChatRoomViewController {
    @objc func handleDeviceListUpdate(notification:Notification) {
        guard let notificationJid = notification.userInfo?["jid"] as? XMPPJID else { return }
        guard let room = self.getRoom() else { return }
        
        let roomModel = ChatRoomModel(room: room)
        let roomBuddies = roomModel.allBuddies()
        for buddy in roomBuddies {
            if notificationJid.bare == buddy.username {
                checkDeviceListUpdate(buddy: buddy)
            }
        }
    }
    
    @objc func checkDeviceListUpdate(buddy:ChatBuddyModel) {
        guard let jid = buddy.bareJID, let xmpp = self.xmppManager() else { return }
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


extension ChatRoomViewController { //call stuff
    @objc func didSelectPhoneButton(sender: Any!) {
        var callBuddies:[String] = []
        if let xmppMgr = xmppManager(), let room = self.getRoom() {
            let roomModel = ChatRoomModel(room: room)
            let allOccs = roomModel.allOccupants()
            for occ in allOccs {
                if let budId = occ.buddyUniqueId, let roomBuddy = ChatBuddyModel.getBuddy(uniqueId: budId), roomBuddy.username != xmppMgr.chatAccount.username {
                    callBuddies.append(roomBuddy.username)
                }
            }
            
            if callBuddies.count == 0 {
                return
            }
            
            if (callBuddies.count > 4) {
                let alert = UIAlertController(title: "Unable to Call", message: "Calls are limited to five participants.", preferredStyle: .alert)
                let cancelAction = UIAlertAction(title: "OK", style: .default, handler: nil)
                alert.addAction(cancelAction)
                present(alert, animated: true, completion: nil)
                return
            }
            
            if xmppMgr.callManager.checkAudioPermissions() == true {
                AVAudioSession.sharedInstance().requestRecordPermission({ [weak self] (granted) in
                    DispatchQueue.main.async {
                        if (granted) { return }
                        let alert = UIAlertController(title: "Allow Audio", message: "Whoops! It looks like you have not permitted Guardian to access your Microphone. To use Guardian calling, please enable the Microphone in the Guardian settings on your device. For a video call, make sure Camera is enabled also.", preferredStyle: .alert)
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
            }
            
            let alert = UIAlertController(title: "Start Call?", message: nil, preferredStyle: .alert)
            let callAction = UIAlertAction(title: "Call", style: .default, handler: { alert in
                //if xmppMgr.callManager.makeCall(callBuddies, name:self.getThreadName()!) == true {
                    //self.addCallUpdate("You called", mgr: xmppMgr, room: room)
                //}
            })
            let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
            alert.addAction(callAction)
            alert.addAction(cancelAction)
            self.present(alert, animated: true, completion: nil)
        }
    }

    func addCallUpdate(_ updateMsg:String, mgr:XMPPManager, room:ChatRoom) {
        let roomModel = ChatRoomModel(room: room)
        let message = roomModel.outgoingMessage(text: updateMsg)
        message.messageSecurity = GlacierMessageTransportSecurity.plaintext //omemo not needed
        
        if let systemMsgModel = message as? ChatRoomMessageModel, var systemMsg = systemMsgModel.grdbRecord {
            
            if let acct = getAccount() {
                systemMsg.msgSenderId = acct.uniqueId
                systemMsg.msgSenderDisplayName = acct.displayName
            }
            
            systemMsg.systemUpdate = true
            systemMsg.messageDate = Date()
            systemMsg.messageReadDate = Date()
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
        let navitem = self.navigationItem
        if let rightNav = navitem.rightBarButtonItem {
            rightNav.isEnabled = enable
        }
        
        UIApplication.shared.isIdleTimerDisabled = !enable
    }
    
    @objc func didSelectOccupantsButton(sender: Any!) {
        let storyboard = UIStoryboard(name: "RoomOccupants", bundle: GlacierInfo.resourcesBundle)
        if let threadKey = self.threadKey, let occupantsVC = storyboard.instantiateViewController(withIdentifier: "roomOccupants") as? RoomOccupantsViewController {
            occupantsVC.delegate = self
            occupantsVC.setRoomKey(threadKey)
            self.navigationController?.pushViewController(occupantsVC, animated: true)
        }
    }
}

// MARK: AttachmentsInputBarViewDelegate

extension ChatRoomViewController: AttachmentsInputBarViewDelegate {
    func didPressPlus(with inputBar: InputBarAccessoryView) {
        self.messageInputBar.inputTextView.resignFirstResponder()
        updateFloatyPosition(force: true)
        floaty.open()
        DispatchQueue.main.async { [weak self] in
            self?.updateFloatyPosition(force: true)
        }
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
        if GlacierAppDelegate.appDelegate.isProxyDetected() == true {
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
        
        guard let text = inputBar.inputTextView.text, text.count > 0, GlacierAppDelegate.appDelegate.isProxyDetected() == false else {
            inputBar.sendButton.image = nil
            inputBar.sendButton.title = "Send"
            inputBar.inputTextView.placeholder = "Send encrypted message"
            if self.room?.isPublic == true {
                inputBar.inputTextView.placeholder = "Send message"
            }
            inputBar.sendButton.isEnabled = false
            (self as? ChatRoomViewControllerExt)?.removePush2TalkButton()
            return
        }
        
        //let components = inputBar.inputTextView.components
        inputBar.inputTextView.text = String()
        inputBar.invalidatePlugins()
        
        // Sending clears composing state
        if let xmpp = xmppManager(), let room = getRoom() {
            xmpp.sendRoomChatState(.inactive, roomUniqueId: room.uniqueId)
        }
        
        // Send button activity animation
        inputBar.sendButton.startAnimating()
        
        self.navigationController?.providesPresentationContextTransitionStyle = true
        self.navigationController?.definesPresentationContext = true
        
        // Resign first responder for iPad split view
        if ChatRoomViewController.IS_IPHONE == false {
            inputBar.inputTextView.resignFirstResponder()
        }
        
        let sendtxt = self.convertBadLinksText(text)
        let msgurls = sendtxt.urls
        if msgurls.count > 0, self.automaticURLFetchingDisabled == false {
            self.handleTextWithLinks(sendtxt, msgurls:msgurls)
        } else {
            self.doSendMessage(text)
        }
        
        inputBar.sendButton.stopAnimating()
        inputBar.inputTextView.placeholder = "Send encrypted message"
        if self.room?.isPublic == true {
            inputBar.inputTextView.placeholder = "Send message"
        }
        //self.insertMessages(components)
        self.messagesCollectionView.scrollToLastItem(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.messagesCollectionView.scrollToLastItem(animated: true)
        }
    }
    
    public func inputBar(_ inputBar: InputBarAccessoryView, textViewTextDidChangeTo text: String) {
        if let untrimmed = self.messageInputBar.inputTextView.text, untrimmed.hasSuffix("\n"), GlacierSettingsManager.bool(forSettingKey: "kOTREnterToSendKey") {
            self.messageInputBar.inputTextView.text = text
            processInputBar(messageInputBar)
        }
        /*self.resetOptionsButton()
         
         let hasText = textView.text.count > 0
         if (hasText != self.state.hasText) {
         self.state.hasText = hasText
         }
         
         //Everytime the textview has text and a notification comes through we are 'typing' otherwise we are done typing
         if (hasText) {
         self.isTyping()
         } else {
         self.didFinishTyping()
         }*/
        
        let hasText = text.count > 0
        if let xmpp = xmppManager(), let room = getRoom() {
            xmpp.sendRoomChatState(hasText ? .composing : .inactive, roomUniqueId: room.uniqueId)
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
            DDLogError("ChatRoomViewController.handleVideoPicked error copying video item")
        }
    }
    
    func doSendMessage(_ text: String) {
        if let xmpp = xmppManager(), let room = getRoom() {
            let roomModel = ChatRoomModel(room: room)
            let outMsg = roomModel.outgoingMessage(text: text)
            if room.isPublic {
                outMsg.messageSecurity = .plaintext
            }
            
            if let acct = getAccount() {
                outMsg.senderId = acct.uniqueId
                outMsg.senderDisplayName = acct.displayName
            }
            
            if let roomMsg = outMsg as? ChatRoomMessageModel {
                self.justSent = true
                xmpp.enqueueMessage(roomMsg)
            }
        }
    }

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
    }
    
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
}

extension ChatRoomViewController { //XMPP stuff
    func fetchOMEMODeviceListForRoom() {
        let pubroom = self.room?.isPublic ?? false
        guard pubroom == false else { return }
        
        var roomBuddies:[XMPPJID] = []
        if let xmpp = xmppManager(), let account = getAccount(), let threadKey = self.threadKey {
            do {
                try DBManager.sharedDB().grdbStorage.read(block: { transaction in
                    if let room = try ChatRoomModel.getXMPPRoom(uniqueId: threadKey, transaction: transaction) {
                        let allOccs = room.allOccupants(transaction: transaction)
                        for occ in allOccs {
                            if let budId = occ.buddyUniqueId, let buddy = ChatBuddyModel.getBuddy(uniqueId: budId, transaction: transaction), buddy.username != account.username, let jid = buddy.bareJID {
                                roomBuddies.append(jid)
                            }
                        }
                    }
                })
            } catch {
                DDLogDebug("ChatRoomViewController.fetchOMEMODeviceListForRoom with error: \(error)")
            }
            
            xmpp.omemoSignalCoordinator?.omemoModule?.performBlock(async: true, {
                for jid in roomBuddies {
                    xmpp.omemoSignalCoordinator?.omemoModule?.fetchDeviceIds(for: jid, elementId: nil)
                }
            })
        }
    }
    
    func updateView(with key: String) {
        if let room = self.getRoom() {
            let roomModel = ChatRoomModel(room: room)
            self.state.isThreadOnline = roomModel.currentStatus != ThreadStatus.offline
            self.refreshTitleView()
        }
        self.tryToMarkAllMessagesAsRead()
    }
    
    @objc private func handleRoomTypingChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let roomId = userInfo["roomId"] as? String,
              roomId == self.threadKey else { return }
        
        let rawNames = userInfo["typingNames"] as? [String] ?? []
        let rawJIDs  = userInfo["typingJIDs"]  as? [String] ?? []
        
        // Strip the local user so they never appear as "typing" in their own header.
        let localNickname = xmppManager()?.chatAccount.displayName.lowercased()
        let filteredPairs = zip(rawNames, rawJIDs).filter { (_, jid) in
            guard let nickname = localNickname,
                  let resource = XMPPJID(string: jid)?.resource else { return true }
            return resource.lowercased() != nickname
        }
        let typingNames = filteredPairs.map { $0.0 }
        let typingJIDs  = filteredPairs.map { $0.1 }
        
        // Reset per-occupant auto-clear timers for currently-typing occupants
        typingJIDs.forEach { jid in
            self.occupantTypingTimers[jid]?.invalidate()
            self.occupantTypingTimers[jid] = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.occupantTypingTimers.removeValue(forKey: jid)
                if let roomKey = self.threadKey {
                    BuddyCache.shared().setTypingOccupant(jid: jid, displayName: "", forRoom: roomKey, isTyping: false)
                }
            }
        }
        
        // For group chat we show typing status in the navigation title subtitle rather
        // than the MessageKit animated bubble — this lets us display who is typing.
        if !typingNames.isEmpty {
            let label = typingNames.count == 1
            ? "\(typingNames[0]) is typing..."
            : "\(typingNames.joined(separator: ", ")) are typing..."
            self.titleView.subtitleLabel.text = label
        } else {
            self.titleView.subtitleLabel.text = nil
        }
    }
    
    func tryToMarkAllMessagesAsRead() {
        // Set all messages as read
        if self.isGlacierVisible() {
            if let xmpp = xmppManager(), let chatRoom = self.getRoom(), let chatThread = ChatThread.getChatThread(threadId: chatRoom.chatThreadId) {
                ChatRoomMessageModel.markAllUnreadMessages(for: chatRoom.uniqueId, completion: { (messagesUpdated:[ChatRoomMessageModel]) in
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
    
    func refreshScreenMessages() {
        let cnt = self.chatRoomMessages.count
        if cnt >= 2, self.chatRoomMessages[cnt-1].msgSenderId == self.chatRoomMessages[cnt-2].msgSenderId, let ip = indexPathForNextToLastItem() {
            self.safeReconfigureItems(at: [ip])
        }
    }
    
    func showDate(at indexPath:IndexPath, message:ChatRoomMessage) -> Bool {
        if (indexPath.section == 0) {
            return true
        }
        
        if let prev = self.prevMessageForItem(at: indexPath) as? ChatRoomMessage {
        //let previp = IndexPath(row: 0, section: indexPath.section-1)
        //if let prev = self.messageAt(previp) {
            let timediff = message.messageDate.timeIntervalSince(prev.messageDate)
            if (timediff > ChatRoomViewController.kGlacierMessageSentDateShowTimeInterval) {
                return true
            }
        }
        
        return false
    }
}

extension ChatRoomViewController: AttachmentPickerDelegate{
    public func addUploadHUD() {
        self.addUploadHUD("Preparing upload, tap to cancel...", tapToCancel: true)
    }
    
    public func addUploadHUD(_ message: String, tapToCancel: Bool) {
        if self.uploadHUD == nil {
            self.uploadHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
            self.uploadHUD?.label.text = message
            if tapToCancel == true {
                let hudSingleTap = UITapGestureRecognizer(target: self, action: #selector(self.hudTap(sender:)))
                self.uploadHUD?.addGestureRecognizer(hudSingleTap)
            }
        }
    }
    
    public func attachmentPicker(_ attachmentPicker: AttachmentPicker, gotPhoto photo: UIImage, withInfo info: [AnyHashable : Any]) {
        self.sendPhoto(photo, asJPEG: true, shouldResize: true, userTypedText: self.messageInputBar.inputTextView.text, info: info)
        self.messageInputBar.inputTextView.text = nil
    }
    
    public func attachmentPicker(_ attachmentPicker: AttachmentPicker, gotVideoURL videoURL: URL) {
        self.sendVideoURL(videoURL)
    }
    
    public func attachmentPicker(_ attachmentPicker: AttachmentPicker, gotGif photo: UIImage, withInfo info: [AnyHashable : Any]) {
        self.sendPhoto(photo, asJPEG: false, shouldResize: false, userTypedText: self.messageInputBar.inputTextView.text, info: info)
        self.messageInputBar.inputTextView.text = nil
    }

    public func attachmentPicker(_ attachmentPicker: AttachmentPicker, preferredMediaTypesFor source: UIImagePickerController.SourceType) -> Array<String>
    {
        return [UTType.image.identifier, UTType.movie.identifier]
    }

    public func attachmentPicker(_ attachmentPicker: AttachmentPicker, gotFileURLs fileURLs: Array<URL>) {
        self.sendFileURLs(fileURLs)
    }
}

extension ChatRoomViewController: UIPopoverPresentationControllerDelegate{
    public func prepareForPopoverPresentation(_ popoverPresentationController: UIPopoverPresentationController) {
        // Without setting this, there will be a crash on iPad
        // This delegate is set in the AttachmentPicker
        popoverPresentationController.sourceView = self.attachButton
    }
}

//#pragma - mark Media Display Methods
extension ChatRoomViewController: AVPlayerViewControllerDelegate {
    func showVideo(_ videoItem: ChatVideoItem) {
        if let videoURL = videoItem.mediaServerURL() {
            let player = AVPlayer.init(url: videoURL)
            let moviePlayerViewController = AVPlayerViewController()
            moviePlayerViewController.player = player
            
            moviePlayerViewController.delegate = self
            self.originalAudioCategory = AVAudioSession.sharedInstance().category as AVAudioSession.Category
            do {
                try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback)
            } catch {
                DDLogError("ChatRoomViewController.showVideo error setting category")
            }
            present(moviePlayerViewController, animated: true, completion: nil)
        }
    }
    
    public func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        if playerViewController.isBeingDismissed, let audioCat = self.originalAudioCategory {
            do {
                try AVAudioSession.sharedInstance().setCategory(audioCat)
            } catch {
                DDLogError("ChatRoomViewController.playerViewController error setting category")
            }
        }
    }
}

extension ChatRoomViewController: MessagesDisplayDelegate {
  // MARK: - Text Messages

    public func textColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        isFromCurrentSender(message: message) ? .white : .label//.darkText
    }

    public func detectorAttributes(for detector: DetectorType, and _: MessageType, at _: IndexPath) -> [NSAttributedString.Key: Any] {
        return ChatViewController.detectorAttributes
    }

    public func enabledDetectors(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> [DetectorType] {
        [.url]//, .address, .phoneNumber, .date, .transitInformation, .mention, .hashtag]
    }

  // MARK: - All Messages

    public func backgroundColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        isFromCurrentSender(message: message) ? UIColor.bubbleBlue() : UIColor.bubbleLightGray()
    }

    public func messageStyle(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> MessageStyle {
        let tail: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft
        return .bubbleTail(tail, .curved)
    }

    public func configureAvatarView(_ avatarView: AvatarView, for message: MessageType, at indexPath: IndexPath, in mcv: MessagesCollectionView) {
        
        //guard let rmessage = message as? ChatRoomMessage else { return }
        
        if let next = nextMessageForItem(at: indexPath), message.sender.senderId == next.sender.senderId {
            avatarView.isHidden = true
            return
        }
        
        guard let message = message as? ChatRoomMessage else { return }
        
        if self.isUpdateMessage(message) {
            avatarView.isHidden = true
            return
        }
        
        avatarView.isHidden = false
        if isFromCurrentSender(message: message) {
            if let avatar = self.fromAvatar {
                avatarView.set(avatar: avatar)
            }
        } else {
            guard let buddyid = message.buddyUniqueId else {
                return
            }
            
            if let avatar = self.toAvatars[buddyid] {
                avatarView.set(avatar: avatar)
            }
        }
    }

    public func configureMediaMessageImageView(_ imageView: UIImageView, for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView)
    {
        guard case MessageKind.photo(let media) = message.kind, let chatMsg = message as? ChatRoomMessage else {
            imageView.kf.cancelDownloadTask()
            return
        }
        
        var imageURL:URL?
        if let roomId = chatMsg.roomUniqueId {
            if let chatimg = media as? ChatImageItem {
                imageURL = chatimg.mediaServerURL(roomId)
            } else if let chatfile = media as? ChatFileItem {
                imageURL = chatfile.mediaServerURL(roomId)
            } else if let htmlfile = media as? ChatHTMLItem {
                imageURL = htmlfile.mediaServerURL(roomId)
            }
        }
        
        if let imageURL = imageURL {
            imageView.kf.indicatorType = .activity
            let thumbnailKey =  String(format: "%@-thumb", chatMsg.uniqueId)
            let resource = KF.ImageResource(downloadURL: imageURL, cacheKey: thumbnailKey)
            //******* set the resource
            if GlacierImageCache.shared().isCached(forKey: thumbnailKey) {
                imageView.kf.setImage(with: resource, options: optionsInfo)
            } else if let chatimg = media as? ChatImageItem {
                imageView.kf.indicator?.startAnimatingView()
                if let prog = chatimg.grdbRecord?.transferProgress, prog < 1.0 {
                    imageView.image = chatimg.placeholderImage
                    return
                }
                
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
                            } else if chatimg.grdbRecord?.transferProgress != 1.0 {
                                chatimg.grdbRecord?.transferProgress = 1.0
                                chatimg.save {}
                            }
                        }

                        let options = KingfisherParsedOptionsInfo(self.optionsInfo)
                        
                        GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in
                            
                            imageView.kf.setImage(with: resource, options: self.optionsInfo) { result in
                                switch result {
                                case .success(_):
                                    ChatRoomMessage.touch(chatMsg.uniqueId)
                                    /*if self.shownMessages.count > ip.section {
                                        self.messagesCollectionView.reconfigureItems(at: [ip])
                                    }*/
                                case .failure(_):
                                    break
                                }
                            }
                        })

                        case .failure(let error):
                            imageView.image = media.placeholderImage
                            imageView.kf.indicator?.stopAnimatingView()
                            print(error)
                            DispatchQueue.main.async {
                                if self.retriedSet.contains(chatMsg.uniqueId) == false {
                                    if let xmpp = self.xmppManager() {
                                        self.retriedSet.insert(chatMsg.uniqueId)
                                        xmpp.fileTransferManager.retryDownloadMedia(ChatRoomMessageModel(message: chatMsg))
                                    }
                                }
                            }
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
                                        self.collectionUpdateQueue.async {
                                            self.safeReconfigureItems(at: [ip])
                                        }
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
                htmlfile.grdbRecord?.parentObjectCollection = ChatRoomMessageModel.collection()
                imageView.kf.indicator?.startAnimatingView()
                if activelyFetching.contains(chatMsg.uniqueId) == false {
                    activelyFetching.insert(chatMsg.uniqueId)
                    KingfisherManager.shared.retrieveImage(with: imageURL, options: optionsInfo) { result in
                        switch result {
                        case .success(let img):
                            let himg = img.image
                            let mediaSize = ChatMediaItem.normalizeWidth(width: ChatHTMLItem.contentPreviewWidth, height: ChatHTMLItem.contentPreviewHeight)
                            let resizedImage = himg.scaleImageWith(newSize: mediaSize)
                            
                            imageView.image = resizedImage
                            imageView.kf.indicator?.stopAnimatingView()
                            
                            self.dsQueue.async {
                                htmlfile.storeInCache(resizedImage, thumbnailKey: thumbnailKey, messageId: chatMsg.uniqueId, buddyId: chatMsg.roomUniqueId, found:true)
                                self.activelyFetching.remove(chatMsg.uniqueId)
                            }
                        case .failure(_):
                            guard let murl = media.url else {
                                DispatchQueue.main.async {
                                    imageView.kf.indicator?.stopAnimatingView()
                                    imageView.kf.cancelDownloadTask()
                                    imageView.image = htmlfile.placeholderImage
                                    self.activelyFetching.remove(chatMsg.uniqueId)
                                }
                                return
                            }

                            htmlfile.getMetadata(murl, completion: { (metadata:LPLinkMetadata?, error:Error?) in
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self else { return }

                                    guard let metadata = metadata else {
                                        imageView.kf.indicator?.stopAnimatingView()
                                        imageView.kf.cancelDownloadTask()
                                        imageView.image = htmlfile.placeholderImage
                                        self.activelyFetching.remove(chatMsg.uniqueId)
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
                                        //imageView.layoutIfNeeded()

                                        self.dsQueue.async {
                                            htmlfile.storeInCache(resizedImage, thumbnailKey: thumbnailKey, messageId: chatMsg.uniqueId, buddyId: chatMsg.roomUniqueId, found:false, completion: {[weak self] _ in
                                                ChatRoomMessage.touch(chatMsg.uniqueId)
                                                self?.scrollIfAppropriate()
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
            if retriedSet.contains(chatMsg.uniqueId) == false {
                if let xmpp = xmppManager() {
                    retriedSet.insert(chatMsg.uniqueId)
                    xmpp.fileTransferManager.retryDownloadMedia(ChatRoomMessageModel(message: chatMsg))
                }
            }
        }
    }

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
        // this is needed especially when the cell is reconfigure while is playing sound
        audioPlaybackController.configureAudioCell(cell, message: message)
        
        guard case MessageKind.audio(let media) = message.kind, let chatMsg = message as? ChatRoomMessage else {
            return
        }
        
        if audioPlaybackController.audioPlayer?.isPlaying == true { return }
        
        if let audioItem = media as? ChatAudioItem {
            //let dtext = cell.durationLabel.text
            if audioItem.duration > 0.0 {
                cell.durationLabel.text = self.audioProgressTextFormat(audioItem.duration, for: cell, in: self.messagesCollectionView)
            } else {
                if let url = MediaServer.sharedInstance().url(forChatMediaItem: audioItem, buddyUniqueId: chatMsg.roomUniqueId) {
                    let audioAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
                    let tlength = Float(CMTimeGetSeconds(audioAsset.duration))
                    cell.durationLabel.text = self.audioProgressTextFormat(tlength, for: cell, in: self.messagesCollectionView)
                }
            }
        }
    }
}

// MARK: MessagesLayoutDelegate

extension ChatRoomViewController: MessagesLayoutDelegate {
    public func cellTopLabelHeight(for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        guard let message = message as? ChatRoomMessage else { return 5 }
        
        let strId = message.uniqueId as NSString
        if let cachedHeight = self.cellTopCache.object(forKey: strId) {
            return cachedHeight.float
        }
        
        var height:CGFloat = 5
        if self.showDate(at: ip, message: message) {
            height = 18
            if self.isUpdateMessage(message) {
                height = 31
            }
        } else if self.isUpdateMessage(message) {
            height = 18
        }
        
        let gfloat = GlacierFloat.init()
        gfloat.float = height
        self.cellTopCache.setObject(gfloat, forKey: strId)
        
        return height
    }

    public func cellBottomLabelHeight(for mtype: MessageType, at ip: IndexPath, in mcv: MessagesCollectionView) -> CGFloat {
        guard let message = mtype as? ChatRoomMessage else { return 5 }
        
        let strId = message.uniqueId as NSString
        if let cachedHeight = self.cellBottomCache.object(forKey: strId) {
            return cachedHeight.float
        }
        
        //if message has displayedJIDs, print it here in small italics centered?
        var height:CGFloat = 5.0
        if let next = nextMessageForItem(at: ip), mtype.sender.senderId == next.sender.senderId {
            height = 0.0
        }
        
        if let at = cellBottomLabelAttributedText(for: mtype, at: ip), at.length > 0 {
            height += 16.0
        }
        
        let gfloat = GlacierFloat.init()
        gfloat.float = height
        self.cellBottomCache.setObject(gfloat, forKey: strId)

        return height
    }

    public func messageTopLabelHeight(for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        // this is an outgoing message
        if message.sender.senderId == self.sender.senderId { return 0 }
        
        // previous message sent by same person
        if let prev = prevMessageForItem(at: ip), prev.sender.senderId == message.sender.senderId { return 0 }
        
        if message.sender.displayName.count == 0 { return 0 }
        
        return 16
        
        //0//20
    }

    public func messageBottomLabelHeight(for mtype: MessageType, at ip: IndexPath, in mcv: MessagesCollectionView) -> CGFloat {
        
        guard let message = mtype as? ChatRoomMessage else { return 0 }
        let strId = message.uniqueId as NSString
        if let cachedHeight = self.messageBottomCache.object(forKey: strId) {
            return cachedHeight.float
        }
        
        var height:CGFloat = 0
        if let at = messageBottomLabelAttributedText(for: mtype, at: ip), at.length > 0 {
            height = 16
        }
        
        let gfloat = GlacierFloat.init()
        gfloat.float = height
        self.messageBottomCache.setObject(gfloat, forKey: strId)
        
        return height
    }
    
    public func textCellSizeCalculator(for message: MessageType, at indexPath: IndexPath, in    messagesCollectionView: MessagesCollectionView) -> CellSizeCalculator? {
        guard let message = message as? ChatRoomMessage else { return nil }
        if self.isUpdateMessage(message) {
            return zeroTextLayout
        }
        return nil
    }
}

extension ChatRoomViewController: FloatyDelegate {
    // MARK: - Floaty Delegate Methods
    public func floatyWillOpen(_ floaty: Floaty) {
        updateFloatyPosition(force: true)
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
            (self as? ChatRoomViewControllerExt)?.microphoneButtonTouched(self)
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

        floaty.addItem(item: locItem)
        floaty.addItem(item: fileItem)
        floaty.addItem(item: audioItem)
        floaty.addItem(item: gifItem)
        floaty.addItem(item: photoItem)
        floaty.addItem(item: cameraItem)
        floaty.hasShadow = false

        floaty.buttonColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
        floaty.plusColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0)
        floaty.animationSpeed = 0.03
        floaty.fabDelegate = self
        floaty.overlayColor = UIColor.black.withAlphaComponent(0.8)
        floaty.relativeToSafeArea = false
        floaty.respondsToKeyboard = false
      
        self.view.addSubview(floaty)
        updateFloatyPosition(force: true)
        floaty.isHidden = true
    }

    private func scheduleFloatyPositionUpdate() {
        guard isViewLoaded, !isFloatyPositionUpdateScheduled else { return }
        isFloatyPositionUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFloatyPositionUpdateScheduled = false
            self.updateFloatyPosition(force: false)
        }
    }

    private func updateFloatyPosition(force: Bool) {
        guard isViewLoaded else { return }
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 8
        let bounds = view.bounds
        let safeInsets = view.safeAreaInsets
        if !force, bounds == lastFloatyLayoutBounds, safeInsets == lastFloatyLayoutSafeAreaInsets {
            return
        }
        lastFloatyLayoutBounds = bounds
        lastFloatyLayoutSafeAreaInsets = safeInsets
        if let inputBar = messageInputBar as? AttachmentsInputBarView,
           let plusButton = inputBar.plusButton {
            inputBar.layoutIfNeeded()
            let buttonFrame = plusButton.convert(plusButton.bounds, to: view)
            let desiredOriginX = max(safeInsets.left + horizontalPadding, buttonFrame.midX - floaty.size / 2)
            let desiredOriginY = max(safeInsets.top + verticalPadding, buttonFrame.midY - floaty.size / 2)
            floaty.paddingX = max(0, bounds.width - floaty.size - safeInsets.right - desiredOriginX)
            floaty.paddingY = max(0, bounds.height - floaty.size - safeInsets.bottom - desiredOriginY)
        } else {
            let desiredOriginX = safeInsets.left + horizontalPadding
            let desiredOriginY = safeInsets.bottom + verticalPadding
            floaty.paddingX = max(0, bounds.width - floaty.size - safeInsets.right - desiredOriginX)
            floaty.paddingY = max(0, desiredOriginY)
        }
    }
}

extension ChatRoomViewController: ContextMenuDelegate {
    func addReaction(_ emoji: String, to message: any GRDBRecord) {
        guard let chatRoomMessage = message as? ChatRoomMessage else {
            return
        }
        toggleReaction(emoji, for: chatRoomMessage)
    }
    
    func handleAction(_ menuItem: ContextMenuItem, for message: any GRDBRecord) {
        guard let idx = self.longIndex, let chatRoomMessage = message as? ChatRoomMessage else {
            return
        }
        
        switch menuItem {
        case .copy:
            if case MessageKind.photo(_) = chatRoomMessage.kind, let txt = chatRoomMessage.messageText, txt.starts(with: "https:") {
                UIPasteboard.general.string = txt
            } else {
                self.collectionView(self.messagesCollectionView, performAction: NSSelectorFromString("copy:"), forItemAt: idx, withSender: nil)
            }
            
        case .delete:
            self.deleteMessage(at: idx)
        case .resend:
            let messageProtocol = ChatRoomMessageModel(message: chatRoomMessage)
            self.resendOutgoingMessage(
                for: messageProtocol.messageKey,
                messageCollection: messageProtocol.messageCollection,
                title: RESEND_STRING()
            )
        case .cancelDownload:
            let messageProtocol = ChatRoomMessageModel(message: chatRoomMessage)
            if let xmpp = xmppManager(),
               let mediaKey = messageProtocol.messageMediaItemKey,
               let mediaItem = ChatMediaItemModel.getMediaItem(with: mediaKey) {
                if mediaItem.grdbRecord?.isIncoming == true, (mediaItem.grdbRecord?.transferProgress ?? 1) < 1 {
                    xmpp.fileTransferManager.cancelDownload(mediaItem: mediaItem)
                }
            }
        case .viewProfile:
            if let room = self.room, let myAccount = getAccount(), var chatThread = ChatThread.getChatThread(threadId: room.chatThreadId) {
                let roomModel = ChatRoomModel(room: room)
                var chatParticipantsAccounts: [ChatAccountModel] = roomModel.allBuddies().compactMap {
                    let account = ChatAccount(uniqueId: $0.uniqueId, username: $0.username, domain: nil, resource: "", port: 0, displayName: $0.displayName, loginDate: nil, lastHistoryFetchDate: nil, pushPubsubEndpoint: nil, pushPubsubNode: nil, org: nil, apiKey: nil, avatarData: $0.avatarData, vCardTemp: nil, lastUpdatedvCardTemp: nil, photoHash: $0.photoHash, modified: nil)
                    return ChatAccountModel(account: account)
                }
                chatParticipantsAccounts.append(myAccount)
                for account in chatParticipantsAccounts {
                    if let userName = account.username.splitToArray(separator: "@").first,
                        (userName.lowercased() == chatRoomMessage.msgSenderDisplayName.lowercased() || account.displayName == chatRoomMessage.msgSenderDisplayName) {
                        let profileView = UserProfileView(
                            account: account,
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
                        break
                    }
                }
            }
        }
    }
    
    private func showReactionDetails(userReactions: [ChatMessageReaction]) {
        guard let room = self.getRoom() else { return }
        let roomModel = ChatRoomModel(room: room)
        
        let usersWhoReacted: [(name: String, reactions: [String])] = userReactions.compactMap {
            guard let name = $0.senderJid.split(separator: "/").last else { return nil }
            return (name: name.description, reactions: $0.reactions)
        }
        
        var chatParticipants: [(isSelf: Bool, name: String, avtarImage: Data?)] = roomModel.allOccupants().compactMap {
            guard let budId = $0.buddyUniqueId,
                  let roomBuddy = ChatBuddyModel.getBuddy(uniqueId: budId) else { return nil }
            return (isSelf: false, name: roomBuddy.displayName, avtarImage: roomBuddy.avatarData)
        }
        
        if let currentUserAccount = getAccount(), chatParticipants.first(where: { $0.name.lowercased() == currentUserAccount.displayName.lowercased()}) == nil {
            chatParticipants.append((isSelf: true, name: currentUserAccount.displayName, avtarImage: currentUserAccount.avatarData))
        }
        
        var userReactionDetails = [UserReactionDetails]()
        for participant in chatParticipants {
            if let user = usersWhoReacted.first(where: { $0.name.lowercased() == participant.name.lowercased()}), !user.reactions.isEmpty {
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

extension ChatRoomViewController: MCEmojiPickerDelegate {
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

extension ChatRoomViewController: UserReactionDetailsViewDelegate {
    func didTapOn(reaction: String, completion: @escaping () -> Void) {
        guard let index = self.longIndex, let message = self.messageAt(index) else {
            return
        }
        self.toggleReaction(reaction, for: message)
        completion()
    }
}

// MARK: - Audio message cell delegate methods

extension ChatRoomViewController: GlacierAudioMessageCellDelegate {
    func didChangeAudioPlaybackSpeed(_ speed: Float) {
        UserDefaults.standard.set(speed, forKey: kAudioPlaybackSpeed)
        audioPlaybackController.setPlaybackSpeed(speed)
    }
}

@objc public class GlacierValue: NSObject, NSDiscardableContent {
    var cgsize: CGSize = .zero
    
    public func beginContentAccess() -> Bool { true }
    public func endContentAccess() { }
    public func discardContentIfPossible() { }
    public func isContentDiscarded() -> Bool { false }
}

@objc public class GlacierFloat: NSObject, NSDiscardableContent {
    var float: CGFloat = 0
    
    public func beginContentAccess() -> Bool { true }
    public func endContentAccess() { }
    public func discardContentIfPossible() { }
    public func isContentDiscarded() -> Bool { false }
}

@objc public class GlacierInt: NSObject, NSDiscardableContent {
    var int: Int = 0
    
    public func beginContentAccess() -> Bool { true }
    public func endContentAccess() { }
    public func discardContentIfPossible() { }
    public func isContentDiscarded() -> Bool { false }
}
