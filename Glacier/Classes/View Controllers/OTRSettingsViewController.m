//
//  OTRSettingsViewController.m
//  Off the Record
//
//  Created by Chris Ballinger on 4/10/12.
//  Copyright (c) 2012 Chris Ballinger. All rights reserved.
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

#import "OTRSettingsViewController.h"
#import "OTRSettingsManager.h"
#import "OTRProtocolManager.h"
#import "OTRBoolSetting.h"
#import "OTRSettingTableViewCell.h"
#import "OTRSettingDetailViewController.h"
@import QuartzCore;
#import "OTRConstants.h"
#import "UIActionSheet+ChatSecure.h"
#import "OTRAppDelegate.h"
#import "OTRUtilities.h"
#import "OTRBaseLoginViewController.h"
#import "OTRXLFormCreator.h"
#import "OTRViewSetting.h"
@import KVOController;
#import "Glacier-Swift.h"
#import "GlacierInfo.h"
@import MobileCoreServices;

#import "NSURL+ChatSecure.h"
#import <SwiftUI/SwiftUI.h>
#import "Glacier-Swift.h"

static NSString *const circleImageName = @"31-circle-plus-large.png";

static NSString *const kSettingsCellIdentifier = @"kSettingsCellIdentifier";

@interface OTRSettingsViewController () <UITableViewDataSource, UITableViewDelegate,OTRSettingDelegate, UIPopoverPresentationControllerDelegate, OTRAttachmentPickerDelegate, UIPickerViewDataSource,UIPickerViewDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *footerContainer;
@property (nonatomic, strong) UIStackView *footerStackView;

/** This is only non-nil during avatar picking */
@property (nonatomic, nullable) OTRAttachmentPicker *avatarPicker;

// for global message expiration setting
@property (nonatomic, strong) UIPickerView *timePickerView;
@property (strong, nonatomic) NSArray *pickerArray;
@property (nonatomic, strong) UITextField *timePickerTextField;
@property (nonatomic, strong) UITapGestureRecognizer *timeTapGesture;
@property (nonatomic, strong) UITapGestureRecognizer *timeTapGesture2;
@property (nonatomic, strong) id<TimerPickerDelegate> timeDel;

@property (nonatomic, strong) SecurityCenter *securityCenter; //IOSM#19

@property (nonatomic, strong) UISwitch *threatDetectionSwitch; //IOSM#58
@property (nonatomic, strong) UISwitch *linkPreviewSwitch;
@property (nonatomic, strong) UISwitch *readReceiptsSwitch;
@property (nonatomic, strong) UISwitch *rebootReminderSwitch;
@property (nonatomic, strong) UISwitch *trackingEnabledSwitch;
@property (nonatomic, strong) UISwitch *enterToSendSwitch; //IOSM#92

@property (nonatomic, strong) ChatAccountModel *primaryAccount; //IOSM#92
@property (assign, nonatomic) BOOL trackingEnabled;

//@property (nonatomic, strong) id allowPassphraseBackupNotificationToken; //ALF IOSM-499

@end

@implementation OTRSettingsViewController

- (id) init
{
    if (self = [super init])
    {
        self.title = SETTINGS_STRING();
        _settingsManager = [[OTRSettingsManager alloc] init];
        self.securityCenter = [[SecurityCenter alloc] init]; //IOSM#19
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.accessibilityIdentifier = @"settingsTableView";
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
    
    //IOSM#19
    //[self.tableView registerClass:[SecurityHubCell class] forCellReuseIdentifier:[SecurityHubCell reuseIdentifier]];
    
    NSBundle *bundle = [NSBundle mainBundle];
    UINib *nib = [UINib nibWithNibName:[XMPPAccountCell cellIdentifier] bundle:bundle];
    [self.tableView registerNib:nib forCellReuseIdentifier:[XMPPAccountCell cellIdentifier]];
    
    [self createFooterStack]; //ALF IOSM-479

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.footerContainer.topAnchor]
    ]];
    
    self.pickerArray = @[@"Off", @"15 seconds", @"1 minute", @"5 minutes", @"1 day", @"1 week", @"4 weeks"]; //IOSM#6 added 4 weeks
    
    ////// KVO //////
    __weak typeof(self)weakSelf = self;
    [self.KVOController observe:[OTRProtocolManager sharedInstance] keyPaths:@[NSStringFromSelector(@selector(numberOfConnectedProtocols)),NSStringFromSelector(@selector(numberOfConnectingProtocols))] options:NSKeyValueObservingOptionNew block:^(id observer, id object, NSDictionary *change) {
        __strong typeof(weakSelf)strongSelf = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.tableView reloadSections:[[NSIndexSet alloc] initWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
        });
    }];
    
    //[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(han:) name:DBManager.didSetupDatabase object:nil];
}

