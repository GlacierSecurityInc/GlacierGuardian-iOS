//
//  BackendHelper.swift
//  Glacier
//
//  Created by Codex on 2/4/26.
//

import Foundation
import Alamofire
import CocoaLumberjack

private struct GlacierUserEnvelope: Decodable {
    let message: String?
    let user: GlacierUserResponse?
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    var rawObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.rawObject }
        case .array(let value):
            return value.map { $0.rawObject }
        case .null:
            return NSNull()
        }
    }
}

private struct GlacierUserResponse: Decodable {
    let organization: String?
    let username: String?
    let userName: String?
    let messengerId: String?
    let glacierpwd: String?
    let xmppToken: String?
    let extensionVoiceserver: String?
    let firstName: String?
    let lastName: String?
    let email: String?
    let isSMSEnabled: Bool?
    let addToCoreVpn: Bool?
    let addUserToSMS: Bool?
    let addUserToPurchaseNumbers: Bool?
    let securityInfo: [String]?
    let selectedTwilionumber: [String]?
    let coreRegion: [String]?

    enum CodingKeys: String, CodingKey {
        case organization
        case username
        case userName = "user_name"
        case messengerId = "messenger_id"
        case glacierpwd
        case xmppToken = "xmpp_token"
        case extensionVoiceserver = "extension_voiceserver"
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case isSMSEnabled
        case addToCoreVpn = "add_to_core_vpn"
        case addUserToSMS = "add_user_to_SMS"
        case addUserToPurchaseNumbers = "add_user_to_purchase_numbers"
        case securityInfo
        case selectedTwilionumber = "selected_twilionumber"
        case coreRegion = "core_region"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        userName = try container.decodeIfPresent(String.self, forKey: .userName)
        messengerId = try container.decodeIfPresent(String.self, forKey: .messengerId)
        glacierpwd = try container.decodeIfPresent(String.self, forKey: .glacierpwd)
        xmppToken = try container.decodeIfPresent(String.self, forKey: .xmppToken)
        extensionVoiceserver = try container.decodeIfPresent(String.self, forKey: .extensionVoiceserver)
        firstName = try container.decodeIfPresent(String.self, forKey: .firstName)
        lastName = try container.decodeIfPresent(String.self, forKey: .lastName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        isSMSEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSMSEnabled)
        addToCoreVpn = try container.decodeIfPresent(Bool.self, forKey: .addToCoreVpn)
        addUserToSMS = try container.decodeIfPresent(Bool.self, forKey: .addUserToSMS)
        addUserToPurchaseNumbers = try container.decodeIfPresent(Bool.self, forKey: .addUserToPurchaseNumbers)
        if let stringArray = try? container.decode([String?].self, forKey: .securityInfo) {
            securityInfo = stringArray.compactMap { $0 }
        } else if let jsonValueArray = try? container.decode([JSONValue].self, forKey: .securityInfo) {
            securityInfo = jsonValueArray.compactMap { value in
                switch value {
                case .string(let str):
                    return str
                case .null:
                    return nil
                default:
                    guard JSONSerialization.isValidJSONObject(value.rawObject),
                          let data = try? JSONSerialization.data(withJSONObject: value.rawObject, options: []),
                          let jsonString = String(data: data, encoding: .utf8) else {
                        return nil
                    }
                    return jsonString
                }
            }
        } else {
            securityInfo = nil
        }
        if let selectedArray = try? container.decode([String?].self, forKey: .selectedTwilionumber) {
            selectedTwilionumber = selectedArray.compactMap { $0 }
        } else if let singleSelected = try? container.decode(String.self, forKey: .selectedTwilionumber) {
            selectedTwilionumber = [singleSelected]
        } else {
            selectedTwilionumber = nil
        }

        if let regionArray = try? container.decode([String?].self, forKey: .coreRegion) {
            coreRegion = regionArray.compactMap { $0 }
        } else if let singleRegion = try? container.decode(String.self, forKey: .coreRegion) {
            coreRegion = [singleRegion]
        } else {
            coreRegion = nil
        }
    }
}

private struct GlacierOrganizationResponse: Decodable {
    let organization: String?
    let securityhubDataEnabled: Bool?
    let smsEnabled: Bool?
    let uploadEnabled: Bool?
    let voicemailEnabled: Bool?
    let trackingEnabled: Bool?
    let forceTracking: Bool?
    let trackingFrequency: String?

