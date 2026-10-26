//
//  GlacierConstants.h
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
#import "GlacierConstants.h"

NSString *const kGlacierProtocolLoginSuccess                   = @"LoginSuccessNotification";
NSString *const kDidDeleteAllChatMessages                  = @"didDeleteAllChatMessages";

NSString *const kGlacierProtocolTypeXMPP = @"xmpp";

NSString *const kGlacierNotificationAccountNameKey       = @"kOTRNotificationAccountNameKey";
NSString *const kGlacierNotificationUserNameKey          = @"kOTRNotificationUserNameKey";
NSString *const kGlacierNotificationProtocolKey          = @"kOTRNotificationProtocolKey";
NSString *const kGlacierNotificationBuddyUniqueIdKey     = @"kOTRNotificationBuddyUniqueIdKey";
NSString *const kGlacierNotificationAccountUniqueIdKey   = @"kOTRNotificationAccountUniqueIdKey";
NSString *const kGlacierNotificationAccountCollectionKey = @"kOTRNotificationAccountCollectionKey";


NSString *const kOTRServiceName            = @"org.chatsecure.ChatSecure";
NSString *const kOTRCertificateServiceName = @"org.chatsecure.ChatSecure.Certificate";
NSString *const kGlacierAccessTokenServiceName = @"com.glaciersec.Chat.AccessToken";

NSString *const kGlacierServiceName            = @"com.glaciersec.Chat";
NSString *const kGlacierGroup      = @"group.com.glaciersec.apps";
NSString *const kGlacierAcct       = @"com.glaciersec.Acct";
NSString *const kGlacierAppIsActiveKey = @"com.glaciersec.AppIsActive";
NSString *const kGlacierUserIsActiveKey = @"com.glaciersec.UserIsActive";
NSString *const kGlacierKeyGroup      = @"5MXM7J8H38.group.com.glaciersec.access";
NSString *const kCognitoAcct       = @"com.glaciersec.Cognito";
NSString *const kGlacierVpn       = @"com.glaciersec.Vpn";

NSString *const kGlacierSalt       = @"com.glaciersec.Salt";
NSString *const kGlacierKeySpec       = @"com.glaciersec.KeySpec";
NSString *const kGlacierMediaSalt       = @"com.glaciersec.MediaSalt";
NSString *const kGlacierMediaKeySpec       = @"com.glaciersec.MediaKeySpec";

NSString *const kGlacierBackup       = @"com.glaciersec.Backup";

NSString *const kGlacierImage            = @"kGlacierImage";

NSString *const kGlacierSettingKeyFontSize                 = @"kOTRSettingKeyFontSize";
NSString *const kGlacierSettingKeyDeleteOnDisconnect       = @"kOTRSettingKeyDeleteOnDisconnect";
NSString *const kGlacierSettingKeyAllowDBPassphraseBackup  = @"kOTRSettingKeyAllowDBPassphraseBackup";
NSString *const kGlacierSettingKeyShowDisconnectionWarning = @"kOTRSettingKeyShowDisconnectionWarning";
NSString *const kGlacierSettingUserAgreedToEULA            = @"kOTRSettingUserAgreedToEULA";
NSString *const kGlacierSettingAccountsKey                 = @"kOTRSettingAccountsKey";
NSString *const kGlacierSettingsValueUpdatedNotification = @"kOTRSettingsValueUpdatedNotification";
NSString *const kGlacierCoreConnection = @"kGlacierCoreConnection";
NSString *const kThreatDetectionKey = @"kThreatDetectionKey";
NSString *const kLinkPreviewKey = @"kLinkPreviewKey";
NSString *const kReadReceiptsKey = @"kReadReceiptsKey";
NSString *const kRebootReminderKey = @"kRebootReminderKey";
NSString *const kTrackingOnKey = @"kTrackingOnKey";
NSString *const kBgTaskId = @"com.glacier.Messenger.task.refresh";

NSString *const kGlacierPushEnabledKey = @"kOTRPushEnabledKey";

NSString *const kGlacierAppVersionKey     = @"kOTRAppVersionKey";

NSString *const GlacierArchiverKey = @"OTRArchiverKey";

NSString *const kGlacierErrorDomain = @"com.glaciersecurity";


NSString *const GlacierUserNotificationsUNTextInputReply = @"OTRUserNotificationsUNTextInputReply";
NSString *const GlacierUserNotificationsChanged = @"OTRUserNotificationsChanged";
NSString *const GlacierPushAccountDeviceChanged = @"OTRPushAccountDeviceChanged";
NSString *const GlacierPushAccountTokensChanged = @"OTRPushAccountTokensChanged";


