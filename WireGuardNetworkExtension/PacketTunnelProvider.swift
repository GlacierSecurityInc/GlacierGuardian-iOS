//
//  PacketTunnelProvider.swift
//  WireGuardNetworkExtension
//
//  Created by andyfriedman on 8/26/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import NetworkExtension
import WireGuardKit
import os

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { logLevel, message in
            //wg_log(logLevel.osLogLevel, message: message)
        }
    }()
    
    static let log = Logger(subsystem: "com.glacier.Messenger", category: "packet-tunnel")

    override init() {
        self.log = Self.log
        log.log(level: .debug, "First light")
        super.init()
    }
        
    let log: Logger

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let activationAttemptId = options?["activationAttemptId"] as? String
        let errorNotifier = ErrorNotifier(activationAttemptId: activationAttemptId)

        //Logger.configureGlobal(tagged: "NET", withFilePath: FileManager.logFileURL?.path

        guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol,
              let tunnelConfiguration = tunnelProviderProtocol.asTunnelConfiguration() else {
            errorNotifier.notify(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
            return
        }

        // Start the tunnel
        adapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
            guard let adapterError = adapterError else {
                let interfaceName = self.adapter.interfaceName ?? "unknown"

                self.log.log(level: .info, "Tunnel interface is \(interfaceName)")

                completionHandler(nil)
                return
            }

            switch adapterError {
            case .cannotLocateTunnelFileDescriptor:
                //wg_log(.error, staticMessage: "Starting tunnel failed: could not determine file descriptor")
                errorNotifier.notify(PacketTunnelProviderError.couldNotDetermineFileDescriptor)
                completionHandler(PacketTunnelProviderError.couldNotDetermineFileDescriptor)

            case .dnsResolution(let dnsErrors):
                let hostnamesWithDnsResolutionFailure = dnsErrors.map { $0.address }
                    .joined(separator: ", ")
                //wg_log(.error, message: "DNS resolution failed for the following hostnames: \(hostnamesWithDnsResolutionFailure)")
                errorNotifier.notify(PacketTunnelProviderError.dnsResolutionFailure)
                completionHandler(PacketTunnelProviderError.dnsResolutionFailure)

            case .setNetworkSettings(let error):
                self.log.log(level: .error, "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotSetNetworkSettings)
                completionHandler(PacketTunnelProviderError.couldNotSetNetworkSettings)

            case .startWireGuardBackend(let errorCode):
                self.log.log(level: .error, "Starting tunnel failed with wgTurnOn returning \(errorCode)")
                errorNotifier.notify(PacketTunnelProviderError.couldNotStartBackend)
                completionHandler(PacketTunnelProviderError.couldNotStartBackend)

            case .invalidState:
                // Must never happen
                fatalError()
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Add code here to start the process of stopping the tunnel.
        log.log(level: .info, "Stopping tunnel")

        adapter.stop { error in
            ErrorNotifier.removeLastErrorFile()

            if let error = error {
                self.log.log(level: .error, "Failed to stop WireGuard adapter: \(error.localizedDescription)")
            }
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Add code here to handle the message.
        guard let completionHandler = completionHandler else { return }

        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { settings in
                var data: Data?
                if let settings = settings {
                    data = settings.data(using: .utf8)!
                }
                completionHandler(data)
            }
        } else {
            completionHandler(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }
}

extension WireGuardLogLevel {
    var osLogLevel: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .error:
            return .error
        }
    }
}
