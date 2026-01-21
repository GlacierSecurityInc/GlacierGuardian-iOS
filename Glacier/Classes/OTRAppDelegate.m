//
//  OTRAppDelegate.m
//  Off the Record
//
//  Created by Chris Ballinger on 8/11/11.
//  Copyright (c) 2011 Chris Ballinger. All rights reserved.
//
//  This file is part of ChatSecure.
//
//  ChatSecure is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ChatSecure is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ChatSecure.  If not, see <http://www.gnu.org/licenses/>.

#import "OTRAppDelegate.h"

#import "OTRSettingsViewController.h"
#import "OTRSettingsManager.h"

#import "OTRConstants.h"

#import "OTRUtilities.h"
@import SAMKeychain;

#import "OTRLog.h"
@import CocoaLumberjack;

#import "OTRCertificatePinning.h"
#import "NSURL+ChatSecure.h"
#import "OTRPasswordGenerator.h"
#import "UIViewController+ChatSecure.h"
@import XMPPFramework;
#import "OTRProtocolManager.h"
#import "Glacier-Swift.h"
#import "UITableView+ChatSecure.h"
@import UserNotifications;
@import BackgroundTasks; //IOSM#88
@import MBProgressHUD;

@interface OTRAppDelegate ()

@property (nonatomic, strong) OTRSplitViewControllerDelegateObject *splitViewControllerDelegate;
@property (nonatomic, strong) OTRSplitViewControllerDelegateObject *splitViewSMSControllerDelegate;

// test to see if we can get to server before attempting login
@property (assign, nonatomic) BOOL enteringForeground;
@property (nonatomic, readwrite) OTRNetworkConnectionStatus networkStatus;

@property (assign, nonatomic) BOOL bypass;
//@property (nonatomic, strong, readwrite) NSDate *lastOnline;
@property (nonatomic, strong) NSString * domainAddress; //IOSM-552

@property (nonatomic, strong) PKPushRegistry *voipRegistry;

@property UIBackgroundTaskIdentifier backgroundUpdateTask; //IOSM#80
@property (nonatomic) dispatch_source_t backgroundUpdateTimer;
@property (assign, nonatomic) BOOL rebootReminder;
@property (assign, nonatomic) BOOL proxyDetected;

//IOSM#88
@property BGTask *backgroundRefreshTask;
@property (assign, nonatomic) BOOL secUpdatesEnabled;

@property (assign, nonatomic) BOOL isGroupController;
@property (nonatomic, strong) MBProgressHUD *hud;

@property (nonatomic, strong) SMSViewController *smsViewControllerStorage;
@property (nonatomic, strong) UINavigationController *securityHubViewControllerStorage;
@property (nonatomic, strong) UINavigationController *dialerViewControllerStorage;
@property (nonatomic, strong) UINavigationController *contactsViewControllerStorage;
@property (nonatomic, strong) UINavigationController *historyViewControllerStorage;

@end