//ALF IOSM-479
- (void) createFooterStack {
    self.footerContainer = [[UIView alloc] init];
    self.footerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.footerContainer.layoutMargins = UIEdgeInsetsMake(10.0, 15.0, 10.0, 15.0);
    [self.view addSubview:self.footerContainer];

    self.footerStackView = [[UIStackView alloc] init];
    self.footerStackView.translatesAutoresizingMaskIntoConstraints = NO;
 
    self.footerStackView.axis = UILayoutConstraintAxisVertical;
    self.footerStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.footerStackView.alignment = UIStackViewAlignmentCenter;
    self.footerStackView.spacing = 10;
    self.footerStackView.layoutMarginsRelativeArrangement = YES;
        
    UIButton *versionButton = [[UIButton alloc] init];
    NSString *bundleVersion = [[[NSBundle mainBundle] infoDictionary] valueForKey:@"CFBundleShortVersionString"];
    NSString *buildNumber = [[[NSBundle mainBundle] infoDictionary] valueForKey:@"CFBundleVersion"];
    NSString *versionTitle = [NSString stringWithFormat:@"%@ %@ (%@)", VERSION_STRING(), bundleVersion, buildNumber];
    [versionButton setTitle:versionTitle forState:UIControlStateNormal];
    [versionButton setTitleColor:UIColor.lightGrayColor forState:UIControlStateNormal];
    [versionButton addTarget:self action:@selector(versionButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    //versionButton.titleLabel.font = [UIFont systemFontOfSize:10.0];
    [versionButton.titleLabel setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2]];
    versionButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    [versionButton sizeToFit];
    CGRect frame = versionButton.frame;
    frame.size.height = frame.size.height * 2;
    versionButton.frame = frame;
 
    UIButton *logoutButton = [[UIButton alloc] init];
    
    [logoutButton setTitle:@"Log Out" forState:UIControlStateNormal];
    [logoutButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [logoutButton setBackgroundColor:UIColor.redColor];
    //logoutButton.titleLabel.font = [UIFont systemFontOfSize:16.0];
    [logoutButton.titleLabel setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]];
    logoutButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    
    [logoutButton addTarget:self action:@selector(logoutButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
 
    [self.footerStackView addArrangedSubview:logoutButton];
    [self.footerStackView addArrangedSubview:versionButton];

    [self.footerContainer addSubview:self.footerStackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.footerStackView.topAnchor constraintEqualToAnchor:self.footerContainer.layoutMarginsGuide.topAnchor],
        [self.footerStackView.leadingAnchor constraintEqualToAnchor:self.footerContainer.layoutMarginsGuide.leadingAnchor],
        [self.footerStackView.trailingAnchor constraintEqualToAnchor:self.footerContainer.layoutMarginsGuide.trailingAnchor],
        [self.footerStackView.bottomAnchor constraintEqualToAnchor:self.footerContainer.layoutMarginsGuide.bottomAnchor]
    ]];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.footerContainer.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.footerContainer.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.footerContainer.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor]
    ]];
    
    logoutButton.translatesAutoresizingMaskIntoConstraints = NO;
    [logoutButton.heightAnchor constraintEqualToConstant:40].active = true;
    [logoutButton.widthAnchor constraintEqualToAnchor:self.footerContainer.layoutMarginsGuide.widthAnchor].active = YES;
    [logoutButton.layer setCornerRadius:20.0];
    if (@available(iOS 13.0, *)) {
        logoutButton.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [logoutButton setClipsToBounds:YES];
    [logoutButton setAutoresizesSubviews:YES];
    [logoutButton setClearsContextBeforeDrawing:YES];
 }

- (BOOL) getIgnoreCompromisedAlert { //IOSM#58 (next 2)
    if (self.securityCenter != nil) {
        return [self.securityCenter shouldIgnoreCompromisedAlert];
    }
    
    return NO;
}

- (void) setIgnoreCompromisedAlert:(BOOL)ignore {
    if (self.securityCenter != nil) {
        [self.securityCenter setIgnoreCompromisedAlert:ignore];
    }
}

//IOSM#19
- (BOOL)needsSecurityAlert {
    if (self.securityCenter != nil) {
        BOOL showAlert = [self.securityCenter getCurrentCompromisedStatus] && ![self getIgnoreCompromisedAlert]; //IOSM#58 added getIgnoreCompromisedAlert
        return showAlert;
    }
    
    return NO;
}

