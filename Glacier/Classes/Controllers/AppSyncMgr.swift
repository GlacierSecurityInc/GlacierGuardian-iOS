//  Copyright © 2019 Glacier Security. All rights reserved.

import Foundation
import Amplify
import AWSAPIPlugin

@objc open class AppSyncMgr: NSObject
{
    private static var requestsBlocked = false
    let versionsKey = "latest_versions"
    @objc override public init() {
        super.init()
    }

    @objc public static func setRequestsBlocked(_ blocked: Bool) {
        requestsBlocked = blocked
    }
    
    @objc public func getUserInfo(username: String, org: String, completion:@escaping (GlacierUser?) -> Void)  {
        if AppSyncMgr.requestsBlocked {
            completion(nil)
            return
        }
        
        Task {
            let gquery = GetGlacierUsersQuery(organization: org, username: username)
            let request = GraphQLRequest<GetGlacierUsersQuery.Data>(document: GetGlacierUsersQuery.operationString,
                variables: gquery.variables?.jsonObject,
                responseType: GetGlacierUsersQuery.Data.self)
            
            do {
                let result = try await Amplify.API.query(request: request)
                
                switch result {
                case .success(let userData):
                    if let gusers = userData.getGlacierUsers {
                        var display = gusers.userName
                        if display == nil {
                            display = username
                        }
                        
                        if let user = gusers.messengerId, let display = display{
                            
                            var displayName = display
                            if let firstname = gusers.firstName {
                                displayName = firstname
                                if let lastname = gusers.lastName {
                                    displayName = firstname + " " + lastname
                                }
                            }
                            
                            let lowerorg = org.lowercased()
                            let ext = gusers.extensionVoiceserver
                            let guser = GlacierUser(username: user, voiceext: ext ?? "", org: lowerorg, displayname: displayName)
                            completion(guser)
                            return
                        }
                    }
                case .failure(let error):
                    print("Got failed result with \(error.errorDescription)")
                }
            } catch let error as APIError {
                print("Failed to update Glacier user: ", error)
            } catch {
                print("Unexpected error: \(error)")
            }
            completion(nil)
        }
    }
    
    @objc public func getOrgInfo(org: String, completion:@escaping (GlacierOrg?) -> Void) {
        if AppSyncMgr.requestsBlocked {
            completion(nil)
            return
        }
        Task {
            let goquery = GetGlacierOrganizationQuery(organization: org)
            let request = GraphQLRequest<GetGlacierOrganizationQuery.Data>(document: GetGlacierOrganizationQuery.operationString,
                variables: goquery.variables?.jsonObject,
                responseType: GetGlacierOrganizationQuery.Data.self)
            
            do {
                let result = try await Amplify.API.query(request: request)
                
                switch result {
                case .success(let glacierOrgData):
                    if let orgData = glacierOrgData.getGlacierOrganization {
                        let secHubEnabled = orgData.securityhubDataEnabled ?? false
                        let smsEnabled = orgData.smsEnabled ?? false
                        let uploadEnabled = orgData.uploadEnabled ?? false
                        let apiKey = orgData.apiKey
                        
                        let trackingEnabled = orgData.trackingEnabled ?? false
                        let forceTracking = orgData.forceTracking ?? false
                        let trackingFrequency = orgData.trackingFrequency ?? "300"
                        let voicemailEnabled = orgData.voicemailEnabled ?? false
                        
                        let gorg = GlacierOrg(org: org, apikey:apiKey, smsEnabled: smsEnabled, securityHubEnabled: secHubEnabled, uploadEnabled: uploadEnabled, voicemailEnabled: voicemailEnabled, trackingEnabled: trackingEnabled, forceTracking: forceTracking, trackingFrequency: trackingFrequency)
                        completion(gorg)
                        return
                    }
                case .failure(let error):
                    print("Got failed result with \(error.errorDescription)")
                }
                completion(nil)
                
            } catch let error as APIError {
                print("Failed to update Glacier user: ", error)
                completion(nil)
            } catch {
                print("Unexpected error: \(error)")
                completion(nil)
            }
        }
    }
    
    @objc public func getAppInfo(username: String, org: String, completion:@escaping ([String]?, [String]?) -> Void)  {
        if AppSyncMgr.requestsBlocked {
            completion(nil, nil)
            return
        }

        Task {
            let gquery = GetGlacierUsersQuery(organization: org, username: username)
            
            let request = GraphQLRequest<GetGlacierUsersQuery.Data>(document: GetGlacierUsersQuery.operationString, variables: gquery.variables?.jsonObject,
                responseType: GetGlacierUsersQuery.Data.self)
            
            do {
                let result = try await Amplify.API.query(request: request)
                
                switch result {
                case .success(let userdata):
                    var secarray: [String] = []
                    if let secinfo = userdata.getGlacierUsers?.securityInfo {
                        for item in secinfo {
                            if let oneinfo = item {
                                secarray.append(oneinfo)
                            }
                        }
                    }
                    
                    var corearray: [String] = []
                    if let coreinfo = userdata.getGlacierUsers?.coreRegion {
                        for item in coreinfo {
                            if let onecore = item?.replacingOccurrences(of: "\"", with: "") {
                                corearray.append(onecore)
                            }
                        }
                    }
                    
                    completion(secarray, corearray)
                case .failure(let error):
                    completion(nil, nil)
                    print("Got failed result with \(error.errorDescription)")
                }
                
            } catch let error as APIError {
                print("Failed to update Glacier user: ", error)
                completion(nil, nil)
            } catch {
                print("Unexpected error: \(error)")
                completion(nil, nil)
            }
        }
    }
    