@implementation OTRAppDelegate
@synthesize window = _window;
NSString *const SMSEnabledNotificationName = @"SMSEnabledNotificationName";
NSString *const NetworkStatusNotificationName = @"NetworkStatusNotificationName";
NSString *const OldNetworkStatusKey = @"OldNetworkStatusKey";
NSString *const NewNetworkStatusKey = @"NewNetworkStatusKey";

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    //[LogManager.shared setupLogging];
    //[self setupCrashReporting];
    
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];
    
    UIViewController *mainRootViewController = nil;
    //[DBStorageCoordinator removeAllFiles]; //just for now to reset every time
    [DDLog addLogger:[DDTTYLogger sharedInstance]]; //doesn't print to system console
    //[DDLog addLogger:[DDOSLogger sharedInstance]];
    
    self.amplifyIsConfigured = NO;
    [self setupAmplify];

    if ([OTRAppDelegate isTestFlight]) {
        [[MetricKitDiagnostics shared] start];
    }
    
    // Create 3 primary view controllers, settings, conversation list and messages
    _conversationViewController = [GlobalTheme.shared conversationViewController];
    _chatViewController = [GlobalTheme.shared chatViewController];
    _chatRoomViewController = [GlobalTheme.shared chatRoomViewController];
    
    mainRootViewController = [self setupDefaultSplitViewControllerWithLeadingViewController:[[UINavigationController alloc] initWithRootViewController:self.conversationViewController]];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(whenDatabaseReady:) name:DBManager.didSetupDatabase object:nil];
    if (UIApplication.sharedApplication.isProtectedDataAvailable) {
        [DBManager sharedDB];
    } else {
        DDLogWarn(@"Protected data unavailable at launch. Deferring database initialization until device is unlocked.");
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleProtectedDataAvailable:)
                                                     name:UIApplicationProtectedDataDidBecomeAvailable
                                                   object:nil];
        if (UIApplication.sharedApplication.isProtectedDataAvailable) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
            [DBManager sharedDB];
        }
    }
    
    self.doubleDone = NO; // handle double notifications on login
    self.groupReadReady = NO;
    self.bypass = YES;
    self.silentUpdate = NO;
    self.voipNotification = NO;
    self.secUpdatesEnabled = NO;
    self.smsEnabled = NO; //IOSM#90
    self.isGroupController = NO;
    self.rebootReminder = YES;
    self.backgroundUpdateTask = UIBackgroundTaskInvalid;
    self.backgroundUpdateTimer = nil;
    
    self.resortNeeded = NO;
    self.handledCallIDs = [NSMutableSet set];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkConnectionStatusChange:) name:NetworkStatusNotificationName object:nil];
    self.enteringForeground = YES;
    
    if (UIApplication.sharedApplication.isProtectedDataAvailable) {
        [self setDomainIfAvailable];
        [self checkConnectionOrTryLogin];
        [_conversationViewController doSecurityCheck:NO]; //IOSM#19
    }
    
    //IOSM#90
    UINavigationController *smsNavController = [[UINavigationController alloc] initWithRootViewController:self.smsViewController];
    [self setupSMSSplitViewControllerWithLeadingViewController:smsNavController];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = mainRootViewController;
    [self.window makeKeyAndVisible];
    
    // For disabling screen dimming while plugged in
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryStateDidChange:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self batteryStateDidChange:nil];
    
    //IOSM#88
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:kBgTaskId usingQueue:nil launchHandler:^(BGTask *task){
        //[self beginScheduledRefresh:task];
    }];
    //[self scheduleAppRefresh]; //change this to schedule only if we see that securityHubEnabled
    
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:kBgRebootTaskId usingQueue:nil launchHandler:^(BGTask *task){
        [self beginRebootReminder:task];
    }];
    [self scheduleRebootReminder];
    
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    
    [self registerVoIPNotifications];
    //IOSM-517 derivative commented out
    //[self performSelector:@selector(migrateAccountPassword:) withObject:nil afterDelay:8.0];
    
    NSDictionary *notification = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
    if (notification)
    {
        DDLogInfo(@"Application was dead and woke with notification.");
    }
    
    return YES;
}

- (void)handleProtectedDataAvailable:(NSNotification *)notification
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
    if (UIApplication.sharedApplication.isProtectedDataAvailable) {
        [DBManager sharedDB];
        [self setDomainIfAvailable];
        [self checkConnectionOrTryLogin];
        [_conversationViewController doSecurityCheck:NO]; //IOSM#19
    }
}

- (SMSViewController *)smsViewController {
    if (self.smsViewControllerStorage == nil) {
        self.smsViewControllerStorage = [[SMSViewController alloc] init];
    }
    return self.smsViewControllerStorage;
}

- (UINavigationController *)securityHubViewController {
    if (self.securityHubViewControllerStorage == nil) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"SecurityCenter" bundle:[GlacierInfo resourcesBundle]];
        SecurityCenterViewController *secHubVC = [storyboard instantiateViewControllerWithIdentifier:@"securityCenter"];
        self.securityHubViewControllerStorage = [[UINavigationController alloc] initWithRootViewController:secHubVC];
        self.securityHubViewControllerStorage.navigationBar.barTintColor = UIColor.labelColor;
    }
    return self.securityHubViewControllerStorage;
}

- (UINavigationController *)dialerViewController {
    if (self.dialerViewControllerStorage == nil) {
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        DialerViewController *dialerVC = [[DialerViewController alloc] initWithCollectionViewLayout:layout];
        [dialerVC doInitStuff];
        self.dialerViewControllerStorage = [[UINavigationController alloc] initWithRootViewController:dialerVC];
        self.dialerViewControllerStorage.navigationBar.barTintColor = UIColor.labelColor;
    }
    return self.dialerViewControllerStorage;
}

- (UINavigationController *)contactsViewController {
    if (self.contactsViewControllerStorage == nil) {
        ContactsViewController *contactsVC = [[ContactsViewController alloc] init];
        self.contactsViewControllerStorage = [[UINavigationController alloc] initWithRootViewController:contactsVC];
        self.contactsViewControllerStorage.navigationBar.barTintColor = UIColor.labelColor;
    }
    return self.contactsViewControllerStorage;
}