    enum CodingKeys: String, CodingKey {
        case organization
        case securityhubDataEnabled = "securityhub_data_enabled"
        case smsEnabled = "sms_enabled"
        case uploadEnabled = "upload_enabled"
        case voicemailEnabled = "voicemail_enabled"
        case trackingEnabled = "tracking_enabled"
        case forceTracking = "force_tracking"
        case trackingFrequency = "tracking_frequency"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        organization = try container.decodeIfPresent(String.self, forKey: .organization)
        securityhubDataEnabled = try container.decodeIfPresent(Bool.self, forKey: .securityhubDataEnabled)
        smsEnabled = try container.decodeIfPresent(Bool.self, forKey: .smsEnabled)
        uploadEnabled = try container.decodeIfPresent(Bool.self, forKey: .uploadEnabled)
        voicemailEnabled = try container.decodeIfPresent(Bool.self, forKey: .voicemailEnabled)
        trackingEnabled = try container.decodeIfPresent(Bool.self, forKey: .trackingEnabled)
        forceTracking = try container.decodeIfPresent(Bool.self, forKey: .forceTracking)

        if let freqString = try? container.decode(String.self, forKey: .trackingFrequency) {
            trackingFrequency = freqString
        } else if let freqInt = try? container.decode(Int.self, forKey: .trackingFrequency) {
            trackingFrequency = String(freqInt)
        } else if let freqDouble = try? container.decode(Double.self, forKey: .trackingFrequency) {
            trackingFrequency = String(Int(freqDouble))
        } else {
            trackingFrequency = nil
        }
    }
}

private struct GlacierOrganizationEnvelope: Decodable {
    let message: String?
    let organization: GlacierOrganizationResponse?
}

private struct LatestVersionResponse: Decodable {
    let altOs: String?
    let altOsNew: String?
    let androidOs: String?
    let glacier: String?
    let glacierAndroid: String?
    let ios: String?

    enum CodingKeys: String, CodingKey {
        case altOs = "alt_os"
        case altOsNew = "alt_os_new"
        case androidOs = "android_os"
        case glacier
        case glacierAndroid = "glacier_android"
        case ios
    }
}

private struct LatestVersionEnvelope: Decodable {
    let message: String?
    let versions: LatestVersionResponse?
}

private struct SecurityInfoRequest: Encodable {
    let organization: String
    let username: String
    let securityInfo: [SecurityInfo]
}

private struct MessageResponse: Decodable {
    let message: String?
}

private struct GlacierFailureResponse: Decodable {
    let message: String?
    let status: String?
    let error: String?
}

