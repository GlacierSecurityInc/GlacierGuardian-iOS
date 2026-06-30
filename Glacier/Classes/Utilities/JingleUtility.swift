//
//  JingleUtility.swift
//  Glacier
//
//  Created by andyfriedman on 4/11/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
import XMPPFramework

struct MediaDescription {
    var contentName: String
    var mediaType: String
    var port: String
    var payloadTypes: [String]
    var rtpMap: [String: PayloadType] = [:]
    var extMap: [String] = []
    var fmtp: [String: [String: String]] = [:]
    var rtcpFb: [String: [String]] = [:]
    var iceUfrag: String?
    var icePwd: String?
    var rtcpmux: Bool = false
    var trickle: Bool = false
    var renomination: Bool = false
    var iceOptions: String?
    var fingerprint: String?
    var setup: String?
    var msid: String?
    var ssrcs: [(String, [String: String])] = []
    var ssrcGroups: [(String, [String])] = []
    var bandwidth: String?
    var groupBundle:Bool = false
    var extmapAllowMixed:Bool = false
}

public enum JingleType : UInt {
    case sessioninitiate = 0
    case sessionanswer = 1
    case contentadd = 2
    case contentaccept = 3
    case contentreject = 4
}

class JingleUtility {
    public static let JINGLE = "urn:xmpp:jingle:1"
    public static let JINGLE_RTP_SOURCE_SPECIFIC_MEDIA_ATTRIBUTES =
    "urn:xmpp:jingle:apps:rtp:ssma:0"
    public static let DLTS_SRTP_VERIFICATION = "http://gultsch.de/xmpp/drafts/omemo/dlts-srtp-verification"
    public static let GLACIER_OMEMO = "com.glaciersecurity.glaciermessenger.axolotl"
    public static let JINGLE_APPS_GROUPING = "urn:xmpp:jingle:apps:grouping:0"
    public static let JINGLE_TRANSPORT_ICE_OPTION =
                "http://gultsch.de/xmpp/drafts/jingle/transports/ice-udp/option"
    
