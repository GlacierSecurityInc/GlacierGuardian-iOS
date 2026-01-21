//
//  LocationManager.swift
//  Glacier
//
//  Created by andyfriedman on 10/2/24.
//  Copyright © 2024 Glacier. All rights reserved.
//

import CoreLocation
import Alamofire

public protocol LocationManagerDelegate {
    func showDeniedAlert(_ alert:UIAlertController)
}

/*public protocol LocationDelegate {
    func locationUpdated(_ location: CLLocation)
}*/

class LocationManager: NSObject, CLLocationManagerDelegate, OrgUpdateDel {
    
    private let locationManager = CLLocationManager()
    private static let sharedLocationMgr = LocationManager()
    private static let SEND_TRACKING_URL = GlacierInfo.trackingAPIEndpoint()
    private var updateSeconds:Double = 90.0
    private var lastLocation = CLLocation(latitude: 0,longitude: 0)
    private var lastUpdated = Date.distantPast
    private var locationManagerDelegate:LocationManagerDelegate?
    //private var locationDelegates:Set<LocationDelegate> = []
    private var finishedLogin = false
    private var orgDataReady = false
    private var trackingOn = false
    private var trackingEnabled = false
    let dateFormatter = DateFormatter()
    private var account:ChatAccountModel?
    private var waitingForPermission = false
    
    let internalQueue = DispatchQueue(label: "LocationManager Queue")
    let sessionManager = Alamofire.Session(configuration: URLSessionConfiguration.ephemeral)
    
    private var username: String?
    private var organization: String?
    private var deviceId: String?
    
    
    /*func addLocationDelegate(_ delegate: LocationDelegate) {
        self.locationDelegates.insert(delegate)
    }
    
    func removeLocationDelegate(_ delegate: LocationDelegate) {
        self.locationDelegates.remove(delegate)
        if self.locationDelegates.count == 0, trackingOn == false {
            self.locationManager.stopUpdatingLocation()
        }
    }
    
    public func getLastObservedLocation() -> CLLocation? {
        return self.lastLocation
    }
    
    public func getCurrentAuthorization() -> CLAuthorizationStatus {
        return self.locationManager.compatibleAuthorizationStatus
    }*/
    
    /*func toggleLocationUpdates(_ enable:Bool) {
        if enable == false, self.trackingOn == false {
            self.locationManager.stopUpdatingLocation()
        }
    }*/
    
    func orgInfoUpdated() {
        //if tracking is on, setupLocationManager
        if orgDataReady == false {
            orgDataReady = true
            self.startLocationTracking()
        }
    }
    
    func startLocationTracking() {
        if self.account == nil {
            self.account = ChatAccountModel.allXMPPAccounts().first
        }
        
        if self.isTrackingEnabled(), finishedLogin == true  {
            self.setupLocationManager()
        }
    }
    
    func uiReadyForLocation() {
        finishedLogin = true
        
        if self.account == nil {
            self.account = ChatAccountModel.allXMPPAccounts().first
        }
        
        if self.isTrackingEnabled() {
            self.orgDataReady = true
            self.trackingEnabled = true
            setupLocationManager()
            return
        }
        
        if orgDataReady == true {
            self.startLocationTracking()
        }
    }
    
    private func isTrackingEnabled() -> Bool {
        let orgdata = AWSAcctManager.sharedMgr().getGlacierEnablements()
        if let account = self.account {
            return account.trackingEnabled || orgdata?.trackingEnabled == true || account.username.starts(with: "appleuser")
        }
        
        return orgdata?.trackingEnabled ?? false
    }
    
    @objc func enableTracking(_ enable:Bool) {
        self.trackingOn = enable
        if !enable {
            locationManager.stopUpdatingLocation()
        } else {
            self.startLocationTracking()
        }
    }

    func setupLocationManager() {
        if trackingEnabled {
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            //locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.activityType = .otherNavigation
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = false
            //locationManager.allowsBackgroundLocationUpdates = true
            self.requestLocationPermission()
        } 
    }
    
    /*func setupLocationManagerForChat() {
        if trackingOn == false {
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.pausesLocationUpdatesAutomatically = false
            self.requestLocationPermission()
        }
    }*/
    
