//  Glacier
//  Created by andyfriedman on 8/18/23.
//  Copyright © 2023 Glacier. All rights reserved.

import InputBarAccessoryView
import MessageKit
import DifferenceKit
import UIKit
import GRDB
import PureLayout
import MBProgressHUD
import MobileCoreServices
import Kingfisher
import Floaty
import MapKit

/// A base class for the example controllers
class SMSChatViewController: MessagesViewController, MessagesDataSource {
    static let kSMSMessageSentDateShowTimeInterval:TimeInterval = 60 * 60 * 12
    
    // MARK: - Public properties
    var conversation: SMSChatConversationModel?
    var currentIndexPath: IndexPath?
    var currentMessage: SMSChatMessage?
    var fromAvatar: Avatar?
    var toAvatar: Avatar?
    var attachmentPicker: OTRAttachmentPicker?
    var uploadHUD: MBProgressHUD?
    var hasText = false
    lazy var sender: MessageKit.SenderType = SMSUser(senderId: "", displayName: "")
    var sizes:[String:CGSize] = [:]
    lazy var floaty = Floaty()
    var phoneButton:UIButton = UIButton(type: .custom)
    
    
    private var msgCancellable: DatabaseCancellable?
    
    //    case first

    private typealias SMSSection = ArraySection<Int64, SMSChatMessage>
    private var smsdata:[SMSSection] = []
    private var dataInput: [SMSSection] {
        get { return smsdata }
        set {
            DispatchQueue.main.async {
                // whenever this dataInput gets assigned a new data, this block of code will run and update the collectionView or tableView with the new changes in the data set.
                var changeset = StagedChangeset(source: self.smsdata, target: newValue)
                
                var deleteds:[DifferenceKit.ElementPath] = []
                var dindex = 0
                var addeds:[DifferenceKit.ElementPath] = []
                var aindex = 0
                
                var sdeleteds:[Int] = []
                var saddeds:[Int] = []
                
                for (index, cset) in changeset.enumerated() {
                    if cset.elementDeleted.count > 0 {
                        deleteds = cset.elementDeleted
                        dindex = index
                    } else if cset.elementInserted.count > 0 {
                        addeds = cset.elementInserted
                        aindex = index
                    } else if cset.sectionDeleted.count > 0 {
                        sdeleteds = cset.sectionDeleted
                    } else if cset.sectionInserted.count > 0 {
                        saddeds = cset.sectionInserted
                    }
                }
                
                //remove the whole first changeset, change added to updated
                if deleteds.count > 0, addeds.count == deleteds.count {
                    let del = deleteds[0].section
                    if changeset[aindex].data.count > del, changeset[dindex].data[del].model == changeset[aindex].data[del].model {
                        changeset[aindex].elementUpdated = addeds
                        changeset[aindex].elementInserted.removeAll()
                    }
                    changeset.remove(at: dindex)
                } else if sdeleteds.count > 3, saddeds.count == sdeleteds.count, saddeds[0] == sdeleteds[0] {
                    if let lastid = self.smsdata.last?.elements.first?.uniqueId, lastid == newValue.last?.elements.first?.uniqueId {
                        return // just redoing same changeset
                    }
                }
                
                if changeset.isEmpty {
                    return
                }
                
                var added = false
                for cset in changeset {
                    if cset.sectionInserted.count > 0 {
                        added = true
                    }
                    
                    if cset.elementUpdated.count > 0 {
                        for updated in cset.elementUpdated {
                            let sec = updated.section
                            let cmsg = cset.data[sec].elements[0]
                            if cmsg.mediaItemUniqueId != nil, let prog = cmsg.transferProgress, prog == 1.0 {
                                added = true
                            }
                        }
                    }
                }
                
                self.messagesCollectionView.reload(using: changeset, interrupt: { $0.changeCount > 100 }) { data in
                    self.smsdata = data
                    DispatchQueue.main.async {
                        if added {
                            self.messagesCollectionView.scrollToLastItem()
                        }
                    }
                }
            }
        }
    }
    
