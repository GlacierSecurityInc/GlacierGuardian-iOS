//
//  GlacierAppDelegate.m
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

#import "GlacierAppDelegate.h"

#import "SettingsViewController.h"
#import "GlacierSettingsManager.h"

#import "GlacierConstants.h"

#import "GlacierUtilities.h"
@import SAMKeychain;

#import "GlacierLog.h"
@import CocoaLumberjack;

#import "PasswordGenerator.h"
@import XMPPFramework;
#import "GlacierProtocolManager.h"
#import "Glacier-Swift.h"
#import "UITableView+Glacier.h"
@import UserNotifications;
@import BackgroundTasks;
@import MBProgressHUD;

//@import Sentry;

@interface GlacierAppDelegate ()

@property (nonatomic, strong) GlacierSplitViewControllerDelegateObject *splitViewControllerDelegate;
@property (nonatomic, strong) GlacierSplitViewControllerDelegateObject *splitViewSMSControllerDelegate;

// test to see if we can get to server before attempting login
@property (assign, nonatomic) BOOL enteringForeground;
@property (nonatomic, readwrite) GlacierNetworkConnectionStatus networkStatus;

@property (assign, nonatomic) BOOL bypass;
//@property (nonatomic, strong, readwrite) NSDate *lastOnline;
@property (nonatomic, strong) NSString * domainAddress;

@property (nonatomic, strong) PKPushRegistry *voipRegistry;

@property UIBackgroundTaskIdentifier backgroundUpdateTask;
@property (nonatomic) dispatch_source_t backgroundUpdateTimer;
@property (assign, nonatomic) BOOL rebootReminder;
@property (assign, nonatomic) BOOL proxyDetected;

@property BGTask *backgroundRefreshTask;
@property (assign, nonatomic) BOOL secUpdatesEnabled;

@property (assign, nonatomic) BOOL isGroupController;
@property (nonatomic, strong) MBProgressHUD *hud;

@property (nonatomic, strong) SMSViewController *smsViewControllerStorage;
@property (nonatomic, strong) UINavigationController *securityHubViewControllerStorage;
@property (nonatomic, strong) UINavigationController *dialerViewControllerStorage;
@property (nonatomic, strong) UINavigationController *contactsViewControllerStorage;
@property (nonatomic, strong) UINavigationController *historyViewControllerStorage;

- (UIViewController *)setupMainInterfaceIfNeeded;

@end

