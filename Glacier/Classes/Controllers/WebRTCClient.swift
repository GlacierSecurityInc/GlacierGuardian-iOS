//  WebRTC
//  Created by Stasel on 20/05/2018.
//  Copyright © 2018 Stasel. All rights reserved.
//  Copyright © 2025 Glacier. All rights reserved.

import WebRTC

@objc
protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data)
    func webRTCClient(_ client: WebRTCClient, didAddVideo video: Bool)
}

@objc
final class WebRTCClient: NSObject {
    
    // The `RTCPeerConnectionFactory` is in charge of creating new RTCPeerConnection instances.
    // A new RTCPeerConnection should be created every new call, but the factory is shared.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    
    @objc var delegate: WebRTCClientDelegate?
    @objc public let peerConnection: RTCPeerConnection
    private let rtcAudioSession =  RTCAudioSession.sharedInstance()
    private let audioQueue = DispatchQueue(label: "audio")
    private let cameraQueue = DispatchQueue(label: "com.glacier.webrtc.camera")
    private let streamId = "-"
    private var mediaConstraints: [String:String] = [:]
    private var isUsingFrontCamera = true
    private var isSwitchingCamera = false
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localDataChannel: RTCDataChannel?
    private var remoteDataChannel: RTCDataChannel?
    private var originalSDP: RTCSessionDescription?
    private var isSpeakerRoute = false

    @available(*, unavailable)
    override init() {
        fatalError("WebRTCClient:init is unavailable")
    }
    
    
    @objc
    static func createPeerConnection(iceServers: [RTCIceServer], forceRelay: Bool) -> RTCPeerConnection? {
        let config = RTCConfiguration()
        if forceRelay {
            config.iceTransportPolicy = .relay
        } else {
            config.iceTransportPolicy = .all
        }
        config.iceServers = iceServers
        
        // Unified plan is more superior than planB
        config.sdpSemantics = .unifiedPlan
        
        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
        config.continualGatheringPolicy = .gatherContinually
        
        config.rtcpMuxPolicy = .negotiate
        
        //aggressive pings to detect wifi - mobile handoffs better
        //Increase timeout to allow more time before an ICE connection is
        //considered lost. The interval for pinging backup candidate pairs is
        //also increased to match the new timeout.
        config.iceConnectionReceivingTimeout = 1000 //0
        config.iceBackupCandidatePairPingInterval = 2000 //0
        
        config.audioJitterBufferMaxPackets = 100;
        
        // Define media constraints. DtlsSrtpKeyAgreement is required to be true to be able to connect with web browsers.
        let constraints = RTCMediaConstraints(mandatoryConstraints: [
            "DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue
        ], optionalConstraints: [
            "echoCancellation": kRTCMediaConstraintsValueTrue,
            "noiseSuppression": kRTCMediaConstraintsValueTrue,
            "voiceActivityDetection": kRTCMediaConstraintsValueTrue
        ])
        
        return WebRTCClient.factory.peerConnection(with: config, constraints: constraints, delegate: nil)
    }
    
    @objc
    required init(iceServers: [RTCIceServer], audioOnly: Bool, forceRelay: Bool) {
        RTCSetMinDebugLogLevel(.verbose)
        
        var peerConnection = WebRTCClient.createPeerConnection(iceServers: iceServers, forceRelay: forceRelay)
        if peerConnection == nil {
            // try again with empty ice server list
            DDLogError("Broken ice server list, retrying without any ice servers: \(String(describing:iceServers))")
            peerConnection = WebRTCClient.createPeerConnection(iceServers: [], forceRelay: forceRelay)
            guard peerConnection != nil else {
                fatalError("Could not create new RTCPeerConnection")
            }
        }
        
        self.peerConnection = peerConnection!
        super.init()
        
        self.createMediaSenders(audioOnly: audioOnly)
        self.peerConnection.delegate = self
        
        if audioOnly {
            self.mediaConstraints = [
                "OfferToReceiveAudio": kRTCMediaConstraintsValueTrue,
                "OfferToReceiveVideo": kRTCMediaConstraintsValueFalse,
            ]
        } else {
            self.mediaConstraints = [
                "OfferToReceiveAudio": kRTCMediaConstraintsValueTrue,
                "OfferToReceiveVideo": kRTCMediaConstraintsValueTrue,
            ]
        }
    }
    