//IOSM#99
- (BOOL)needsSecurityAwareness {
    if (self.securityCenter != nil) {
        return ([self.securityCenter getCurrentCompromisedStatus] || ![self.securityCenter devicePasscodeEnabled]);
    }
    
    return NO;
}

-(void)checkSecurity {
    if (self.securityCenter != nil) {
        [self.securityCenter doSettingsSecurityChecks];
    }
}

- (SecurityInfoUtil*) getLatestSecurityInfo { //IOSM#110
    if (self.securityCenter != nil) {
        return [self.securityCenter getSecurityInfo];
    }
    return nil;
}

-(void)setVersionIssue:(BOOL)versionIssue {
    if (self.securityCenter != nil) {
        [self.securityCenter setVersionIssue:versionIssue];
    }
}

//ALF IOSM-479 commented out
- (void)logoutButtonPressed:(id)sender {
    UIAlertAction * cancelButtonItem = [UIAlertAction actionWithTitle:CANCEL_STRING() style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction * okButtonItem = [UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self doLogout:sender];
    }];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Warning" message:@"Logging out will also clear your message history. Are you sure you want to logout?" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:cancelButtonItem];
    [alert addAction:okButtonItem];
    [self presentViewController:alert animated:YES completion:nil];
}

-(void) doLogout:(id)sender {
    //try running all this on a background thread while first pullingup the Cognito login page first
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
    ChatAccountModel *account = [self accountAtIndexPath:ip];
    
    if (account && [[OTRProtocolManager sharedInstance] existsProtocolForAccount:account]) {
        OTRXMPPManager *xmpp = [[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:account];
        if (account.pushPubsubEndpoint) {
            XMPPJID *serverJID = [XMPPJID jidWithUser:nil domain:account.pushPubsubEndpoint resource:nil];
            [xmpp.serverCheck.pushModule disablePushForServerJID:serverJID node:account.pushPubsubNode elementId:nil];
            
            //IOSM-453 log out of push. This will use the device and shouldn't impact other devices with same user
            XMPPJID *userjid = [XMPPJID jidWithString:account.username resource:account.resource];
            NSString *pushjid = [@"p2." stringByAppendingString:[GlacierInfo defaultHost]];
            [xmpp.serverCheck.pushModule unregisterPushForUserJID:userjid server:pushjid elementId:nil];
        }
        
        [OTRProtocolManager.pushController deactivate];
        
        [[TwilioBackendManager sharedMgr] shutdown];
    }
    
    [self.KVOController unobserve:[OTRProtocolManager sharedInstance]];
    [[[OTRAppDelegate appDelegate] conversationViewController] resetAfterLogout:account];
}

//ALF IOSM-479
/*-(void) handleLogout {
    [self.KVOController unobserve:[OTRProtocolManager sharedInstance]];
}*/

- (void) versionButtonPressed:(id)sender {
    // Licenses are in Settings bundle now
    NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
    [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    //[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(serverCheckUpdate:) name:ServerCheck.UpdateNotificationName object:nil];
    //[self.settingsManager populateSettings];
    
    NSArray<UIView *> *views = self.navigationController.view.subviews;
    for (UIView *view in views) {
        if ([view isKindOfClass:[UITabBar class]]) {
            view.hidden = YES;
            break;
        }
    }
    
    self.primaryAccount = [ChatAccountModel allXMPPAccounts].firstObject;
    if (self.primaryAccount) {
        self.trackingEnabled = self.primaryAccount.trackingEnabled;
        BOOL modified = [self.settingsManager maybeRepopulateSettings:self.trackingEnabled];
        if (modified) {
            [self.tableView reloadData];
        }
    }
    
    [self.tableView reloadData];
    
    //ALF IOSM-499
    /*if (self) {
        __weak __typeof__(self) weakSelf = self;
        self.allowPassphraseBackupNotificationToken = [[NSNotificationCenter defaultCenter] addObserverForName:kOTRSettingsValueUpdatedNotification object:kOTRSettingKeyAllowDBPassphraseBackup queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_Nonnull note) {
            [weakSelf handleDatabaseBackup];
        }];
    }*/
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    //[[NSNotificationCenter defaultCenter] removeObserver:self];
    
    //ALF IOSM-499
    /*if (self.allowPassphraseBackupNotificationToken != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.allowPassphraseBackupNotificationToken];
    }*/
}

/*- (void) serverCheckUpdate:(NSNotification*)notification {
    //
}*/

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return YES;
    } else {
        return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
    }
}