- (UINavigationController *)historyViewController {
    if (self.historyViewControllerStorage == nil) {
        HistoryViewController *historyVC = [[HistoryViewController alloc] init];
        self.historyViewControllerStorage = [[UINavigationController alloc] initWithRootViewController:historyVC];
        self.historyViewControllerStorage.navigationBar.barTintColor = UIColor.labelColor;
    }
    return self.historyViewControllerStorage;
}

- (void) whenDatabaseReady:(NSNotification*)notification {
    //if hud, remove
    if (self.hud) {
        [self.hud removeFromSuperview];
    }
    
    [self setDomainIfAvailable];
    //[self checkConnectionOrTryLogin];
    [_conversationViewController handleDatabaseInitialization];
    [_conversationViewController doSecurityCheck:NO]; //IOSM#19
    [[TwilioBackendManager sharedMgr] queryForNumbers]; //IOSM#76
    [self checkConnectionOrTryLogin];
}

- (void) doSettingsController {
    if (_settingsViewController == nil && [ChatAccountModel allAutoLoginAccounts].count > 0) {
        _settingsViewController = [GlobalTheme.shared settingsViewController];
    }
}

// tries to open Glacier Voice or notifies user if can't
- (void) goGlacierVoice {
    if (![self tryOpenURL:[NSURL URLWithString:@"glaciervoice://"]]) {
        UIAlertAction *ok = [UIAlertAction actionWithTitle:OK_STRING() style:UIAlertActionStyleDefault handler:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Glacier Voice not installed" message:@"Install Glacier Voice from the App Store" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:ok];
        [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
    }
}

- (void) registerVoIPNotifications {
    self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:nil];
    self.voipRegistry.delegate = self;
    self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
    
    NSData *pushData = [self.voipRegistry pushTokenForType:PKPushTypeVoIP];
    if (pushData != nil) {
        [self handleVoipPushToken:pushData];
    }
}

/**
 * This creates a UISplitViewController using a leading view controller (the left view controller). It uses a navigation controller with
 * self.messagesViewController as teh right view controller;
 * This also creates and sets up teh OTRSplitViewCoordinator
 *
 * @param leadingViewController The leading or left most view controller in a UISplitViewController. Should most likely be some sort of UINavigationViewController
 * @return The base default UISplitViewController
 *
 */
- (UIViewController *)setupDefaultSplitViewControllerWithLeadingViewController:(nonnull UIViewController *)leadingViewController
{
    _splitViewCoordinator = [[OTRSplitViewCoordinator alloc] init];
    self.splitViewControllerDelegate = [[OTRSplitViewControllerDelegateObject alloc] init];
    self.conversationViewController.delegate = self.splitViewCoordinator;
    
    //MessagesViewController Nav
    //self.messagesViewController.hidesBottomBarWhenPushed = YES;
    UINavigationController *messagesNavigationController = [[UINavigationController alloc ]initWithRootViewController:self.chatViewController];
    //[messagesNavigationController setCustomBackButton];
    //messagesNavigationController.hidesBottomBarWhenPushed = YES;
    
    //SplitViewController
    UISplitViewController *splitViewController = [[UISplitViewController alloc] init];
    splitViewController.viewControllers = @[leadingViewController,messagesNavigationController];
    splitViewController.delegate = self.splitViewControllerDelegate;
    splitViewController.title = CHAT_STRING();
    splitViewController.presentsWithGesture = NO; //ALF IOSM-496
    splitViewController.displayModeButtonItem.enabled = NO;
    splitViewController.view.backgroundColor = UIColor.systemBackgroundColor;
    
    //splitViewController.hidesBottomBarWhenPushed = YES;
    //splitViewController.navigationController.hidesBottomBarWhenPushed = YES;
    
    // for preferred iPad views
    //splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModePrimaryOverlay;
    splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    
    //setup 'back' button in nav bar
    messagesNavigationController.topViewController.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem;
    messagesNavigationController.topViewController.navigationItem.leftItemsSupplementBackButton = YES;
    
    self.splitViewCoordinator.splitViewController = splitViewController;
    
    return splitViewController;
}

//IOSM#76
- (UIViewController *)setupSMSSplitViewControllerWithLeadingViewController:(nonnull UIViewController *)leadingViewController
{
    _smsSplitViewCoordinator = [[SMSSplitViewCoordinator alloc] init];
    self.splitViewSMSControllerDelegate = [[OTRSplitViewControllerDelegateObject alloc] init];
    self.smsViewController.delegate = self.smsSplitViewCoordinator;
    _smsMessagesViewController = [[SMSChatViewController alloc] init];
    
    //MessagesViewController Nav
    UINavigationController *smsMessagesNavigationController = [[UINavigationController alloc] initWithRootViewController:self.smsMessagesViewController];
    
    //SplitViewController
    UISplitViewController *splitViewController = [[UISplitViewController alloc] init];
    splitViewController.viewControllers = @[leadingViewController,smsMessagesNavigationController];
    splitViewController.delegate = self.splitViewSMSControllerDelegate;
    splitViewController.title = @"SMS";
    splitViewController.presentsWithGesture = NO; //ALF IOSM-496
    splitViewController.displayModeButtonItem.enabled = NO;
    splitViewController.view.backgroundColor = UIColor.systemBackgroundColor;
    
    // for preferred iPad views
    splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    
    //setup 'back' button in nav bar
    smsMessagesNavigationController.topViewController.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem;
    smsMessagesNavigationController.topViewController.navigationItem.leftItemsSupplementBackButton = YES;
    
    self.smsSplitViewCoordinator.splitViewController = splitViewController;
    
    return splitViewController;
}

//IOSM#76
- (void) setSMSEnabled:(BOOL)enabled {
    //IOSM#90
    if ((enabled && !self.smsEnabled) || (!enabled && self.smsEnabled)) {
        //send notification to listeners
        self.smsEnabled = enabled;
        NSLog(@"***** setSMSEnabled %@", (enabled) ? @"YES" : @"NO");
        
        NSArray<ChatAccountModel*> *accounts = [ChatAccountModel allXMPPAccounts];
        if (accounts.count > 0) {
            ChatAccountModel *acct = accounts.firstObject;
            acct.smsEnabled = enabled;
            [acct saveXMPPAccountAsync];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SMSEnabledNotificationName object:self userInfo:nil];
        });
    }
}