    let jpegType = "image/jpeg"
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - MessagesDataSource
    var currentSender: MessageKit.SenderType {
        return self.sender
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        
        // Hide any default left bar button and add a custom button
        self.navigationItem.hidesBackButton = true
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )
        
        configureMessageCollectionView()
        configureMessageInputBar()
        
        if (conversation?.grdbRecord?.remoteNumber) != nil {
            self.messagesCollectionView.reloadData()
            self.messagesCollectionView.layoutIfNeeded()
        }
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        if let navigationController = self.navigationController {
            for subview in navigationController.view.subviews {
                if let tabBar = subview as? UITabBar {
                    tabBar.isHidden = true
                    break
                }
            }
        }
    }
    
    open func setConversationKey(_ conversationId:String, collection: String) {
        let conv = SMSChatConversationModel.existingConversation(with: conversationId)
        
        if let conversation = conv {
            self.conversation = conversation
            self.navigationItem.title = conversation.grdbRecord?.preferredName ?? conversation.grdbRecord?.remoteNumber
            
            self.sender = SMSUser(senderId: (conversation.grdbRecord?.smsAccountId)!, displayName: (conversation.grdbRecord?.preferredName ?? conversation.grdbRecord?.remoteNumber)!)
            
            self.setupTopRightButtons()
            
            self.fromAvatar = nil
            self.getAvatarImages()
            self.messagesCollectionView.setContentOffset(CGPointZero, animated: false)
            self.messageInputBar.inputTextView.placeholder = "Send SMS message"
            
            self.observeConversations()
            
        }
    }

    //IOSM#95
    @objc open func infoButtonPressed(_ sender: AnyObject?) {
        if let conv = self.conversation, let number = conv.grdbRecord?.remoteNumber, let displayName = conv.grdbRecord?.preferredName {
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = NSTextAlignment.left
            
            var name = ""
            if displayName != number {
                name = "\nName: \(displayName)"
            }
            
            let infomsg = "\nPhone number: \(number)" + name
            
            let alert = UIAlertController(title: "Info", message: infomsg, preferredStyle: .alert)
            let okAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
            let nameAction = UIAlertAction(title: "Set Name", style: .default, handler: {_ in
                self.setDisplayName()
            })
            alert.addAction(okAction)
            alert.addAction(nameAction)
            
            let messageText = NSMutableAttributedString(
                string: infomsg,
                attributes: [
                    NSAttributedString.Key.paragraphStyle: paragraphStyle,
                    NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
                ]
            )
            alert.setValue(messageText, forKey: "attributedMessage")
            
            self.present(alert, animated: true, completion: nil)
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
        self.phoneButton.addTarget(self, action: #selector(didSelectPhoneButton), for: UIControl.Event.touchUpInside)
        
        self.navigationItem.rightBarButtonItems = nil
        let callWindow = OTRAppDelegate.appDelegate.callWindow
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: self.phoneButton)
        if callWindow?.rootViewController != nil {
            self.navigationItem.rightBarButtonItem?.isEnabled = false
        }
    }
    
    func setDisplayName() {
        guard let conv = self.conversation else {return}
        var name = "Contact name"
        if let displayName = conv.grdbRecord?.preferredName {
            name = displayName
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment.left

        let alert = UIAlertController(title: NSLocalizedString("Display Name", comment: "Display name for conversation"), message: nil, preferredStyle: UIAlertController.Style.alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Set Name", comment: "Set name button"), style: UIAlertAction.Style.default, handler: {(action: UIAlertAction!) in

            if let displayName = alert.textFields?.first?.text, displayName.count > 0 {
                conv.grdbRecord?.preferredName = displayName
            } else {
                conv.grdbRecord?.preferredName = conv.grdbRecord?.remoteNumber
            }
        
            self.navigationItem.title = self.sender.displayName
            conv.save()
        }))

        let msg = "\nSet a name for this contact. Contact names will not be stored on device and will not transfer to a new device."
        let messageText = NSMutableAttributedString(
            string: msg,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paragraphStyle,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
            ]
        )
        alert.setValue(messageText, forKey: "attributedMessage")

        alert.addAction(UIAlertAction(title: NSLocalizedString("No thanks", comment: "No button"), style: UIAlertAction.Style.cancel, handler: nil))
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.placeholder = name
            if let dname = conv.grdbRecord?.preferredName, let firstChar = dname.first, firstChar.isLetter {
                textField.text = dname
            }
            textField.isSecureTextEntry = false
        })
        self.present(alert, animated: true, completion: nil)
    }


    func configureMessageCollectionView() {
        messagesCollectionView.messagesDataSource = self
        messagesCollectionView.messageCellDelegate = self

        scrollsToLastItemOnKeyboardBeginsEditing = true // default false
        showMessageTimestampOnSwipeLeft = true // default false
      
        messagesCollectionView.messagesLayoutDelegate = self
        messagesCollectionView.messagesDisplayDelegate = self

    }
    
    func textCellSizeCalculator(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CellSizeCalculator? {
        nil
    }

    func configureMessageInputBar() {
        messageInputBar = AttachmentsInputBarView()
        messageInputBar.delegate = self
        messageInputBar.inputTextView.tintColor = .label
        messageInputBar.sendButton.setTitleColor(UIColor.bubbleBlue(), for: .normal)
        messageInputBar.sendButton.setTitleColor(UIColor.bubbleBlue(), for: .highlighted)
        
        messageInputBar.sendButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        messageInputBar.sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        
        inputBarType = .custom(messageInputBar)
        self.layoutFAB()
    }
    
    private func scrollToEnd(at pos: UICollectionView.ScrollPosition = .bottom, animated: Bool = true) {
        if self.dataInput[0].elements.count < 2 { return }
        let lastIndexPath = IndexPath(item: self.dataInput[0].elements.count - 2, section: 0)

        self.messagesCollectionView.scrollToItem(at: lastIndexPath, at: pos, animated: animated)
    }
    

  // MARK: - Helpers
    func getAvatarImages() {
        if self.fromAvatar == nil {
            if let account = ChatAccountModel.allXMPPAccounts().first {
                let initials = account.displayName.prefix(2)
                self.fromAvatar = Avatar(image: account.avatarImage, initials: String(initials))
            }
            if let conv = self.conversation {
                var lastTwo = "TO"
                if let num = conv.grdbRecord?.remoteNumber {
                    lastTwo = String(num.suffix(2))
                }
                if let avatar = conv.avatar {
                    self.toAvatar = Avatar(image: avatar, initials: lastTwo)
                } else {
                    self.toAvatar = Avatar(image: nil, initials: lastTwo)
                }
            }
        }
    }
    
    private func updateDataSource(from messages: [SMSChatMessage]) {
        var asec:[SMSSection] = []
        for msg in messages {
            asec.append(ArraySection(model: msg.id!, elements: [msg]))
        }
        
        self.dataInput = asec
        
        
    }
    
    private func observeConversations() {
        let request: QueryInterfaceRequest<SMSChatMessage>
        
        msgCancellable?.cancel()
        
        if let convid = self.conversation?.uniqueId {
            request = SMSChatMessage.all().filter(Column("conversationId") == convid)
        } else {
            return
        }
            
        msgCancellable = ValueObservation
            .tracking(request.fetchAll(_:))
            .start(
                in: DBManager.sharedDB().grdbStorage.pool,
                // Immediate scheduling feeds the data source right on subscription,
                // and avoids an undesired animation when the application starts.
                scheduling: .immediate,
                onError: { error in fatalError("Unexpected error: \(error)") },
                onChange: { [weak self] messages in
                    guard let self else { return }
                    self.updateDataSource(from: messages)
                })
        
        //scroll to bottom, not animated
    }
    
    public override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
    {
        if messagesCollectionView.messagesDataSource == nil {
            DDLogError("SMSChatViewController.collectionView missing messagesDataSource for indexPath: \(indexPath). Reconfiguring message collection view.")
            configureMessageCollectionView()
        }

        guard messagesCollectionView.messagesDataSource != nil else {
            DDLogError("SMSChatViewController.collectionView still missing messagesDataSource after reconfiguration. Returning empty cell to avoid crash.")
            return UICollectionViewCell()
        }

        // Very important to check this when overriding `cellForItemAt`
        // Super method will handle returning the typing indicator cell
        guard !isSectionReservedForTypingIndicator(indexPath.section) else {
            return super.collectionView(collectionView, cellForItemAt: indexPath)
        }

        guard indexPath.section < dataInput.count, indexPath.row < dataInput[indexPath.section].elements.count else {
            DDLogWarn("SMSChatViewController.collectionView received out-of-bounds indexPath: \(indexPath) for dataInput counts (sections: \(dataInput.count)). Returning empty cell.")
            return UICollectionViewCell()
        }

        return super.collectionView(collectionView, cellForItemAt: indexPath)

    }

    func isLastSectionVisible() -> Bool {
        guard !self.dataInput.isEmpty else { return false }
        
        let lastIndexPath = IndexPath(item: 0, section: self.dataInput.count - 1)
        return messagesCollectionView.indexPathsForVisibleItems.contains(lastIndexPath)
    }

    func numberOfSections(in _: MessagesCollectionView) -> Int {
        self.dataInput.count
    }
    
    
    func messageForItem(at indexPath: IndexPath, in messagesCollectionView: MessageKit.MessagesCollectionView) -> MessageKit.MessageType {
        return self.dataInput[indexPath.section].elements[indexPath.row]
    }

    func cellTopLabelAttributedText(for message: MessageType, at indexPath: IndexPath) -> NSAttributedString? {
        let text = NSMutableAttributedString(string: "")
        guard let message = message as? SMSChatMessage else { return text }
      
        if self.showDate(at: indexPath, message: message) {
            text.append(NSAttributedString(
                string: MessageKitDateFormatter.shared.string(from: message.sentDate),
                attributes: [
                    NSAttributedString.Key.font: UIFontMetrics(forTextStyle: .caption2).scaledFont(for: UIFont.systemFont(ofSize: 10)),
                    NSAttributedString.Key.foregroundColor: UIColor.darkGray,
                ]))
        }
      
        return text
    }

    func showDate(at indexPath:IndexPath, message:SMSChatMessage) -> Bool {
        if (indexPath.section == 0) {
            return true
        }
        
        if let prev = self.prevMessageForItem(at: indexPath) as? SMSChatMessage {
            let timediff = message.messageDate.timeIntervalSince(prev.messageDate)
            if (timediff > SMSChatViewController.kSMSMessageSentDateShowTimeInterval) {
                return true
            }
        }

        return false
    }
    
    public func prevMessageForItem(at indexPath: IndexPath) -> MessageKit.MessageType? {
        
        if indexPath.section >= 1, self.dataInput.count > indexPath.section {
            return self.dataInput[indexPath.section-1].elements[indexPath.row]
        }
        
        return nil
    }
    
    public func nextMessageForItem(at indexPath: IndexPath) -> MessageKit.MessageType? {
        
        if self.dataInput.count > indexPath.section+1 {
            return self.dataInput[indexPath.section+1].elements[indexPath.row]
        }
        
        return nil
    }
    
    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

  // MARK: Private

  // MARK: - Private properties

  private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}

