//  Glacier
//  from NumPadLBTA
//  Created by Brian Voong on 3/19/19.
//  Copyright © 2019 Brian Voong. All rights reserved.

import UIKit
import MBProgressHUD

@objc open class DialerViewController: UICollectionViewController, UICollectionViewDelegateFlowLayout, UITabBarDelegate, SMSNumbersDelegate {
    
    fileprivate let cellId = "cellId"
    fileprivate let greenButtonCellId = "greenButtonCellId"
    fileprivate let backspaceCellId = "backspaceCellId"
    fileprivate let headerId = "headerId"
    var tabBar:GlacierTabs?
    var vmBtn:UIBarButtonItem?
    var vmBtnNew:UIBarButtonItem?
    var numAction: SMSNumbersAction?
    var addRemoveMenu: UIMenu?
    var addNumber: UIAction?
    var releaseNumber: UIAction?
    var nameNumber: UIAction?
    var copyNumber: UIAction?
    var spinnerHUD: MBProgressHUD?
    var shouldHaveToolTip = false
    var vmEnabled = false
    var addNumberOpen = false
    private weak var dialedNumbersHeader: DialedNumbersHeader?
    
    let numbers = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"
    ]
    
    // hack solution
    let lettering = [
        "", "A B C", "D E F", "G H I", "J K L", "M N O", "P Q R S", "T U V", "W X Y Z", "", "+", ""
    ]
    
    var dialedNumbersDisplayString = ""
    private var shouldIgnoreNextDigitSelection = false
    
    var smsMenu = UIMenu(title: "Phone Numbers", children: [])
    var settingsButton: UIBarButtonItem?
    
    @objc func doInitStuff() {
        let lblColor = UIColor.label
        let settingsIcon = UIImage(named: "OTRSettingsIcon-1", in: GlacierInfo.resourcesBundle, compatibleWith: nil)
        
        settingsButton = UIBarButtonItem(image: settingsIcon, style: UIBarButtonItem.Style.plain, target: nil, action:nil)
        settingsButton?.tintColor = lblColor
        
        let initial = UIAction(title: "No numbers to display", handler: { (_) in  })
        addRemoveMenu = UIMenu(title: "", options: .displayInline, children: [initial])
        
        let items = [self.addRemoveMenu!]
        smsMenu = UIMenu(title: "Phone Numbers", children: items)
        
        self.addNumber = UIAction(title: "Add Number", image: UIImage(systemName: "plus"), handler: { (_) in
            self.handleAddNumber()
        })
        self.releaseNumber = UIAction(title: "Release Number", image: UIImage(systemName: "trash"), handler: { (_) in
            self.setNumbersWithAction(SMSNumbersAction.release)
        })
        self.nameNumber = UIAction(title: "Name a Number", image: UIImage(systemName: "person"), handler: { (_) in
            self.setNumbersWithAction(SMSNumbersAction.name)
        })
        self.copyNumber = UIAction(title: "Copy Number", image: UIImage(systemName: "doc.on.doc"), handler: { (_) in
            self.doCopy()
        })
        
        let vmIcon = UIImage(systemName: "recordingtape")?.imageMasked(with: UIColor.label)
        let vmUBtn = UIButton(type: .custom)
        vmUBtn.translatesAutoresizingMaskIntoConstraints = false
        if let normalVmImage = vmIcon?.imageMasked(with: UIColor.label) {
            vmUBtn.setImage(normalVmImage, for: UIControl.State.normal)
        }
        vmUBtn.addTarget(self, action: #selector(vmButtonPressed), for: UIControl.Event.touchUpInside)
        vmUBtn.autoSetDimensions(to: CGSize(width: 36, height: 40))
        vmBtn = UIBarButtonItem(customView: vmUBtn)
        vmBtn?.style = UIBarButtonItem.Style.plain
        
        TwilioBackendManager.sharedMgr().setSMSDelegate(self)
    }
    
    open override func viewDidLoad() {
        super.viewDidLoad()
        
        let vmIcon = UIImage(systemName: "recordingtape")?.imageMasked(with: UIColor.label)
        let customView = createCustomBarButtonView(with: vmIcon!)
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(vmButtonPressed))
        customView.isUserInteractionEnabled = true
        customView.addGestureRecognizer(tapGesture)
        vmBtnNew = UIBarButtonItem(customView: customView)
        vmBtnNew?.style = UIBarButtonItem.Style.plain
        
        var titleColor = UIColor.label
        let tmgr = TwilioBackendManager.sharedMgr()
        if let acctrec = tmgr.selectedAccount?.grdbRecord {
            self.navigationItem.title = acctrec.displayName ?? acctrec.phoneNumber
            if let colorstr = acctrec.color {
                titleColor = UIColor.UIColorFromString(string: colorstr)
            }
            
            if AWSAcctManager.sharedMgr().getGlacierEnablements()?.voicemailEnabled == true {
                self.vmEnabled = true
                self.navigationItem.rightBarButtonItem = self.vmBtn
            }
        }
        
        let appearance = UINavigationBarAppearance.init()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        self.navigationController?.navigationBar.tintColor = titleColor
        
        collectionView.backgroundColor = .systemBackground
        collectionView.register(KeyPadCell.self, forCellWithReuseIdentifier: cellId)
        collectionView.register(GreenCallButtonCell.self, forCellWithReuseIdentifier: greenButtonCellId)
        collectionView.register(BackspaceCell.self, forCellWithReuseIdentifier: backspaceCellId)
        
        collectionView.register(DialedNumbersHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: headerId)
        
        if !self.shouldHaveToolTip && self.settingsButton?.menu == nil {
            self.settingsButton?.menu = self.smsMenu
        }
        
        self.navigationItem.leftBarButtonItem = self.settingsButton
        
        self.tabBar = GlacierTabs()
        if let tabs = self.tabBar {
            self.navigationController?.view.addSubview(tabs)
            tabs.delegate = self
            tabs.setPhoneModule()
        }
    }
    
    func createCustomBarButtonView(with image: UIImage) -> UIView {
        let containerView = UIView()
            
        // ImageView for the button image
        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(imageView)
            
        // Blue dot
        let blueDot = UIView()
        blueDot.backgroundColor = .red
        blueDot.layer.cornerRadius = 4 // Make it round
        blueDot.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(blueDot)
            
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
        ])
            
        NSLayoutConstraint.activate([
            blueDot.widthAnchor.constraint(equalToConstant: 8), // Size of the blue dot
            blueDot.heightAnchor.constraint(equalToConstant: 8), // Size of the blue dot
            blueDot.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -5), // Position it near the bottom-right
            blueDot.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5) // Position it near the right edge
        ])
            
        // Size of the container view to fit the image and blue dot
        containerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: 36.0),
            containerView.heightAnchor.constraint(equalToConstant: 40.0)
        ])
            
        return containerView
    }
    
    override open func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        self.tabBar?.selectedItem = self.tabBar?.dialItem
        if let acctrec = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord {
            let title = acctrec.displayName ?? acctrec.phoneNumber
            if self.navigationItem.title != title {
                self.navigationItem.title = title
                if let colorstr = acctrec.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
                    let titleColor = UIColor.UIColorFromString(string: colorstr)
                    appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
                    self.navigationController?.navigationBar.standardAppearance = appearance
                    self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
                    self.navigationController?.navigationBar.tintColor = titleColor
                }
            }
        }
        
        //check vm status
        self.handleVMStatus()
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.shouldHaveToolTip {
            self.setToolTipOnLoad()
        }
    }
    
    func setToolTipOnLoad() {
        self.settingsButton?.removeToolTip()
        self.settingsButton?.menu = nil
        self.settingsButton?.addToolTip(description: "You are not authorized to add a number. Please contact your administrator.")
    }
    
    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        self.navigationController?.popToRootViewController(animated: false)
        if let appDelegate = Application.shared.delegate as? OTRAppDelegate {
            switch (item.tag) {
            case GlacierTabs.Screen.chats.rawValue:
                appDelegate.window?.rootViewController = appDelegate.splitViewCoordinator.splitViewController
                break
            case GlacierTabs.Screen.sms.rawValue:
                appDelegate.window?.rootViewController = appDelegate.smsSplitViewCoordinator.splitViewController
                break
            case GlacierTabs.Screen.contacts.rawValue:
                appDelegate.window?.rootViewController = appDelegate.contactsViewController
                break
            case GlacierTabs.Screen.history.rawValue:
                appDelegate.window?.rootViewController = appDelegate.historyViewController
                break
            default:
                break
            }
        }
    }
    
    public func numberSelected(_ selectedNumber:String, selectedName:String?) {
        let tmgr = TwilioBackendManager.sharedMgr()
        if self.numAction == SMSNumbersAction.release {
            self.addSpinnerHUD("Releasing number (be patient)...")
            tmgr.releaseNumber(selectedNumber)
        } else if self.numAction == SMSNumbersAction.name {
            tmgr.nameANumber(selectedNumber, selectedName: selectedName)
        } else if self.numAction == SMSNumbersAction.add {
            self.addSpinnerHUD("Initializing number (be patient)...")
            tmgr.purchaseNumber(selectedNumber, selectedName: selectedName)
        }
        self.numAction = nil
        if self.numAction != SMSNumbersAction.name {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.removeSpinnerHUD()
            }
        }
    }
    
    func setAddRemoveMenu() {
        var bottomActions = [UIAction]()
        
        let tmgr = TwilioBackendManager.sharedMgr()
        if tmgr.glacierSMS?.addUserToPurchaseNumbers == true, let addNum = self.addNumber {
            bottomActions.append(addNum)
        }
        
        if tmgr.glacierSMS?.addUserToPurchaseNumbers == true && tmgr.currentAccounts.count > 0, let releaseNum = self.releaseNumber {
                bottomActions.append(releaseNum)
        }
        
        if tmgr.currentAccounts.count > 0, let nameNum = self.nameNumber, let copyNum = self.copyNumber {
            bottomActions.append(nameNum)
            bottomActions.append(copyNum)
        }
                
        self.addRemoveMenu = UIMenu(title: "", options: .displayInline, children: bottomActions)
    }
    
    func setNumbersWithAction(_ action:SMSNumbersAction) {
        self.numAction = action
        
        let tmgr = TwilioBackendManager.sharedMgr()
        let smsNumbersViewController = SMSNumbersViewController()
        smsNumbersViewController.delegate = self
        var currentNumbers:[String] = []
        var currentNames:[String?] = []
        for acct in tmgr.currentAccounts {
            if let number = acct.grdbRecord?.phoneNumber {
                currentNumbers.append(number)
                if let dis = acct.grdbRecord?.displayName {
                    currentNames.append(dis)
                }
            }
        }
        smsNumbersViewController.setNumbers(currentNumbers, names: currentNames, action: action)
        let modalNavigationController = UINavigationController(rootViewController: smsNumbersViewController)
        modalNavigationController.modalPresentationStyle = .formSheet
        
        self.present(modalNavigationController, animated: true, completion: nil)
    }
    
    func doCopy() {
        let alert = UIAlertController(title: "Copy to Clipboard?", message: "Copying this number to your device will allow any other apps on your device to access it.", preferredStyle: .alert)
    
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord?.phoneNumber
            self.dismiss(animated: true, completion: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: {(action: UIAlertAction!) in
            self.dismiss(animated: true, completion: nil)
        }))
    
        self.present(alert, animated: true)
    }
    
    open override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {

        if shouldIgnoreNextDigitSelection {
            shouldIgnoreNextDigitSelection = false
            if indexPath.section == 0 && numbers[indexPath.item] == "0" {
                return
            }
        }

        // backspace indexPath
        if indexPath.section == 1 {
            if indexPath.item == 1{
                dialedNumbersDisplayString = String(dialedNumbersDisplayString.dropLast())
            } else {
                if dialedNumbersDisplayString.count > 8 { //string longer than 7?
                    didSelectCallButton()
                }
            }
        } else {
            let number = numbers[indexPath.item]
            dialedNumbersDisplayString += number
            CallManager.sharedCallManager().dialedDigit(number)
        }

        collectionView.reloadData()
    }
    
    open override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: headerId, for: indexPath) as! DialedNumbersHeader
        header.numbersLabel.text = dialedNumbersDisplayString
        header.tapHandler = { [weak self, weak header] in
            guard let self = self, let header = header else { return }
            self.presentPasteMenu(from: header.numbersLabel)
        }
        dialedNumbersHeader = header
        return header
    }
    
    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if section == 1 {
            return .zero
        }
        let height = view.frame.height * 0.2
        return .init(width: view.frame.width, height: height)
    }
    
    open override func numberOfSections(in collectionView: UICollectionView) -> Int {
        return 2
    }
    
    open override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if section == 1 {
            return 2
        }
        return numbers.count
    }
    
    open override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        
        if indexPath.section == 1 {
            if indexPath.item == 0 {
                let greenButtonCell = collectionView.dequeueReusableCell(withReuseIdentifier: greenButtonCellId, for: indexPath) as! GreenCallButtonCell
                return greenButtonCell
            } else {
                let backspaceCell = collectionView.dequeueReusableCell(withReuseIdentifier: backspaceCellId, for: indexPath) as! BackspaceCell
                return backspaceCell
            }
            
        }
        
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellId, for: indexPath) as! KeyPadCell
        cell.digitsLabel.text = numbers[indexPath.item]
        cell.lettersLabel.text = lettering[indexPath.item]
        cell.longPressAction = nil
        if numbers[indexPath.item] == "0" {
            cell.longPressAction = { [weak self] in
                self?.handleZeroLongPress()
            }
        }
        return cell
    }
    
    lazy var leftRightPadding = view.frame.width * 0.13
    lazy var interSpacing = view.frame.width * 0.1
    lazy var totalEmptySpace = (view.frame.width - 2 * leftRightPadding - 2 * interSpacing)
    lazy var cellWidth = totalEmptySpace / 3
    

    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return .init(width: cellWidth, height: cellWidth)
    }
    
    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        return 16
    }
    
    public func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        if section == 1 {
            let leftPadding = (view.frame.width) / 2 - cellWidth / 2
            return .init(top: 0, left: leftPadding, bottom: 0, right: self.leftRightPadding)
        }
        return .init(top: 16, left: leftRightPadding, bottom: 16, right: leftRightPadding)
    }

    func didSelectCallButton() {
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
            let name = CallManager.cleanPhoneNumber(self.dialedNumbersDisplayString)
            CallManager.sharedCallManager().makeVoiceCall(self.dialedNumbersDisplayString, name: name)
            
            self.dialedNumbersDisplayString = ""
            self.collectionView.reloadData()
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
        alert.addAction(callAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }

    private func presentPasteMenu(from sourceView: UIView) {
        guard UIPasteboard.general.string != nil else { return }
        becomeFirstResponder()
        let menuController = UIMenuController.shared
        let pasteItem = UIMenuItem(title: "Paste", action: #selector(handlePasteFromMenu))
        menuController.menuItems = [pasteItem]
        menuController.showMenu(from: sourceView, rect: sourceView.bounds)
    }

    @objc private func handlePasteFromMenu() {
        guard let clipboardText = UIPasteboard.general.string else { return }
        guard let sanitizedText = sanitizedDialString(from: clipboardText) else {
            presentInvalidPasteAlert()
            return
        }

        dialedNumbersDisplayString = sanitizedText
        shouldIgnoreNextDigitSelection = false
        dialedNumbersHeader?.numbersLabel.text = dialedNumbersDisplayString
        collectionView.reloadData()
    }

    private func sanitizedDialString(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        var result = ""
        var hasPlusPrefix = false
        let ignorableCharacters: Set<Character> = [" ", "-", "(", ")", ".", ",", ";"]

        for character in trimmed {
            if character.isNumber {
                result.append(character)
            } else if character == "*" || character == "#" {
                result.append(character)
            } else if character == "+" {
                if hasPlusPrefix || result.isEmpty == false {
                    return nil
                }
                hasPlusPrefix = true
                result.append(character)
            } else if ignorableCharacters.contains(character) {
                continue
            } else {
                return nil
            }
        }

        return result.isEmpty ? nil : result
    }

    private func presentInvalidPasteAlert() {
        let alert = UIAlertController(title: "Cannot Paste", message: "The clipboard does not contain text that can be used as a phone number.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    override open var canBecomeFirstResponder: Bool {
        return true
    }

    override open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handlePasteFromMenu) {
            return UIPasteboard.general.string != nil
        }
        return false
    }

    private func handleZeroLongPress() {
        shouldIgnoreNextDigitSelection = true
        if dialedNumbersDisplayString.isEmpty {
            dialedNumbersDisplayString = "+"
        } else if dialedNumbersDisplayString.hasPrefix("+") == false {
            let trimmedLeadingZeros = dialedNumbersDisplayString.drop(while: { $0 == "0" })
            if trimmedLeadingZeros.isEmpty {
                dialedNumbersDisplayString = "+"
            } else {
                dialedNumbersDisplayString = "+" + String(trimmedLeadingZeros)
            }
        }
        collectionView.reloadData()
    }
    
    @objc open func vmButtonPressed() {
        let vmViewController = VoicemailViewController.init()
        self.navigationController?.pushViewController(vmViewController, animated: true)
    }
}