/*- (void)showConversationViewController
 {
 self.window.rootViewController = [self setupDefaultSplitViewControllerWithLeadingViewController:[[UINavigationController alloc] initWithRootViewController:self.conversationViewController]];
 }*/

- (void)applicationWillResignActive:(UIApplication *)application
{
    [OTRAppDelegate setLastInteractionDate:NSDate.date];
    [self updateSharedAppActiveState:NO];
    
    /*
     Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
     Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
     */
    
    // for Splash/Privacy page
    if ([self hasAddress]) { //ALF IOSM-500
        self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        
        // creates a "privacy" screen, showing splash screen when backgrounded
        UIView *splashUiView = [[[NSBundle mainBundle] loadNibNamed:@"LaunchMsgr" owner:self options:nil] objectAtIndex:0];
        splashUiView.frame = [[UIScreen mainScreen] bounds];
        
        splashUiView.tag = 12345;
        [self.window addSubview:splashUiView];
        [self.window bringSubviewToFront:splashUiView];
        
        // fade in the view
        [UIView animateWithDuration:0.5 animations:^{
            splashUiView.alpha = 1;
        }];
    }
}

- (void)setProxyDetected:(BOOL)detected
{
    if (_proxyDetected == detected) {
        return;
    }
    _proxyDetected = detected;
    [AWSAcctManager.sharedMgr setProxyDetected:detected];
    [CallManager.sharedCallManager setProxyDetected:detected];
    
    if (detected) {
        ChatAccountModel *account = [ChatAccountModel firstAccount];
        if (account != nil && [[OTRProtocolManager sharedInstance] isAccountIdConnected:account.uniqueId]) {
            [[OTRProtocolManager sharedInstance] disconnectAllAccounts];
        }
    } else {
        ChatAccountModel *account = [ChatAccountModel firstAccount];
        if (account != nil && [[OTRProtocolManager sharedInstance] isAccountIdConnected:account.uniqueId] == NO) {
            if (self.enteringForeground || [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                [self autoLoginFromBackground:NO];
            }
        }
    }
}

- (void)finishedConnecting {
    if (_proxyDetected) {
        [[OTRProtocolManager sharedInstance] disconnectAllAccounts];
    }
}

- (BOOL)isProxyDetected
{
    return _proxyDetected;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [self updateSharedAppActiveState:NO];
    [self beginBackgroundUpdateTask]; //IOSM#80
    
    self.enteringForeground = NO;
    self.doubleDone = NO;
    self.groupReadReady = NO;
    self.silentUpdate = NO;
    self.voipNotification = NO;
    
    self.resortNeeded = NO;
    
    [self unreadMessageCountWithCompletion:^(NSInteger unread){
        application.applicationIconBadgeNumber = unread;
    }];
    
    // logout when backgrounded. Push notifications should then occur with messages
    //[[OTRProtocolManager sharedInstance] disconnectAllAccounts];
    [[OTRProtocolManager sharedInstance] goAwayForAllAccounts]; //IOSM#80
}

// allows us to check if network is available
- (void)setDomain:(NSString *)address {
    [self setAddress:address];
}

- (void)bypassNetworkCheck:(BOOL)bypass {
    self.bypass = bypass;
}

- (BOOL) tryOpenURL:(NSURL*)url {
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return YES;
    }
    return NO;
}