    // MARK: Signaling
    @objc
    func offer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstraints,
                                             optionalConstraints: nil)
        self.peerConnection.offer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }

            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                completion(sdp)
            })
        }
    }
    
    @objc
    func answer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void)  {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstraints,
                                             optionalConstraints: nil)
        self.peerConnection.answer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }

            self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                completion(sdp)
            })
        }
    }
    
    @objc
    func answerUpgrade(forcePassive: Bool, completion: @escaping (_ sdp: RTCSessionDescription) -> Void)  {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstraints,
                                             optionalConstraints: nil)
        self.peerConnection.answer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                return
            }
            
            var newSDP = sdp
            if forcePassive {
                let modifiedSDP = self.forceSetupPassive(in: sdp.sdp)
                newSDP = RTCSessionDescription(type: .answer, sdp: modifiedSDP)
            }
            
            self.peerConnection.setLocalDescription(newSDP, completionHandler: { (error) in
                completion(newSDP)
            })
        }
    }
    
    func forceSetupPassive(in sdp: String) -> String {
        return sdp.replacingOccurrences(of: "a=setup:active", with: "a=setup:passive")
    }
    
    @objc
    func upgradeToVideoOffer(isCaller: Bool, completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        self.originalSDP = self.peerConnection.localDescription
        self.mediaConstraints = ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"]
        return self.offer(completion: completion)
    }
    
    @objc
    func upgradeToVideoAnswer(isCaller: Bool, completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        self.mediaConstraints = ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"]
        return self.answerUpgrade(forcePassive: isCaller, completion: completion)
    }
    
    func removeVideoOffer() {
        guard let sdp = self.originalSDP else {
            return
        }
        self.mediaConstraints = ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"]
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstraints,
                                             optionalConstraints: nil)
        self.peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
            self.stopCaptureLocalVideo()
            self.removeVideo()
        })
    }
    
    func terminateSession() {
        if self.rtcAudioSession.isActive {
            self.stopCaptureLocalVideo()
            self.peerConnection.close()
            self.localVideoTrack = nil
            self.videoCapturer = nil
            
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setActive(false)
            } catch {}
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    @objc
    func setRemoteSdp(_ remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> ()) {
        self.peerConnection.setRemoteDescription(remoteSdp, completionHandler: completion)
    }
    
    @objc
    func setRemoteCandidate(_ remoteCandidate : RTCIceCandidate, completion: @escaping (Error?) -> ()) {
        self.peerConnection.add(remoteCandidate, completionHandler: completion)
    }
    
    // MARK: Media
    @objc
    func startCaptureLocalVideo(renderer: RTCVideoRenderer, andCameraPosition position: AVCaptureDevice.Position) {
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else {
                return
            }
            
            guard
                let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
                let format = findSafeFormat(for: device),
                let fps = format.videoSupportedFrameRateRanges
                        .max(by: { $0.maxFrameRate < $1.maxFrameRate })
            else {
                print("❌ No safe format or FPS available for device \(position)")
                return
            }

            capturer.startCapture(with: device,
                                  format: format,
                                  fps: Int(fps.maxFrameRate))

            self.localVideoTrack?.add(renderer)
        }
    }

    @objc
    func stopCaptureLocalVideo() {
        let capturer = self.videoCapturer as? RTCCameraVideoCapturer
        cameraQueue.async {
            capturer?.stopCapture()
        }
    }

    func switchCamera() {
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else { return }

            if self.isSwitchingCamera {
                return
            }
            self.isSwitchingCamera = true

            self.isUsingFrontCamera.toggle()
            guard let newDevice = self.getCameraDevice(usingFront: self.isUsingFrontCamera),
                  let format = findSafeFormat(for: newDevice),
                  let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate else {
                DDLogWarn("Could not find valid camera device or format.")
                self.isSwitchingCamera = false
                return
            }

            capturer.stopCapture(completionHandler: { [weak self] in
                guard let self = self else { return }
                capturer.startCapture(with: newDevice, format: format, fps: Int(fps))
                DDLogDebug("Switched camera to \(self.isUsingFrontCamera ? "front" : "back")")
                self.isSwitchingCamera = false
            })
        }
    }
    
    func findSafeFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let safePixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA
        ]

        // Filter only formats WebRTC can safely consume
        let safeFormats = device.formats.filter { format in
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let hasSafePixelFormat = safePixelFormats.contains(subtype)

            let hasReasonableFps = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= 30
            }

            return hasSafePixelFormat && hasReasonableFps
        }

        guard !safeFormats.isEmpty else { return nil }

        // Choose highest resolution among safe formats
        let bestFormat = safeFormats.max { f1, f2 in
            let w1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription).width
            let w2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription).width
            return w1 < w2
        }

        return bestFormat
    }
    
    private func getCameraDevice(usingFront: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = usingFront ? .front : .back
        return RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
    }
    
    @objc
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        self.remoteVideoTrack?.add(renderer)
    }
    
    @objc
    func addVideo() {
        guard let device = selectCamera(usingFrontCamera: true),
              let format = RTCCameraVideoCapturer.supportedFormats(for: device).first,
              let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate else {
            DDLogWarn("❌ Could not find a valid capture device")
            return
        }
        
        let videoTrack = self.createVideoTrack()
        self.localVideoTrack = videoTrack
        self.peerConnection.add(videoTrack, streamIds: [self.streamId])
    }
    
    @objc
    func removeVideo() {
        let videoSender = self.peerConnection.transceivers.first {
            $0.mediaType == .video
        }?.sender
        if let sender = videoSender {
            self.peerConnection.removeTrack(sender)
        }
    }
    
    private func selectCamera(usingFrontCamera: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        return RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
    }
    
    @objc
    func configureAudioSession() {
        DDLogInfo("***** Configuring shared rtcAudioSession...")
        self.rtcAudioSession.lockForConfiguration()
        self.rtcAudioSession.isAudioEnabled = false
        do {
            try self.rtcAudioSession.setPreferredSampleRate(24000)
            try self.rtcAudioSession.setPreferredIOBufferDuration(0.2)
            try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord)
            try self.rtcAudioSession.setMode(AVAudioSession.Mode.voiceChat)
        } catch let error {
            DDLogDebug("Error changeing AVAudioSession category: \(error)")
        }
        self.rtcAudioSession.useManualAudio = true
        self.rtcAudioSession.unlockForConfiguration()
    }
    
    private func createMediaSenders(audioOnly: Bool) {
        //Audio
        let audioTrack = self.createAudioTrack()
        self.peerConnection.add(audioTrack, streamIds: [self.streamId])
        
        //Video
        if !audioOnly {
            self.addVideo()
        }
        
        //we don't use any data channels for A/V calls
//         // Data
    }
    
    private func createAudioTrack() -> RTCAudioTrack {
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = WebRTCClient.factory.audioSource(with: audioConstrains)
        let audioTrack = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "audio-"+UUID().uuidString)
        return audioTrack
    }
    
    private func createVideoTrack() -> RTCVideoTrack {
        let videoSource = WebRTCClient.factory.videoSource()
        
        self.videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        
        let aClass: AnyClass! = object_getClass(self.videoCapturer!)
        let bClass: AnyClass! = object_getClass(self)
        if self.videoCapturer!.responds(to: NSSelectorFromString("updateOrientation")) {
            DDLogWarn("Swizzling method 'updateOrientation' of video capturer...")
            let swizzledMethod = class_getInstanceMethod(aClass, NSSelectorFromString("updateOrientation"))
            let replacementMethod = class_getInstanceMethod(bClass, NSSelectorFromString("dummyUpdateOrientation"))
            let replacementImplementation = method_getImplementation(replacementMethod!)
            method_setImplementation(swizzledMethod!, replacementImplementation)
        }
        
        let videoTrack = WebRTCClient.factory.videoTrack(with: videoSource, trackId: "video-"+UUID().uuidString)
        return videoTrack
    }
    
    @objc
    func dummyUpdateOrientation() {
        DDLogDebug("Ignoring device orientation change in webrtc...")
    }
    
    // MARK: Data Channels
    private func createDataChannel() -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        guard let dataChannel = self.peerConnection.dataChannel(forLabel: "WebRTCData", configuration: config) else {
            DDLogDebug("Warning: Couldn't create data channel.")
            return nil
        }
        return dataChannel
    }
    
    @objc
    func sendData(_ data: Data) {
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        self.remoteDataChannel?.sendData(buffer)
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        DDLogDebug("peerConnection new signaling state: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DDLogDebug("peerConnection did add stream")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        DDLogDebug("peerConnection did remove stream")
    }
    
    /** Called when a receiver and its track are created. */
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack {
            DDLogDebug("peerConnection did add video RtpReceiver")
            self.remoteVideoTrack = track
            self.delegate?.webRTCClient(self, didAddVideo: true)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        DDLogDebug("peerConnection did remove RtpReceiver")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        DDLogDebug("peerConnection should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DDLogDebug("peerConnection new connection state: \(newState.rawValue)")
        self.delegate?.webRTCClient(self, didChangeConnectionState: newState)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DDLogDebug("peerConnection new gathering state: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        self.delegate?.webRTCClient(self, didDiscoverLocalCandidate: candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        DDLogDebug("peerConnection did remove candidate(s)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DDLogDebug("peerConnection did open data channel")
        self.remoteDataChannel = dataChannel
    }
}
extension WebRTCClient {
    private func setTrackEnabled<T: RTCMediaStreamTrack>(_ type: T.Type, isEnabled: Bool) {
        peerConnection.transceivers
            .compactMap { return $0.sender.track as? T }
            .forEach {
                $0.isEnabled = isEnabled
            }
    }
}

// MARK: - Video control
extension WebRTCClient {
    @objc
    func hideVideo() {
        self.audioQueue.async { [weak self] in
            self?.setVideoEnabled(false)
        }
    }
    @objc
    func showVideo() {
        self.audioQueue.async { [weak self] in
            self?.setVideoEnabled(true)
        }
    }
    
    @objc
    func videoIsEnabled() -> Bool {
        return self.localVideoTrack?.isEnabled ?? false
    }
    
    private func setVideoEnabled(_ isEnabled: Bool) {
        setTrackEnabled(RTCVideoTrack.self, isEnabled: isEnabled)
    }
}

// MARK:- Audio control
extension WebRTCClient {
    @objc
    func muteAudio() {
        self.setAudioEnabled(false)
    }
    
    @objc
    func unmuteAudio() {
        self.setAudioEnabled(true)
    }
    
    @objc
    func isAudioEnabled() -> Bool {
        var isEnabled = true
        if let sender = self.peerConnection.senders.first(where: { $0.track is RTCAudioTrack }) {
            isEnabled = sender.track?.isEnabled ?? true
        }
        return isEnabled
    }
    
    // Fallback to the default playing device: headphones/bluetooth/ear speaker
    @objc
    func turnSpeakerOff() {
        self.isSpeakerRoute = false
        self.audioQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
                try self.rtcAudioSession.overrideOutputAudioPort(.none)
            } catch let error {
                DDLogDebug("Error setting AVAudioSession category: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    // Force speaker
    @objc
    func turnSpeakerOn() {
        self.isSpeakerRoute = true
        self.audioQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setPreferredSampleRate(24000)
                try self.rtcAudioSession.setPreferredIOBufferDuration(0.2)
                try self.rtcAudioSession.setCategory(AVAudioSession.Category.playAndRecord)
                try self.rtcAudioSession.overrideOutputAudioPort(.speaker)
            } catch let error {
                DDLogDebug("Couldn't force audio to speaker: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    func getSpeakerOn() -> Bool {
        return self.isSpeakerRoute
    }
    
    private func setAudioEnabled(_ isEnabled: Bool) {
        self.audioQueue.async { [weak self] in
            if let sender = self?.peerConnection.senders.first(where: { $0.track is RTCAudioTrack }) {
                sender.track?.isEnabled = isEnabled // mutes the mic
            }
        }
    }
}


extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DDLogDebug("dataChannel did change state: \(dataChannel.readyState)")
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        self.delegate?.webRTCClient(self, didReceiveData: buffer.data)
    }
}