extension DialerViewController : TwilioAccountDelegateProtocol {
    public func availableNumbersUpdated(_ availableNumbers: [String]) {
        DispatchQueue.main.async {
            guard let appDelegate = Application.shared.delegate as? OTRAppDelegate, appDelegate.window?.rootViewController == appDelegate.dialerViewController else {
                return
            }
            
            if self.addNumberOpen {
                //passthedata?  not needed if it's a delegate
            } else if availableNumbers.count > 0 {
                var availableNames: [String?] = []
                for _ in availableNumbers {
                    availableNames.append(nil)
                }
                
                let smsNumbersViewController = SMSNumbersViewController()
                smsNumbersViewController.delegate = self
                self.numAction = SMSNumbersAction.add
                smsNumbersViewController.setNumbers(availableNumbers, names: availableNames, action:SMSNumbersAction.add)
                let modalNavigationController = UINavigationController(rootViewController: smsNumbersViewController)
                modalNavigationController.modalPresentationStyle = .formSheet
                self.addNumberOpen = true
                    
                self.present(modalNavigationController, animated: true, completion: nil)
            }
        }
    }
    
    func handleAddNumber() {
        let tmgr = TwilioBackendManager.sharedMgr()
        if (tmgr.currentAccounts.count > 4) {
            let alert = UIAlertController(title: "Unable to Add Number", message: "There is a limit of 5 numbers. Remove one or more numbers to add another.", preferredStyle: .alert)
            let cancelAction = UIAlertAction(title: "OK", style: .default, handler: nil)
            alert.addAction(cancelAction)
            present(alert, animated: true, completion: nil)
            return
        }
        
        TwilioBackendManager.sharedMgr().queryForAvailableNumbers(areaCode:nil, contains: nil)
    }
    