- (void) networkConnectionStatusChange:(NSNotification*)notification {
    /*_networkStatus = [notification.userInfo[NewNetworkStatusKey] integerValue];
     if (_networkStatus == OTRNetworkConnectionStatusConnecting || _networkStatus == OTRNetworkConnectionStatusUnknown || _networkStatus == OTRNetworkConnectionStatusDisconnected) {
     return;
     }*/
    
    if (self.enteringForeground || [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [self autoLoginFromBackground:NO];
    }
}

//IOSM-552 commented out
/*- (OTRNetworkConnectionStatus) getCurrentNetworkStatus {
 return OTRNetworkConnectionStatusConnected;
 //return _networkStatus;
 }*/


/** Doesn't stop autoLogin if previous crash when it's a background launch */
- (void)autoLoginFromBackground:(BOOL)fromBackground
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.proxyDetected) {
            return;
        }
        NSArray *autoaccts = [ChatAccountModel allAutoLoginAccounts];
        if (autoaccts && autoaccts.count > 0) {
            [[OTRProtocolManager sharedInstance] loginAccounts:autoaccts];
            [PushController registerForPushNotifications];
        } else if ([self hasAddress]){
            [_conversationViewController tryGlacierGroupAccount];
        }
    });
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    
    self.enteringForeground = YES;
    //autoLoginFromBackground
    
    if (self.backgroundUpdateTask != UIBackgroundTaskInvalid) { //IOSM#80
        DDLogInfo(@"**** Application entering foreground, stopping background task");
        [self cancelBackgroundUpdateTimer];
        [[UIApplication sharedApplication] endBackgroundTask: self.backgroundUpdateTask];
        self.backgroundUpdateTask = UIBackgroundTaskInvalid;
    }
    
    [_conversationViewController doSecurityCheck:NO]; //IOSM#19
    [[TwilioBackendManager sharedMgr] queryForNumbers]; //IOSM#76
    [[TwilioBackendManager sharedMgr] queryForVMInfo]; //IOSM#76
    [self checkConnectionOrTryLogin];
}

// call just before checkConnectionOrTryLogin
- (void) setDomainIfAvailable {
    NSArray *accounts = [ChatAccountModel allAutoLoginAccounts];
    [accounts enumerateObjectsUsingBlock:^(ChatAccountModel * xact, NSUInteger idx, BOOL *stop) {
        [self setDomain:xact.domain];
        [self bypassNetworkCheck:xact.bypassNetworkCheck];
    }];
}

// if there is a domain address, see if we can reach the server before attempting login
- (void) checkConnectionOrTryLogin {
    //this only calls autoLoginFromBackground on enteringForeground, not needed I think
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:NetworkStatusNotificationName object:nil userInfo:nil];
    });
    
    //called in networkConnectionStatusChange from the post commented out above
    //[self autoLoginFromBackground:NO];
}

//IOSM-552 (next 2)
- (BOOL)hasAddress {
    if (self.domainAddress) {
        return YES;
    }
    
    return NO;
}

- (void)setAddress:(NSString *)address{
    self.domainAddress = address;
}