- (ChatAccountModel *)accountAtIndexPath:(NSIndexPath *)indexPath
{
    ChatAccountModel *account = nil;
    NSArray<ChatAccountModel *> *accts = [ChatAccountModel allXMPPAccounts];
    if (accts.count > indexPath.row) {
        account = accts[indexPath.row];
    }
    return account;
}

#pragma mark UITableViewDataSource methods

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

-(UITableViewCell*)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {// && indexPath.row != [self.settingsManager numberOfSettingsInSection:indexPath.section]-1) { //ALF IOSM-479
        static NSString *addAccountCellIdentifier = @"addAccountCellIdentifier";
        UITableViewCell * cell = nil;
        if (indexPath.row == [ChatAccountModel allXMPPAccounts].count) {
            cell = [tableView dequeueReusableCellWithIdentifier:addAccountCellIdentifier];
            if (cell == nil) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:addAccountCellIdentifier];
                cell.textLabel.text = NEW_ACCOUNT_STRING();
                cell.imageView.image = [UIImage imageNamed:circleImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
                cell.detailTextLabel.text = nil;
            }
        } else {
            ChatAccountModel *account = [self accountAtIndexPath:indexPath];
            
            if (account == nil) { //IOSM#44
                cell = [tableView dequeueReusableCellWithIdentifier:addAccountCellIdentifier];
                if (cell == nil) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:addAccountCellIdentifier];
                    cell.textLabel.text = NEW_ACCOUNT_STRING();
                    cell.imageView.image = [UIImage imageNamed:circleImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
                    cell.detailTextLabel.text = nil;
                }
            } else {
                XMPPAccountCell *accountCell = [tableView dequeueReusableCellWithIdentifier:[XMPPAccountCell cellIdentifier] forIndexPath:indexPath];
                [accountCell setAppearanceWithAccount:account];
            
                OTRSetting *setting = [self.settingsManager settingAtIndexPath:indexPath];
                setting.delegate = self;
                //cell.otrSetting = setting;
            
                accountCell.infoButton.hidden = YES;
            
                UITapGestureRecognizer *nameTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDisplayNameClick:)];
                [accountCell.displayNameLabel addGestureRecognizer:nameTapGesture];

                accountCell.avatarButtonAction = ^(UITableViewCell *cell, id sender) {
                    self.avatarPicker = [[OTRAttachmentPicker alloc] initWithParentViewController:self delegate:self];
                    self.avatarPicker.tag = account;
                    [self.avatarPicker showAlertControllerFromSourceView:cell withCompletion:nil];
                };
                accountCell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell = accountCell;
            }
        }
        return cell;
    }
    
    OTRSetting *setting = [self.settingsManager settingAtIndexPath:indexPath];
    setting.delegate = self;
    
    OTRSettingTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSettingsCellIdentifier];
	if (cell == nil)
	{
		cell = [[OTRSettingTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kSettingsCellIdentifier];
	}
    //cell.otrSetting = setting;
    
    if ([setting isKindOfClass:[OTRBoolSetting class]]) { //IOSM#58 and else below
        OTRBoolSetting *bsetting = (OTRBoolSetting*)setting;
        
        if ([bsetting.key isEqualToString:kThreatDetectionKey]) {
            
            if (!self.threatDetectionSwitch) {
                self.threatDetectionSwitch = [[UISwitch alloc] init];
                [self.threatDetectionSwitch addTarget:bsetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
                
                if (bsetting.enabled) { //threatDetectionSetting
                    self.threatDetectionSwitch.enabled = YES;
                } else {
                    self.threatDetectionSwitch.enabled = NO;
                }
                
                [self.threatDetectionSwitch addTarget:self action:@selector(threatDetectionToggled) forControlEvents:UIControlEventValueChanged];
            }
            
            [cell setOtrBoolSetting:bsetting boolSwitch:self.threatDetectionSwitch];
        } else if ([bsetting.key isEqualToString:kLinkPreviewKey]) {
            
            if (!self.linkPreviewSwitch) {
                self.linkPreviewSwitch = [[UISwitch alloc] init];
                [self.linkPreviewSwitch addTarget:bsetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
                [self.linkPreviewSwitch addTarget:self action:@selector(linkPreviewToggle) forControlEvents:UIControlEventValueChanged];
            }
            
            [cell setOtrBoolSetting:bsetting boolSwitch:self.linkPreviewSwitch];
        } else if ([bsetting.key isEqualToString:kReadReceiptsKey]) {
            if (!self.readReceiptsSwitch) {
                self.readReceiptsSwitch = [[UISwitch alloc] init];
                [self.readReceiptsSwitch addTarget:bsetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
                [self.readReceiptsSwitch addTarget:self action:@selector(readReceiptsToggle) forControlEvents:UIControlEventValueChanged];
            }
            
            [cell setOtrBoolSetting:bsetting boolSwitch:self.readReceiptsSwitch];
        } else if ([bsetting.key isEqualToString:kRebootReminderKey]) {
            
            if (!self.rebootReminderSwitch) {
                self.rebootReminderSwitch = [[UISwitch alloc] init];
                [self.rebootReminderSwitch addTarget:bsetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
                [self.rebootReminderSwitch addTarget:self action:@selector(rebootReminderToggled) forControlEvents:UIControlEventValueChanged];
            }
            
            [cell setOtrBoolSetting:bsetting boolSwitch:self.rebootReminderSwitch];
        } else if ([bsetting.key isEqualToString:kTrackingOnKey]) {
            
            if (!self.trackingEnabledSwitch) {
                self.trackingEnabledSwitch = [[UISwitch alloc] init];
                [self.trackingEnabledSwitch addTarget:bsetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
                [self.trackingEnabledSwitch addTarget:self action:@selector(trackingEnabledToggled) forControlEvents:UIControlEventValueChanged];
            }
            
            [cell setOtrBoolSetting:bsetting boolSwitch:self.trackingEnabledSwitch];
            self.trackingEnabledSwitch.enabled = YES;
            if (self.primaryAccount && self.primaryAccount.trackingOn && self.primaryAccount.forceTracking) {
                [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
                cell.userInteractionEnabled = NO;
                self.trackingEnabledSwitch.enabled = NO;
            }
            
        } else if ([bsetting.key isEqualToString:@"kOTREnterToSendKey"]) {
            
            if (!self.enterToSendSwitch) {
                self.enterToSendSwitch = [[UISwitch alloc] init];
                [self.enterToSendSwitch addTarget:bsetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
                
                /*if (bsetting.enabled) { //enterToSendSetting
                    self.enterToSendSwitch.enabled = YES;
                } else {
                    self.enterToSendSwitch.enabled = NO;
                }*/
            }
            
            [cell setOtrBoolSetting:bsetting boolSwitch:self.enterToSendSwitch];
        }
        //BOOL threatDetectionSetting = [OTRSettingsManager boolForOTRSettingKey:kThreatDetectionKey];
    } else {
        cell.otrSetting = setting;
    }
    
    return cell;
}

//IOSM#58
- (void) linkPreviewToggle {
    BOOL linkPreview = [OTRSettingsManager boolForOTRSettingKey:kLinkPreviewKey];
    
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
    ChatAccountModel *account = [self accountAtIndexPath:ip];
    
    if (account) {
        account.disableLinkFetching = !linkPreview;
        [account saveXMPPAccountAsync];
        [ChatMessageModel setHTMLDownload:linkPreview];
        [ChatRoomMessageModel setHTMLDownload:linkPreview];
    }
}

- (void) readReceiptsToggle {
    BOOL isReadReceiptsOn = [OTRSettingsManager boolForOTRSettingKey:kReadReceiptsKey];
    
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
    ChatAccountModel *account = [self accountAtIndexPath:ip];
    
    if (account) {
        account.isReadReceiptsOn = isReadReceiptsOn;
        [account saveXMPPAccountAsync];
    }
}

//IOSM#58
- (void) threatDetectionToggled {
    BOOL threatDetection = [OTRSettingsManager boolForOTRSettingKey:kThreatDetectionKey];
    
    if (threatDetection) {
        [self setIgnoreCompromisedAlert:NO];
    } else {
        UIAlertAction * cancelAction = [UIAlertAction actionWithTitle:CANCEL_STRING() style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            OTRBoolSetting *threatDetectionSetting = (OTRBoolSetting *)[self.settingsManager settingForOTRSettingKey:kThreatDetectionKey];
            [threatDetectionSetting toggle];
        }];
        UIAlertAction * ignoreAction = [UIAlertAction actionWithTitle:@"Disable" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setIgnoreCompromisedAlert:YES];
        }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Disable Threat Detection" message:@"Are you sure you want to disable threat detection? You will no longer receive alerts when your device is compromised." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:cancelAction];
        [alert addAction:ignoreAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void) rebootReminderToggled {
    BOOL rebootReminder = [OTRSettingsManager boolForOTRSettingKey:kRebootReminderKey];
    
    if (rebootReminder) {
        [[OTRAppDelegate appDelegate] enableRebootReminder:YES];
        
        NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
        ChatAccountModel *account = [self accountAtIndexPath:ip];
        
        if (account) {
            account.rebootReminderEnabled = rebootReminder;
            [account saveXMPPAccountAsync];
        }
    } else {
        UIAlertAction * cancelAction = [UIAlertAction actionWithTitle:CANCEL_STRING() style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            OTRBoolSetting *rebootReminderSetting = (OTRBoolSetting *)[self.settingsManager settingForOTRSettingKey:kRebootReminderKey];
            [rebootReminderSetting toggle];
        }];
        UIAlertAction * ignoreAction = [UIAlertAction actionWithTitle:@"Disable" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[OTRAppDelegate appDelegate] enableRebootReminder:NO];
            NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
            ChatAccountModel *account = [self accountAtIndexPath:ip];
            if (account) {
                account.rebootReminderEnabled = rebootReminder;
                [account saveXMPPAccountAsync];
            }
        }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Disable Reboot Reminder" message:@"Are you sure you want to disable? You will no longer receive weekly reboot reminders, which helps ensure that iOS remains secure." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:cancelAction];
        [alert addAction:ignoreAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void) trackingEnabledToggled {
    BOOL trackingOn = [OTRSettingsManager boolForOTRSettingKey:kTrackingOnKey];
    
    if (trackingOn) {
        UIAlertAction * cancelAction = [UIAlertAction actionWithTitle:CANCEL_STRING() style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            OTRBoolSetting *trackingEnabledSetting = (OTRBoolSetting *)[self.settingsManager settingForOTRSettingKey:kTrackingOnKey];
            [trackingEnabledSetting toggle];
        }];
        UIAlertAction * ignoreAction = [UIAlertAction actionWithTitle:@"Enable" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
            ChatAccountModel *account = [self accountAtIndexPath:ip];
            if (account) {
                account.trackingOn = trackingOn;
                [account saveXMPPAccount];
            }
            [[LocationManager shared] enableTracking:YES];
        }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enable Tracking" message:@"Are you sure you want to enable tracking?" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:cancelAction];
        [alert addAction:ignoreAction];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
        ChatAccountModel *account = [self accountAtIndexPath:ip];
        
        if (account) {
            account.trackingOn = trackingOn;
            [account saveXMPPAccount];
        }
        [[LocationManager shared] enableTracking:NO];
    }
}

- (void) handleDisplayNameClick:(id)sender {
    if ([ChatAccountModel allXMPPAccounts].count != 0) {
        ChatAccountModel *xcct = [self accountAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        [_settingsManager handleChangeDisplayName:self currentDisplayName:xcct.displayName];
    }
}

//ALF IOSM-499 (not in use right now)
/*- (void) handleDatabaseBackup {
    BOOL allowBackup = [OTRSettingsManager boolForOTRSettingKey:kOTRSettingKeyAllowDBPassphraseBackup];
    
    if (allowBackup) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Set Database Backup Password" message:nil preferredStyle:UIAlertControllerStyleAlert];
    
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            //textField.secureTextEntry = YES;
            textField.placeholder = @"Password";
        }];
    
        UIAlertAction *setpass = [UIAlertAction actionWithTitle:@"Set Password" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *pass = alert.textFields.firstObject.text;
            if (pass.length > 1) {
                [[DatabaseManager sharedInstance] setBackupPassphrase:pass];
            }
        }];
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            //if you cancel, it should turn back off
            [self.settingsManager setBackupCancelled];
        }];
        [alert addAction:cancel];
        [alert addAction:setpass];
    
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = self.view.bounds;
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [[DatabaseManager sharedInstance] setBackupPassphrase:nil];
    }
}*/

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView 
{
    return [self.settingsManager.settingsGroups count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)sectionIndex
{
    if (sectionIndex == 0) {
        if ([ChatAccountModel allXMPPAccounts].count == 0) {
            return 1;
        }
    }
    return [self.settingsManager numberOfSettingsInSection:sectionIndex];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        if (indexPath.row == [ChatAccountModel allXMPPAccounts].count) {
            return 50.0;
        } else {
            return [XMPPAccountCell cellHeight];
        }
    } 
    return UITableViewAutomaticDimension;
}

- (NSString*)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [self.settingsManager stringForGroupInSection:section];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) { //} && indexPath.row != [self.settingsManager numberOfSettingsInSection:indexPath.section]-1) { //ALF IOSM-479
        if (indexPath.row == [ChatAccountModel allXMPPAccounts].count) {
            OTRBaseLoginViewController *baseLoginViewController = [[OTRBaseLoginViewController alloc] init];
            baseLoginViewController.showsCancelButton = YES;
            baseLoginViewController.form = [XLFormDescriptor existingAccountFormWithAccountType:ChatAccountTypeJabber];
            baseLoginViewController.loginHandler = [[OTRXMPPLoginHandler alloc] init];
            UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:baseLoginViewController];
            navigationController.modalPresentationStyle = UIModalPresentationFormSheet;
            [self presentViewController:navigationController animated:YES completion:nil];
        } else { //IOSM-479 should be account
            OTRSetting *setting = [self.settingsManager settingAtIndexPath:indexPath];
            OTRSettingActionBlock actionBlock = setting.actionBlock;
            if (actionBlock) {
                actionBlock(self);
            }
        }
    } else {
        OTRSetting *setting = [self.settingsManager settingAtIndexPath:indexPath];
        OTRSettingActionBlock actionBlock = setting.actionBlock;
        if (actionBlock) {
            actionBlock(self);
        }
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0) {
        return;
    }
}

#pragma - mark Other Methods

-(void)changeDisplayName:(id)sender withNewName:(NSString *)newname {
    if ([ChatAccountModel allXMPPAccounts].count == 0) {
        return;
    }
    ChatAccountModel *xcct = [self accountAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    
    if (!xcct.vCardTemp) {
        XMPPvCardTemp *newvCardTemp = [XMPPvCardTemp vCardTemp];
        xcct.vCardTemp = newvCardTemp;
    }
    
    //xcct.vCardTemp.nickname = newname;
    OTRXMPPManager *xmgr = [[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:xcct];
    XMPPvCardTemp *vCardTemp = xcct.vCardTemp;
    vCardTemp.nickname = newname;
    [xmgr updateNickname:vCardTemp];
    //manually update?
    //[xmgr forcevCardUpdateWithCompletion:^(BOOL success){}]; //ALF IOSM-452
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshView];
    });
}

- (void) addAccount:(id)sender {
    //if this ever happens, bring up Amplify AuthView
}

- (NSIndexPath *)indexPathForSetting:(OTRSetting *)setting
{
    return [self.settingsManager indexPathForSetting:setting];
}

#pragma mark OTRSettingDelegate method

- (void)refreshView
{
    [self.tableView reloadData];
}

#pragma mark OTRSettingViewDelegate method
- (void) otrSetting:(OTRSetting*)setting showDetailViewControllerClass:(Class)viewControllerClass
{
    if (viewControllerClass == [CoreConnectionViewController class]) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"CoreConnection" bundle:[GlacierInfo resourcesBundle]];
        CoreConnectionViewController *coreConnectionVC = [storyboard instantiateViewControllerWithIdentifier:@"coreConnection"];
        coreConnectionVC.modalPresentationStyle = UIModalPresentationFormSheet;
        if (coreConnectionVC) {
            //[coreConnectionVC addSettings:self.settingsManager];
            [self.navigationController pushViewController:coreConnectionVC animated:YES];
        }
        return;
    } else if (viewControllerClass == [ChatProfileViewController class]) { //ALF IOSM-479
        // Assuming you're inside a method of your view controller (e.g., didSelectRowAtIndexPath or a button action)
        ChatAccountModel *account = [ChatAccountModel firstAccount];
        if (!account) {
            return;
        }

        UIViewController *hostingVC = [UserProfileHostingController
                createHostingControllerWithAccount:account
                shouldShowReadReceiptsSetting:NO
                canEditDetails:YES
                isReadReceiptsOn:YES
                onReadReceiptsSettingChanged:^(BOOL enabled) {}
                onViewWillDisappear:^{}
        ];
        [self.navigationController pushViewController:hostingVC animated:YES];
        return;
    } else if (viewControllerClass == [SecurityCenterViewController class]) { //IOSM#19
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"SecurityCenter" bundle:[GlacierInfo resourcesBundle]];
        SecurityCenterViewController *securityCenterVC = [storyboard instantiateViewControllerWithIdentifier:@"securityCenter"];
        securityCenterVC.modalPresentationStyle = UIModalPresentationFormSheet;
        if (securityCenterVC) {
            [self.navigationController pushViewController:securityCenterVC animated:YES];
        }
        return;
    }
    UIViewController *viewController = [[viewControllerClass alloc] init];
    viewController.title = setting.title;
    if ([viewController isKindOfClass:[OTRSettingDetailViewController class]]) 
    {
        OTRSettingDetailViewController *detailSettingViewController = (OTRSettingDetailViewController*)viewController;
        detailSettingViewController.otrSetting = setting;
        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:detailSettingViewController];
        navController.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:navController animated:YES completion:nil];
    } else {
        [self.navigationController pushViewController:viewController animated:YES];
    }
}

