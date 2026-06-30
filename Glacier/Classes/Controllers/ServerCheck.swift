//
//  ServerCheck.swift
//  ChatSecure
//
//  Created by Chris Ballinger on 2/15/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

import Foundation
import os

/// Privacy-safe diagnostic log for push registration (subsystem "com.glaciersec.push").
private let registerLog = Logger(subsystem: "com.glaciersec.push", category: "Envelope")

/**
 * The purpose of this class is to collect and process server
 * and push info in one place.
 *
 * All public members must be accessed from the main queue.
 */
public class ServerCheck: XMPPModule {
    
    @objc public let push: PushController
    @objc public let serverCapabilities: GlacierServerCapabilities
    @objc public let xmppCapabilities: XMPPCapabilities
    @objc public let pushModule: XMPPPushModule
    
    @objc public var result = ServerCheckResult()
    
    //@objc public static let UpdateNotificationName = Notification.Name(rawValue: "ServerCheckUpdateNotification")

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// pushModule should be activated elsewhere
    @objc public init(push: PushController,
                      pushModule: XMPPPushModule,
                      dispatchQueue: DispatchQueue? = nil) {
        self.push = push
        let capsStorage = XMPPCapabilitiesCoreDataStorage(inMemoryStore: ())!
        let capabilities = XMPPCapabilities(capabilitiesStorage: capsStorage, dispatchQueue: dispatchQueue)
        self.xmppCapabilities = capabilities
        self.serverCapabilities = GlacierServerCapabilities(capabilities: capabilities, dispatchQueue: dispatchQueue)

        self.pushModule = pushModule
        super.init(dispatchQueue: dispatchQueue)
        
        self.xmppCapabilities.autoFetchHashedCapabilities = true
        self.xmppCapabilities.autoFetchNonHashedCapabilities = true
        self.xmppCapabilities.autoFetchMyServerCapabilities = true
        
        serverCapabilities.addDelegate(self, delegateQueue: moduleQueue)
        pushModule.addDelegate(self, delegateQueue: moduleQueue)
        NotificationCenter.default.addObserver(self, selector: #selector(pushAccountChanged(_:)), name: Notification.Name(rawValue: GlacierPushAccountDeviceChanged), object: push)
        NotificationCenter.default.addObserver(self, selector: #selector(pushAccountChanged(_:)), name: Notification.Name(rawValue: GlacierPushAccountTokensChanged), object: push)
        fetch()
    }
    
    // MARK: XMPPModule overrides
    
    @discardableResult override public func activate(_ xmppStream: XMPPStream) -> Bool {
        guard super.activate(xmppStream),
            xmppCapabilities.activate(xmppStream),
            serverCapabilities.activate(xmppStream)
            else {
                return false
        }
        return true
    }
    
    public override func deactivate() {
        pushModule.removeDelegate(self)
        serverCapabilities.removeDelegate(self)
        
        serverCapabilities.deactivate()
        xmppCapabilities.deactivate()
        super.deactivate()
    }
    
    // MARK: Public API
    
    @objc public func getCombinedPushStatus() -> ServerCheckPushStatus {
        if let xmpp = xmppStream, xmpp.state != .STATE_XMPP_CONNECTED || !xmpp.isAuthenticated {
            return .unknown
        }
        return result.getCombinedPushStatus()
    }
    
    
    
    /// set pushInfoReady, capabilitiesReady, pushStatusUpdate to get result
    @objc public func fetch() {
        refreshPush()
        refreshCapabilities()
        checkReady()
    }
    
    /// Must be called from main queue
    @objc public func refresh() {
        serverCapabilities.fetchAllCapabilities()
        fetch()
    }
    
    // This will refresh the pushStatusUpdate block
    /*private func updatePushStatus() {
        guard let pubsubEndpoint = push.pubsubEndpoint else { return }
        if let jid = XMPPJID(user: nil, domain: pubsubEndpoint as String, resource: nil) {
            let status = pushModule.registrationStatus(forServerJID: jid)
            result.pushStatus = status
            //postUpdateNotification()
        }
    }*/
    
    @objc private func pushAccountChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.refresh()
        }
    }
    
    private func checkReady() {
        /*if let _ = result.capabilities {
            postUpdateNotification()
        }*/
        //updatePushStatus()
    }
    
    /*private func postUpdateNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: type(of: self).UpdateNotificationName, object: self)
        }
    }*/
    
    private func refreshPush() {
        //
    }
    
    private func refreshCapabilities() {
        let caps = ServerCapabilityInfo.allCapabilities()
        result.capabilities = serverCapabilities.markAvailable(capabilities: caps)
        checkReady()
    }
    
}

// MARK: - GlacierServerCapabilitiesDelegate

