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

@import UIKit;

NS_ASSUME_NONNULL_BEGIN
extern NSString *const kGlacierProtocolLoginSuccess;
extern NSString *const kDidDeleteAllChatMessages;

extern NSString *const kGlacierProtocolTypeXMPP;

extern NSString *const kGlacierNotificationAccountNameKey;
extern NSString *const kGlacierNotificationUserNameKey;
extern NSString *const kGlacierNotificationProtocolKey;
extern NSString *const kGlacierNotificationBuddyUniqueIdKey;
extern NSString *const kGlacierNotificationAccountUniqueIdKey;
extern NSString *const kGlacierNotificationAccountCollectionKey;


extern NSString *const kOTRServiceName;
extern NSString *const kOTRCertificateServiceName;

extern NSString *const kGlacierServiceName;
extern NSString *const kGlacierKeyGroup;
extern NSString *const kGlacierAcct;
extern NSString *const kGlacierGroup;
extern NSString *const kGlacierAppIsActiveKey;
extern NSString *const kGlacierUserIsActiveKey;
extern NSString *const kCognitoAcct;
extern NSString *const kGlacierVpn;

extern NSString *const kGlacierSalt;
extern NSString *const kGlacierKeySpec;
extern NSString *const kGlacierMediaSalt;
extern NSString *const kGlacierMediaKeySpec;

extern NSString *const kGlacierBackup;

extern NSString *const kGlacierImage;

extern NSString *const kGlacierSettingKeyFontSize;
extern NSString *const kGlacierSettingKeyDeleteOnDisconnect;
extern NSString *const kGlacierSettingKeyAllowDBPassphraseBackup;
extern NSString *const kGlacierSettingKeyShowDisconnectionWarning;
extern NSString *const kGlacierSettingUserAgreedToEULA;
extern NSString *const kGlacierSettingAccountsKey;
extern NSString *const kGlacierSettingsValueUpdatedNotification;
typedef void (^GlacierSettingActionBlock)(id sender);
extern NSString *const kGlacierCoreConnection;
extern NSString *const kThreatDetectionKey;
extern NSString *const kLinkPreviewKey;
extern NSString *const kReadReceiptsKey;
extern NSString *const kRebootReminderKey;
extern NSString *const kTrackingOnKey;
extern NSString *const kBgTaskId;

extern NSString *const kGlacierAppVersionKey;

extern NSString *const GlacierArchiverKey;

extern NSString *const GlacierSuccessfulRemoteNotificationRegistration;

extern NSString *const GRDBDatabasePassphraseAccountName;

extern NSString *const GlacierMediaDatabaseName;

extern NSString *const GlacierGRDBPassphraseAccountName;
extern NSString *const GlacierMediaPassphraseName;

//Notifications

/// Used to lookup account for connection errors
extern NSString *const kGlacierNotificationAccountKey;
extern NSString *const kGlacierNotificationThreadKey;
extern NSString *const kGlacierNotificationThreadCollection;
extern NSString *const kGlacierNotificationType;
extern NSString *const kGlacierNotificationTypeNone;
extern NSString *const kGlacierNotificationTypeSubscriptionRequest;
extern NSString *const kGlacierNotificationTypeApprovedBuddy;
extern NSString *const kGlacierNotificationTypeConnectionError;
extern NSString *const kGlacierNotificationTypeChatMessage;

extern NSString *const kNotificationCallIdKey;
extern NSString *const kNotificationCallerKey;
extern NSString *const kNotificationRoomnameKey;
extern NSString *const kNotificationCallStatusKey;
extern NSString *const kNotificationTwilioType;
extern NSString *const kNotificationTwilioVoiceCall;
extern NSString *const kNotificationTwilioCallIdKey;
extern NSString *const kNotificationTwilioCallerKey;
extern NSString *const kNotificationVoicemailType;

// OMEMO-over-push: the push carries the message inside a sealed-box "ge" envelope so neither
// the routing metadata (JIDs/type) nor the ciphertext is visible to APNs. The NSE opens the
// envelope locally, then runs the existing OMEMO decrypt/classify/route on the recovered fields.
extern NSString *const kGlacierPushEnvelopeKey;        // userInfo dict: {alg, kid, data}
extern NSString *const kGlacierPushEnvelopeAlgKey;     // "alg"
extern NSString *const kGlacierPushEnvelopeKidKey;     // "kid"
extern NSString *const kGlacierPushEnvelopeDataKey;    // "data" (base64 sealed box)
extern NSString *const kGlacierPushSealedBoxAlg;       // "sealedbox-x25519-xsalsa20poly1305"
extern NSString *const kGlacierPushEncryptKeychainService; // SAMKeychain service for the X25519 keypair (account = kid)

// XData field vars added to the XEP-0357 enable IQ to register our push-encryption public key.
extern NSString *const kGlacierPushEncryptAlgField;    // "push-encrypt-alg"
extern NSString *const kGlacierPushEncryptPubkeyField; // "push-encrypt-pubkey" (base64 pk)
extern NSString *const kGlacierPushEncryptKidField;    // "push-encrypt-kid"
extern NSString *const kGlacierPushOmemoRidField;      // "push-omemo-rid" (our OMEMO device id, decimal)

extern NSString *const GlacierUserNotificationsChanged;
/** This is fired when you have a change to a device on a push account */
extern NSString *const GlacierPushAccountDeviceChanged;
/** This is fired when you have a change to your tokens */
extern NSString *const GlacierPushAccountTokensChanged;
extern NSString *const BuddyPendingApprovalDidChangeNotification;


extern NSString *const GlacierUserNotificationsUNTextInputReply;


//NSUserDefaults
extern NSString *const kGlacierPushEnabledKey;
/** Shows OMEMO Group Encryption toggle on group chat screen */
extern NSString *const kGlacierShowOMEMOGroupEncryptionKey;
/** Enables or disables debug file logging */
extern NSString *const kGlacierEnableDebugLoggingKey;

extern NSString *const kAudioPlaybackSpeed;

//Chatview
extern CGFloat const kGlacierSentDateFontSize;
extern CGFloat const kGlacierDeliveredFontSize;
extern CGFloat const kGlacierMessageFontSize;
extern CGFloat const kGlacierMessageSentDateLabelHeight;
extern CGFloat const kGlacierMessageDeliveredLabelHeight;

extern NSString *const kGlacierErrorDomain;

extern NSUInteger const kGlacierMinimumPassphraseLength;
extern NSUInteger const kGlacierMaximumPassphraseLength;

NS_ASSUME_NONNULL_END