@objcMembers
open class BackendHelper: NSObject {
    private static let sharedHelper = BackendHelper()
    private static var requestsBlocked = false
    private let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral, serverTrustManager: GlacierPinningConfiguration.makeServerTrustManager())
    private let internalQueue = DispatchQueue(label: "BackendHelperQueue")

    @objc public class func shared() -> BackendHelper {
        return sharedHelper
    }

    @objc public class func setRequestsBlocked(_ blocked: Bool) {
        requestsBlocked = blocked
    }

    private override init() {
        super.init()
    }

    private func getEndpoint() -> String {
        if let account = ChatAccountModel.firstAccount() {
            return account.useStageConsole ? GlacierInfo.stageAPIEndpoint() : GlacierInfo.backendAPIEndpoint()
        }
        return GlacierInfo.backendAPIEndpoint()
    }

    private func clearChatHistoryUrl() -> String {
        return getEndpoint() + "clearEjabberdChatHistory"
    }

    private func webhookUrl(_ path: String) -> String {
        let endpoint = getEndpoint()
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "\(base)/\(suffix)"
    }

    private func webhookUrlWithQuery(_ path: String, queryItems: [URLQueryItem]) -> String? {
        let rawUrl = webhookUrl(path)
        guard var components = URLComponents(string: rawUrl) else {
            return nil
        }
        components.queryItems = queryItems
        return components.url?.absoluteString
    }

    private func logFailureResponse(_ data: Data?, context: String) {
        guard let data = data else { return }
        if let parsed = try? JSONDecoder().decode(GlacierFailureResponse.self, from: data) {
            DDLogError("\(context) failure: message=\(parsed.message ?? "nil") status=\(parsed.status ?? "nil") error=\(parsed.error ?? "nil")")
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            DDLogError("\(context) failure body: \(text)")
        }
    }

    @objc public func clearChatHistory() {
        guard !Self.requestsBlocked else { return }
        Task { [weak self] in
            guard let self = self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            
            self.sessionManager.request(
                self.clearChatHistoryUrl(),
                method: .post,
                encoding: JSONEncoding.default,
                headers: headers
            )
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success:
                    return
                case .failure(let error):
                    DDLogError("Error clearing chat history: \(error)")
                    return
                }
            }
        }
    }

    public func getGlacierUser(
        organization: String,
        username: String,
        completion: @escaping (GlacierUser?) -> Void
    ) {
        guard !Self.requestsBlocked else {
            completion(nil)
            return
        }
        Task { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion(nil)
                return
            }

            guard let requestUrl = self.webhookUrlWithQuery(
                "/glacier-users",
                queryItems: [
                    URLQueryItem(name: "organization", value: organization),
                    URLQueryItem(name: "username", value: username)
                ]
            ) else {
                completion(nil)
                return
            }

            self.sessionManager.request(
                requestUrl,
                method: .get,
                headers: headers
            )
            .validate()
            .responseDecodable(of: GlacierUserEnvelope.self, queue: self.internalQueue) { response in
                switch response.result {
                case .success(let payload):
                    guard let userPayload = payload.user,
                          let user = userPayload.messengerId else {
                        completion(nil)
                        return
                    }
                    // Require at least one usable credential. glacierpwd is kept
                    // for backward compatibility; once the server moves to JWT
                    // auth the backend returns xmpp_token instead and glacierpwd
                    // may be absent.
                    let token = userPayload.xmppToken
                    guard (userPayload.glacierpwd?.isEmpty == false) || (token?.isEmpty == false) else {
                        self.logFailureResponse(response.data, context: "getGlacierUser")
                        DDLogError("getGlacierUser: response had neither glacierpwd nor xmpp_token")
                        completion(nil)
                        return
                    }
                    let password = userPayload.glacierpwd ?? ""
                    var displayName = userPayload.userName ?? username
                    if let firstName = userPayload.firstName {
                        displayName = firstName
                        if let lastName = userPayload.lastName {
                            displayName = firstName + " " + lastName
                        }
                    }
                    let lowerOrg = organization.lowercased()
                    let guser = GlacierUser(
                        username: user,
                        voiceext: userPayload.extensionVoiceserver ?? "",
                        password: password,
                        token: token,
                        org: lowerOrg,
                        displayname: displayName
                    )
                    completion(guser)
                case .failure(let error):
                    self.logFailureResponse(response.data, context: "getGlacierUser")
                    DDLogError("Error getting glacier user from webhook: \(error)")
                    completion(nil)
                }
            }
        }
    }

    public func getGlacierOrganization(
        organization: String,
        username: String,
        completion: @escaping (GlacierOrg?) -> Void
    ) {
        guard !Self.requestsBlocked else {
            completion(nil)
            return
        }
        Task { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion(nil)
                return
            }

            guard let requestUrl = self.webhookUrlWithQuery(
                "/glacier-organization",
                queryItems: [
                    URLQueryItem(name: "organization", value: organization),
                    URLQueryItem(name: "username", value: username)
                ]
            ) else {
                completion(nil)
                return
            }

            self.sessionManager.request(
                requestUrl,
                method: .get,
                headers: headers
            )
            .validate()
            .responseDecodable(of: GlacierOrganizationEnvelope.self, queue: self.internalQueue) { response in
                switch response.result {
                case .success(let payload):
                    guard let orgPayload = payload.organization,
                          let org = orgPayload.organization else {
                        completion(nil)
                        return
                    }
                    let gorg = GlacierOrg(
                        org: org,
                        smsEnabled: orgPayload.smsEnabled ?? false,
                        securityHubEnabled: orgPayload.securityhubDataEnabled ?? false,
                        uploadEnabled: orgPayload.uploadEnabled ?? false,
                        voicemailEnabled: orgPayload.voicemailEnabled ?? false,
                        trackingEnabled: orgPayload.trackingEnabled ?? false,
                        forceTracking: orgPayload.forceTracking ?? false,
                        trackingFrequency: orgPayload.trackingFrequency ?? "300"
                    )
                    completion(gorg)
                case .failure(let error):
                    self.logFailureResponse(response.data, context: "getGlacierOrganization")
                    DDLogError("Error getting glacier organization from webhook: \(error)")
                    completion(nil)
                }
            }
        }
    }

    public func getLatestVersion(
        key: String,
        completion: @escaping (LatestVersions?) -> Void
    ) {
        guard !Self.requestsBlocked else {
            completion(nil)
            return
        }
        Task { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion(nil)
                return
            }

            guard let requestUrl = self.webhookUrlWithQuery(
                "/latest-version",
                queryItems: [
                    URLQueryItem(name: "key", value: key)
                ]
            ) else {
                completion(nil)
                return
            }

            self.sessionManager.request(
                requestUrl,
                method: .get,
                headers: headers
            )
            .validate()
            .responseDecodable(of: LatestVersionEnvelope.self, queue: self.internalQueue) { response in
                switch response.result {
                case .success(let payload):
                    guard let versions = payload.versions,
                          let altOs = versions.altOs,
                          let altOsNew = versions.altOsNew,
                          let androidOs = versions.androidOs,
                          let glacier = versions.glacier,
                          let glacierAndroid = versions.glacierAndroid,
                          let ios = versions.ios else {
                        completion(nil)
                        return
                    }
                    completion(
                        LatestVersions(
                            altOs: altOs,
                            altOsNew: altOsNew,
                            androidOs: androidOs,
                            glacier: glacier,
                            glacierAndroid: glacierAndroid,
                            ios: ios
                        )
                    )
                case .failure(let error):
                    self.logFailureResponse(response.data, context: "getLatestVersion")
                    DDLogError("Error getting latest versions from webhook: \(error)")
                    completion(nil)
                }
            }
        }
    }

    public func getAppInfo(
        organization: String,
        username: String,
        completion: @escaping ([String]?, [String]?) -> Void
    ) {
        guard !Self.requestsBlocked else {
            completion(nil, nil)
            return
        }
        Task { [weak self] in
            guard let self = self else {
                completion(nil, nil)
                return
            }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion(nil, nil)
                return
            }

            guard let requestUrl = self.webhookUrlWithQuery(
                "/glacier-users",
                queryItems: [
                    URLQueryItem(name: "organization", value: organization),
                    URLQueryItem(name: "username", value: username)
                ]
            ) else {
                completion(nil, nil)
                return
            }

            self.sessionManager.request(
                requestUrl,
                method: .get,
                headers: headers
            )
            .validate()
            .responseDecodable(of: GlacierUserEnvelope.self, queue: self.internalQueue) { response in
                switch response.result {
                case .success(let payload):
                    guard let userPayload = payload.user else {
                        completion(nil, nil)
                        return
                    }
                    let sec = userPayload.securityInfo ?? []
                    let core = userPayload.coreRegion?.map { $0.replacingOccurrences(of: "\"", with: "") } ?? []
                    completion(sec, core)
                case .failure(let error):
                    self.logFailureResponse(response.data, context: "getAppInfo")
                    DDLogError("Error getting app info from webhook: \(error)")
                    completion(nil, nil)
                }
            }
        }
    }

    public func updateSecurityInfo(
        organization: String,
        username: String,
        securityInfo: [String],
        completion: @escaping (Bool) -> Void
    ) {
        guard !Self.requestsBlocked else {
            completion(false)
            return
        }
        Task { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            guard let headers = await GlacierAPIHeaders.authHeaders() else {
                completion(false)
                return
            }

            let decoder = JSONDecoder()
            let parsedSecurityInfo = securityInfo.compactMap { jsonString -> SecurityInfo? in
                guard let data = jsonString.data(using: .utf8) else { return nil }
                return try? decoder.decode(SecurityInfo.self, from: data)
            }

            let body = SecurityInfoRequest(
                organization: organization,
                username: username,
                securityInfo: parsedSecurityInfo
            )

            self.sessionManager.request(
                self.webhookUrl("/glacier-users/security-info"),
                method: .put,
                parameters: body,
                encoder: JSONParameterEncoder.default,
                headers: headers
            )
            .validate()
            .responseDecodable(of: MessageResponse.self, queue: self.internalQueue) { response in
                switch response.result {
                case .success(let payload):
                    if payload.message?.lowercased() == "success" || payload.message == nil {
                        completion(true)
                    } else {
                        DDLogError("updateSecurityInfo returned non-success message: \(payload.message ?? "nil")")
                        completion(false)
                    }
                case .failure(let error):
                    self.logFailureResponse(response.data, context: "updateSecurityInfo")
                    DDLogError("Error updating security info via webhook: \(error)")
                    completion(false)
                }
            }
        }
    }

    public func downloadWireguardProfile(
        organization: String,
        coreRegion: String,
        username: String,
        destinationURL: URL,
        completion: @escaping (Bool) -> Void
    ) {
        guard !Self.requestsBlocked else {
            completion(false)
            return
        }
        Task { [weak self] in
            guard let self = self else {
                completion(false)
                return
            }
            guard var headers = await GlacierAPIHeaders.authHeaders() else {
                completion(false)
                return
            }
            headers.add(name: "Accept", value: "text/plain")

            guard let requestUrl = self.webhookUrlWithQuery(
                "/core-profile",
                queryItems: [
                    URLQueryItem(name: "organization", value: organization),
                    URLQueryItem(name: "core_region", value: coreRegion),
                    URLQueryItem(name: "username", value: username)
                ]
            ) else {
                completion(false)
                return
            }

            self.sessionManager.request(
                requestUrl,
                method: .get,
                headers: headers
            )
            .validate()
            .responseData(queue: self.internalQueue) { response in
                switch response.result {
                case .success(let data):
                    do {
                        try data.write(to: destinationURL, options: .atomic)
                        completion(true)
                    } catch {
                        DDLogError("Failed writing wireguard profile to disk: \(error)")
                        completion(false)
                    }
                case .failure(let error):
                    self.logFailureResponse(response.data, context: "downloadWireguardProfile")
                    DDLogError("Error downloading wireguard profile from webhook: \(error)")
                    completion(false)
                }
            }
        }
    }
}