// remove the privacy screen
- (void) removeSplashView {
    UIView *splashView = [self.window viewWithTag:12345];
    if (splashView == nil) {
        self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary; //ALF IOSM-500
        return;
    }
    
    // fade away splash view from main view
    [UIView animateWithDuration:0.3 animations:^{
        splashView.alpha = 0;
    } completion:^(BOOL finished) {
        // remove when finished fading
        [splashView removeFromSuperview];
        
        // in case there are somehow more than one
        [self removeSplashView];
        self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary; //ALF IOSM-500
    }];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // remove the privacy screen
    [self removeSplashView];
    
    [OTRAppDelegate setLastInteractionDate:NSDate.date];
    [self batteryStateDidChange:nil];
    DDLogInfo(@"Application became active");
    [self updateSharedAppActiveState:YES];
    
    [UIApplication.sharedApplication removeExtraForegroundNotifications];
    
    self.doubleDone = NO;
    self.groupReadReady = NO;
    self.enteringForeground = NO;
    self.silentUpdate = NO;
    //self.voipNotification = NO;
    
    // allow app to login and receive existing messages before in-app notifications start
    [self performSelector:@selector(handleDoubleNotification:) withObject:nil afterDelay:15.0];
    [self performSelector:@selector(handleGroupReadReadyNotification:) withObject:nil afterDelay:5.0];
    [self performSelector:@selector(uploadMetricKitHangsIfNeeded) withObject:nil afterDelay:5.0];
}

- (void)updateSharedAppActiveState:(BOOL)isActive
{
    NSUserDefaults *glacierDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGlacierGroup];
    if (!glacierDefaults) {
        return;
    }
    [glacierDefaults setBool:isActive forKey:kGlacierAppIsActiveKey];
}

- (void) handleGroupReadReadyNotification:(id)sender //IOSM#8
{
    self.groupReadReady = YES;
}

- (void) handleDoubleNotification:(id)sender
{
    self.doubleDone = YES;
}

- (void) resetDoubleNotificationHandlerIfNeeded {
    //if (self.doubleDone) { //ALF IOSM-497 commented out
    self.doubleDone = NO;
    [self performSelector:@selector(handleDoubleNotification:) withObject:nil afterDelay:15.0];
}

- (void) resetSMS {
    self.smsEnabled = false;
    _smsMessagesViewController = nil;
    self.smsViewControllerStorage = nil;
    _smsSplitViewCoordinator = nil;
    UINavigationController *smsNavController = [[UINavigationController alloc] initWithRootViewController:self.smsViewController];
    [self setupSMSSplitViewControllerWithLeadingViewController:smsNavController];
    
    self.dialerViewControllerStorage = nil;
    (void)self.dialerViewController;
    
    self.contactsViewControllerStorage = nil;
    (void)self.contactsViewController;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    /*
     Called when the application is about to terminate.
     Save data if appropriate.
     See also applicationDidEnterBackground:.
     */
    
    [self updateSharedAppActiveState:NO];
    [[OTRProtocolManager sharedInstance] disconnectAllAccounts];
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *restorableObjects))restorationHandler {
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        NSURL *url = userActivity.webpageURL;
        if ([url otr_isInviteLink]) { //removed stuff
            return YES;
        }
    } else if ([userActivity.activityType isEqualToString:@"INStartVideoCallIntent"] || [userActivity.activityType isEqualToString:@"INStartCallIntent"]) {
        [[CallManager sharedCallManager] performVideoAction];
    }
    return NO;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    if ([url.scheme isEqualToString:@"xmpp"]) {
        XMPPURI *xmppURI = [[XMPPURI alloc] initWithURL:url];
        XMPPJID *jid = xmppURI.jid;
        if (jid) {
            return YES;
        }
    }
    return NO;
    // I think we only want this if no user exists or under certain conditions
    // maybe check what is in options?
    //return [[AWSCognitoAuth defaultCognitoAuth] application:app openURL:url options:options];
}

- (void) showSubscriptionRequestForBuddy:(NSDictionary*)userInfo {
    // This is probably in response to a user requesting subscriptions from us
    [self.splitViewCoordinator showConversationsViewController];
}

- (void)application:(UIApplication *)app didRegisterForRemoteNotificationsWithDeviceToken:(nonnull NSData *)deviceToken
{
    [OTRProtocolManager.pushController setPushToken:[deviceToken hexString]];
    [[TwilioBackendManager sharedMgr] setPushData:deviceToken];
}

- (void)application:(UIApplication *)app didFailToRegisterForRemoteNotificationsWithError:(NSError *)err {
    DDLogError(@"Error in registration. Error: %@%@", [err localizedDescription], [err userInfo]);
}

//IOSM#80
- (void)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler
{
    //NSLog(@"**** didReceiveRemoteNotification silent? com.apple.pushLaunch");
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        self.silentUpdate = YES;
        [self beginBackgroundUpdateTask];
        [self beginBackgroundFetch];
    }
    completionHandler(UIBackgroundFetchResultNewData);
}