    public func numbersControllerClosed() {
        self.addNumberOpen = false
    }
    
    public func setSelectedAccount(_ account: SMSChatAccountModel?) {
        self.navigationItem.title = (account?.grdbRecord?.displayName ?? account?.grdbRecord?.phoneNumber) ?? "SMS"
        if let titleColor = account?.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
            appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
            self.navigationController?.navigationBar.standardAppearance = appearance
            self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
            self.navigationController?.navigationBar.tintColor = titleColor
        }
        
        if !vmEnabled, AWSAcctManager.sharedMgr().getGlacierEnablements()?.voicemailEnabled == true {
            self.vmEnabled = true
            self.navigationItem.rightBarButtonItem = self.vmBtn
        }
    }
    
    public func voicemailUpdated() {
        self.handleVMStatus()
    }
    
    @objc func handleVMStatus() {
        if self.vmEnabled {
            if TwilioBackendManager.sharedMgr().hasNewVM, self.vmBtnNew != nil {
                self.navigationItem.rightBarButtonItem = self.vmBtnNew
            } else {
                self.navigationItem.rightBarButtonItem = self.vmBtn
            }
        }
    }
    
    public func accountsUpdated() {
        let tmgr = TwilioBackendManager.sharedMgr()
        let accounts = tmgr.currentAccounts
        let selected = tmgr.selectedAccount
        var menuItems: [UIMenuElement] = []
        
        for account in accounts {
            let phoneImage = UIImage(systemName:"phone")?.withTintColor(account.color ?? UIColor.orange, renderingMode: .alwaysOriginal)
            
            guard let phonenumber = account.grdbRecord?.phoneNumber else { continue }
            
            var natitle = phonenumber
            if let naname = account.grdbRecord?.displayName {
                natitle = natitle + " " + naname
                if (natitle.count > 21) {
                    natitle = natitle.prefix(18) + "..."
                }
            }
            
            let numberAction = UIAction(title: natitle, image: phoneImage, handler: {(_) in
                TwilioBackendManager.sharedMgr().selectedAccount = account
            })
            
            menuItems.append(numberAction)
        }
        
        DispatchQueue.main.async {
            if (accounts.count == 0) {
                self.navigationItem.title = "No account"
            } else {
                if let selacct = selected {
                    self.setSelectedAccount(selacct)
                }
            }
            
            if menuItems.count == 0 && tmgr.glacierSMS?.addUserToPurchaseNumbers == false { //IOSM#85
                self.shouldHaveToolTip = true
                self.settingsButton?.menu = nil
                self.settingsButton?.addToolTip(description: "You are not authorized to add a number. Please contact your administrator.")
            } else {
                self.shouldHaveToolTip = false
                self.settingsButton?.removeToolTip()
                self.setAddRemoveMenu()
                menuItems.append(self.addRemoveMenu!)
                self.smsMenu = UIMenu(title: "Phone Numbers", children: menuItems)
                self.settingsButton?.menu = self.smsMenu
            }
        }
    }
}

extension DialerViewController {
    public func addSpinnerHUD(_ message:String) {
        DispatchQueue.main.async {
            if (self.spinnerHUD == nil) {
                self.spinnerHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
                self.spinnerHUD?.label.text = message
            }
        }
    }
    
    func removeSpinnerHUD() {
        DispatchQueue.main.async {
            if let hud = self.spinnerHUD {
                hud.removeFromSuperview()
                self.spinnerHUD = nil
            }
        }
    }
}