@implementation GlacierAppDelegate
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
    //[DDLog addLogger:[DDTTYLogger sharedInstance]]; //doesn't print to system console
    [DDLog addLogger:[DDOSLogger sharedInstance]]; //prints to system console
    
    /*if ([GlacierAppDelegate isTestFlight]) {
        [[MetricKitDiagnostics shared] start];
        
        [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
            options.dsn = @"https://a9a4298819a7fe07113cbcdc6d18f472@o4510793861562368.ingest.us.sentry.io/4510793868771328";

            //options.debug = YES;
            
            // Enable app hang detection (this is what we want for watchdogs)
            options.enableAppHangTracking = YES;

            // Session tracking helps Sentry group events correctly
            options.enableAutoSessionTracking = YES;

            // Keep overhead low while debugging hangs
            options.tracesSampleRate = @(0.0);

            // Optional: useful while debugging integration
            // options.debug = YES;
        }];

        AddBC(@"lifecycle", @"didFinishLaunching", nil);
        
        NSDictionary *remote = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
        if (remote) {
            AddBC(@"push", @"Push opened app (cold launch)", remote);
        }
    }*/
    
    self.amplifyIsConfigured = NO;
    [self setupAmplify];
    
    BOOL shouldSetupUI = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    if (shouldSetupUI) {
        // UI setup is handled by SceneDelegate.
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(whenDatabaseReady:) name:DBManager.didSetupDatabase object:nil];
    if (UIApplication.sharedApplication.isProtectedDataAvailable) {
        //AddBC(@"db", @"DB init start", nil);
        [DBManager sharedDB];
        //AddBC(@"db", @"DB init end", nil);
    } else {
        DDLogWarn(@"Protected data unavailable at launch. Deferring database initialization until device is unlocked.");
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleProtectedDataAvailable:)
                                                     name:UIApplicationProtectedDataDidBecomeAvailable
                                                   object:nil];
        if (UIApplication.sharedApplication.isProtectedDataAvailable) {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
            //AddBC(@"db", @"DB init start", nil);
            [DBManager sharedDB];
            //AddBC(@"db", @"DB init end", nil);
        }
    }
    
    self.doubleDone = NO; // handle double notifications on login
    self.groupReadReady = NO;
    self.bypass = YES;
    self.silentUpdate = NO;
    self.voipNotification = NO;
    self.secUpdatesEnabled = NO;
    self.smsEnabled = NO;
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
        if (self.conversationViewController != nil) {
            [_conversationViewController doSecurityCheck:NO];
        }
    }
    if (mainRootViewController != nil) {
        self.window.rootViewController = mainRootViewController;
        [self.window makeKeyAndVisible];
    }
    
    // For disabling screen dimming while plugged in
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryStateDidChange:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [self batteryStateDidChange:nil];
    
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:kBgTaskId usingQueue:nil launchHandler:^(BGTask *task){
        //[self beginScheduledRefresh:task];
    }];
    //[self scheduleAppRefresh]; //change this to schedule only if we see that securityHubEnabled

    [self syncAndScheduleRebootReminder];
    
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    
    [self registerVoIPNotifications];
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
        //AddBC(@"db", @"handleProtectedDataAvailable - DB init start", nil);
        [DBManager sharedDB];
        //AddBC(@"db", @"handleProtectedDataAvailable - DB init end", nil);
        // DB is now available; sync the reboot reminder from the saved preference.
        [self syncAndScheduleRebootReminder];
        [self setDomainIfAvailable];
        [self checkConnectionOrTryLogin];
        if (self.conversationViewController != nil) {
            [_conversationViewController doSecurityCheck:NO];
        }
    }
}

/*static inline void AddBC(NSString *category, NSString *message, NSDictionary *data)
{
    if ([GlacierAppDelegate isTestFlight]) {
        SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] init];
        crumb.level = kSentryLevelInfo;
        crumb.category = category;
        crumb.message = message;
        if (data) crumb.data = data;
        // NSLog(@"*****DBG %@", message);
        [SentrySDK addBreadcrumb:crumb];
    }
}*/