// To improve usability, keep the app open when you're plugged in
- (void) batteryStateDidChange:(NSNotification*)notification {
    UIDeviceBatteryState currentState = [[UIDevice currentDevice] batteryState];
    if (currentState == UIDeviceBatteryStateCharging || currentState == UIDeviceBatteryStateFull) {
        [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    } else {
        [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    }
}

//IOSM#80 (next 2-3)
- (void) beginBackgroundUpdateTask
{
    //NSLog(@"**** Application beginBackgroundUpdateTask com.apple.pushLaunch");
    if (self.backgroundUpdateTask != UIBackgroundTaskInvalid) {
        [self endBackgroundUpdateTask];
    }
    
    //dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    self.backgroundUpdateTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self endBackgroundUpdateTask];
    }];
    //});
    
    [self scheduleBackgroundUpdateTaskExpiration];
}

- (void) endBackgroundUpdateTask
{
    //NSLog(@"**** Application endBackgroundUpdateTask com.apple.pushLaunch");
    if (self.backgroundUpdateTask == UIBackgroundTaskInvalid) {
        [self cancelBackgroundUpdateTimer];
        return;
    }
    
    [self cancelBackgroundUpdateTimer];
    UIBackgroundTaskIdentifier taskIdentifier = self.backgroundUpdateTask;
    self.backgroundUpdateTask = UIBackgroundTaskInvalid;
    //do the stuff I'd normally do on backgrounding
    self.silentUpdate = NO;
    [[OTRMediaServer sharedInstance] disconnectWebServer:^ {
        [[OTRProtocolManager sharedInstance] disconnectAllAccounts];
        [[UIApplication sharedApplication] endBackgroundTask:taskIdentifier];
        //NSLog(@"Background time remaining: %f seconds", [UIApplication sharedApplication].backgroundTimeRemaining);
    }];
}

- (void) scheduleBackgroundUpdateTaskExpiration
{
    [self cancelBackgroundUpdateTimer];
    
    NSTimeInterval delay = 25.0;
    NSTimeInterval remaining = UIApplication.sharedApplication.backgroundTimeRemaining;
    if (remaining > 0 && remaining < DBL_MAX) {
        NSTimeInterval preferredDelay = remaining - 5.0;
        if (preferredDelay > 0) {
            delay = MIN(preferredDelay, delay);
        } else {
            delay = 1.0;
        }
    }
    
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    self.backgroundUpdateTimer = timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (int64_t)(1 * NSEC_PER_SEC));
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf endBackgroundUpdateTask];
    });
    dispatch_resume(timer);
}

- (void) cancelBackgroundUpdateTimer
{
    if (self.backgroundUpdateTimer) {
        dispatch_source_cancel(self.backgroundUpdateTimer);
        self.backgroundUpdateTimer = nil;
    }
}

- (void) beginBackgroundFetch
{ //currently not being called from p2 in 0.9. But something is weird about this if that ever changes
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *autoaccts = [ChatAccountModel allAutoLoginAccounts];
        if (autoaccts && autoaccts.count > 0 && self.proxyDetected == NO) {
            OTRXMPPManager *xmppManager = [[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:autoaccts.firstObject];
            //NSLog(@"***** beginBackgroundFetch about to connect com.apple.pushLaunch");
            if (![xmppManager connectFromBackground]) {
                [self endBackgroundUpdateTask];
            }
        } else {
            [self endBackgroundUpdateTask];
        }
    });
}

//IOSM#88 (next 4)
- (void) beginScheduledRefresh:(BGTask*)task
{
    //NSLog(@"***** BGTaskScheduler beginScheduledRefresh");
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        self.backgroundRefreshTask = task;
        //[AWSAccountManager.shared setSecurityDelegate:self]; //reset when this is fixed
        __weak typeof(self) weakSelf = self;
        self.backgroundRefreshTask.expirationHandler = ^{
            //[AWSAccountManager.shared setSecurityDelegate:nil];
            [weakSelf.backgroundRefreshTask setTaskCompletedWithSuccess:NO];
        };
        //commented due to background crashing in AWSSQLLite
        //[_conversationViewController doSecurityCheck:YES];
        [task setTaskCompletedWithSuccess:YES]; //remove when this is fixed
    } else {
        [task setTaskCompletedWithSuccess:YES];
    }
    
    [self scheduleAppRefresh];
}