NSString *const GlacierSuccessfulRemoteNotificationRegistration = @"OTRSuccessfulRemoteNotificationRegistration";

NSString *const GRDBDatabasePassphraseAccountName = @"OTRYapDatabasePassphraseAccountName";

NSString *const GlacierMediaDatabaseName = @"Glacier-media.sqlite";

NSString *const GlacierGRDBPassphraseAccountName = @"GlacierGRDBPassphraseAccountName";
NSString *const GlacierMediaPassphraseName = @"GlacierMediaPassphraseName";

//Noticications
NSString *const kGlacierNotificationAccountKey = @"kOTRNotificationAccountKey";
NSString *const kGlacierNotificationThreadKey = @"kOTRNotificationThreadKey";
NSString *const kGlacierNotificationThreadCollection = @"kOTRNotificationThreadCollection";
NSString *const kGlacierNotificationType = @"kOTRNotificationType";
NSString *const kGlacierNotificationTypeNone = @"kOTRNotificationTypeNone";
NSString *const kGlacierNotificationTypeSubscriptionRequest = @"kOTRNotificationTypeSubscriptionRequest";
NSString *const kGlacierNotificationTypeApprovedBuddy = @"kOTRNotificationTypeApprovedBuddy";
NSString *const kGlacierNotificationTypeConnectionError = @"kOTRNotificationTypeConnectionError";
NSString *const kGlacierNotificationTypeChatMessage = @"kOTRNotificationTypeChatMessage";
NSString *const BuddyPendingApprovalDidChangeNotification = @"BuddyPendingApprovalDidChangeNotification";

// Twilio/WebRTC Video Calls
NSString *const kNotificationCallIdKey   = @"call_id";
NSString *const kNotificationCallerKey   = @"caller";
NSString *const kNotificationRoomnameKey   = @"roomname";
NSString *const kNotificationCallStatusKey = @"status";

// Twilio Voice Calls
NSString *const kNotificationTwilioCallIdKey   = @"twi_call_sid";
NSString *const kNotificationTwilioCallerKey   = @"twi_from";

// OMEMO-over-push sealed-box envelope (must match the keys p2/mod_push stamp on the APNs payload)
NSString *const kGlacierPushEnvelopeKey            = @"ge";
NSString *const kGlacierPushEnvelopeAlgKey         = @"alg";
NSString *const kGlacierPushEnvelopeKidKey         = @"kid";
NSString *const kGlacierPushEnvelopeDataKey        = @"data";
NSString *const kGlacierPushSealedBoxAlg           = @"sealedbox-x25519-xsalsa20poly1305";
NSString *const kGlacierPushEncryptKeychainService = @"com.glaciersec.pushEncryptKey";

NSString *const kGlacierPushEncryptAlgField    = @"push-encrypt-alg";
NSString *const kGlacierPushEncryptPubkeyField = @"push-encrypt-pubkey";
NSString *const kGlacierPushEncryptKidField    = @"push-encrypt-kid";
NSString *const kGlacierPushOmemoRidField      = @"push-omemo-rid";

// Twilio SMS
NSString *const kNotificationTwilioType   = @"twi_message_type";
NSString *const kNotificationTwilioVoiceCall   = @"twilio.voice.call";
NSString *const kNotificationVoicemailType   = @"voicemail_type";

//NSUserDefaults
NSString *const kGlacierShowOMEMOGroupEncryptionKey = @"kOTRShowOMEMOGroupEncryptionKey";
NSString *const kGlacierEnableDebugLoggingKey = @"kOTREnableDebugLoggingKey";

NSString *const kAudioPlaybackSpeed = @"kAudioPlaybackSpeed";

extern NSString *const kGlacierEnableDebugLoggingKey;
//Chatview
CGFloat const kGlacierSentDateFontSize            = 13;
CGFloat const kGlacierDeliveredFontSize           = 13;
CGFloat const kGlacierMessageFontSize             = 16;
CGFloat const kGlacierMessageSentDateLabelHeight  = kGlacierSentDateFontSize + 7;
CGFloat const kGlacierMessageDeliveredLabelHeight = kGlacierDeliveredFontSize + 7;

NSUInteger const kGlacierMinimumPassphraseLength = 8;
NSUInteger const kGlacierMaximumPassphraseLength = 64;
