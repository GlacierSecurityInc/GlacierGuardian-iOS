//
//  OTRConstants.h
//  Off the Record
//
//  Created by David Chiles on 6/28/12.
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
#import "OTRConstants.h"

NSString *const kOTRProtocolLoginSuccess                   = @"LoginSuccessNotification";
NSString *const kDidDeleteAllChatMessages                  = @"didDeleteAllChatMessages";

NSString *const kOTRProtocolTypeXMPP = @"xmpp";

NSString *const kOTRNotificationAccountNameKey       = @"kOTRNotificationAccountNameKey";
NSString *const kOTRNotificationUserNameKey          = @"kOTRNotificationUserNameKey";
NSString *const kOTRNotificationProtocolKey          = @"kOTRNotificationProtocolKey";
NSString *const kOTRNotificationBuddyUniqueIdKey     = @"kOTRNotificationBuddyUniqueIdKey";
NSString *const kOTRNotificationAccountUniqueIdKey   = @"kOTRNotificationAccountUniqueIdKey";
NSString *const kOTRNotificationAccountCollectionKey = @"kOTRNotificationAccountCollectionKey";


NSString *const kOTRServiceName            = @"org.chatsecure.ChatSecure";
NSString *const kOTRCertificateServiceName = @"org.chatsecure.ChatSecure.Certificate";

NSString *const kGlacierServiceName            = @"com.glaciersec.Chat"; //IOSM#105
NSString *const kGlacierGroup      = @"group.com.glaciersec.apps";
NSString *const kGlacierAcct       = @"com.glaciersec.Acct";
NSString *const kGlacierAppIsActiveKey = @"com.glaciersec.AppIsActive";
NSString *const kGlacierKeyGroup      = @"5MXM7J8H38.group.com.glaciersec.access";
NSString *const kCognitoAcct       = @"com.glaciersec.Cognito";
NSString *const kGlacierVpn       = @"com.glaciersec.Vpn";

//ALF IOSM-465
NSString *const kGlacierSalt       = @"com.glaciersec.Salt";
NSString *const kGlacierKeySpec       = @"com.glaciersec.KeySpec";
NSString *const kGlacierMediaSalt       = @"com.glaciersec.MediaSalt";
NSString *const kGlacierMediaKeySpec       = @"com.glaciersec.MediaKeySpec";

//ALF IOSM-499
NSString *const kGlacierBackup       = @"com.glaciersec.Backup";

NSString *const kGlacierImage            = @"kGlacierImage";

NSString *const kOTRSettingKeyFontSize                 = @"kOTRSettingKeyFontSize";
NSString *const kOTRSettingKeyDeleteOnDisconnect       = @"kOTRSettingKeyDeleteOnDisconnect";
NSString *const kOTRSettingKeyAllowDBPassphraseBackup  = @"kOTRSettingKeyAllowDBPassphraseBackup";
NSString *const kOTRSettingKeyShowDisconnectionWarning = @"kOTRSettingKeyShowDisconnectionWarning";
NSString *const kOTRSettingUserAgreedToEULA            = @"kOTRSettingUserAgreedToEULA";
NSString *const kOTRSettingAccountsKey                 = @"kOTRSettingAccountsKey";
NSString *const kOTRSettingsValueUpdatedNotification = @"kOTRSettingsValueUpdatedNotification";
NSString *const kGlacierCoreConnection = @"kGlacierCoreConnection";
NSString *const kThreatDetectionKey = @"kThreatDetectionKey"; //IOSM#58
NSString *const kLinkPreviewKey = @"kLinkPreviewKey";
NSString *const kReadReceiptsKey = @"kReadReceiptsKey";
NSString *const kRebootReminderKey = @"kRebootReminderKey";
NSString *const kTrackingOnKey = @"kTrackingOnKey";
NSString *const kBgTaskId = @"com.glacier.Messenger.task.refresh"; //IOSM#88
NSString *const kBgRebootTaskId = @"com.glacier.Messenger.task.reboot";

NSString *const kOTRPushEnabledKey = @"kOTRPushEnabledKey";