#pragma - mark OTRAttachmentPickerDelegate

- (void)attachmentPicker:(OTRAttachmentPicker *)attachmentPicker gotPhoto:(UIImage *)photo withInfo:(NSDictionary *)info {
    self.avatarPicker = nil;
    ChatAccountModel *account = attachmentPicker.tag;
    
    OTRXMPPManager *xmpp = [OTRProtocolManager.shared xmppManagerForChatAccount:account];
    
    [xmpp setAvatar:photo completion:nil];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshView];
    });
}

- (void)attachmentPicker:(OTRAttachmentPicker *)attachmentPicker gotVideoURL:(NSURL *)videoURL {
    self.avatarPicker = nil;
}

- (NSArray <NSString *>*)attachmentPicker:(OTRAttachmentPicker *)attachmentPicker preferredMediaTypesForSource:(UIImagePickerControllerSourceType)source
{
    return @[(NSString*)kUTTypeImage];
}

// for global message expiration setting
- (void) showTimerSelector:(id<TimerPickerDelegate>)tdel withSelectedRow:(NSInteger)selrow {
    self.timePickerView = [[UIPickerView alloc]init];
    self.timePickerView.dataSource = self;
    self.timePickerView.delegate = self;
    self.timePickerView.backgroundColor = [UIColor colorWithRed:41/255.0 green:54/255.0 blue:62/255.0 alpha:1];
    self.timeDel = tdel;
    
    self.timeTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(clearTimePicker:)];
    self.timeTapGesture.delegate = self;
    self.timeTapGesture.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:self.timeTapGesture];
    
    self.timeTapGesture2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(clearTimePicker:)];
    self.timeTapGesture2.delegate = self;
    self.timeTapGesture2.cancelsTouchesInView = NO;
    [self.timePickerView addGestureRecognizer:self.timeTapGesture2];
    
    NSString *strHeader = @"Set a time for messages to disappear";
    float lblWidth = self.view.frame.size.width;
    float lblXposition = self.timePickerView.frame.origin.x;
    float lblYposition = (self.timePickerView.frame.origin.y);
    
    UILabel *lblHeader = [[UILabel alloc] initWithFrame:CGRectMake(lblXposition, lblYposition,
                                                                   lblWidth, 20)];
    [lblHeader setText:strHeader];
    [lblHeader setTextAlignment:NSTextAlignmentCenter];
    lblHeader.textColor = [UIColor whiteColor];
    lblHeader.font = [UIFont fontWithName:kFontAwesomeFont size:10];
    [self.timePickerView addSubview:lblHeader];
    
    self.timePickerTextField = [[UITextField alloc]initWithFrame:CGRectZero];
    [self.view addSubview:self.timePickerTextField];
    
    self.timePickerTextField.inputView = self.timePickerView;
    [self.timePickerTextField becomeFirstResponder];
    
    [self.timePickerView selectRow:selrow inComponent:0 animated:YES];
}

