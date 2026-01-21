//
//  DBManager.swift
//  Glacier
//
//  Created by andyfriedman on 12/29/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import GRDB
import SAMKeychain
import Foundation

/// DBManager lets the application access the database.
///
/// It applies the pratices recommended at
/// <https://github.com/groue/GRDB.swift/blob/master/Documentation/GoodPracticesForDesigningRecordTypes.md>
@objc public class DBManager: Transactable {
    
    private static let shared = DBManager()
    
    private var _grdbStorage: DBStorageCoordinator?
    private var hasPendingCrossProcessWrite = false
    private var needsDataMigration = false
    //public var dbStatements = DBStatements()
#if !TARGET_IS_EXTENSION
    private var mediaServer: OTRMediaServer?
#endif
    
    @objc
    public static let didSetupDatabase = Notification.Name("didSetupGRDB")
    
    @objc public var grdbStorage: DBStorageCoordinator {
        if let storage = _grdbStorage {
            return storage
        } else {
            let storage = createGrdbStorage()
            _grdbStorage = storage
            return storage
        }
    }
    
    @objc public class func sharedDB() -> DBManager {
        return shared
    }
    
    @objc public class func setMigrateData() -> DBManager {
        return shared
    }
    
    override init() {
        do {
            // Crash if keychain is inaccessible or database can't be created
            try DBStorageCoordinator.ensureDatabaseKeySpecExists()
        } catch {
            fatalError("Cannot create GRDB: \(error)")
        }
        
        super.init()
        needsDataMigration = !DBStorageCoordinator.existsGlacierGRDB()
        let storage = grdbStorage
        
        DispatchQueue.global().async {
            self.runGrdbSchemaMigrationsOnMainDatabase(completion: { () in
                //alert app that migration completed
                DDLogInfo("ran Migrations")
#if !TARGET_IS_EXTENSION
                self.setupSharedSecureMediaStorage()
                //check if setup
                self.verifyMediaSetup()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DBManager.didSetupDatabase, object: self)
                }
                
                self.grdbStorage.setStorageFileProtections()
#endif
            })
        }
#if !TARGET_IS_EXTENSION
        addObservers()
#endif
    }
    
#if !TARGET_IS_EXTENSION
    private func verifyMediaSetup() {
        if OTRMediaServer.sharedInstance().hasFileSystem() == false {
            DBStorageCoordinator.removeMediaFiles()
            self.clearMediaKeychain()
            self.setupSharedSecureMediaStorage()
        }
    }