- (UIViewController *)setupMainInterfaceIfNeeded
{
    if (self.window != nil && self.window.rootViewController != nil) {
        return self.window.rootViewController;
    }
    
    // Create 3 primary view controllers, settings, conversation list and messages
    _conversationViewController = [GlobalTheme.shared conversationViewController];
    _chatViewController = [GlobalTheme.shared chatViewController];
    _chatRoomViewController = [GlobalTheme.shared chatRoomViewController];
    
    UIViewController *rootViewController = [self setupDefaultSplitViewControllerWithLeadingViewController:[[UINavigationController alloc] initWithRootViewController:self.conversationViewController]];
    
    UINavigationController *smsNavController = [[UINavigationController alloc] initWithRootViewController:self.smsViewController];
    [self setupSMSSplitViewControllerWithLeadingViewController:smsNavController];
    
    if (self.window == nil) {
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState != UISceneActivationStateUnattached) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (windowScene != nil) {
            self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        } else {
            self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        }
    }
    self.window.rootViewController = rootViewController;
    
    return rootViewController;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0))
{
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions API_AVAILABLE(ios(13.0))
{
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
    [_conversationViewController doSecurityCheck:NO];
    [[TwilioBackendManager sharedMgr] queryForNumbers];
    [self checkConnectionOrTryLogin];
}

- (void) doSettingsController {
    if (_settingsViewController == nil && [ChatAccountModel allAutoLoginAccounts].count > 0) {
        _settingsViewController = [GlobalTheme.shared settingsViewController];
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
 * This also creates and sets up teh GlacierSplitViewCoordinator
 *
 * @param leadingViewController The leading or left most view controller in a UISplitViewController. Should most likely be some sort of UINavigationViewController
 * @return The base default UISplitViewController
 *
 */
- (UIViewController *)setupDefaultSplitViewControllerWithLeadingViewController:(nonnull UIViewController *)leadingViewController
{
    _splitViewCoordinator = [[GlacierSplitViewCoordinator alloc] init];
    self.splitViewControllerDelegate = [[GlacierSplitViewControllerDelegateObject alloc] init];
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
    splitViewController.presentsWithGesture = NO;
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

- (UIViewController *)setupSMSSplitViewControllerWithLeadingViewController:(nonnull UIViewController *)leadingViewController
{
    _smsSplitViewCoordinator = [[SMSSplitViewCoordinator alloc] init];
    self.splitViewSMSControllerDelegate = [[GlacierSplitViewControllerDelegateObject alloc] init];
    self.smsViewController.delegate = self.smsSplitViewCoordinator;
    _smsMessagesViewController = [[SMSChatViewController alloc] init];
    
    //MessagesViewController Nav
    UINavigationController *smsMessagesNavigationController = [[UINavigationController alloc] initWithRootViewController:self.smsMessagesViewController];
    
    //SplitViewController
    UISplitViewController *splitViewController = [[UISplitViewController alloc] init];
    splitViewController.viewControllers = @[leadingViewController,smsMessagesNavigationController];
    splitViewController.delegate = self.splitViewSMSControllerDelegate;
    splitViewController.title = @"SMS";
    splitViewController.presentsWithGesture = NO;
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

- (void) setSMSEnabled:(BOOL)enabled {
    if ((enabled && !self.smsEnabled) || (!enabled && self.smsEnabled)) {
        //send notification to listeners
        self.smsEnabled = enabled;
        // NSLog(@"***** setSMSEnabled %@", (enabled) ? @"YES" : @"NO");
        
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
    //NSLog(@"*****DBG GlacierAppDelegate applicationWillResignActive");
    //AddBC(@"lifecycle", @"applicationWillResignActive", nil);
    
    [GlacierAppDelegate setLastInteractionDate:NSDate.date];
    [self updateSharedAppActiveState:NO];
    
    /*
     Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
     Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
     */
    
    // for Splash/Privacy page
    if ([self hasAddress] && self.window != nil && self.splitViewCoordinator != nil) {
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
    [[TwilioBackendManager sharedMgr] setProxyDetected:detected];
    
    if (detected) {
        ChatAccountModel *account = [ChatAccountModel firstAccount];
        if (account != nil && [[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:account] != nil && [[GlacierProtocolManager sharedInstance] isAccountIdConnected:account.uniqueId]) {
            [[GlacierProtocolManager sharedInstance] disconnectAllAccounts];
        }
    } else {
        ChatAccountModel *account = [ChatAccountModel firstAccount];
        if (account != nil && [[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:account] != nil && [[GlacierProtocolManager sharedInstance] isAccountIdConnected:account.uniqueId] == NO) {
            if (self.enteringForeground || [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                [self autoLoginFromBackground:NO];
            }
        }
    }
}

- (void)finishedConnecting {
    if (_proxyDetected) {
        [[GlacierProtocolManager sharedInstance] disconnectAllAccounts];
    }
}

- (BOOL)isProxyDetected
{
    return _proxyDetected;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    //NSLog(@"*****DBG GlacierAppDelegate applicationDidEnterBackground");
    //AddBC(@"lifecycle", @"applicationDidEnterBackground", nil);
    
    [self updateSharedAppActiveState:NO];
    [self beginBackgroundUpdateTask];
    
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
    //[[GlacierProtocolManager sharedInstance] disconnectAllAccounts];
    [[GlacierProtocolManager sharedInstance] goAwayForAllAccounts];
    [self updateSharedUserActiveState:NO];
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
     if (_networkStatus == GlacierNetworkConnectionStatusConnecting || _networkStatus == GlacierNetworkConnectionStatusUnknown || _networkStatus == GlacierNetworkConnectionStatusDisconnected) {
     return;
     }*/
    
    if (self.enteringForeground || [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [self autoLoginFromBackground:NO];
    }
}

/*- (GlacierNetworkConnectionStatus) getCurrentNetworkStatus {
 return GlacierNetworkConnectionStatusConnected;
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
            [[GlacierProtocolManager sharedInstance] loginAccounts:autoaccts];
            [PushController registerForPushNotifications];
        } else if ([self hasAddress]){
            [_conversationViewController tryGlacierGroupAccount];
        }
    });
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    //NSLog(@"*****DBG GlacierAppDelegate applicationWillEnterForeground");
    //AddBC(@"lifecycle", @"applicationWillEnterForeground", nil);
    
    self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    
    self.enteringForeground = YES;
    //autoLoginFromBackground
    
    if (self.backgroundUpdateTask != UIBackgroundTaskInvalid) {
        DDLogInfo(@"**** Application entering foreground, stopping background task");
        [self cancelBackgroundUpdateTimer];
        [[UIApplication sharedApplication] endBackgroundTask: self.backgroundUpdateTask];
        self.backgroundUpdateTask = UIBackgroundTaskInvalid;
    }
    
    [_conversationViewController doSecurityCheck:NO];
    
    if (!_proxyDetected) {
        [[TwilioBackendManager sharedMgr] queryForNumbers];
        [[TwilioBackendManager sharedMgr] queryForVMInfo];
        [[TwilioBackendManager sharedMgr] refreshTokenOnForeground];
    }
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
    if (self.window == nil || self.splitViewCoordinator == nil) {
        return;
    }
    UIView *splashView = [self.window viewWithTag:12345];
    if (splashView == nil) {
        self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
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
        self.splitViewCoordinator.splitViewController.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    }];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    //NSLog(@"*****DBG GlacierAppDelegate applicationDidBecomeActive");
    //AddBC(@"lifecycle", @"applicationDidBecomeActive", nil);
    
    if (self.window == nil) {
        [self setupMainInterfaceIfNeeded];
        if (UIApplication.sharedApplication.isProtectedDataAvailable) {
            [self setDomainIfAvailable];
            [self checkConnectionOrTryLogin];
            if (self.conversationViewController != nil) {
                [_conversationViewController doSecurityCheck:NO];
            }
        }
        [self.window makeKeyAndVisible];
    }
    
    // remove the privacy screen
    [self removeSplashView];
    
    [GlacierAppDelegate setLastInteractionDate:NSDate.date];
    [self batteryStateDidChange:nil];
    // DDLogInfo(@"*****DBG Application became active");
    [self updateSharedAppActiveState:YES];
    [self updateSharedUserActiveState:YES];
    
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

- (void)updateSharedUserActiveState:(BOOL)isActive
{
    NSUserDefaults *glacierDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGlacierGroup];
    if (!glacierDefaults) {
        return;
    }
    [glacierDefaults setBool:isActive forKey:kGlacierUserIsActiveKey];
}

- (void) handleGroupReadReadyNotification:(id)sender
{
    self.groupReadReady = YES;
}

- (void) handleDoubleNotification:(id)sender
{
    self.doubleDone = YES;
}

- (void) resetDoubleNotificationHandlerIfNeeded {
    //if (self.doubleDone) {
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
    [self updateSharedUserActiveState:NO];
    [[GlacierProtocolManager sharedInstance] disconnectAllAccounts];
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *restorableObjects))restorationHandler {
    if ([userActivity.activityType isEqualToString:@"INStartVideoCallIntent"] || [userActivity.activityType isEqualToString:@"INStartCallIntent"]) {
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
    [GlacierProtocolManager.pushController setPushToken:[deviceToken hexString]];
    [[TwilioBackendManager sharedMgr] setPushData:deviceToken];
}

- (void)application:(UIApplication *)app didFailToRegisterForRemoteNotificationsWithError:(NSError *)err {
    DDLogError(@"Error in registration. Error: %@%@", [err localizedDescription], [err userInfo]);
}

- (void)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler
{
    if (application.applicationState == UIApplicationStateInactive) {
        //AddBC(@"push", @"Push opened app (resume)", nil);
    } else {
        //AddBC(@"push", @"didReceiveRemoteNotification", nil);
    }
    
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
    [[MediaServer sharedInstance] disconnectWebServer:^ {
        [[GlacierProtocolManager sharedInstance] disconnectAllAccounts];
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

- (void)suspendBackgroundUpdateTimerForCall
{
    [self cancelBackgroundUpdateTimer];
}

- (void)resumeBackgroundUpdateTimerAfterCallIfNeeded
{
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
        return;
    }
    
    if (self.backgroundUpdateTask == UIBackgroundTaskInvalid) {
        return;
    }
    
    [self scheduleBackgroundUpdateTaskExpiration];
}

- (void) beginBackgroundFetch
{ //currently not being called from p2 in 0.9. But something is weird about this if that ever changes
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *autoaccts = [ChatAccountModel allAutoLoginAccounts];
        if (autoaccts && autoaccts.count > 0 && self.proxyDetected == NO) {
            GlacierXMPPManager *xmppManager = [[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:autoaccts.firstObject];
            //NSLog(@"***** beginBackgroundFetch about to connect com.apple.pushLaunch");
            if (![xmppManager connectFromBackground]) {
                [self endBackgroundUpdateTask];
            }
        } else {
            [self endBackgroundUpdateTask];
        }
    });
}

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
    [self scheduleRebootReminder];
}

// Schedule (or cancel) the recurring reboot reminder based on self.rebootReminder.
// Scheduled via a recurring UNCalendarNotificationTrigger (Sunday 8pm local), so
// it no longer relies on BGAppRefreshTask waking the app.
- (void) scheduleRebootReminder {
    if (self.rebootReminder) {
        [[UIApplication sharedApplication] scheduleRebootNotification];
    } else {
        [[UIApplication sharedApplication] cancelRebootNotification];
    }
}

// Sync self.rebootReminder from the user's saved account preference, then
// schedule/cancel accordingly. The account may be unavailable if protected data
// is still locked at launch; in that case self.rebootReminder keeps its default
// and this runs again once the DB is ready (see handleProtectedDataAvailable).
- (void) syncAndScheduleRebootReminder {
    NSArray<ChatAccountModel*> *accounts = [ChatAccountModel allXMPPAccounts];
    if (accounts.count > 0) {
        self.rebootReminder = accounts.firstObject.rebootReminderEnabled;
    }
    [self scheduleRebootReminder];
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

- (BOOL)isMainInterfaceReady {
    return (self.window != nil && self.window.rootViewController != nil && _conversationViewController != nil);
}

#pragma - mark Class Methods
+ (instancetype)appDelegate
{
    return (GlacierAppDelegate*)[[UIApplication sharedApplication] delegate];
    /*if (NSThread.isMainThread) {
        return (GlacierAppDelegate *)UIApplication.sharedApplication.delegate;
    }

    __block GlacierAppDelegate *delegate = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        delegate = (GlacierAppDelegate *)UIApplication.sharedApplication.delegate;
    });
    return delegate;*/
}

#pragma mark - Theming

- (void) setupTheme { }

@end