extension SMSChatViewController {
    @objc func didSelectPhoneButton(sender: Any!) {
        guard let callnum = self.conversation?.grdbRecord?.remoteNumber, let name = self.navigationItem.title else {
            return
        }

        if CallManager.sharedCallManager().checkAudioPermissions() == true {
            AVAudioSession.sharedInstance().requestRecordPermission({ [weak self] (granted) in
                DispatchQueue.main.async {
                    if (granted) { return }
                    let alert = UIAlertController(title: "Allow Audio", message: "Whoops! It looks like you have not permitted Glacier to access your Microphone. To use Glacier calling, please enable the Microphone in the Glacier settings on your device.", preferredStyle: .alert)
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
            
        //IOSM-509 prevent accidental hot mic
        let alert = UIAlertController(title: "Start Call?", message: nil, preferredStyle: .alert)
        let callAction = UIAlertAction(title: "Call", style: .default, handler: { alert in
            CallManager.sharedCallManager().makeVoiceCall(callnum, name: name)
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
        alert.addAction(callAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }
}

// MARK: MessageCellDelegate

extension SMSChatViewController: MessageCellDelegate {
  func didTapAvatar(in _: MessageCollectionViewCell) {
    print("Avatar tapped")
  }

  func didTapMessage(in _: MessageCollectionViewCell) {
      print("Message tapped")
  }

  func didTapImage(in cell: MessageCollectionViewCell) {
      guard let indexPath = messagesCollectionView.indexPath(for: cell),
            let message = messagesCollectionView.messagesDataSource?.messageForItem(at: indexPath, in: messagesCollectionView)
      else {
          return
      }
      
      if let chatMsg = message as? SMSChatMessage, let mediaItem = SMSChatMediaItemModel.mediaItem(for: chatMsg.uniqueId), mediaItem.grdbRecord?.transferProgress == 1, let imgUrl = mediaItem.url {
          
          mediaItem.downloadImage(imgUrl, completion: {[weak self] (img, url) in
              guard let img = img, let self = self else {return }
              DispatchQueue.main.async {
                  let agrumeVC = ImageViewHelper()
                  agrumeVC.openImage(img, from: self)
              }
          })
      }
  }

  func didTapCellTopLabel(in _: MessageCollectionViewCell) {
    print("Top cell label tapped")
  }

  func didTapCellBottomLabel(in _: MessageCollectionViewCell) {
    print("Bottom cell label tapped")
  }

  func didTapMessageTopLabel(in _: MessageCollectionViewCell) {
    print("Top message label tapped")
  }

  func didTapMessageBottomLabel(in _: MessageCollectionViewCell) {
    print("Bottom label tapped")
  }

  func didTapAccessoryView(in _: MessageCollectionViewCell) {
    print("Accessory view tapped")
  }
}

// MARK: MessageLabelDelegate

extension SMSChatViewController: MessageLabelDelegate {
  func didSelectPhoneNumber(_ phoneNumber: String) {
    print("Phone Number Selected: \(phoneNumber)")
  }

  func didSelectURL(_ url: URL) {
    print("URL Selected: \(url)")
  }
}

// MARK: InputBarAccessoryViewDelegate

extension SMSChatViewController: InputBarAccessoryViewDelegate {
    // MARK: Internal

    @objc func inputBar(_: InputBarAccessoryView, didPressSendButtonWith _: String) {
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
        
        guard let text = inputBar.inputTextView.text, text.count > 0, OTRAppDelegate.appDelegate.isProxyDetected() == false else {
            inputBar.inputTextView.placeholder = "Send SMS message"
            return
        }

        inputBar.inputTextView.text = String()
        inputBar.invalidatePlugins()
        // Send button activity animation
        inputBar.sendButton.startAnimating()
      
        self.navigationController?.providesPresentationContextTransitionStyle = true
        self.navigationController?.definesPresentationContext = true
      
        // Resign first responder for iPad split view
        inputBar.inputTextView.resignFirstResponder()
        self.doSendMessage(text)
    
        inputBar.sendButton.stopAnimating()
        inputBar.inputTextView.placeholder = "Send SMS message"
        self.messagesCollectionView.scrollToLastItem(animated: true)
    }
    
    func doSendMessage(_ text:String) {
        if let conv = self.conversation {
            TwilioBackendManager.sharedMgr().sendMessage(conv, messageText: text)
        }
    }
}

extension SMSChatViewController: MessagesDisplayDelegate {
  // MARK: - Text Messages

    func textColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
        isFromCurrentSender(message: message) ? .white : .label//.darkText
    }
    
    public func detectorAttributes(for detector: DetectorType, and _: MessageType, at _: IndexPath) -> [NSAttributedString.Key: Any] {
        return ChatViewController.detectorAttributes
    }

    func enabledDetectors(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> [DetectorType] {
        [.url, .phoneNumber]
    }

  // MARK: - All Messages

  func backgroundColor(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> UIColor {
    isFromCurrentSender(message: message) ? UIColor.bubbleBlue() : UIColor.bubbleLightGray()
  }

  func messageStyle(for message: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> MessageStyle {
    let tail: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft
    return .bubbleTail(tail, .curved)
  }

    func configureAvatarView(_ avatarView: AvatarView, for message: MessageType, at ip: IndexPath, in _: MessagesCollectionView) {
        if let next = nextMessageForItem(at: ip), message.sender.senderId == next.sender.senderId {
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

    func configureMediaMessageImageView(_ imageView: UIImageView, for message: MessageType, at _: IndexPath, in _: MessagesCollectionView)
    {
        if case MessageKind.photo(let media) = message.kind, let imageURL = media.url, let chatMsg = message as? SMSChatMessage {
            let thumbnailKey =  String(format: "%@-thumb", chatMsg.uniqueId)
            if GlacierImageCache.shared().isCached(forKey: thumbnailKey) {
                let resource = KF.ImageResource(downloadURL: imageURL, cacheKey: thumbnailKey)
                let options:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                                     .memoryCacheExpiration(.days(14)),
                                                     .memoryCacheAccessExtendingExpiration(.cacheTime)]
                imageView.kf.setImage(with: resource, options: options)
            } else if let chatimg = media as? SMSChatMediaItemModel {
                imageView.kf.indicatorType = .activity
                KingfisherManager.shared.retrieveImage(with: imageURL) { result in
                    //if is not gif
                    switch result {
                    case .success(let img):
                        var resizedImage = img.image
                        var idata:Data? = img.data()
                        
                        let mediaSize = ChatMediaItem.normalizeWidth(width: img.image.size.width, height: img.image.size.height)
                        resizedImage = img.image.scaleImageWith(newSize: mediaSize)
                        idata = resizedImage.jpegData(dataSize: .unlimited)
                        
                        let optionsInfo:KingfisherOptionsInfo = [.cacheMemoryOnly,
                                                                 .memoryCacheExpiration(.days(14)),
                                                                 .memoryCacheAccessExtendingExpiration(.cacheTime)]
                        let options = KingfisherParsedOptionsInfo(optionsInfo)
                        
                        GlacierImageCache.shared().store(resizedImage, original: idata, forKey: thumbnailKey, options: options, toDisk: false, completionHandler: {_ in
                            
                            let resource = KF.ImageResource(downloadURL: imageURL, cacheKey: thumbnailKey)
                            imageView.kf.setImage(with: resource, options: optionsInfo) { result in
                                switch result {
                                case .success(_):
                                    SMSChatMessage.touch(chatMsg.uniqueId)
                                case .failure(_):
                                    break
                                }
                            }
                        })
                        
                    case .failure(let error):
                        print(error)
                    }
                }
            }
        }
    }

    // MARK: - Location Messages

    func annotationViewForLocation(message _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> MKAnnotationView? {
        let annotationView = MKAnnotationView(annotation: nil, reuseIdentifier: nil)
        let pinImage = #imageLiteral(resourceName: "ic_map_marker")
        annotationView.image = pinImage
        annotationView.centerOffset = CGPoint(x: 0, y: -pinImage.size.height / 2)
        return annotationView
    }

  func snapshotOptionsForLocation(
    message _: MessageType,
    at _: IndexPath,
    in _: MessagesCollectionView)
    -> LocationMessageSnapshotOptions
  {
    LocationMessageSnapshotOptions(
      showsBuildings: true,
      showsPointsOfInterest: true,
      span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10))
  }
}

// MARK: AttachmentsInputBarViewDelegate

extension SMSChatViewController: AttachmentsInputBarViewDelegate {
    func didPressPlus(with inputBar: InputBarAccessoryView) {
        self.messageInputBar.inputTextView.resignFirstResponder()
        floaty.open()
    }
    
    func didChooseVideo(with url: URL) {
    }
    
    func inputBar(_ inputBar: InputBarAccessoryView, didPressSendButtonWith attachments: [AttachmentManager.Attachment]) {
        if handleProxy() {
            return
        }
        
        for item in attachments {
            if case .image(let image) = item {
                self.sendImageMessage(photo: image)
            }
        }
        inputBar.invalidatePlugins()
    }

    func sendImageMessage(photo: UIImage) {
        if let data = photo.jpegData(dataSize: .unlimited) {
            self.sendPhoto(data, asJPEG:true)
        }
    }
    
    func sendPhoto(_ mediaData: Data, asJPEG:Bool) {
        if let conv = self.conversation {
            self.addUploadHUD()
            
            TwilioBackendManager.sharedMgr().sendMediaMessage(conv, mediaData: mediaData, filename:"Test", contentType: jpegType, completion: { (uploadSuccess) in
                self.removeUploadHUD()
            })
        }
    }
    
    public func addUploadHUD() {
        DispatchQueue.main.async {
            if (self.uploadHUD == nil) {
                self.uploadHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
                self.uploadHUD?.label.text = "Preparing upload, tap to cancel..."
                let hudSingleTap = UITapGestureRecognizer(target: self, action: #selector(self.hudTap(_:)))
                self.uploadHUD?.addGestureRecognizer(hudSingleTap)
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
    
    @objc func hudTap(_ sender: UITapGestureRecognizer) {
        let alert = UIAlertController(title: "Stop upload?", message: "Are you sure you want to stop sending this?", preferredStyle: .alert)
        let stop = UIAlertAction(title: "Stop", style: UIAlertAction.Style.default) {
            (result : UIAlertAction) -> Void in
            self.removeUploadHUD()
        }
        let cont = UIAlertAction(title: "Continue", style: .cancel, handler: nil)
        alert.addAction(cont)
        alert.addAction(stop)
        DispatchQueue.main.async {
            self.present(alert, animated: true, completion: nil)
        }
    }
}

// MARK: MessagesLayoutDelegate

extension SMSChatViewController: MessagesLayoutDelegate {
    func cellTopLabelHeight(for mtype: MessageType, at ip: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        guard let message = mtype as? SMSChatMessage else { return 5 }
        var height:CGFloat = 5
        if self.showDate(at: ip, message: message) {
            height = 18
        }
        
        return height
    }

    func cellBottomLabelHeight(for mtype: MessageType, at ip: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        if let next = nextMessageForItem(at: ip), mtype.sender.senderId == next.sender.senderId {
            return 0
        }
        return 5
        
        //5//17
    }

    func messageTopLabelHeight(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        0
    }

    func messageBottomLabelHeight(for _: MessageType, at _: IndexPath, in _: MessagesCollectionView) -> CGFloat {
        0
    }
}

extension SMSChatViewController: FloatyDelegate {
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

extension Int64: Differentiable {
    public var differenceIdentifier: Self {
        return self
    }
    
    public func isContentEqual(to source: Self) -> Bool {
        return self == source
    }
}

struct SMSUser: SenderType, Equatable {
  var senderId: String
  var displayName: String
}