#endif
    
    func resetDB() {
        self.deleteGrdbFiles()
        self.clearMediaKeychain()
        DBStorageCoordinator.clearStoredPassword()
        do {
            // Crash if keychain is inaccessible or database can't be created
            try DBStorageCoordinator.ensureDatabaseKeySpecExists()
        } catch {
            fatalError("Cannot create KeySpec: \(error)")
        }
        
        _grdbStorage = nil
        _ = grdbStorage
        
        DispatchQueue.global().async {
            self.runGrdbSchemaMigrationsOnMainDatabase(completion: { () in
                //alert app that migration completed
                DDLogInfo("ran Migrations")
                self.setupSharedSecureMediaStorage()
#if !TARGET_IS_EXTENSION
                self.verifyMediaSetup()
#endif
                /*DispatchQueue.main.async {
                    NotificationCenter.default.post(name: DBManager.didSetupDatabase, object: self)
                }*/
            })
        }
    }
    
    private func setupSharedSecureMediaStorage() {
#if !TARGET_IS_EXTENSION
        var samerror: NSError?
        var password = SAMKeychain.password(forService: kGlacierServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &samerror)
        var saltdata = SAMKeychain.passwordData(forService: kGlacierMediaSalt, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &samerror)
        
        var path = DBStorageCoordinator.sharedGlacierMediaPath()
        var salt = saltdata?.hexEncodedString()
        
        if salt == nil || password == nil {
            password = SAMKeychain.password(forService: kGlacierServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &samerror)
            saltdata = SAMKeychain.passwordData(forService: kGlacierMediaSalt, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &samerror)
            
            if DBStorageCoordinator.existsGlacierMediaDB() == false {
                if let data = SAMKeychain.passwordData(forService: kGlacierKeySpec, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: nil) {
                    let datastr = data.hexEncodedString()
                    if datastr.count == DBStorageCoordinator.kSQLCipherKeySpecLength*2 {
                       // var index = datastr.index(strH.startIndex, offsetBy: 64)
                        //datastr.substring(from: range.)
                        if password == nil {
                            password = String(datastr.prefix(64))
                            if let passwd = password {
                                var error: NSError?
                                let result = SAMKeychain.setPassword(passwd, forService: kGlacierServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &error)
                            }
                        }
                        
                        if salt == nil {
                            salt = String(datastr.dropFirst(64))
                            if let saltstr = salt {
                                var error: NSError?
                                if let saltdata = (saltstr as NSString).dataFromHex() {
                                    let result = SAMKeychain.setPasswordData(saltdata, forService: kGlacierMediaSalt, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: &error)
                                }
                            }
                        }
                    }
                    
                }
            }
            //if server doesn't exist, create new password and/or salt data
        }
        
        if salt != nil, let nonopsalt = salt {
            salt = "\"x'" + nonopsalt + "'\";"
        } else if let saltdata = saltdata {
            salt = "\"x'" + saltdata.hexEncodedString() + "'\";"
        }
        
        guard let password = password, let path = path, let salt = salt else {
            fatalError("Couldnt setup media server")
            return
        }
        
        let success = OTRMediaFileManager.sharedInstance().setup(withPath: path, password: password, salt: salt)
        
        self.mediaServer = OTRMediaServer.sharedInstance()
        if self.mediaServer?.isRunning() == false {
            do {
                try self.mediaServer?.start(onPort: 0)
            } catch {}
            if self.mediaServer?.isRunning() == false {
                DDLogError("Error starting media server");
            }
        }
#endif
    }
    
    private func clearMediaKeychain() {
        var error: NSError?
        if SAMKeychain.password(forService: kGlacierServiceName, account: GlacierMediaPassphraseName, accessGroup:kGlacierKeyGroup, error: &error) != nil {
            SAMKeychain.deletePassword(forService: kGlacierServiceName, account: GlacierMediaPassphraseName, accessGroup: kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting DB password from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
        
        if SAMKeychain.passwordData(forService: kGlacierMediaSalt, account: GlacierMediaPassphraseName, accessGroup:kGlacierKeyGroup, error: &error) != nil {
            SAMKeychain.deletePassword(forService: kGlacierMediaSalt, account: GlacierMediaPassphraseName, accessGroup:kGlacierKeyGroup, error: nil)
        }
        if let error = error {
            DDLogError("Error deleting media DB salt from keychain: \(error.localizedDescription) \(error.userInfo)")
        }
    }
    
    private func addObservers() {
            // Cross process writes
        /*crossProcess.callback = { [weak self] in
            DispatchQueue.main.async {
                self?.handleCrossProcessWrite()
            }
        }*/
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name:UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    func createGrdbStorage() -> DBStorageCoordinator {
        return DBStorageCoordinator()
    }

    @objc public func deleteGrdbFiles() {
        DBStorageCoordinator.removeAllFiles()
    }

    @objc public func resetAllStorage() {
        //DBStorageCoordinator.resetAllStorage()
    }
    
    // completion is performed on the main queue.
    @objc public func runGrdbSchemaMigrationsOnMainDatabase(completion: @escaping () -> Void) {
        let didPerformIncrementalMigrations: Bool = {
            do {
                return try DBSchemaCoordinator.migrateDatabase(
                    databaseStorage: grdbStorage,
                    isMainDatabase: true
                )
            } catch {
                //DatabaseCorruptionState.flagDatabaseCorruptionIfNecessary(
                //    userDefaults: CurrentAppContext().appUserDefaults(),
                //    error: error
                //)
                fatalError("Database migration failed. Error: \(error.grdbErrorForLogging)")
            }
        }()

        DDLogInfo("didPerformIncrementalMigrations: \(didPerformIncrementalMigrations)")

        if didPerformIncrementalMigrations {
            reopenGRDBStorage(completion: completion)
        } else {
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    public func reopenGRDBStorage(completion: @escaping () -> Void = {}) {
        // There seems to be a rare issue where at least one reader or writer
        // (e.g. SQLite connection) in the GRDB pool ends up "stale" after
        // a schema migration and does not reflect the migrations.
        grdbStorage.pool.releaseMemory()
        _grdbStorage = createGrdbStorage()

        DispatchQueue.main.async {
            completion()
        }
    }

    
    @objc func didBecomeActive() {
        //AssertIsOnMainThread()

        //guard hasPendingCrossProcessWrite else {
        //    return
        //}
        //hasPendingCrossProcessWrite = false

        //postCrossProcessNotificationActiveAsync()
    }
    
    private func handleCrossProcessWrite() {
        //AssertIsOnMainThread()

        //guard CurrentAppContext().isMainApp else {
        //    return
        //}

        // Post these notifications always, sync.
        NotificationCenter.default.post(name: DBManager.didReceiveCrossProcessNotificationAlwaysSync, object: nil, userInfo: nil)

        // Post these notifications async and defer if inactive.
        //if Application.shared.applicationState == .active {
        //if CurrentAppContext().isMainAppAndActive {
            // If already active, update immediately.
            postCrossProcessNotificationActiveAsync()
        //} else {
            // If not active, set flag to update when we become active.
            //hasPendingCrossProcessWrite = true
        //}
    }

    @objc
    public static let didReceiveCrossProcessNotificationActiveAsync = Notification.Name("didReceiveCrossProcessNotificationActiveAsync")
    @objc
    public static let didReceiveCrossProcessNotificationAlwaysSync = Notification.Name("didReceiveCrossProcessNotificationAlwaysSync")

    private func postCrossProcessNotificationActiveAsync() {
        // TODO: The observers of this notification will inevitably do
        //       expensive work.  It'd be nice to only fire this event
        //       if this had any effect, if the state of the database
        //       has changed.
        //
        //       In the meantime, most (all?) cross process write notifications
        //       will be delivered to the main app while it is inactive. By
        //       de-bouncing notifications while inactive and only updating
        //       once when we become active, we should be able to effectively
        //       skip most of the perf cost.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: DBManager.didReceiveCrossProcessNotificationActiveAsync, object: nil)
        }
    }

    // MARK: - Transactable

    public override func read(file: String = #file,
                              function: String = #function,
                              line: Int = #line,
                              block: (GRDBReadTransaction) -> Void) {
        //InstrumentsMonitor.measure(category: "db", parent: "read", name: Self.owsFormatLogMessage(file: file, function: function, line: line)) {
            do {
                try grdbStorage.read { transaction in
                    block(transaction)
                }
            } catch {
                fatalError("error: \(error.grdbErrorForLogging)")
            }
        //}
    }

    @objc(readWithBlock:)
    public func readObjC(block: (GRDBReadTransaction) -> Void) {
        read(file: "objc", function: "block", line: 0, block: block)
    }

    @objc(readWithBlock:file:function:line:)
    public func readObjC(block: (GRDBReadTransaction) -> Void, file: UnsafePointer<CChar>, function: UnsafePointer<CChar>, line: Int) {
        read(file: String(cString: file), function: String(cString: function), line: line, block: block)
    }

    // NOTE: This method is not @objc. See SDSDatabaseStorage+Objc.h.
    public override func write(file: String = #file,
                               function: String = #function,
                               line: Int = #line,
                               block: (GRDBWriteTransaction) -> Void) {
        #if TESTABLE_BUILD
        if Thread.isMainThread &&
            AppReadiness.isAppReady {
            Logger.warn("Database write on main thread.")
        }
        #endif

        //let benchTitle = "Slow Write Transaction \(Self.owsFormatLogMessage(file: file, function: function, line: line))"
        //let timeoutThreshold = DebugFlags.internalLogging ? 0.1 : 0.5

        //InstrumentsMonitor.measure(category: "db", parent: "write", name: Self.owsFormatLogMessage(file: file, function: function, line: line)) {
            do {
                try grdbStorage.write { transaction in
                    //Bench(title: benchTitle, logIfLongerThan: timeoutThreshold, logInProduction: true) {
                        block(transaction)
                    //}
                }
            } catch {
                fatalError("error: \(error.grdbErrorForLogging)")
            }
        //}
        //crossProcess.notifyChangedAsync()
    }
    
    /// Provides access to the database.
    ///
    /// Application can use a `DatabasePool`, and tests can use a fast
    /// in-memory `DatabaseQueue`.
    ///
    /// See <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections>
    //private let dbWriter: any DatabaseWriter
}

#if !TARGET_IS_EXTENSION
extension DBManager {
    @objc public static func deleteAll() {
        DBManager.sharedDB().grdbStorage.asyncWrite(block: { transaction in
            do {
                try SMSChatAccount.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SMSChatAccount.removeAll: \(error)")
            }
            
            do {
                try SMSChatConversation.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SMSChatConversation.removeAll: \(error)")
            }
            
            do {
                try SMSChatMessage.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SMSChatMessage.removeAll: \(error)")
            }
            
            do {
                try SMSChatMediaItem.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SMSChatMediaItem.removeAll: \(error)")
            }
            
            do {
                try ChatPreKey.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SignalPreKey.removeAll: \(error)")
            }
            
            do {
                try ChatSenderKey.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SignalSenderKey.removeAll: \(error)")
            }
            
            do {
                try ChatSignedPreKey.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SignalSignedPreKey.removeAll: \(error)")
            }
            
            do {
                try ChatSignalSession.deleteAll(transaction.database)
            } catch {
                DDLogDebug("SignalSession.removeAll: \(error)")
            }
            
            do {
                try ChatAccountSignalIdentity.deleteAll(transaction.database)
            } catch {
                DDLogDebug("AccountSignalIdentity.removeAll: \(error)")
            }
            
            do {
                try ChatRoomOccupant.deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatRoomOccupant.removeAll: \(error)")
            }
            
            do {
                try ChatRoomMessage.deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatRoomMessage.deleteAll: \(error)")
            }
            
            do {
                try ChatRoom.deleteAll(transaction.database)
            } catch {
                DDLogDebug("XMPPRoom.removeAll: \(error)")
            }
            
            do {
                try ChatBuddy.deleteAll(transaction.database)
            } catch {
                DDLogDebug("XMPPBuddy.removeAll: \(error)")
            }
            
            do {
                try ChatMediaItem.deleteAll(transaction.database)
            } catch {
                DDLogDebug("MediaItem.removeAll: \(error)")
            }
            
            do {
                try ChatMessage.deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatMessage.deleteAll: \(error)")
            }
            
            do {
                try ChatOmemoDevice.deleteAll(transaction.database)
            } catch {
                DDLogDebug("OMEMODevice.removeAll: \(error)")
            }
            
            do {
                try ChatAccount.deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatAccount.removeAll: \(error)")
            }
            
            do {
                try ChatThread.deleteAll(transaction.database)
            } catch {
                DDLogDebug("ChatThread.removeAll: \(error)")
            }
        })
    }
}
#endif