NSString *const kOTRAppVersionKey     = @"kOTRAppVersionKey";

NSString *const OTRArchiverKey = @"OTRArchiverKey";

NSString *const kOTRErrorDomain = @"com.glaciersecurity";


NSString *const OTRUserNotificationsUNTextInputReply = @"OTRUserNotificationsUNTextInputReply";
NSString *const OTRUserNotificationsChanged = @"OTRUserNotificationsChanged";
NSString *const OTRPushAccountDeviceChanged = @"OTRPushAccountDeviceChanged";
NSString *const OTRPushAccountTokensChanged = @"OTRPushAccountTokensChanged";


NSString *const OTRSuccessfulRemoteNotificationRegistration = @"OTRSuccessfulRemoteNotificationRegistration";

NSString *const GRDBDatabasePassphraseAccountName = @"OTRYapDatabasePassphraseAccountName";

NSString *const OTRYapDatabaseName = @"ChatSecureYap.sqlite";

//ALF IOSM-465
NSString *const GlacierYapDatabaseName = @"GlacierYap.sqlite";
NSString *const GlacierMediaDatabaseName = @"Glacier-media.sqlite";

NSString *const GlacierGRDBPassphraseAccountName = @"GlacierGRDBPassphraseAccountName"; //IOSM#105
NSString *const GlacierMediaPassphraseName = @"GlacierMediaPassphraseName";

//Noticications
NSString *const kOTRNotificationAccountKey = @"kOTRNotificationAccountKey";
NSString *const kOTRNotificationThreadKey = @"kOTRNotificationThreadKey";
NSString *const kOTRNotificationThreadCollection = @"kOTRNotificationThreadCollection";
NSString *const kOTRNotificationType = @"kOTRNotificationType";
NSString *const kOTRNotificationTypeNone = @"kOTRNotificationTypeNone";
NSString *const kOTRNotificationTypeSubscriptionRequest = @"kOTRNotificationTypeSubscriptionRequest";
NSString *const kOTRNotificationTypeApprovedBuddy = @"kOTRNotificationTypeApprovedBuddy";
NSString *const kOTRNotificationTypeConnectionError = @"kOTRNotificationTypeConnectionError";
NSString *const kOTRNotificationTypeChatMessage = @"kOTRNotificationTypeChatMessage";
NSString *const BuddyPendingApprovalDidChangeNotification = @"BuddyPendingApprovalDidChangeNotification";

// Twilio/WebRTC Video Calls
NSString *const kNotificationCallIdKey   = @"call_id";
NSString *const kNotificationCallerKey   = @"caller";
NSString *const kNotificationRoomnameKey   = @"roomname";
NSString *const kNotificationCallStatusKey = @"status"; //IOSM-569

// Twilio Voice Calls
NSString *const kNotificationTwilioCallIdKey   = @"twi_call_sid";
NSString *const kNotificationTwilioCallerKey   = @"twi_from";

// Twilio SMS
NSString *const kNotificationTwilioType   = @"twi_message_type";
NSString *const kNotificationTwilioVoiceCall   = @"twilio.voice.call";
NSString *const kNotificationVoicemailType   = @"voicemail_type";

//NSUserDefaults
NSString *const kOTRShowOMEMOGroupEncryptionKey = @"kOTRShowOMEMOGroupEncryptionKey";
NSString *const kOTREnableDebugLoggingKey = @"kOTREnableDebugLoggingKey";

NSString *const kAudioPlaybackSpeed = @"kAudioPlaybackSpeed";

extern NSString *const kOTREnableDebugLoggingKey;
//Chatview
CGFloat const kOTRSentDateFontSize            = 13;
CGFloat const kOTRDeliveredFontSize           = 13;
CGFloat const kOTRMessageFontSize             = 16;
CGFloat const kOTRMessageSentDateLabelHeight  = kOTRSentDateFontSize + 7;
CGFloat const kOTRMessageDeliveredLabelHeight = kOTRDeliveredFontSize + 7;

NSUInteger const kOTRMinimumPassphraseLength = 8;
NSUInteger const kOTRMaximumPassphraseLength = 64;
