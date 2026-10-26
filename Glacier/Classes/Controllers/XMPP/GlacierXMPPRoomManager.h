//
//  GlacierXMPPRoomManager.h
//  ChatSecure
//
//  Created by David Chiles on 10/9/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;
@import XMPPFramework;

#import "GlacierBookmarks2Module.h"

@class RoomStorage;

NS_ASSUME_NONNULL_BEGIN
@interface GlacierXMPPRoomManager : XMPPModule

@property (nonatomic, strong, readonly) RoomStorage *roomStorage;
@property (nonatomic, strong, readonly) XMPPMessageArchiveManagement *archiving;
/** XEP-0048 private XML storage. Read-only fallback for servers that do not
    have the XEP-0402 node; iOS no longer writes to it. */
@property (nonatomic, strong, readonly) XMPPBookmarksModule *bookmarksModule;
/** XEP-0402 PEP native bookmarks. The store iOS reads and writes.
    nil once the module has been deactivated. */
@property (nonatomic, strong, readonly, nullable) GlacierBookmarks2Module *bookmarks2Module;
@property (nonatomic, strong, readonly, nullable)  NSArray<NSString*> *conferenceServicesJID;
@property (nonatomic, strong, readonly)  NSArray<NSString*> * _Nullable availableRooms;
@property (nonatomic, strong, readonly)  NSArray<NSString*> * _Nullable allRooms;
@property (nonatomic, strong, readonly)  NSMutableDictionary<NSString*,NSString*> * _Nullable allRoomsWithNames;

- (instancetype) init NS_UNAVAILABLE;
- (instancetype) initWithRoomStorage:(RoomStorage*)roomStorage
                           archiving:(XMPPMessageArchiveManagement*)archiving
                       dispatchQueue:(nullable dispatch_queue_t)dispatchQueue;

/** All room joining should go through this method. This ensures the delegates are setup properly and database is in sync. Returns ThreadOwner.threadIdentifier */
- (void)joinRoom:(XMPPJID *)jid
                   withNickname:(nullable NSString *)name
                        subject:(nullable NSString *)subject
                       password:(nullable NSString*)password
                     completion:(void (^ _Nullable)(NSString*))completion;

- (void)joinRoom:(XMPPJID *)jid
                   withNickname:(nullable NSString *)name
                        subject:(nullable NSString *)subject
                       password:(nullable NSString*)password
                       isPublic:(BOOL)ispublic
                     completion:(void (^ _Nullable)(NSString*))completion;

- (void)leaveRoom:(XMPPJID *)jid;
- (nullable XMPPRoom*) roomForJID:(XMPPJID*)jid;
- (void) setRoomName:(nonnull XMPPRoom*)room name:(nonnull NSString*)roomname;

/** Returns ThreadOwner.threadIdentifier. buddiesArray is array of ChatBuddy.uniqueId */
- (void)startGroupChatWithBuddies:(nullable NSArray <NSString *>*)buddiesArray
                                         roomJID:(XMPPJID *)roomName
                                        nickname:(nullable NSString *)name
                                         subject:(nullable NSString *)subject
                                        isPublic:(BOOL)ispublic
                                      completion:(void (^ _Nullable)(NSString*))completion;

- (void)inviteBuddies:(nullable NSArray<NSString *>*)buddyUniqueIds
               toRoom:(XMPPRoom*)room;

- (void)xmppMUC:(nullable XMPPMUC *)sender roomJID:(XMPPJID *)roomJID didReceiveInvitation:(XMPPMessage *)message;

- (void) publishJoinedRoom:(XMPPJID *)roomjid withName:(NSString *)name;

/** Publishes these rooms to the XEP-0402 bookmarks node, one item each. */
- (void)publishConferenceBookmarks:(NSArray<XMPPConferenceBookmark *> *)bookmarks;

- (void)clearOccupantRoleWithJID:(XMPPJID *)occupantJID;

@end

NS_ASSUME_NONNULL_END