extension ServerCheck: GlacierServerCapabilitiesDelegate {
    
    @objc public func serverCapabilities(_ sender: GlacierServerCapabilities, didDiscoverCapabilities capabilities: [XMPPJID : XMLElement]) {
        refreshCapabilities()
    }
    
}

// MARK: - XMPPPushDelegate

extension ServerCheck: XMPPPushDelegate {
    
    public func pushModule(_ module: XMPPPushModule, didRegisterWithResponseIq responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        // Confirms whether the server ACCEPTED the enable IQ and whether our push-encrypt
        // fields were actually on the stanza that went out (kid + omemo rid for pruning).
        registerLog.info("register: enable ACCEPTED sentKid=\(ServerCheck.sentFormValue(outgoingIq, var: kGlacierPushEncryptKidField) ?? "(none)", privacy: .public) sentRid=\(ServerCheck.sentFormValue(outgoingIq, var: kGlacierPushOmemoRidField) ?? "(none)", privacy: .public)")
        if let enable = outgoingIq.element(forName: "enable", xmlns: XMPPPushXMLNS), let serverjid = enable.attributeStringValue(forName: "jid") {
            self.push.pubsubEndpoint = serverjid as NSString
        }
        checkReady()
    }

    public func pushModule(_ module: XMPPPushModule, failedToRegisterWithErrorIq errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        // If the server REJECTED the enable IQ, this is the likely reason the encrypt key
        // never registered (e.g. strict publish-options validation rejecting the extra fields).
        let errorElement = errorIq?.element(forName: "error")
        let type = errorElement?.attributeStringValue(forName: "type") ?? "(none)"
        let condition = errorElement?.children?.first?.name ?? "timeout"
        registerLog.error("register: enable REJECTED type=\(type, privacy: .public) condition=\(condition, privacy: .public) sentKid=\(ServerCheck.sentFormValue(outgoingIq, var: kGlacierPushEncryptKidField) ?? "(none)", privacy: .public) sentRid=\(ServerCheck.sentFormValue(outgoingIq, var: kGlacierPushOmemoRidField) ?? "(none)", privacy: .public)")
        checkReady()
    }

    /// Reads back a publish-options field value from an outgoing enable IQ, proving the field
    /// actually left the device. Returns nil if that var wasn't on the stanza.
    private static func sentFormValue(_ outgoingIq: XMPPIQ, var fieldVar: String) -> String? {
        guard let enable = outgoingIq.element(forName: "enable", xmlns: XMPPPushXMLNS),
              let form = enable.element(forName: "x", xmlns: "jabber:x:data") else {
            return nil
        }
        for field in form.elements(forName: "field") where field.attributeStringValue(forName: "var") == fieldVar {
            return field.element(forName: "value")?.stringValue
        }
        return nil
    }
    
    public func pushModule(_ module: XMPPPushModule, disabledPushForServerJID serverJID: XMPPJID, node: String?, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        checkReady()
    }
    
    public func pushModule(_ module: XMPPPushModule, failedToDisablePushWithErrorIq errorIq: XMPPIQ?, serverJID: XMPPJID, node: String?, outgoingIq: XMPPIQ) {
        checkReady()
    }
    
    public func pushModule(_ module: XMPPPushModule, readyWithCapabilities caps: XMLElement, jid: XMPPJID) {
        // This _should_ be handled elsewhere in GlacierServerCapabilities
        // Not sure why it's not working properly
        if let caps = result.capabilities {
            caps[.XEP0357]?.status = .Available
        }
        checkReady()
    }
}

@objc
public enum ServerCheckPushStatus: UInt {
    case unknown
    case broken
    case working
}

@objc(OTRServerCheckResult)
public class ServerCheckResult: NSObject {
    public var capabilities: [CapabilityCode : ServerCapabilityInfo]?
    public var pushStatus: XMPPPushStatus?
    
    /** This lets you collect all push info in one place */
    fileprivate func getCombinedPushStatus() -> ServerCheckPushStatus {
        var checkStatus: ServerCheckPushStatus = .unknown
        if let pushStatus = pushStatus, pushStatus != .registered {
            return .broken
        }
        if let pushCap = capabilities?[.XEP0357], pushCap.status != .Available {
            return .broken
        }
        guard let caps = capabilities, let status = pushStatus else {
            return .unknown
        }
        var xepExists = false
        if let pushCap = caps[.XEP0357], pushCap.status == .Available {
            xepExists = true
        }
        //let pushAcctWorks = push.pushMaybeWorks()
        let xmppWorks = status == .registered
        if xepExists && xmppWorks {
            checkStatus = .working
        } else {
            checkStatus = .broken
        }
        return checkStatus
    }
}