    static func parseSDP(_ sdp: String) -> [MediaDescription] {
        let lines = sdp.split(separator: "\r\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var mediaDescriptions: [MediaDescription] = []
        var currentMedia: MediaDescription?
        
        var groupBundle = false
        var groupNames: [String] = []
        var extmapAllowMixed = false
        
        for line in lines {
            if line.starts(with: "a=group:BUNDLE") {
                //print("***** parseSDP \(line)")
                groupBundle = true
                groupNames = line.split(separator: " ").dropFirst(1).map { String($0) }
            } else if line.starts(with: "a=extmap-allow-mixed") {
                extmapAllowMixed = true
            } else if line.starts(with: "m=") {
                let parts = line.split(separator: " ")
                let type = String(parts[0].dropFirst(2))
                let port = String(parts[1])
                let payloads = parts.dropFirst(3).map { String($0) }
                var contentName = type
                if let media = currentMedia {
                    mediaDescriptions.append(media)
                }
                if groupNames.count > mediaDescriptions.count {
                    contentName = String(mediaDescriptions.count)
                }
                currentMedia = MediaDescription(contentName: contentName, mediaType: type, port: port, payloadTypes: payloads)
                currentMedia?.groupBundle = groupBundle
                currentMedia?.extmapAllowMixed = extmapAllowMixed
            } else if currentMedia != nil {
                if line.starts(with: "a=rtpmap:") {
                    if let rtpmap = parseRtpmap(line) {
                        currentMedia?.rtpMap[rtpmap.id] = rtpmap
                    }
                } else if line.starts(with: "a=extmap:") {
                    let extmap = String(line.dropFirst(9))
                    currentMedia?.extMap.append(extmap)
                } else if line.starts(with: "a=fmtp:") {
                    if let fmtp = parseFmtp(line) {
                        currentMedia?.fmtp[fmtp.id] = fmtp.parameters
                    }
                } else if line.starts(with: "a=rtcp-fb:") {
                    let rest = line.dropFirst(10).split(separator: " ", maxSplits: 2)
                    if rest.count >= 2 {
                        let pt = String(rest[0])
                        let fb = rest[1...].joined(separator: " ")
                        currentMedia?.rtcpFb[pt, default: []].append(fb)
                    }
                } else if line.starts(with: "a=rtcp-mux") {
                    currentMedia?.rtcpmux = true
                } else if line.starts(with: "a=rtcp-mux") {
                    currentMedia?.rtcpmux = true
                } else if line.starts(with: "a=ice-ufrag:") {
                    currentMedia?.iceUfrag = String(line.dropFirst(12))
                } else if line.starts(with: "a=ice-pwd:") {
                    currentMedia?.icePwd = String(line.dropFirst(10))
                } else if line.starts(with: "a=ice-options:") {
                    if line.contains("trickle") {
                        currentMedia?.trickle = true
                    }
                    if line.contains("renomination") {
                        currentMedia?.renomination = true
                    }
                } else if line.starts(with: "a=fingerprint:sha-256") {
                    currentMedia?.fingerprint = line.components(separatedBy: " ")[1]
                } else if line.starts(with: "a=setup:") {
                    currentMedia?.setup = String(line.dropFirst(8))
                } else if line.starts(with: "a=ssrc:") {
                    let ssrcLine = line.dropFirst(7)
                    let parts = ssrcLine.split(separator: " ", maxSplits: 1)
                    if parts.count == 2 {
                        let ssrcId = String(parts[0])
                        let attrParts = parts[1].split(separator: ":", maxSplits: 1)
                        if attrParts.count == 2 {
                            let key = String(attrParts[0])
                            let value = String(attrParts[1])
                            if let index = currentMedia?.ssrcs.firstIndex(where: { $0.0 == ssrcId }) {
                                currentMedia?.ssrcs[index].1[key] = value
                            } else {
                                currentMedia?.ssrcs.append((ssrcId, [key: value]))
                            }
                        }
                    }
                } else if line.starts(with: "a=msid:") {
                    currentMedia?.msid = String(line.dropFirst(7))
                } else if line.starts(with: "a=ssrc-group:") {
                    let parts = line.dropFirst(13).split(separator: " ")
                    guard parts.count >= 2 else { continue }
                    let semantics = String(parts[0])
                    let ssrcs = parts.dropFirst().map { String($0) }
                    currentMedia?.ssrcGroups.append((semantics, ssrcs))
                } else if line.starts(with: "b=AS:") {
                    currentMedia?.bandwidth = String(line.dropFirst(5))
                } //else if line.starts(with: "a=group:BUNDLE") {
                    //print("***** parseSDP \(line)")
                    //groupBundle = true
                //}
            }
        }
        
        if let media = currentMedia {
            mediaDescriptions.append(media)
        }
        
        return mediaDescriptions
    }
    
    /*
    session-accept will include a responder jid
     */
    static func generateContentReject(initiator: String, sessionID: String) -> XMLElement {
        let jingleElement = XMLElement(name: "jingle", xmlns: JingleUtility.JINGLE)
        jingleElement.addAttribute(withName: "action", stringValue: "content-reject")
        //jingleElement.addAttribute(withName: "initiator", stringValue: initiator)
        jingleElement.addAttribute(withName: "sid", stringValue: sessionID)
        
        let transportElement = XMLElement(name: "transport", xmlns: CallManager.JINGLE_TRANSPORT_ICE_UDP)
        let contentElement = XMLElement(name: "content")
        contentElement.addAttribute(withName: "creator", stringValue: "initiator")
        contentElement.addAttribute(withName: "name", stringValue: "video")
        contentElement.addChild(transportElement)
        jingleElement.addChild(contentElement)
    
        return jingleElement
    }
    
    /*
    session-accept will include a responder jid
     */
    static func generateJingle(from sdp: String, jingleType:JingleType, initiator: String, responder: String?, sessionID: String, encryptedAudioElement: XMLElement, encryptedVideoElement: XMLElement?) -> XMLElement {
        
        let jingleElement = XMLElement(name: "jingle", xmlns: JingleUtility.JINGLE)
        
        switch jingleType {
        case .sessioninitiate:
            jingleElement.addAttribute(withName: "action", stringValue: "session-initiate")
            //jingleElement.addAttribute(withName: "initiator", stringValue: initiator)
        case .sessionanswer:
            jingleElement.addAttribute(withName: "action", stringValue: "session-accept")
            /*jingleElement.addAttribute(withName: "initiator", stringValue: initiator)
            if let responder = responder {
                jingleElement.addAttribute(withName: "responder", stringValue: responder)
            }*/
        case .contentadd:
            jingleElement.addAttribute(withName: "action", stringValue: "content-add")
        case .contentaccept:
            jingleElement.addAttribute(withName: "action", stringValue: "content-accept")
        case .contentreject:
            jingleElement.addAttribute(withName: "action", stringValue: "content-reject")
        }
        
        jingleElement.addAttribute(withName: "sid", stringValue: sessionID)
        
        let mediaDescriptions = parseSDP(sdp)
        
        for media in mediaDescriptions {
            //content add and accept should only be when adding video, wo we just want the video
            if jingleType == .contentadd || jingleType == .contentaccept || jingleType == .contentreject {
                if media.mediaType == "audio" {
                    continue
                }
            }
            
            let contentElement = XMLElement(name: "content")
            contentElement.addAttribute(withName: "creator", stringValue: "initiator")
            contentElement.addAttribute(withName: "name", stringValue: media.contentName)
            //contentElement.addAttribute(withName: "sender", stringValue: "both")
            
            let descElement = XMLElement(name: "description", xmlns: CallManager.JINGLE_APPS_RTP)
            descElement.addAttribute(withName: "media", stringValue: media.mediaType)
            //descElement.stringValue = "m=audio \(audioPort) RTP/SAVPF 111"
            
            if let bw = media.bandwidth {
                let bwEl = XMLElement(name: "bandwidth")
                bwEl.addAttribute(withName: "type", stringValue: "AS")
                bwEl.stringValue = bw
                descElement.addChild(bwEl)
            }
            
            for extMap in media.extMap {
                let splitMap = extMap.splitToArray(separator: " ")
                if splitMap.count == 2 {
                    let rtpHeader = JingleUtility.createRtpHeaderExtensionElement(id: splitMap[0], uri: splitMap[1])
                    descElement.addChild(rtpHeader)
                }
            }

            for payload in media.payloadTypes {
                guard let payloadType = media.rtpMap[payload] else { continue }
                let payloadEl = XMLElement(name: "payload-type")
                payloadEl.addAttribute(withName: "id", stringValue: payload)
                payloadEl.addAttribute(withName: "name", stringValue: payloadType.name)
                payloadEl.addAttribute(withName: "clockrate", stringValue: payloadType.clockrate)
                if let channels = payloadType.channels {
                    payloadEl.addAttribute(withName: "channels", stringValue: channels)
                }

                if let fmtp = media.fmtp[payload] {
                    for (name, value) in fmtp {
                        let parameterEl = XMLElement(name: "parameter")
                        parameterEl.addAttribute(withName: "name", stringValue: name)
                        parameterEl.addAttribute(withName: "value", stringValue: value)
                        payloadEl.addChild(parameterEl)
                    }
                }

                if let feedbacks = media.rtcpFb[payload] {
                    for fb in feedbacks {
                        let components = fb.split(separator: " ")
                        let type = String(components[0])
                        let subtype = components.count >= 2 ? String(components[1]) : nil
                        
                        let fbEl = XMLElement(name: "rtcp-fb", xmlns: "urn:xmpp:jingle:apps:rtp:rtcp-fb:0")
                        fbEl.addAttribute(withName: "type", stringValue: type)
                        if let sub = subtype {
                            fbEl.addAttribute(withName: "subtype", stringValue: sub)
                        }
                        payloadEl.addChild(fbEl)
                    }
                }
                descElement.addChild(payloadEl)
            }
            
            if media.extmapAllowMixed == true {
                let allowMixedElement = XMLElement(name: "extmap-allow-mixed", xmlns: "urn:xmpp:jingle:apps:rtp:rtp-hdrext:0")
                descElement.addChild(allowMixedElement)
            }
                
            for (ssrcId, attributes) in media.ssrcs {
                let sourceElement = XMLElement(name: "source", xmlns: JingleUtility.JINGLE_RTP_SOURCE_SPECIFIC_MEDIA_ATTRIBUTES)
                sourceElement.addAttribute(withName: "ssrc", stringValue: ssrcId)
                
                let cname = attributes["cname"] ?? ""
                let finalMsid = attributes["msid"] ?? media.msid!
                let cnamePar = XMLElement(name: "parameter")
                cnamePar.addAttribute(withName: "name", stringValue: "cname")
                cnamePar.addAttribute(withName: "value", stringValue: cname)
                let msidPar = XMLElement(name: "parameter")
                msidPar.addAttribute(withName: "name", stringValue: "msid")
                msidPar.addAttribute(withName: "value", stringValue: finalMsid)
                //ssrcEl.addAttribute(withName: "msid", stringValue: finalMsid)
                sourceElement.addChild(cnamePar)
                sourceElement.addChild(msidPar)
                
                if sourceElement.children?.isEmpty == false {
                    descElement.addChild(sourceElement)
                }
            }
            
            if !media.ssrcGroups.isEmpty {
                for (semantics, ssrcs) in media.ssrcGroups {
                    let ssrcgroupEl = XMLElement(name: "ssrc-group", xmlns: JingleUtility.JINGLE_RTP_SOURCE_SPECIFIC_MEDIA_ATTRIBUTES)
                    ssrcgroupEl.addAttribute(withName: "semantics", stringValue: semantics)
                    for ssrc in ssrcs {
                        let srcEl = XMLElement(name: "source")
                        srcEl.addAttribute(withName: "ssrc", stringValue: ssrc)
                        ssrcgroupEl.addChild(srcEl)
                    }
                    
                    descElement.addChild(ssrcgroupEl)
                }
            }
            
            if media.rtcpmux {
                descElement.addChild(XMLElement(name: "rtcp-mux"))
            }
            
            contentElement.addChild(descElement)

            if let ufrag = media.iceUfrag, let pwd = media.icePwd {
                let transportElement = XMLElement(name: "transport", xmlns: CallManager.JINGLE_TRANSPORT_ICE_UDP)
                
                transportElement.addAttribute(withName: "ufrag", stringValue: ufrag)
                transportElement.addAttribute(withName: "pwd", stringValue: pwd)
                
                if let fingerprint = media.fingerprint {
                    let fingerprintEl = XMLElement(name: "fingerprint", xmlns: CallManager.DLTS_SRTP_VERIFICATION)
                    
                    fingerprintEl.addAttribute(withName: "hash", stringValue: "sha-256")
                    let setup = media.setup ?? "actpass"
                    //print("***** generate Jingle from SDP with setup: \(setup)")
                    fingerprintEl.addAttribute(withName: "setup", stringValue: setup)
                    //fingerprintEl.addAttribute(withName: "setup", stringValue: setupval)
                    
                    //if let encryptedEl = getOmemoFingerprint(fingerprint) {
                    if media.mediaType == "video", let encryptedCopy = encryptedVideoElement?.copy() as? XMLElement {
                        fingerprintEl.addChild(encryptedCopy)
                    } else {
                        let encryptedCopy = encryptedAudioElement.copy() as! XMLElement
                        fingerprintEl.addChild(encryptedCopy)
                    }
                    //} else {
                        //fingerprintEl.stringValue = fingerprint
                    //}
                    
                    transportElement.addChild(fingerprintEl)
                }
                
                // If trickle ICE is supported, declare the xmlns:trickle namespace
                if media.trickle {
                    let trickleEl = XMLElement(name: "trickle", xmlns: JingleUtility.JINGLE_TRANSPORT_ICE_OPTION)
                    transportElement.addChild(trickleEl)
                }
                    
                // If renomination is supported, declare the xmlns:renomination namespace
                if media.renomination {
                    let renominationEl = XMLElement(name: "renomination", xmlns: JingleUtility.JINGLE_TRANSPORT_ICE_OPTION)
                    transportElement.addChild(renominationEl)
                }
                
                contentElement.addChild(transportElement)
            }
            
            jingleElement.addChild(contentElement)
        }
        
        if let group = mediaDescriptions.first?.groupBundle {
            let groupElement = XMLElement(name: "group", xmlns: JingleUtility.JINGLE_APPS_GROUPING)
            groupElement.addAttribute(withName: "semantics", stringValue: "BUNDLE")
            for media in mediaDescriptions {
                let contentElement = XMLElement(name: "content")
                contentElement.addAttribute(withName: "name", stringValue: media.contentName)
                groupElement.addChild(contentElement)
            }
            
            jingleElement.addChild(groupElement)
        }
        
        return jingleElement
    }
    
    static func generateJingle(from mediaDescriptions:[MediaDescription], fingerprint: String) -> XMLElement {
        
        let jingleElement = XMLElement(name: "jingle", xmlns: JingleUtility.JINGLE)
        
        for media in mediaDescriptions {
            let contentElement = XMLElement(name: "content")
            contentElement.addAttribute(withName: "creator", stringValue: "initiator")
            contentElement.addAttribute(withName: "name", stringValue: media.contentName)
            contentElement.addAttribute(withName: "sender", stringValue: "both")
            
            let descElement = XMLElement(name: "description", xmlns: CallManager.JINGLE_APPS_RTP)
            descElement.addAttribute(withName: "media", stringValue: media.mediaType)
            //descElement.stringValue = "m=audio \(audioPort) RTP/SAVPF 111"
            
            if let bw = media.bandwidth {
                let bwEl = XMLElement(name: "bandwidth")
                bwEl.addAttribute(withName: "type", stringValue: "AS")
                bwEl.stringValue = bw
                descElement.addChild(bwEl)
            }
            
            for extMap in media.extMap {
                let splitMap = extMap.splitToArray(separator: " ")
                if splitMap.count == 2 {
                    let rtpHeader = JingleUtility.createRtpHeaderExtensionElement(id: splitMap[0], uri: splitMap[1])
                    descElement.addChild(rtpHeader)
                }
            }

            for payload in media.payloadTypes {
                guard let payloadType = media.rtpMap[payload] else { continue }
                let payloadEl = XMLElement(name: "payload-type")
                payloadEl.addAttribute(withName: "id", stringValue: payload)
                payloadEl.addAttribute(withName: "name", stringValue: payloadType.name)
                payloadEl.addAttribute(withName: "clockrate", stringValue: payloadType.clockrate)
                if let channels = payloadType.channels {
                    payloadEl.addAttribute(withName: "channels", stringValue: channels)
                }

                if let fmtp = media.fmtp[payload] {
                    for (name, value) in fmtp {
                        let parameterEl = XMLElement(name: "parameter")
                        parameterEl.addAttribute(withName: "name", stringValue: name)
                        parameterEl.addAttribute(withName: "value", stringValue: value)
                        payloadEl.addChild(parameterEl)
                    }
                }

                if let feedbacks = media.rtcpFb[payload] {
                    for fb in feedbacks {
                        let components = fb.split(separator: " ")
                        let type = String(components[0])
                        let subtype = components.count >= 2 ? String(components[1]) : nil
                        
                        let fbEl = XMLElement(name: "rtcp-fb", xmlns: "urn:xmpp:jingle:apps:rtp:rtcp-fb:0")
                        fbEl.addAttribute(withName: "type", stringValue: type)
                        if let sub = subtype {
                            fbEl.addAttribute(withName: "subtype", stringValue: sub)
                        }
                        payloadEl.addChild(fbEl)
                    }
                }
                descElement.addChild(payloadEl)
            }
            
            if media.extmapAllowMixed == true {
                let allowMixedElement = XMLElement(name: "extmap-allow-mixed", xmlns: "urn:xmpp:jingle:apps:rtp:rtp-hdrext:0")
                descElement.addChild(allowMixedElement)
            }
            
            for (ssrcId, attributes) in media.ssrcs {
                let sourceElement = XMLElement(name: "source", xmlns: JingleUtility.JINGLE_RTP_SOURCE_SPECIFIC_MEDIA_ATTRIBUTES)
                sourceElement.addAttribute(withName: "ssrc", stringValue: ssrcId)
                
                let cname = attributes["cname"] ?? ""
                let finalMsid = attributes["msid"] ?? media.msid!
                let cnamePar = XMLElement(name: "parameter")
                cnamePar.addAttribute(withName: "name", stringValue: "cname")
                cnamePar.addAttribute(withName: "value", stringValue: cname)
                let msidPar = XMLElement(name: "parameter")
                msidPar.addAttribute(withName: "name", stringValue: "msid")
                msidPar.addAttribute(withName: "value", stringValue: finalMsid)
                //ssrcEl.addAttribute(withName: "msid", stringValue: finalMsid)
                sourceElement.addChild(cnamePar)
                sourceElement.addChild(msidPar)
                
                if sourceElement.children?.isEmpty == false {
                    descElement.addChild(sourceElement)
                }
            }
            
            if !media.ssrcGroups.isEmpty {
                for (semantics, ssrcs) in media.ssrcGroups {
                    let ssrcgroupEl = XMLElement(name: "ssrc-group", xmlns: JingleUtility.JINGLE_RTP_SOURCE_SPECIFIC_MEDIA_ATTRIBUTES)
                    ssrcgroupEl.addAttribute(withName: "semantics", stringValue: semantics)
                    for ssrc in ssrcs {
                        let srcEl = XMLElement(name: "source")
                        srcEl.addAttribute(withName: "ssrc", stringValue: ssrc)
                        ssrcgroupEl.addChild(srcEl)
                    }
                    
                    descElement.addChild(ssrcgroupEl)
                }
            }
            
            if media.rtcpmux {
                descElement.addChild(XMLElement(name: "rtcp-mux"))
            }
            
            contentElement.addChild(descElement)

            if let ufrag = media.iceUfrag, let pwd = media.icePwd {
                let transportElement = XMLElement(name: "transport", xmlns: CallManager.JINGLE_TRANSPORT_ICE_UDP)
                
                transportElement.addAttribute(withName: "ufrag", stringValue: ufrag)
                transportElement.addAttribute(withName: "pwd", stringValue: pwd)
                
                if let fingerprint = media.fingerprint {
                    let fingerprintEl = XMLElement(name: "fingerprint", xmlns: CallManager.DLTS_SRTP_VERIFICATION)
                    
                    fingerprintEl.addAttribute(withName: "hash", stringValue: "sha-256")
                    let setup = media.setup ?? "actpass"
                    //print("***** generate Jingle from Media, setup \(setup)")
                    fingerprintEl.addAttribute(withName: "setup", stringValue: setup)
                    
                    //if let encryptedEl = getOmemoFingerprint(fingerprint) {
                    //let encryptedCopy = encryptedElement.copy() as! XMLElement
                    //fingerprintEl.addChild(encryptedCopy)
                    //} else {
                        fingerprintEl.stringValue = fingerprint
                    //}
                    
                    transportElement.addChild(fingerprintEl)
                }
                
                // If trickle ICE is supported, declare the xmlns:trickle namespace
                if media.trickle {
                    let trickleEl = XMLElement(name: "trickle", xmlns: JingleUtility.JINGLE_TRANSPORT_ICE_OPTION)
                    transportElement.addChild(trickleEl)
                }
                    
                // If renomination is supported, declare the xmlns:renomination namespace
                if media.renomination {
                    let renominationEl = XMLElement(name: "renomination", xmlns: JingleUtility.JINGLE_TRANSPORT_ICE_OPTION)
                    transportElement.addChild(renominationEl)
                }
                
                contentElement.addChild(transportElement)
            }
            
            jingleElement.addChild(contentElement)
        }
        
        if let group = mediaDescriptions.first?.groupBundle {
            let groupElement = XMLElement(name: "group", xmlns: JingleUtility.JINGLE_APPS_GROUPING)
            groupElement.addAttribute(withName: "semantics", stringValue: "BUNDLE")
            for media in mediaDescriptions {
                let contentElement = XMLElement(name: "content")
                contentElement.addAttribute(withName: "name", stringValue: media.contentName)
                groupElement.addChild(contentElement)
            }
            
            jingleElement.addChild(groupElement)
        }
        
        return jingleElement
    }
    
    static func parseIceCandidate(_ sdp: String) -> IceCandidate? {
        
        guard sdp.starts(with: "candidate:") else { return nil }
        
        let tokens = sdp.split(separator: " ").map { String($0) }
        
        guard tokens.count >= 16 else { return nil }

        let foundation = tokens[0].split(separator: ":")[1]
        let component = tokens[1]
        let protocolType = tokens[2]
        let priority = tokens[3]
        let ip = tokens[4]
        let port = tokens[5]
        let candidateTypeIndex = tokens.firstIndex(of: "typ") ?? 6
        let candidateType = tokens[candidateTypeIndex + 1]
        if candidateType == "tcp" || ip.starts(with: "169.254") || ip.starts(with: "fe80::") {
            return nil
        }
        
        if let tcpIndex = tokens.firstIndex(of: "tcptype") {
            return nil
        }
        DDLogInfo("IceCandidate \(sdp)")

        let generationIndex = tokens.firstIndex(of: "generation") ?? 8
        let generation = tokens[generationIndex + 1]

        let ufragIndex = tokens.firstIndex(of: "ufrag") ?? 10
        let ufrag = tokens[ufragIndex + 1]

        /*let networkIndex = tokens.firstIndex(of: "network-id") ?? 12
        let network = tokens[networkIndex + 1]
        
        let networkCostIndex = tokens.firstIndex(of: "network-cost") ?? 14
        let networkCost = tokens[networkCostIndex + 1]*/
        
        var raddr: String?
        if let raddrIndex = tokens.firstIndex(of: "raddr") {
            raddr = tokens[raddrIndex + 1]
        }
        
        var rport: String?
        if let rportIndex = tokens.firstIndex(of: "rport") {
            rport = tokens[rportIndex + 1]
        }
        
        var network: String?
        if let networkIndex = tokens.firstIndex(of: " network ") {
            network = tokens[networkIndex + 1]
        }

        let id = UUID().uuidString

        return IceCandidate(
            foundation: String(foundation),
            component: component,
            protocolType: protocolType,
            priority: priority,
            ip: ip,
            port: port,
            candidateType: candidateType,
            raddr: raddr,
            rport: rport,
            generation: generation,
            id: id,
            network: network,
            //networkCost: networkCost,
            //tcptype: tcptype,
            ufrag: ufrag
        )
    }
    
    static func filterCandidatesByHighestPriority(_ candidates: [IceCandidate]) -> [IceCandidate] {
        // Dictionary key is (ip, candidateType)
        var bestCandidates: [String: IceCandidate] = [:]

        for candidate in candidates {
            let key = "\(candidate.ip)-\(candidate.candidateType)-\(candidate.component)"
            let candidatePriority = UInt32(candidate.priority) ?? 0

            if let existing = bestCandidates[key] {
                let existingPriority = UInt32(existing.priority) ?? 0
                if candidatePriority > existingPriority {
                    bestCandidates[key] = candidate
                }
            } else {
                bestCandidates[key] = candidate
            }
        }

        return Array(bestCandidates.values)
    }
    
    static func generateTransportInfo(candidates: [String:[IceCandidate]], ufrag: String, pwd: String, initiator: String, responder: String?, sessionID: String) -> XMLElement {
        let jingleElement = XMLElement(name: "jingle", xmlns: JingleUtility.JINGLE)
        jingleElement.addAttribute(withName: "action", stringValue: "transport-info")
        //jingleElement.addAttribute(withName: "initiator", stringValue: initiator)
        //jingleElement.addAttribute(withName: "responder", stringValue: responder)
        jingleElement.addAttribute(withName: "sid", stringValue: sessionID)
        
        for mediaType in candidates.keys {
            let candidateAr = candidates[mediaType] ?? []
            //let bestCandidates = filterCandidatesByHighestPriority(candidateAr)
            let contentElement = XMLElement(name: "content")
            contentElement.addAttribute(withName: "creator", stringValue: "initiator")
            contentElement.addAttribute(withName: "name", stringValue: mediaType)
            
            let transportElement = XMLElement(name: "transport", xmlns: CallManager.JINGLE_TRANSPORT_ICE_UDP)
            transportElement.addAttribute(withName: "ufrag", stringValue: ufrag)
            transportElement.addAttribute(withName: "pwd", stringValue: pwd)
            
            for ic in candidateAr {
                let candidateElement = XMLElement(name: "candidate")
                candidateElement.addAttribute(withName: "component", stringValue: ic.component)
                candidateElement.addAttribute(withName: "foundation", stringValue: ic.foundation)
                candidateElement.addAttribute(withName: "generation", stringValue: ic.generation)
                candidateElement.addAttribute(withName: "id", stringValue: ic.id)
                candidateElement.addAttribute(withName: "ip", stringValue: ic.ip)
                candidateElement.addAttribute(withName: "port", stringValue: ic.port)
                candidateElement.addAttribute(withName: "priority", stringValue: ic.priority)
                candidateElement.addAttribute(withName: "protocol", stringValue: ic.protocolType.lowercased())
                candidateElement.addAttribute(withName: "type", stringValue: ic.candidateType)
                
                if ic.protocolType.lowercased() == "tcp" {
                    continue
                }
                
                if let raddr = ic.raddr {
                    candidateElement.addAttribute(withName: "rel-addr", stringValue: raddr)
                }
                
                if let rport = ic.rport {
                    candidateElement.addAttribute(withName: "rel-port", stringValue: rport)
                }
                
                if let network = ic.network {
                    candidateElement.addAttribute(withName: "network", stringValue: network)
                }
                //if ic.protocolType.lowercased() == "tcp", let tcpType = ic.tcptype {
                //    candidateElement.addAttribute(withName: "tcptype", stringValue: tcpType)
                //}
                
                transportElement.addChild(candidateElement)
            }
            contentElement.addChild(transportElement)
            jingleElement.addChild(contentElement)
        }
 
        return jingleElement
    }
    
    static func getFingerprintElement(from jingleElement: XMLElement) -> XMLElement? {
        // Iterate through all <content> elements
        for content in jingleElement.elements(forName: "content") {
            // Find the <transport> element with the DTLS fingerprint
            if let transport = content.elements(forLocalName: "transport", uri: "urn:xmpp:jingle:transports:ice-udp:1").first {
                if let fingerprint = transport.elements(forName: "fingerprint").first {
                    return fingerprint
                }
            }
        }
        return nil
    }
    
    static func generateSDP(from jingleElement: XMLElement, fingerprint:String?) -> String {
        var sdpLines: [String] = []
        sdpLines.append("v=0")
        sdpLines.append("o=- 0 0 IN IP4 127.0.0.1")
        sdpLines.append("s=-")
        sdpLines.append("t=0 0")
        
        var hasGroupBundle = false
        if let groupElement = jingleElement.elements(forLocalName: "group", uri: JingleUtility.JINGLE_APPS_GROUPING).first {
            let contentEls = groupElement.elements(forName: "content")
            //let groupNames = contentEls.compactMap { $0.attributeStringValue(forName: "name") }.joined(separator: " ")
            var bundleline = "a=group:BUNDLE"
            //var num = 0
            for (index, _) in contentEls.enumerated() {
                bundleline += " \(index)"
            }
            
            sdpLines.append(bundleline)  //"a=group:BUNDLE 0 1")//\(groupNames)")
            //this is hard coded for now, not sure how to get this
            hasGroupBundle = true
        }
                
        let contentElements = jingleElement.elements(forName: "content")
        var midNum = 0
        for content in contentElements {
            guard let contentName = content.attributeStringValue(forName: "name"), let desc = content.elements(forLocalName: "description", uri: "urn:xmpp:jingle:apps:rtp:1").first, let mediaType = desc.attributeStringValue(forName: "media") else { continue }
                    
            var hasRtcpMux = false
            if desc.elements(forName: "rtcp-mux").count > 0 {
                hasRtcpMux = true
            }
            let payloadTypes = desc.elements(forName: "payload-type")
            let extMaps = desc.elements(forName: "rtp-hdrext")
            let ssrcSources = desc.elements(forLocalName: "source", uri: "urn:xmpp:jingle:apps:rtp:ssma:0")
            let ssrcGroups = desc.elements(forLocalName: "ssrc-group", uri: "urn:xmpp:jingle:apps:rtp:ssma:0")
                    
            let payloadIDs = payloadTypes.compactMap { $0.attributeStringValue(forName: "id") }.joined(separator: " ")
                    
            sdpLines.append("m=\(mediaType) 9 UDP/TLS/RTP/SAVPF \(payloadIDs)")
            sdpLines.append("c=IN IP4 0.0.0.0")
            sdpLines.append("a=rtcp:9 IN IP4 0.0.0.0")
                    
            if let transport = content.elements(forLocalName: "transport", uri: "urn:xmpp:jingle:transports:ice-udp:1").first {
                if let ufrag = transport.attributeStringValue(forName: "ufrag") {
                    sdpLines.append("a=ice-ufrag:\(ufrag)")
                }
                if let pwd = transport.attributeStringValue(forName: "pwd") {
                    sdpLines.append("a=ice-pwd:\(pwd)")
                }
                
                if JingleUtility.supportsTrickleICE(transportElement: transport) {
                    if JingleUtility.supportsRenomination(transportElement: transport) {
                        sdpLines.append("a=ice-options:trickle renomination")
                    } else {
                        sdpLines.append("a=ice-options:trickle")
                    }
                }
                
                var fingerprintElem = transport.elements(forLocalName: "fingerprint", uri: "urn:xmpp:jingle:apps:dtls:0").first
                if fingerprintElem == nil {
                    fingerprintElem = transport.elements(forName: "fingerprint").first
                }
                
                if let fingerprintElem = fingerprintElem, let algo = fingerprintElem.attributeStringValue(forName: "hash") {
                    if let finger = fingerprint {
                        sdpLines.append("a=fingerprint:\(algo) \(finger)")
                    } else if let fingerstr = fingerprintElem.stringValue {
                        sdpLines.append("a=fingerprint:\(algo) \(fingerstr)")
                    }
                    
                    if let setup = fingerprintElem.attributeStringValue(forName: "setup") {
                        sdpLines.append("a=setup:\(setup)")
                    }
                }
                        
                // Add ICE candidates
                let candidates = transport.elements(forLocalName: "candidate", uri: "urn:xmpp:jingle:transports:ice-udp:1")
                for cand in candidates {
                    if let foundation = cand.attributeStringValue(forName: "foundation"),
                        let component = cand.attributeStringValue(forName: "component"),
                        let protocolStr = cand.attributeStringValue(forName: "protocol"),
                        let priority = cand.attributeStringValue(forName: "priority"),
                        let ip = cand.attributeStringValue(forName: "ip"),
                        let port = cand.attributeStringValue(forName: "port"),
                        let typ = cand.attributeStringValue(forName: "type") {
                        var candidateLine = "a=candidate:\(foundation) \(component) \(protocolStr.uppercased()) \(priority) \(ip) \(port) typ \(typ)"
                        if typ == "tcp", let tcpType = cand.attributeStringValue(forName: "tcptype") {
                            candidateLine += " tcptype \(tcpType)"
                        }
                        if let raddr = cand.attributeStringValue(forName: "rel-addr") {
                            candidateLine += " raddr \(raddr)"
                        }
                        if let rport = cand.attributeStringValue(forName: "rel-port") {
                            candidateLine += " rport \(rport)"
                        }
                        if let generation = cand.attributeStringValue(forName: "generation") {
                            candidateLine += " generation \(generation)"
                        }
                        if let ufrag = cand.attributeStringValue(forName: "ufrag") {
                            candidateLine += " ufrag \(ufrag)"
                        }
                        if let network = cand.attributeStringValue(forName: "network") {
                            candidateLine += " network \(network)"
                        }
                        /*if let networkId = cand.attributeStringValue(forName: "network-id") {
                            candidateLine += " network-id \(networkId)"
                        }
                        if let networkCost = cand.attributeStringValue(forName: "network-cost") {
                            candidateLine += " network-cost \(networkCost)"
                        }*/
                        sdpLines.append(candidateLine)
                    }
                }
            }
             
            sdpLines.append("a=mid:\(midNum)") //this needs to match the group bundle. This is the value we are receiving, a number
            midNum+=1
            
            for extmap in extMaps {
                if let extid = extmap.attributeStringValue(forName: "id"),
                    let uri = extmap.attributeStringValue(forName: "uri") {
                    sdpLines.append("a=extmap:\(extid) \(uri)")
                }
            }
            
            sdpLines.append("a=sendrecv")
            
            if hasGroupBundle || hasRtcpMux {
                sdpLines.append("a=rtcp-mux")
                //sdpLines.append("a=rtcp-rsize")
            }
                    
            for pt in payloadTypes {
                guard let id = pt.attributeStringValue(forName: "id"),
                    let name = pt.attributeStringValue(forName: "name"),
                    let clockrate = pt.attributeStringValue(forName: "clockrate") else { continue }
                        
                let channels = pt.attributeStringValue(forName: "channels") ?? "1"
                let rtpmap = channels != "1" ? "\(name)/\(clockrate)/\(channels)" : "\(name)/\(clockrate)"
                sdpLines.append("a=rtpmap:\(id) \(rtpmap)")
                        
                // Parameters → fmtp
                let params = pt.elements(forName: "parameter").compactMap {
                    if let pname = $0.attributeStringValue(forName: "name"),
                        let pval = $0.attributeStringValue(forName: "value") {
                        return "\(pname)=\(pval)"
                    }
                    return nil
                }
                if !params.isEmpty {
                    sdpLines.append("a=fmtp:\(id) \(params.joined(separator: ";"))")
                }
                        
                // RTCP feedback
                let rtcpFeedbacks = pt.elements(forName: "rtcp-fb")
                for fb in rtcpFeedbacks {
                    let type = fb.attributeStringValue(forName: "type") ?? ""
                    let subtype = fb.attributeStringValue(forName: "subtype")
                    let fbLine = subtype != nil ? "a=rtcp-fb:\(id) \(type) \(subtype!)" : "a=rtcp-fb:\(id) \(type)"
                    sdpLines.append(fbLine)
                }
            }
                    
            // SSRCs
            for source in ssrcSources {
                for ssrc in source.elements(forName: "ssrc") {
                    if let id = ssrc.attributeStringValue(forName: "id"),
                        let cname = ssrc.attributeStringValue(forName: "cname") {
                        sdpLines.append("a=ssrc:\(id) cname:\(cname)")
                        if let msid = ssrc.attributeStringValue(forName: "msid") {
                            sdpLines.append("a=ssrc:\(id) msid:\(msid)")
                        }
                    }
                }
            }
                    
            // SSRC-Groups
            for group in ssrcGroups {
                let semantics = group.attributeStringValue(forName: "semantics") ?? "FID"
                let ssrcIDs = group.elements(forName: "source").compactMap {
                    $0.attributeStringValue(forName: "ssrc")
                }
                if !ssrcIDs.isEmpty {
                    sdpLines.append("a=ssrc-group:\(semantics) \(ssrcIDs.joined(separator: " "))")
                }
            }
        }
                
        return sdpLines.joined(separator: "\r\n") + "\r\n"
    }
    
    static func generateSDPCandidates(from jingleElement: XMLElement) -> [String:[String]] {
        var sdpCandidates: [String:[String]] = [:]
        
        let contentElements = jingleElement.elements(forName: "content")
        for content in contentElements {
            guard let contentName = content.attributeStringValue(forName: "name") else { continue }
                    
            if let transport = content.elements(forLocalName: "transport", uri: "urn:xmpp:jingle:transports:ice-udp:1").first {
                  
                // Add ICE candidates
                var candidates: [String] = []
                //if let ufrag = transport.attributeStringValue(forName: "ufrag") {
                //    candidates.append("a=ice-ufrag:\(ufrag)")
                //}
                //if let pwd = transport.attributeStringValue(forName: "pwd") {
                //    candidates.append("a=ice-pwd:\(pwd)")
                //}
                let candidateElements = transport.elements(forName: "candidate")
                for cand in candidateElements {
                    if let foundation = cand.attributeStringValue(forName: "foundation"),
                        let component = cand.attributeStringValue(forName: "component"),
                        let protocolStr = cand.attributeStringValue(forName: "protocol"),
                        let priority = cand.attributeStringValue(forName: "priority"),
                        let ip = cand.attributeStringValue(forName: "ip"),
                        let port = cand.attributeStringValue(forName: "port"),
                        let typ = cand.attributeStringValue(forName: "type") {
                        var candidateLine = "a=candidate:\(foundation) \(component) \(protocolStr.uppercased()) \(priority) \(ip) \(port) typ \(typ)"
                        if typ == "tcp", let tcpType = cand.attributeStringValue(forName: "tcptype") {
                            candidateLine += " tcptype \(tcpType)"
                        }
                        if let raddr = cand.attributeStringValue(forName: "rel-addr") {
                            candidateLine += " raddr \(raddr)"
                        }
                        if let rport = cand.attributeStringValue(forName: "rel-port") {
                            candidateLine += " rport \(rport)"
                        }
                        if let generation = cand.attributeStringValue(forName: "generation") {
                            candidateLine += " generation \(generation)"
                        }
                        if let ufrag = transport.attributeStringValue(forName: "ufrag") {
                            candidateLine += " ufrag \(ufrag)"
                        }
                        if let network = cand.attributeStringValue(forName: "network") {
                            candidateLine += " network \(network)"
                        }
                        /*if let networkId = cand.attributeStringValue(forName: "network-id") {
                            candidateLine += " network-id \(networkId)"
                        }
                        if let networkCost = cand.attributeStringValue(forName: "network-cost") {
                            candidateLine += " network-cost \(networkCost)"
                        }*/
                        candidates.append(candidateLine)
                    }
                }
                sdpCandidates[contentName] = candidates
            }
        }
                
        return sdpCandidates
    }
    
    static func createRtpHeaderExtensionElement(id: String, uri: String) -> XMLElement {
        let ext = XMLElement(name: "rtp-hdrext", xmlns: "urn:xmpp:jingle:apps:rtp:rtp-hdrext:0")
        ext.addAttribute(withName: "id", stringValue: id)
        ext.addAttribute(withName: "uri", stringValue: uri)
        return ext
    }
    
    static func parseRtpmap(_ line: String) -> PayloadType? {
        guard line.starts(with: "a=rtpmap:") else { return nil }
        
        let payloadInfo = line.dropFirst("a=rtpmap:".count)
        let components = payloadInfo.split(separator: " ", maxSplits: 1)
        guard components.count == 2 else { return nil }
        
        let id = String(components[0])
        let codecParts = components[1].split(separator: "/")
        guard codecParts.count >= 2 else { return nil }

        let name = String(codecParts[0])
        let clockrate = String(codecParts[1])
        let channels = codecParts.count > 2 ? String(codecParts[2]) : nil
        
        return PayloadType(id: id, name: name, clockrate: clockrate, channels: channels)
    }
    
    static func parseRtcpFb(_ lines: [String]) -> RtcpFeedback? {
        var feedbacks: [(String, String?)] = []
        var id: String?

        for line in lines {
            guard line.starts(with: "a=rtcp-fb:") else { continue }
            let info = line.dropFirst("a=rtcp-fb:".count)
            let components = info.split(separator: " ")
            guard components.count >= 2 else { continue }

            let payloadId = String(components[0])
            if id == nil { id = payloadId }
            let type = String(components[1])
            let subtype = components.count > 2 ? String(components[2]) : nil
            feedbacks.append((type, subtype))
        }

        if let id = id {
            return RtcpFeedback(id: id, feedbacks: feedbacks)
        }
        return nil
    }
    
    static func parseFmtp(_ line: String) -> FmtpParameter? {
        guard line.starts(with: "a=fmtp:") else { return nil }
        
        let fmtpInfo = line.dropFirst("a=fmtp:".count)
        let components = fmtpInfo.split(separator: " ", maxSplits: 1)
        guard components.count == 2 else { return nil }
        
        let id = String(components[0])
        let paramString = components[1]
        
        var parameters: [String: String] = [:]
        let pairs = paramString.split(separator: ";")
        
        for pair in pairs {
            let keyValue = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if keyValue.count == 2 {
                parameters[keyValue[0]] = keyValue[1]
            }
        }
        
        return FmtpParameter(id: id, parameters: parameters)
    }
    
    static func supportsTrickleICE(transportElement: XMLElement) -> Bool {
        if transportElement.elements(forName: "trickle").count > 0 {
            return true
        }
        return false
    }
    
    static func supportsRenomination(transportElement: XMLElement) -> Bool {
        if transportElement.elements(forName: "renomination").count > 0 {
            return true
        }
        return false
    }
}

struct IceCandidate {
    let foundation: String
    let component: String
    let protocolType: String
    let priority: String
    let ip: String
    let port: String
    let candidateType: String // "host", "srflx", or "relay"
    let raddr: String?
    let rport: String?
    let generation: String
    let id: String
    let network: String?
    //let networkCost: String
    //let tcptype: String? // only if protocol is tcp
    let ufrag: String
}

struct PayloadType {
    var id: String
    var name: String
    var clockrate: String
    var channels: String?
}

struct RtcpFeedback {
    var id: String
    var feedbacks: [(type: String, subtype: String?)]
}

struct FmtpParameter {
    var id: String
    var parameters: [String: String]
}