#pragma - mark UIPickerViewDelegate
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    
    return 1;
}


-(NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component
{
    return self.pickerArray.count;
}

- (NSAttributedString *)pickerView:(UIPickerView *)pickerView attributedTitleForRow:(NSInteger)row forComponent:(NSInteger)component
{
    NSString *title = self.pickerArray[row];
    NSAttributedString *attString =
    [[NSAttributedString alloc] initWithString:title attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}];
    
    return attString;
}


-(NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component
{
    return self.pickerArray[row];
}


-(void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component
{
    [self.timeDel timeSelected:row];
}

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer{
    return true;
}

- (void)clearTimePicker:(UITapGestureRecognizer *)gesture {
    [self.timePickerTextField resignFirstResponder];
    [self.timePickerTextField removeFromSuperview];
    self.timePickerTextField = nil;
    [self.view removeGestureRecognizer:self.timeTapGesture];
    [self.timePickerView removeGestureRecognizer:self.timeTapGesture2];
    self.timeTapGesture = nil;
    self.timeTapGesture2 = nil;
    self.timePickerView = nil;
    self.timeDel = nil;
    
    [self performSelector:@selector(performTimerTitleRefresh:) withObject:nil afterDelay:.5];
}

- (void) performTimerTitleRefresh:(id)sender {
    [self.tableView reloadData];
}

@end