- (void) scheduleAppRefresh {
    if (!self.secUpdatesEnabled) {
        return;
    }
    
    // cancel existing task (if any)
    [BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:kBgTaskId];
    
    BGAppRefreshTaskRequest *refreshTaskRequest = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kBgTaskId];
    refreshTaskRequest.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:60*60*12]; //12 hours
    
    NSError *error;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:refreshTaskRequest error:&error]) {
        NSLog(@"BGTaskScheduler failed: %@", error);
    } else {
        //NSLog(@"***** BGTaskScheduler success");
    }
}

- (void) enableRebootReminder:(BOOL)enable {
    self.rebootReminder = enable;
    if (!enable) {
        [BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:kBgRebootTaskId];
    } else {
        [self scheduleRebootReminder];
    }
}

- (void) scheduleRebootReminder {
    if (!self.rebootReminder) {
        return;
    }
    
    // cancel existing task (if any)
    //[BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:kBgRebootTaskId];
    
    BGAppRefreshTaskRequest *refreshTaskRequest = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kBgRebootTaskId];
    NSDate *refreshDate = [self getRefreshDate];
    refreshTaskRequest.earliestBeginDate = refreshDate; //[NSDate dateWithTimeIntervalSinceNow:60*60*4];
    
    NSError *error;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:refreshTaskRequest error:&error]) {
        NSLog(@"BGTaskScheduler failed: %@", error);
    } else {
        //NSLog(@"***** BGTaskScheduler success");
    }
}

-(NSDate *) getRefreshDate {
    // Step 1: Get the current date and calendar
    NSDate *now = [NSDate date];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];//[NSCalendar currentCalendar];
    
    // Step 2: Find the next Monday
    NSDateComponents *components = [calendar components:NSCalendarUnitWeekday fromDate:now];
    NSInteger currentWeekday = components.weekday;
    
    // Calculate the number of days to the next Monday (week starts from Sunday = 1)
    NSInteger daysUntilNextMonday = (9 - currentWeekday) % 7;
    
    // If today is Monday, set daysUntilNextMonday to 7 to get next Monday
    if (daysUntilNextMonday == 0) {
        daysUntilNextMonday = 7;
    }
    
    //testing!!!
    //daysUntilNextMonday = 1;
    
    // Get the next Monday
    NSDate *nextMonday = [calendar dateByAddingUnit:NSCalendarUnitDay value:daysUntilNextMonday toDate:now options:0];
    
    // Step 3: Set the time to 3 pm on that day
    NSDateComponents *timeComponents = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:nextMonday];
    [timeComponents setHour:15];
    [timeComponents setMinute:0];
    [timeComponents setSecond:0];
    
    // Create the new date with 6 AM time
    NSDate *nextMondayAt6AM = [calendar dateFromComponents:timeComponents];
    
    return nextMondayAt6AM;
}

- (void) beginRebootReminder:(BGTask*)task
{
    [self scheduleRebootReminder];
    [[UIApplication sharedApplication] showRebootNotification];
    [task setTaskCompletedWithSuccess:YES];
}

#pragma - mark SecurityUpdateDelegate Methods
- (void)secInfoUpdated:(BOOL)success {
    //NSLog(@"***** BGTaskScheduler securityInfoUpdated with success (NO could indicate securityHub not enabled): %@", (success) ? @"YES" : @"NO");
    if (self.backgroundRefreshTask) {
        if (success) {
            [self.backgroundRefreshTask setTaskCompletedWithSuccess:YES];
        } else {
            [self.backgroundRefreshTask setTaskCompletedWithSuccess:NO];
        }
    }
    //[AWSAccountManager.shared setSecurityDelegate:nil];
}

- (void)setSecurityHubEnabled:(BOOL)enable {
    if (enable && !self.secUpdatesEnabled) {
        //NSLog(@"***** Turning on BGTaskScheduler for SecurityHub");
        self.secUpdatesEnabled = enable;
        [self scheduleAppRefresh];
    } else {
        self.secUpdatesEnabled = enable;
    }
}

#pragma - mark Class Methods
+ (instancetype)appDelegate
{
    return (OTRAppDelegate*)[[UIApplication sharedApplication] delegate];
    /*if (NSThread.isMainThread) {
        return (OTRAppDelegate *)UIApplication.sharedApplication.delegate;
    }

    __block OTRAppDelegate *delegate = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        delegate = (OTRAppDelegate *)UIApplication.sharedApplication.delegate;
    });
    return delegate;*/
}

#pragma mark - Theming

- (void) setupTheme { }

@end
