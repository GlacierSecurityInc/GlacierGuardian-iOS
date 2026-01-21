//
//  UserProfileView.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 19/11/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import SwiftUI
import UIKit
import FormatterKit
import GRDB

/**
 It shows user profile details like avatar image (or display name initials), display name and settings like read receipt on/off, etc.
 */
struct UserProfileView: View {
    
    // MARK: - Private properties
    
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isReadReceiptsOn: Bool
    @State private var isCurrentUser: Bool
    @State private var currentDevice: ChatOmemoDevice?
    @State private var userDevices: [ChatOmemoDevice] = []
    @State private var groups: [String] = []
    
    @State private var shouldShowAlert: Bool = false
    @State private var alertTitle: String?
    @State private var alertMessage: String?
    @State private var alertConfirmationButtonTitle: String?
    @State private var alertConfirmationButtonAction: (() -> Void)?
    
    private let account: ChatAccountModel
    private let shouldShowReadReceiptsSetting: Bool
    private let canEditDetails: Bool
    private let onReadReceiptsSettingChanged: ((Bool) -> Void)?
    private let onViewWillDisappear: (() -> Void)?
    
    private var borderColor: Color {
        colorScheme == .dark ? Color.gray : Color(UIColor.darkGray)
    }
    
    private var userName: String? {
        guard let userId = account.username.splitToArray(separator: "@").first else { return nil }
        return "@\(userId)"
    }
    
    // MARK: - Initializer
    
    init(
        account: ChatAccountModel,
        shouldShowReadReceiptsSetting: Bool,
        canEditDetails: Bool = false,
        isReadReceiptsOn: Bool = true,
        onReadReceiptsSettingChanged: ((Bool) -> Void)? = nil,
        onViewWillDisappear: (() -> Void)? = nil
    ) {
        self.account = account
        self.shouldShowReadReceiptsSetting = shouldShowReadReceiptsSetting
        self.canEditDetails = canEditDetails
        self.onReadReceiptsSettingChanged = onReadReceiptsSettingChanged
        self.onViewWillDisappear = onViewWillDisappear
        self.isCurrentUser = false
        self._isReadReceiptsOn = State(initialValue: isReadReceiptsOn)
    }
    