    func requestLocationPermission() {
        internalQueue.async {
            if CLLocationManager.locationServicesEnabled() {
                let authStatus = self.locationManager.authorizationStatus
                if self.trackingEnabled {
                    DispatchQueue.main.async {
                        self.handleAuthStatus(authStatus)
                    }
                } //else {
                   // self.handleAuthStatusForChat(authStatus)
                //}
            } else {
                DispatchQueue.main.async {
                    self.handleLocationAuthorizationDenied()
                }
            }
        }
    }
    
    func setLocationManagerDelegate(_ del: LocationManagerDelegate) {
        self.locationManagerDelegate = del
    }
    
    func handleLocationAuthorizationDenied() {
        let account = self.account ?? ChatAccountModel.allXMPPAccounts().first
        let shouldPresentAlert = self.waitingForPermission || account?.forceTracking == true
        self.waitingForPermission = false

        guard shouldPresentAlert else {
            return
        }

        DispatchQueue.main.async {
            var alertMessage = "Glacier doesn't have location access. Please enable Location Services for Glacier in your device settings to use this feature."
            if account?.forceTracking == true {
                alertMessage = "Your organization requires location access, but Glacier isn't permitted. Please enable Location Services for Glacier in your device settings."
            }

            let alert = UIAlertController(title: "Allow Location Access", message: alertMessage, preferredStyle: .alert)
            let fix = UIAlertAction(title: "Go to Settings", style: .default, handler: { action in
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            })
            let cancel = UIAlertAction(title: "No Thanks", style: .cancel)
            alert.addAction(fix)
            alert.addAction(cancel)
            self.locationManagerDelegate?.showDeniedAlert(alert)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.handleAuthStatus(manager.authorizationStatus)
    }
    
    func handleAuthStatus(_ status:CLAuthorizationStatus) {
        switch (status) {
        case .notDetermined:
            self.waitingForPermission = true
            self.handleNotDetermined()
            break
        case .restricted, .denied:
            self.handleLocationAuthorizationDenied()
            break
        case .authorizedWhenInUse:
            if waitingForPermission {
                self.locationManager.requestAlwaysAuthorization()
            } else {
                let acct = ChatAccountModel.allXMPPAccounts().first
                if let acct = acct, acct.username.starts(with: "appleuser") {
                    locationManager.allowsBackgroundLocationUpdates = false
                    locationManager.showsBackgroundLocationIndicator = false
                } else {
                    acct?.trackingOn = true
                    acct?.saveXMPPAccountAsync()
                    if acct?.forceTracking == true {
                        self.handleAuthorizedWhenInUse()
                    }
                }
            }
            self.handleAuthorized()
            break
        case .authorizedAlways:
            locationManager.allowsBackgroundLocationUpdates = true
            self.handleAuthorized()
            break
        default:
            self.handleAuthorized()
            break
        }
    }
    
    /*func handleAuthStatusForChat(_ status:CLAuthorizationStatus) {
        switch (status) {
        case .notDetermined:
            self.locationManager.requestWhenInUseAuthorization()
            break
        case .restricted, .denied:
            self.handleLocationAuthorizationDenied()
            break
        case .authorizedWhenInUse, .authorizedAlways:
            self.locationManager.startUpdatingLocation()
            break
        default:
            break
        }
    }*/
    
    private func handleNotDetermined() {
        DispatchQueue.main.async {
            var alertMessage = "Your organization enabled live tracking for your account. In order to provide this service, Glacier will need location access.\n\nOn the first prompt, please select \"Allow While Using App\".\n\nThat will be followed by another prompt, select \"Change to Always Allow.\""
            
            if let account = ChatAccountModel.allXMPPAccounts().first, account.username.starts(with: "appleuser") {
                alertMessage = "Enabling location access allows Glacier to deliver accurate, real-time location services tailored to your needs.\n\nTo be able to send your location in chats, on the first prompt, please select \"Allow While Using App\".\n\nThat will be followed by another prompt. If you'd like to enable the live tracking service for safety needs, you can select \"Change to Always Allow.\" Otherwise choose \"Keep Only While Using.\""
            }
            
            let alert = UIAlertController(title: "Allow Location Access", message: alertMessage, preferredStyle: .alert)
            let okbtn = UIAlertAction(title: "OK", style: .default, handler: { action in
                self.locationManager.requestWhenInUseAuthorization()
            })
            
            alert.addAction(okbtn)
            self.locationManagerDelegate?.showDeniedAlert(alert)
        }
    }
    
    private func handleAuthorizedWhenInUse() {
        //if user has not yet done this
        DispatchQueue.main.async {
            let alertMessage = "Your organization enabled live tracking for your account. In order to provide this service, Glacier will need continual location access.\n\nPlease set Location Services for Glacier in your device settings to \"Always Allow.\""
            
            let alert = UIAlertController(title: "Allow Location Access", message: alertMessage, preferredStyle: .alert)
            let okbtn = UIAlertAction(title: "OK", style: .default, handler: { action in
                self.locationManager.requestAlwaysAuthorization()
            })
            
            alert.addAction(okbtn)
            self.locationManagerDelegate?.showDeniedAlert(alert)
        }
    }
    
    private func handleAuthorized() {
        let acct = ChatAccountModel.allXMPPAccounts().first
        
        if let acct = acct, acct.username.starts(with: "appleuser") {
            self.waitingForPermission = false
            self.locationManager.startUpdatingLocation()
            return
        }
        
        var tOn = acct?.trackingOn
        if waitingForPermission, let acct = acct, acct.trackingOn == false {
            acct.trackingOn = true
            tOn = true
            acct.saveXMPPAccountAsync()
            self.waitingForPermission = false
        }
        
        if tOn == true {
            self.trackingOn = true
            if let intval = acct?.trackingInterval {
                self.updateSeconds = Double(intval)
            }
            self.dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            self.locationManager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Adjust location update frequency based on user activity
        let currentLocation = locations.last

        //handle updates for chat
        //for locDel in self.locationDelegates {
        //    locDel.locationUpdated(currentLocation)
        //}

        // Handle location updates
        if trackingEnabled, trackingOn {
            handleLocationUpdate(currentLocation)
        }
    }

    private func userIsStationary(_ location: CLLocation?) -> Bool {
        // Your logic to determine if the user is stationary
        // For example, check if speed is below a certain threshold
        return location?.speed ?? 0 < 0.5
    }

    private func handleLocationUpdate(_ location: CLLocation?) {
        
        if self.username == nil {
            if let glacierDefaults = UserDefaults.init(suiteName: kGlacierGroup) {
                if let userstr = glacierDefaults.string(forKey: "username") {
                    let userjid = XMPPJID(string: userstr)
                    self.username = userjid?.user
                }
                
                self.organization = glacierDefaults.string(forKey: "orgid")
                if let devid = UIDevice.current.identifierForVendor?.uuidString, let username = self.username {
                    self.deviceId = username + "_" + devid
                }
            }
        }
        
        if let location = location, let org = self.organization, let username = self.username, let deviceId = self.deviceId {
            lastLocation = location
            
            if self.isTimeToSend() {
                let locData = LocationData()
                locData.latitude = self.lastLocation.coordinate.latitude
                locData.longitude = self.lastLocation.coordinate.longitude
                
                let dateString = dateFormatter.string(from: Date())
                let lastupdated = dateString
                
                locData.timestamp = lastupdated
                locData.device_id = deviceId
                locData.username = username
                locData.organization = org
                self.sendLocationData(locData) //locJson
                self.lastUpdated = Date()
            }
        }
    }
    
    private func isTimeToSend() -> Bool {
        let sinceUpdated = abs(self.lastUpdated.timeIntervalSinceNow)
        if sinceUpdated >= self.updateSeconds {
            return true
        }
        return false
    }
    
    func sendLocationData(_ locData: LocationData) {
        Task { [weak self] in
            guard let self = self else { return }
            guard let headers = await GlacierAPIHeaders.authHeaders() else { return }
            self.internalQueue.async {
                self.sessionManager.request(LocationManager.SEND_TRACKING_URL, method: .post, parameters: [
                    "coordinates": [
                        "latitude": locData.latitude,
                        "longitude": locData.longitude],
                    "timestamp": locData.timestamp!,
                    "device_id": locData.device_id!,
                    "username": locData.username!,
                    "organization": locData.organization!
                ], encoding: JSONEncoding.default, headers: headers)
                    .validate()
                    .responseData(queue: self.internalQueue) { response in
                        switch response.result {
                        case .success(_):
                            return
                        case .failure(let error):
                            DDLogError("Error sending location data: \(error)")
                            return
                        }
                    }
            }
        }
    }
    
    @objc public class func shared() -> LocationManager {
        return sharedLocationMgr
    }
}

public class LocationData:NSObject, Codable {
    var latitude: Double?
    var longitude: Double?
    var timestamp: String?
    var device_id: String?
    var username: String?
    var organization: String?
}