    @objc public func getLatestVersionInfo(completion:@escaping (LatestVersions?) -> Void)  {
        if AppSyncMgr.requestsBlocked {
            completion(nil)
            return
        }
        Task {
            let gquery = GetLatestVersionQuery(key: self.versionsKey)
            let request = GraphQLRequest<GetLatestVersionQuery.Data>(document: GetLatestVersionQuery.operationString,
                variables: gquery.variables?.jsonObject,
                responseType: GetLatestVersionQuery.Data.self)
            
            do {
                let result = try await Amplify.API.query(request: request)
                
                switch result {
                case .success(let versionsData):
                    if let gversions = versionsData.getLatestVersion {
                        let latestVersions = LatestVersions(altOs: gversions.altOs, altOsNew: gversions.altOsNew, androidOs: gversions.androidOs, glacier: gversions.glacier, glacierAndroid: gversions.glacierAndroid, ios: gversions.ios)
                        completion(latestVersions)
                        return
                    }
                case .failure(let error):
                    print("Got failed result with \(error.errorDescription)")
                }
            } catch let error as APIError {
                print("Failed to get Latest Versions: ", error)
            } catch {
                print("Unexpected error: \(error)")
            }
            completion(nil)
        }
    }
    
    @objc public func sendSecurityInfo(username: String, org: String, secInfo: [String], completion:@escaping (_ success: Bool) -> Void)  {
        if AppSyncMgr.requestsBlocked {
            completion(false)
            return
        }
        
        Task {
            var ginput = UpdateGlacierUsersInput.init(organization: org, username: username)
            ginput.securityInfo = secInfo
            
            let request = GraphQLRequest<UpdateGlacierUsersMutation.Data>(document: UpdateGlacierUsersMutation.operationString, variables: UpdateGlacierUsersMutation.init(input: ginput).variables?.jsonObject,
                responseType: UpdateGlacierUsersMutation.Data.self)
            
            do {
                let result = try await Amplify.API.mutate(request: request)
                
                switch result {
                case .success(let updateGlacierUsers):
                    completion(true)
                    return
                case .failure(let error):
                    print("Got failed result with \(error.errorDescription)")
                }
                completion(false)
                
            } catch let error as APIError {
                print("Failed to update Glacier user: ", error)
                completion(false)
            } catch {
                print("Unexpected error: \(error)")
                completion(false)
            }
        }
    }
}

@objc public class GlacierUser:NSObject {
    @objc public let username:String
    @objc public var voiceext:String?
    @objc public var organization:String?
    @objc public var displayName:String?
    
    @objc public init(username:String, voiceext:String, org:String, displayname:String) {
        self.username = username
        self.voiceext = voiceext
        self.organization = org
        self.displayName = displayname
    }
}

@objc public class GlacierOrg:NSObject {
    @objc public var organization:String?
    @objc public var apikey:String?
    @objc public var smsEnabled:Bool = false
    @objc public var securityHubEnabled:Bool = false
    @objc public var uploadEnabled:Bool = false
    @objc public var voicemailEnabled:Bool = false
    @objc public var trackingEnabled:Bool = false
    @objc public var trackingInterval:Int = 300
    @objc public var forceTracking:Bool = false
    
    @objc public init(org:String, apikey:String, smsEnabled:Bool, securityHubEnabled:Bool, uploadEnabled:Bool, voicemailEnabled:Bool, trackingEnabled:Bool, forceTracking:Bool, trackingFrequency:String) {
        self.organization = org
        self.apikey = apikey
        self.smsEnabled = smsEnabled
        self.securityHubEnabled = securityHubEnabled
        self.uploadEnabled = uploadEnabled
        self.trackingEnabled = trackingEnabled
        self.forceTracking = forceTracking
        self.voicemailEnabled = voicemailEnabled
        self.trackingInterval = Int(trackingFrequency) ?? 300
    }
}

@objc public class LatestVersions:NSObject {
    @objc public var altOs:String?
    @objc public var altOsNew:String?
    @objc public var androidOs:String?
    @objc public var glacier:String?
    @objc public var glacierAndroid:String?
    @objc public var ios:String?
    
    @objc public init(altOs: String, altOsNew: String, androidOs: String, glacier: String, glacierAndroid: String, ios: String) {
        self.altOs = altOs
        self.altOsNew = altOsNew
        self.androidOs = androidOs
        self.glacier = glacier
        self.glacierAndroid = glacierAndroid
        self.ios = ios
    }
}