    // MARK: - User interface
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .center, spacing: 0) {
                
                // Avatar (image or initials)
                ZStack {
                    Image(uiImage: account.avatarImage)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: 75, height: 75)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(borderColor, lineWidth: 1)
                )
                
                // Display name
                Text(account.displayName)
                    .font(.system(size: 20, weight: .medium))
                    .padding(.top, 12)
                
                // User name
                if let name = userName {
                    Text(name)
                        .font(.system(size: 18, weight: .regular))
                }
                
                
                // "Privacy" label
                if shouldShowReadReceiptsSetting {
                    Text("Privacy")
                        .font(.system(size: 18, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                    
                    // Privacy container with "Read receipts" + switch
                    VStack {
                        HStack(spacing: 16) {
                            Text("Read receipts")
                                .font(.system(size: 16, weight: .regular))
                            
                            Spacer()
                            
                            Toggle("", isOn: $isReadReceiptsOn)
                                .labelsHidden()
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 60)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(12)
                    .padding(.top, 12)
                }
                
                // Edit profile details
                
                if self.canEditDetails {
                    Button(
                        action: {
                            didTapOnResetPasswordButton()
                        },
                        label: {
                            Text("Reset Password")
                                .font(.system(size: 16, weight: .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 30)
                                .padding(.bottom, 12)
                        }
                    )
                    Button(
                        action: {
                            didTapOnResetSecureConnectionsButton()
                        },
                        label: {
                            Text("Reset Secure Sessions")
                                .font(.system(size: 16, weight: .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    )
                }
                
                // Teams
                if !groups.isEmpty {
                    Text(isCurrentUser ? "Teams" : "Shared Teams")
                        .font(.system(size: 18, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .center, spacing: 8) {
                                ForEach(groups, id: \.self) { group in
                                    Text(group)
                                        .font(.system(size: 16, weight: .regular))
                                        .padding(.all, 6)
                                        .background {
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(lineWidth: 1)
                                        }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .padding(.all, 16)
                    }
                }
                
                // Current session
                if isCurrentUser, let crntDevice = currentDevice {
                    Text("Current Session")
                        .font(.system(size: 18, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    UserDeviceDetailsView(device: crntDevice, title: "Fingerprint (message origin)", shouldShowSwitch: false, shouldShowLastSeenTime: true)
                }
                
                // User devices
                
                if !userDevices.isEmpty {
                    HStack(alignment: .center) {
                        Text(isCurrentUser ? "Other Devices" : "Devices")
                            .font(.system(size: 18, weight: .medium))
                            
                        if self.canEditDetails {
                            Spacer()
                            Button(
                                action: {
                                    didTapOnClearDevicesButton()
                                },
                                label: {
                                    Text("Clear Devices")
                                        .font(.system(size: 16, weight: .regular))
                                }
                            )
                        }
                    }
                    .padding(.top, 30)
                    .padding(.bottom, 12)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(userDevices, id: \.deviceId) { device in
                            UserDeviceDetailsView(device: device, title: "Fingerprint", shouldShowSwitch: true, shouldShowLastSeenTime: false)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
        }
        .background(
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
        )
        .onChange(of: isReadReceiptsOn) { newValue in
            guard shouldShowReadReceiptsSetting else { return }
            onReadReceiptsSettingChanged?(newValue)
        }
        .onAppear {
            if let currentAccount = ChatAccountModel.currentAccount {
                isCurrentUser = account.uniqueId == currentAccount.uniqueId
            }
            getUserDevices()
            getGroups()
        }
        .onDisappear {
            onViewWillDisappear?()
        }
        .alert(alertTitle ?? "", isPresented: $shouldShowAlert) {
            Button("Cancel", role: .cancel) {
                shouldShowAlert = false
            }
            
            Button(alertConfirmationButtonTitle ?? "Ok") {
                alertConfirmationButtonAction?()
            }
        } message: {
            Text(alertMessage ?? "")
        }
    }
    
    // MARK: - Private methods
    
    private func getGroups() {
        guard groups.isEmpty, let buddy = ChatBuddy.getBuddy(uniqueId: account.uniqueId), let sharedGroups = buddy.sharedGroups else { return }
        self.groups = sharedGroups
    }
    
    func getUserDevices() {
        guard let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account) else {
            return
        }
        
        self.groups = xmpp.getTeams()
        
        do {
            try DBManager.sharedDB().grdbStorage.write(block: { transaction in
                if let bundle = xmpp.omemoSignalCoordinator?.fetchMyBundle(transaction) {
                    let idNumber = NSNumber(value: bundle.deviceId)
                    
                    self.currentDevice = ChatOmemoDevice(
                        deviceId: idNumber,
                        trustLevel: .trustedUser,
                        parentKey: account.uniqueId,
                        parentCollection: ChatAccountModel.collection(),
                        publicIdentityKeyData: bundle.identityKey,
                        lastSeenDate: xmpp.getLastConnected()
                    )
                    
                    var devices: [ChatOmemoDevice] = []
                    if isCurrentUser {
                        devices = ChatOmemoDevice.allOMEMODevices(
                            for: account.uniqueId,
                            collection: ChatAccountModel.collection(),
                            transaction: transaction
                        )
                    } else {
                        devices = ChatOmemoDevice.allOMEMODevices(for: account.uniqueId)
                    }
                    
                    let filteredDevices = devices.filter { $0.publicIdentityKeyData != nil }
                    let sortedDevices = filteredDevices.sorted(by: { $0.lastSeenDate < $1.lastSeenDate })
                    self.userDevices = sortedDevices
                }
            })
        } catch {
            DDLogError("getFingerprintData error \(error)")
        }
    }
    
    private func didTapOnResetPasswordButton() {
        guard let url = URL(string: "https://console.glacier.chat/forget-password/"),
              UIApplication.shared.canOpenURL(url) else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    
    private func didTapOnResetSecureConnectionsButton() {
        alertTitle = "Reset Secure Sessions"
        alertMessage = "This may help if you are having problems with message delivery. All your messages will be kept."
        alertConfirmationButtonTitle = "Reset"
        alertConfirmationButtonAction = {
            resetSecureConnections()
        }
        shouldShowAlert = true
    }
    
    private func resetSecureConnections() {
        guard let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account),
              let omemoCoord = xmpp.omemoSignalCoordinator else {
            return
        }
        var allDevicesToClear: [ChatOmemoDevice] = []
        
        let buddies = ChatBuddyModel.getAllBuddies(for: account.uniqueId)
        for buddy in buddies {
            let devices = ChatOmemoDevice.allOMEMODevices(for: buddy.uniqueId)
            allDevicesToClear.append(contentsOf: devices)
        }
        
        if let curDevice = currentDevice {
            allDevicesToClear.append(curDevice)
        }
        
        var mutableDevices:[NSNumber] = []
        if let bareJid = account.bareJID {
            let devices = omemoCoord.fetchDeviceIds(for: bareJid)
            mutableDevices = devices
            
            if let curId = self.currentDevice?.deviceId {
                let removeId = NSNumber(value:curId)
                let indexSet = devices.enumerated().lazy
                    .filter {
                        removeId == $0.element
                    }.map{$0.offset}
                
                let iset = IndexSet(indexSet)
                mutableDevices.remove(atOffsets: iset)
            }
        }
        
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try ChatAccountSignalIdentity
                    .filter(Column("accountKey") == account.uniqueId)
                    .deleteAll(transaction.database)
                try ChatSignedPreKey
                    .filter(Column("accountKey") == account.uniqueId)
                    .deleteAll(transaction.database)
            } catch {
                DDLogError("ChatProfileView error removing old secure keys: \(error)")
            }
        }, completion: {
            if let bundle = omemoCoord.fetchMyBundle() {
                omemoCoord.omemoModule?.publishBundle(bundle, elementId: nil)
                mutableDevices.append(NSNumber(value: bundle.deviceId))
                let copyDevices = mutableDevices
                omemoCoord.omemoModule?.publishDeviceIds(copyDevices, elementId: nil)
                omemoCoord.removeDevice(allDevicesToClear, localOnly: true, completion: { (success) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.userDevices.removeAll()
                        self.getUserDevices()
                    }
                })
            }
        })
    }
    
    private func didTapOnClearDevicesButton() {
        alertTitle = "Clear Devices"
        alertMessage = "Are you sure you want to clear all your other devices? If you have other devices with the same account, the next time they connect they will reannounce themselves, but they might not receive messages sent in the meantime."
        alertConfirmationButtonTitle = "Clear"
        alertConfirmationButtonAction = {
            clearDevices()
        }
        shouldShowAlert = true
    }
    
    private func clearDevices() {
        guard let currentDevice = self.currentDevice else { return }
        
        let devicenums = [NSNumber(value: currentDevice.deviceId)]
        let xmpp = OTRProtocolManager.shared.xmppManager(forChatAccount: account)
        xmpp?.omemoSignalCoordinator?.omemoModule?.publishDeviceIds(devicenums, elementId: nil)
        
        let devices:[ChatOmemoDevice] = ChatOmemoDevice.allOMEMODevices(for: account.uniqueId, collection: ChatAccountModel.collection())
        guard !devices.isEmpty else { return }
        let allDevices:[ChatOmemoDevice] = devices.filter{ $0.deviceId != currentDevice.deviceId }
        
        guard !allDevices.isEmpty else { return }
        xmpp?.omemoSignalCoordinator?.removeDevice(allDevices, localOnly: true, completion: {_ in
            self.userDevices.removeAll()
        })
    }
}

// MARK: - Objective-C compatible wrapper
@objcMembers
public class UserProfileHostingController: UIViewController {
    
    @objc public static func createHostingController(withAccount account: ChatAccountModel,
                                                     shouldShowReadReceiptsSetting: Bool = true,
                                                     canEditDetails: Bool = false,
                                                     isReadReceiptsOn: Bool = true,
                                                     onReadReceiptsSettingChanged: ((Bool) -> Void)? = nil,
                                                     onViewWillDisappear: (() -> Void)? = nil) -> UIViewController {
        
        let userProfileView = UserProfileView(
            account: account,
            shouldShowReadReceiptsSetting: shouldShowReadReceiptsSetting,
            canEditDetails: canEditDetails,
            isReadReceiptsOn: isReadReceiptsOn,
            onReadReceiptsSettingChanged: onReadReceiptsSettingChanged
        )
        
        let hostingController = UIHostingController(rootView: userProfileView)
        hostingController.modalPresentationStyle = .formSheet
        return hostingController
    }
}

/**
 Shows user device details with action buttons
 */
struct UserDeviceDetailsView: View {
    
    // MARK: - Public properties
    
    var device: ChatOmemoDevice
    var title: String
    var shouldShowSwitch: Bool = true
    var shouldShowLastSeenTime: Bool = false
    
    // MARK: - Private properties
    
    @State private var isTrusted: Bool = true
    
    private var lastSeenTimeStamp: String? {
        let interval = -Date().timeIntervalSince(device.lastSeenDate)
        let intervalFormatter = TTTTimeIntervalFormatter()
        guard let since = intervalFormatter.string(forTimeInterval: interval) else { return nil }
        return "Session established: " + since
    }
    
    // MARK: - User interface
    
    var body: some View {
        ZStack {
            
            
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.humanReadableFingerprint)
                        .font(.system(size: 16, weight: .regular))
                        .padding(.bottom, 5)
                    
                    Text(title)
                        .font(.system(size: 14, weight: .regular))
                    
                    if shouldShowLastSeenTime, let timeStampt = lastSeenTimeStamp {
                        Text(timeStampt)
                            .font(.system(size: 14, weight: .regular))
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                
                Spacer()
                
                if shouldShowSwitch {
                    Toggle("", isOn: $isTrusted)
                        .labelsHidden()
                        .padding(.trailing, 16)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            self.isTrusted = device.isTrusted()
        }
        .onChange(of: isTrusted) { trusted in
            guard var userDevice = ChatOmemoDevice.omemoDevice(for: device.uniqueId) else { return }
            if trusted {
                userDevice.trustLevel = OMEMOTrustLevel.trustedUser.rawValue
                if userDevice.isExpired() {
                    userDevice.lastSeenDate = Date()
                }
            } else {
                userDevice.trustLevel = OMEMOTrustLevel.untrusted.rawValue
            }
            userDevice.save()
        }
    }
}
