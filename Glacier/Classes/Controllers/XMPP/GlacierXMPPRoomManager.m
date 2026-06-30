//
//  GlacierXMPPRoomManager.m
//  ChatSecure
//
//  Created by David Chiles on 10/9/15.
//  Copyright © 2015 Chris Ballinger. All rights reserved.
//

#import "GlacierXMPPRoomManager.h"
#import "GlacierXMPPManager.h"
#import "GlacierProtocolManager.h"
@import XMPPFramework;
@import CocoaLumberjack;
#import "GlacierLog.h"
#import "UITableView+Glacier.h"
#import "Glacier-Swift.h"

@interface GlacierXMPPRoomManager () <XMPPMUCDelegate, XMPPRoomDelegate, XMPPStreamDelegate>

@property (nonatomic, strong, readonly) NSMutableDictionary<XMPPJID*,XMPPRoom*> *rooms;

@property (nonatomic, strong, readonly) XMPPMUC *mucModule;

/** This dictionary has jid as the key and array of buddy unique Ids to invite once we've joined the room*/
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString*,NSArray<NSString *> *> *inviteDictionary;
@property (nonatomic, strong, readonly) NSString *inviteAuthor;

/** This dictionary is a temporary holding for setting a room name. Once the room is created teh subject is set from this dictionary. */
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString*,NSString*> *tempRoomName;

/** This dictionary holds the desired public/private status of rooms to create. */
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString*,NSNumber*> *roomStatusDict;

/** This array is a temporary holding with rooms we should configure once connected */
@property (nonatomic, strong, readonly) NSMutableArray<NSString*> *roomsToConfigure;

@property (nonatomic) BOOL updateRoomName;

@property (nonatomic) BOOL addedCapsDelegate;

@property (nonatomic) NSInteger highSeedNum;

@end

@implementation GlacierXMPPRoomManager

-  (instancetype) initWithRoomStorage:(RoomStorage*)roomStorage
                            archiving:(XMPPMessageArchiveManagement*)archiving
                        dispatchQueue:(nullable dispatch_queue_t)dispatchQueue {
    if (self = [super initWithDispatchQueue:dispatchQueue]) {
        _roomStorage = roomStorage;
        _archiving = archiving;
        _mucModule = [[XMPPMUC alloc] init];
        _inviteDictionary = [[NSMutableDictionary alloc] init];
        _roomStatusDict = [[NSMutableDictionary alloc] init];
        _tempRoomName = [[NSMutableDictionary alloc] init];
        _roomsToConfigure = [[NSMutableArray alloc] init];
        _rooms = [[NSMutableDictionary alloc] init];
        _allRoomsWithNames = [[NSMutableDictionary alloc] init];
        _bookmarksModule = [[XMPPBookmarksModule alloc] initWithMode:XMPPBookmarksModePrivateXmlStorage dispatchQueue:nil];
    }
    self.addedCapsDelegate = NO;
    self.updateRoomName = NO;
    self.highSeedNum = -1;
    return self;
}

- (BOOL)activate:(XMPPStream *)aXmppStream
{
    BOOL result = [super activate:aXmppStream];
    [self.mucModule activate:aXmppStream];
    [self.mucModule addDelegate:self delegateQueue:moduleQueue];
    [multicastDelegate addDelegate:self delegateQueue:moduleQueue];
    
    [self.bookmarksModule activate:self.xmppStream];
    
    return result;
}

- (void) deactivate {
    
    // clear rooms
    [self.rooms enumerateKeysAndObjectsUsingBlock:^(id jid, id room, BOOL* stop) {
        [self removeRoomForJID:jid];
        [room removeDelegate:self];
        [room deactivate];
    }];
    
    [self.mucModule removeDelegate:self];
    [self.mucModule deactivate];
    [self.bookmarksModule deactivate];
    
    [multicastDelegate removeDelegate:self];
    
    [super deactivate];
    
    _roomStorage = nil;
    _archiving = nil;
    _mucModule = nil;
    _inviteDictionary = nil;
    _roomStatusDict = nil;
    _tempRoomName = nil;
    _roomsToConfigure = nil;
    _rooms = nil;
    _bookmarksModule = nil;
}

- (void)joinRoom:(XMPPJID *)jid withNickname:(NSString *)name subject:(NSString *)subject password:(nullable NSString *)password completion:(void (^)(NSString*))completion
{
    [self joinRoom:jid withNickname:name subject:subject password:password isPublic:NO completion:completion];
}

- (void)joinRoom:(XMPPJID *)jid withNickname:(NSString *)name subject:(NSString *)subject password:(nullable NSString *)password isPublic:(BOOL)ispublic completion:(void (^)(NSString*))completion
{
    dispatch_async(moduleQueue, ^{
        if ([subject length]) {
            [self.tempRoomName setObject:subject forKey:jid.bare];
        }
    });
    
    [self createRoomIfNeeded:jid accountId:self.xmppStream.tag isPublic:ispublic seedNum:self.highSeedNum completion:^(ChatRoomModel *xroom) {// completion:^(ChatRoomModel *xroom){
        [self performBlockAsync:^{
            NSString* accountId = self.xmppStream.tag;
            NSString *databaseRoomKey = [ChatRoomModel createUniqueId:accountId jid:jid.bare];
            NSString *nickname = name;
            __block ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId: accountId];
            // Already joined? Can happen if we have auto-join bookmarks.
            XMPPRoom *room = [self roomForJID:jid];
            if (room && room.isJoined) {
                if (completion) {
                    completion(databaseRoomKey);
                }
                return;
            }
            
            if (!room) {
                room = [[XMPPRoom alloc] initWithRoomStorage:self.roomStorage jid:jid];
                [self setRoom:room forJID:room.roomJID];
                [room activate:self.xmppStream];
                [room addDelegate:self delegateQueue:moduleQueue];
            }
            
            // query for disco#info to find public/private
            dispatch_async(moduleQueue, ^{
                @try {
                    //ChatAccountModel *account = [ChatAccountModel accountForStream:self.xmppStream];
                    GlacierXMPPManager *xmppManager = [[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:account];
                    if (xmppManager != nil) {
                        if(!self.addedCapsDelegate) {
                            self.addedCapsDelegate = YES;
                            [xmppManager.serverCheck.xmppCapabilities addDelegate:self delegateQueue:self->moduleQueue];
                        }
                        [xmppManager.serverCheck.xmppCapabilities sendDiscoInfoQueryTo:jid withNode:nil ver:nil];
                    }
                }
                @catch ( NSException *e ) {
                    //
                }
            });
            
            if (!nickname) {
                //ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId: accountId];
                nickname = account.bareJID.user;
            }
            
            /** Create room database object */
            id<MessageProtocol> lastMessage;
            if (xroom) {
                lastMessage = [xroom lastMessage];
            }
            
            //Get history if any
            NSXMLElement *historyElement = nil;
            if (lastMessage) {
                NSDate *lastMessageDate = [lastMessage messageDate];
                if (lastMessageDate) {
                    //Use since as our history marker if we have a last message
                    //http://xmpp.org/extensions/xep-0045.html#enter-managehistory
                    NSString *dateTimeString = [lastMessageDate xmppDateTimeString];
                    historyElement = [NSXMLElement elementWithName:@"history"];
                    [historyElement addAttributeWithName:@"since" stringValue:dateTimeString];
                }
            }
            
            [room joinRoomUsingNickname:nickname history:historyElement password:password];
            if (completion) {
                completion(databaseRoomKey);
            }
        }];
    }];
}

- (void)createRoomIfNeeded:(XMPPJID *)jid completion:(void (^)(ChatRoomModel*))completion {
    NSString* accountId = self.xmppStream.tag;
    NSString *databaseRoomKey = [ChatRoomModel createUniqueId:accountId jid:jid.bare];
    
    ChatRoomModel *xroom = [ChatRoomModel getXMPPRoomWithUniqueId:databaseRoomKey];
    if(!xroom) {
        xroom = [[ChatRoomModel alloc] initWithAccountId:accountId jid:jid.bare];
        xroom.avatarSeedNum = [xroom nextAvatarNumWith:self.highSeedNum];
        
        ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:accountId];
        ChatThreadModel *thread = [[ChatThreadModel alloc] initWithAccountId:account.accountId uniqueId:xroom.uniqueId isGroup:YES];
        [thread saveThreadWithCompletion:^{
            ChatThreadModel *tmodel = [ChatThreadModel getChatThreadWithUniqueId:thread.uniqueId];
            xroom.chatThreadId = tmodel.threadIdentifier;
            [xroom saveThreadWithCompletion:^{
                if (completion) {
                    completion(xroom);
                }
            }];
        }];
    } else {
        if (xroom.avatarSeedNum < 0) {
            xroom.avatarSeedNum = [xroom nextAvatarNumWith:self.highSeedNum];
            [xroom saveThread];
            if (completion) {
                completion(xroom);
            }
        }
    }
}

- (void)xmppCapabilities:(XMPPCapabilities *)sender didDiscoverCapabilities:(NSXMLElement *)caps forJID:(XMPPJID *)jid {
    DDLogInfo(@"New caps in GlacierXMPPManager: %@ for %@", caps, [jid bare]);
    NSXMLElement * identity  = [caps elementForName:@"identity"];
    if (identity) {
        NSString* cat = [identity attributeStringValueForName:@"category"];
        NSString* type = [identity attributeStringValueForName:@"type"];
        NSString* name = [identity attributeStringValueForName:@"name"];
        if ([cat isEqualToString:@"conference"] && [type isEqualToString:@"text"]) {
            XMPPRoom *room = [self roomForJID:jid];
            ChatRoomModel *xroom = nil;
            
            if (room) {
                xroom = [self roomWithXMPPRoom:room];
                __block BOOL changed = NO;
                if (name != nil) {
                    if (xroom && ![xroom.roomName isEqualToString:name]) {
                        xroom.roomName = name;
                        changed = YES;
                    }
                } //if its a new room (ie invited) there might not be a name
                
                NSNumber *pubnum = [self.roomStatusDict objectForKey:room.roomJID.bare];
                if (pubnum != nil && [pubnum boolValue] == NO) {
                    //do nothing
                } else {
                    NSArray *features = [caps elementsForName:@"feature"];
                    [features enumerateObjectsUsingBlock:^(NSXMLElement * _Nonnull feature, NSUInteger idx, BOOL * _Nonnull stop) {
                        NSString *value = [feature attributeStringValueForName:@"var"];
                        if ([value isEqualToString:@"muc_open"]) {
                            if (!xroom.isPublic) {
                                xroom.isPublic = YES;
                                changed = YES;
                            }
                            *stop = YES;
                        }
                    }];
                }
                
                if (changed) {
                    [xroom saveThread];
                }
            }
        }
    }
}

- (void)leaveRoom:(nonnull XMPPJID *)jid
{
    XMPPRoom *room = [self roomForJID:jid];
    [room leaveRoom];
    [self removeRoomForJID:jid];
    [room removeDelegate:self];
    [room deactivate];
}

- (void)clearOccupantRolesInRoom:(ChatRoomModel *)room {
    NSArray<ChatRoomOccupantModel *> *occsArray = [ChatRoomOccupantModel allXMPPRoomOccupantsFor:room.uniqueId];
    [occsArray enumerateObjectsUsingBlock:^(ChatRoomOccupantModel * _Nonnull occupant, NSUInteger idx, BOOL * _Nonnull stop) {
        occupant.role = RoomOccupantRoleNone;
        [occupant save];
    }];
}

- (void)clearOccupantRoleWithJID:(XMPPJID *)occupantJID {
}

- (void)startGroupChatWithBuddies:(NSArray<NSString *> *)buddiesArray roomJID:(XMPPJID *)roomName nickname:(NSString *)name subject:(nullable NSString *)subject isPublic:(BOOL)ispublic completion:(void (^)(NSString*))completion
{
    if (buddiesArray.count) {
        [self performBlockAsync:^{
            [self.inviteDictionary setObject:buddiesArray forKey:roomName.bare];
        }];
    }
    if (!ispublic) {
        _inviteAuthor = name;
    }
    [self.roomStatusDict setObject:[NSNumber numberWithBool:ispublic] forKey:roomName.bare];
    [self.roomsToConfigure addObject:roomName.bare];
    XMPPConferenceBookmark *bookmark = [[XMPPConferenceBookmark alloc] initWithJID:roomName bookmarkName:subject nick:name autoJoin:YES];
    [self.bookmarksModule fetchAndPublishWithBookmarksToAdd:@[bookmark] bookmarksToRemove:nil completion:^(NSArray<id<XMPPBookmark>> * _Nullable newBookmarks, XMPPIQ * _Nullable responseIq) {
        if (newBookmarks) {
            DDLogInfo(@"Joined new room, added to merged bookmarks: %@", newBookmarks);
        }
    } completionQueue:nil];
    //save thread first?
    [self joinRoom:roomName withNickname:name subject:subject password:nil isPublic:ispublic completion:completion];
}

- (void)inviteBuddies:(NSArray<NSString *> *)buddyUniqueIds toRoom:(XMPPRoom *)room {
    if (!buddyUniqueIds.count) {
        return;
    }
    
    NSMutableArray<NSString*> *buddyNames = [NSMutableArray arrayWithCapacity:buddyUniqueIds.count];
    if (_inviteAuthor != nil) {
        [buddyNames addObject:[_inviteAuthor copy]];
        _inviteAuthor = nil;
    }
    
    NSMutableArray<XMPPJID*> *buddyJIDs = [NSMutableArray arrayWithCapacity:buddyUniqueIds.count];
    
    [buddyUniqueIds enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        ChatBuddyModel *buddy = [ChatBuddyModel getBuddyWithUniqueId:obj];
        XMPPJID *buddyJID = buddy.bareJID;
        if (buddyJID) {
            [buddyJIDs addObject:buddyJID];
            [buddyNames addObject:buddy.threadName];
        }
    }];
    // XMPPRoom.inviteUsers doesn't seem to work, so you have
    // to send an individual invitation for each person.
    NSMutableArray<NSXMLElement*> *invitees = [NSMutableArray arrayWithCapacity:buddyJIDs.count];
    [buddyJIDs enumerateObjectsUsingBlock:^(XMPPJID * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [room inviteUser:obj withMessage:nil];
        
        NSXMLElement *item = [[NSXMLElement alloc] initWithName:@"item"];
        [item addAttributeWithName:@"jid" stringValue:obj.bare];
        [item addAttributeWithName:@"affiliation" stringValue:@"member"];
        [invitees addObject:item];
    }];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self publishInvitedBuddyList:room withBuddies:buddyNames occupantItems:invitees];
    });
}

// send message to the room with invitedBuddy list
- (void) publishInvitedBuddyList:(XMPPRoom *)room withBuddies:(NSArray<NSString *> *)buddyNames occupantItems:(NSArray<NSXMLElement*> *)items {
    NSString *invitedString = [[buddyNames componentsJoinedByString:@", "] stringByAppendingString:@" added to the group"];
    ChatRoomModel *xroom = [self roomWithXMPPRoom:room];
    if (xroom) {
        id<MessageProtocol> message = [xroom outgoingMessageWithText:invitedString];
        ChatRoomMessageModel *roommsg = (ChatRoomMessageModel *)message;
        roommsg.memberUpdate = YES;
        roommsg.messageOriginalText = invitedString;
        ChatAccountModel *account = [ChatAccountModel accountForStream:self.xmppStream];
        GlacierXMPPManager *xmppManager = (GlacierXMPPManager *)[[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:account];
        
        if (roommsg != nil && xmppManager != nil) {
            [xmppManager enqueueMessage:roommsg];
            [room fetchMembersList];
        }
        
        if (xroom.isPublic) {
            [self xmppRoom:room addOccupantItems:items];
        }
    }
}

// send message to the room joined
- (void) publishJoinedRoom:(XMPPJID *)roomjid withName:(NSString *)name{
    NSArray *buddyme = [NSArray arrayWithObjects: name, nil];
    XMPPRoom *room = [self roomForJID:roomjid];
    [self publishInvitedBuddyList:room withBuddies:buddyme occupantItems:[[NSArray alloc] init]];
}

#pragma - mark XMPPStreamDelegate Methods

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
            //back to xmppQueue
            [self performBlockAsync:^{
                [self handleStreamDidAuthenticate:sender];
            }];
        }
    });
}

- (void)handleStreamDidAuthenticate:(XMPPStream *)sender {
    //Once we've connecected and authenticated we find what room services are available
    [self.mucModule discoverServices];
    //Once we've authenitcated we need to rejoin existing rooms
    
    NSMutableArray <ChatRoomModel *>*roomArray = [[NSMutableArray alloc] init];
    NSString *nickname = self.xmppStream.myJID.user;
    ChatAccountModel *account = [ChatAccountModel accountForStream:sender];
    if (account) {
        nickname = account.displayName;
    }
        
    NSArray<ChatRoomModel*> *allRoomArray = [ChatRoomModel allXMPPRoomsFor:account.uniqueId];
    for (ChatRoomModel *room in allRoomArray) {
        if ([room.uniqueId containsString:sender.tag] && room.roomJID) {
            [roomArray addObject:room];
                
            if (room.avatarSeedNum > self.highSeedNum) {
                self.highSeedNum = room.avatarSeedNum;
            }
        }
    }
    
    [roomArray enumerateObjectsUsingBlock:^(ChatRoomModel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [self joinRoom:obj.roomJID withNickname:nickname subject:obj.subject password:obj.roomPassword completion:nil];
    }];
    
    [self addRoomsToBookmarks:roomArray];
    
    [self.bookmarksModule fetchBookmarks:^(NSArray<id<XMPPBookmark>> * _Nullable bookmarks, XMPPIQ * _Nullable responseIq) {
        
    } completionQueue:nil];
}

- (void)xmppStream:(XMPPStream *)sender didFailToSendMessage:(XMPPMessage *)message error:(NSError *)error
{
    //Check id and mark as needs sending
    
}

- (void)xmppStream:(XMPPStream *)sender didSendMessage:(XMPPMessage *)message
{
    //Check id and mark as sent
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)message
{
    XMPPJID *from = [message from];
    XMPPRoom *room = [self roomForJID:from]; 
    //Check that this is a message for one of our rooms
    if([message isGroupChatMessageWithSubject] && room != nil) {
        
        NSString *subject = [message subject];
        
        NSString *databaseRoomKey = [ChatRoomModel createUniqueId:self.xmppStream.tag jid:from.bare];
        
        ChatRoomModel *room = [ChatRoomModel getXMPPRoomWithUniqueId:databaseRoomKey];
        room.subject = subject;
        [room saveThread];
    }
    
    // Handle group chat message receipts
    [ChatRoomMessageModel handleDeliveryReceiptResponseWithMessage:message];
}

// looking for errors when (re)joining room
- (void)xmppStream:(XMPPStream *)sender didReceivePresence:(XMPPPresence *)presence
{
    DDLogVerbose(@"%@: %@\n%@", THIS_FILE, THIS_METHOD, presence.prettyXMLString);
    XMPPJID *to = [presence to];
    
    if (![to isEqualToJID:self.xmppStream.myJID options:XMPPJIDCompareBare]){
        return; // Stanza isn't for me
    }
    
    NSString *presenceType = [presence type];
    if (presenceType == nil) { return; }
    
    if ([presenceType isEqualToString:@"error"]) {
        XMPPJID *from = [presence from];
        NSString *fromDomain = from.domain;
        if (fromDomain != nil && [fromDomain hasPrefix:@"conference"]) {
            // check group size before putting it in list?
            NSXMLElement * errorel  = [presence elementForName:@"error"];
            if (errorel) {
                NSXMLElement * errortext  = [errorel elementForName:@"text"];
                if (errortext && [[errortext stringValue] containsString:@"destroyed"]) {
                    dispatch_async(dispatch_get_main_queue(), ^(void){
                        [self performSelector:@selector(removeRoomOnDestroyed:) withObject:from afterDelay:1.0];
                    });
                } else if (errortext && [[errortext stringValue] containsString:@"Too many users"]){
                    dispatch_async(dispatch_get_main_queue(), ^(void){
                        [self performSelector:@selector(tooManyUsersError:) withObject:from afterDelay:1.0];
                    });
                } else if (errortext && [[errortext stringValue] containsString:@"Membership is required"]){
                    dispatch_async(dispatch_get_main_queue(), ^(void){
                        [self performSelector:@selector(removeRoomOnDestroyed:) withObject:from afterDelay:1.0];
                    });
                }
            }
        }
    } else if ([presenceType isEqualToString:@"unavailable"]) {
        NSXMLElement *x = [presence elementForName:@"x" xmlns:XMPPMUCUserNamespace];
        if (x) {
            NSXMLElement *destroy = [x elementForName:@"destroy"];
            
            if (destroy) {
                XMPPJID *xjid = [presence from].bareJID;
                dispatch_async(moduleQueue, ^{
                    [self removeRoomOnDestroyed:xjid];
                });
            } /*else {
                NSXMLElement *item = [x elementForName:@"item"];
                NSString *role = [item attributeStringValueForName:@"role"];
                NSString *affiliation = [item attributeStringValueForName:@"affiliation"];
                if (role != nil && affiliation != nil && [role isEqualToString:@"none"] && [affiliation isEqualToString:@"none"]) {
                    XMPPJID *xjid = [presence from].bareJID;
                    dispatch_async(moduleQueue, ^{
                        [self removeRoomOnDestroyed:xjid kicked:YES];
                    });
                }
            }*/
        }
    }
}

- (void) tooManyUsersError:(XMPPJID*)roomjid  {
    NSString *amsg = [NSString stringWithFormat:@"The %@ group is currently full. Please try again later.", roomjid.user];
    UIAlertAction * cancelButtonItem = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Problem joining group" message:amsg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:cancelButtonItem];
    [GlacierAppDelegate.appDelegate.window.rootViewController  presentViewController:alert animated:YES completion:nil];
}

- (void) removeRoomOnKicked:(XMPPJID*)roomjid {
    [self removeRoomOnDestroyed:roomjid kicked:YES];
}

- (void) removeRoomOnDestroyed:(XMPPJID*)roomjid {
    [self removeRoomOnDestroyed:roomjid kicked:NO];
}

// this happens when room no longer exists or we are kicked out and we try to enter it
// updated for
- (void) removeRoomOnDestroyed:(XMPPJID*)roomjid kicked:(BOOL)kicked{
    [self performBlockAsync:^{
        __block ChatAccountModel *account = [ChatAccountModel accountForStream:self.xmppStream];
        ChatRoomModel *foundroom = [ChatRoomModel getXMPPRoomWithRoomJid:roomjid];
        if (foundroom != nil) {
            [self removeRoomsFromBookmarks:@[foundroom]];
            __weak typeof(self)weakSelf = self;
            [foundroom removeWithCompletionBlock:^{
                XMPPRoom *xroom = [self roomForJID:roomjid];
                if (xroom != nil) {
                    if (account != nil) {
                        [xroom unsubscribeFromRoom: account.bareJID];
                    }
                    [xroom leaveRoom];
                    [xroom removeDelegate:self];
                    [xroom deactivate];
                } else {
                    return;
                }
                __strong typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf removeRoomForJID:roomjid];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:ReloadDataNotificationName object:self userInfo:nil];
                    
                    NSString *amsg = [NSString stringWithFormat:@"The %@ group was deleted, so you won’t see it in your conversations anymore.", roomjid.user];
                    if (kicked) {
                        amsg = [NSString stringWithFormat:@"You are no longer a member of the %@ group, so you won’t see it in your conversations anymore.", roomjid.user];
                    }
                    UIAlertAction * cancelButtonItem = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil];
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Group removed" message:amsg preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:cancelButtonItem];
                    [GlacierAppDelegate.appDelegate.window.rootViewController presentViewController:alert animated:YES completion:nil];
                });
            }];
        }
    }];
}


#pragma - mark XMPPMUCDelegate Methods

- (void)xmppMUC:(XMPPMUC *)sender didDiscoverServices:(NSArray *)services
{
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:[services count]];
    [services enumerateObjectsUsingBlock:^(NSXMLElement   * _Nonnull element, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *jid = [element attributeStringValueForName:@"jid"];
        if ([jid length] && [jid containsString:@"conference"]) {
            [array addObject:jid];
            //TODO instead of just checking if it has the word 'confernce' in the name we need to preform a iq 'get' to see it's capabilities.
            
        }
        
    }];
    _conferenceServicesJID = array;
    
    if ([_conferenceServicesJID count] > 0) {
        [self.mucModule discoverRoomsForServiceNamed:[_conferenceServicesJID firstObject]];
    }
}

// what rooms are available for our service
- (void)xmppMUC:(XMPPMUC *)sender didDiscoverRooms:(NSArray *)rooms forServiceNamed:(NSString *)serviceName
{
    NSMutableArray <NSString *>*curRoomArray = [[NSMutableArray alloc] init];
    NSArray<ChatRoomModel*> *allRoomArray = [ChatRoomModel allXMPPRooms];
    for (ChatRoomModel *room in allRoomArray) {
        if (room.roomJID != nil) {
            [curRoomArray addObject:room.roomJID.bare];
        }
    }
    
    NSMutableDictionary<NSString*,NSString*> *roomsNames = [[NSMutableDictionary alloc] init];
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:[rooms count]];
    NSMutableArray *allarray = [NSMutableArray arrayWithCapacity:[rooms count]];
    [rooms enumerateObjectsUsingBlock:^(NSXMLElement   * _Nonnull element, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *jid = [element attributeStringValueForName:@"jid"];
        NSString *name = [element attributeStringValueForName:@"name"];
        if ([jid length] && ![curRoomArray containsObject:jid]) {
            [array addObject:jid];
        }
        if ([jid length]) {
            [allarray addObject:jid];
            [roomsNames setObject:name forKey:jid];
        }
    }];
    _availableRooms = array;
    _allRooms = allarray;
    _allRoomsWithNames = roomsNames;
}

- (void)xmppMUC:(XMPPMUC *)sender roomJID:(XMPPJID *)roomJID didReceiveInvitation:(XMPPMessage *)message
{
    // We must check if we trust the person who invited us
    // because some servers will send you invites from anyone
    // We should probably move some of this code upstream into XMPPFramework
    
    // Since XMPP is super great, there are (at least) two ways to receive a room invite.

    // Examples from XEP-0045:
    // Example 124. Room Sends Invitation to New Member:
    //
    // <message from='darkcave@chat.shakespeare.lit' to='hecate@shakespeare.lit'>
    //   <x xmlns='http://jabber.org/protocol/muc#user'>
    //     <invite from='bard@shakespeare.lit'/>
    //     <password>cauldronburn</password>
    //   </x>
    // </message>
    //
    
    // Examples from XEP-0249:
    //
    //
    // Example 1. A direct invitation
    //
    // <message from='crone1@shakespeare.lit/desktop' to='hecate@shakespeare.lit'>
    //   <x xmlns='jabber:x:conference'
    //      jid='darkcave@macbeth.shakespeare.lit'
    //      password='cauldronburn'
    //      reason='Hey Hecate, this is the place for all good witches!'/>
    // </message>
    
    XMPPJID *fromJID = nil;
    NSString *password = nil;
    
    NSXMLElement * roomInvite = [message elementForName:@"x" xmlns:XMPPMUCUserNamespace];
    NSXMLElement * directInvite = [message elementForName:@"x" xmlns:@"jabber:x:conference"];
    if (roomInvite) {
        // XEP-0045
        NSXMLElement * invite  = [roomInvite elementForName:@"invite"];
        fromJID = [XMPPJID jidWithString:[invite attributeStringValueForName:@"from"]];
        password = [roomInvite elementForName:@"password"].stringValue;
    } else if (directInvite) {
        // XEP-0249
        fromJID = [message from];
        password = [directInvite attributeStringValueForName:@"password"];
    }
    if (!fromJID) {
        DDLogWarn(@"Could not parse fromJID from room invite: %@", message);
        return;
    }
    
    XMPPStream *stream = self.xmppStream;
    NSString *accountUniqueId = stream.tag;
    NSString *nickname = stream.myJID.user;
    ChatAccountModel *account = [ChatAccountModel accountForStream:stream];
    if (account) {
        nickname = account.displayName;
    }
    
    //how do I query the server for room characteristics?
    
    [ChatBuddyModel fetchBuddyAsyncWithJid:fromJID accountUniqueId:accountUniqueId queue:self.moduleQueue completion:^(ChatBuddyModel *buddy){
        // We were invited by someone not on our roster. Shady business!
        if (!buddy) {
            DDLogWarn(@"Received room invitation from someone not on our roster! %@ %@", fromJID, message);
            return;
        }
        //create thread?
        [self joinRoom:roomJID withNickname:nickname subject:nil password:password completion:nil];
    }];
}

#pragma - mark XMPPRoomDelegate Methods

- (ChatRoomModel*)roomWithXMPPRoom:(XMPPRoom*)xmppRoom {
    NSString *databaseRoomKey = [ChatRoomModel createUniqueId:self.xmppStream.tag jid:[xmppRoom.roomJID bare]];
    
    return [ChatRoomModel getXMPPRoomWithUniqueId:databaseRoomKey];
}

- (RoomRuntimeProperties *)roomRuntimeProperties:(XMPPRoom*)xmppRoom {
    ChatRoomModel *room = [self roomWithXMPPRoom:xmppRoom];
    if (room) {
        return [BuddyCache.shared runtimePropertiesForRoom:room];
    }
    return nil;
}

- (void) fetchHistoryIfListsDownloaded:(XMPPRoom *)xmppRoom {
    RoomRuntimeProperties *properties = [self roomRuntimeProperties:xmppRoom];
    if (properties && !properties.hasFetchedHistory &&
        properties.hasFetchedMembers &&
        properties.hasFetchedAdmins &&
        properties.hasFetchedOwners) {
        properties.hasFetchedHistory = YES;
        //[self fetchHistoryFor:xmppRoom];
    }
}

- (void) xmppRoom:(XMPPRoom *)room didEditPrivileges:(nonnull XMPPIQ *)iqResult {
    [self performBlockAsync:^{
        [room fetchMembersList];
    }];
}

- (void) xmppRoom:(XMPPRoom *)room didFetchMembersList:(NSArray<NSXMLElement*> *)items {
    //DDLogInfo(@"Fetched members list: %@", items);
    
    ChatRoomModel *xroom = [self roomWithXMPPRoom:room];
    NSArray<ChatRoomOccupantModel*> *allOccs = [ChatRoomOccupantModel allXMPPRoomOccupantsFor:xroom.uniqueId];
    
    NSString *occjid;
    BOOL found = NO;
    NSMutableArray *removeArray = [[NSMutableArray alloc] init];
    for (ChatRoomOccupantModel *occupant in allOccs) {
        if (occupant.affiliation == RoomOccupantAffiliationOwner || occupant.affiliation == RoomOccupantAffiliationAdmin) {
            continue;
        }
        
        occjid = occupant.realJID.bare;
        found = NO;
        for (NSXMLElement * elem in items) {
            NSString *jid = [elem attributeStringValueForName:@"jid"];
            if ([jid isEqualToString:occjid]) {
                found = YES;
                break;
            }
        }
        
        if (!found && !xroom.isPublic) { //don't remove occupants from public rooms
            [removeArray addObject:occupant];
        }
    }
    
    for (ChatRoomOccupantModel *occupant in removeArray) {
        DDLogInfo(@"didFetchMembersList Removing %@ from %@", occupant.realJID.bare, room.roomJID.bare);
        [occupant remove];
    }
    
    [self xmppRoom:room addOccupantItems:items];
    [[self roomRuntimeProperties:room] setHasFetchedMembers:YES];
    [self fetchHistoryIfListsDownloaded:room];
}

- (void)xmppRoom:(XMPPRoom *)room didNotFetchMembersList:(XMPPIQ *)iqError {
    [[self roomRuntimeProperties:room] setHasFetchedMembers:YES];
    [self fetchHistoryIfListsDownloaded:room];
}

- (void) xmppRoom:(XMPPRoom *)room didFetchAdminsList:(NSArray<NSXMLElement*> *)items {
    //DDLogInfo(@"Fetched admins list: %@", items);
    [self xmppRoom:room addOccupantItems:items];
    [[self roomRuntimeProperties:room] setHasFetchedAdmins:YES];
    [self fetchHistoryIfListsDownloaded:room];
}
     
- (void)xmppRoom:(XMPPRoom *)room didNotFetchAdminsList:(XMPPIQ *)iqError {
    [[self roomRuntimeProperties:room] setHasFetchedAdmins:YES];
    [self fetchHistoryIfListsDownloaded:room];
}

- (void) xmppRoom:(XMPPRoom *)room didFetchOwnersList:(NSArray<NSXMLElement*> *)items {
    //DDLogInfo(@"Fetched owners list: %@", items);
    [self xmppRoom:room addOccupantItems:items];
    [[self roomRuntimeProperties:room] setHasFetchedOwners:YES];
    [self fetchHistoryIfListsDownloaded:room];
}

- (void)xmppRoom:(XMPPRoom *)room didNotFetchOwnersList:(XMPPIQ *)iqError {
    [[self roomRuntimeProperties:room] setHasFetchedOwners:YES];
    [self fetchHistoryIfListsDownloaded:room];
}

- (void)xmppRoom:(XMPPRoom *)room didFetchModeratorsList:(NSArray *)items {
    //DDLogInfo(@"Fetched moderators list: %@", items);
    [self xmppRoom:room addOccupantItems:items];
}

- (void) xmppRoom:(XMPPRoom *)room addOccupantItems:(NSArray<NSXMLElement*> *)items {
    NSAssert([room.xmppRoomStorage isKindOfClass:RoomStorage.class], @"Wrong room storage class");
    if ([room.xmppRoomStorage isKindOfClass:RoomStorage.class]) {
        RoomStorage *roomStorage = (RoomStorage*)room.xmppRoomStorage;
        [roomStorage insertOccupantItems:items into:room];
    } else {
        DDLogError(@"Could not store occupants. Wrong room storage class!");
    }
}

- (void)xmppRoomDidCreate:(XMPPRoom *)sender {
    [self.roomsToConfigure removeObject:sender.roomJID.bare];
    [sender fetchConfigurationForm];
}

- (void)xmppRoom:(XMPPRoom *)sender didFetchConfigurationForm:(DDXMLElement *)configForm {
    BOOL ispublic = NO;
    NSNumber *pubnum = [self.roomStatusDict objectForKey:sender.roomJID.bare];
    if (pubnum != nil) {
        ispublic = [pubnum boolValue];
        [self.roomStatusDict removeObjectForKey:sender.roomJID.bare];
    }
    
    NSString *roomname = [self.tempRoomName objectForKey:sender.roomJID.bare];
    if (self.updateRoomName) {
        [sender configureRoomUsingOptions:[[self class] roomNameConfiguration:configForm withName:roomname]];
    } else {
        [sender configureRoomUsingOptions:[[self class] defaultRoomConfiguration:ispublic roomname:roomname]];
    }
    self.updateRoomName = NO;
}

- (void)xmppRoom:(XMPPRoom *)sender didConfigure:(XMPPIQ *)iqResult {
    //Set Room Name
    NSString *name = [self.tempRoomName objectForKey:sender.roomJID.bare];
    NSNumber *pubnum = [self.roomStatusDict objectForKey:sender.roomJID.bare];
    BOOL ispublic = NO;
    if (name) {
        [self.tempRoomName removeObjectForKey:sender.roomJID.bare];
        
        __block ChatRoomModel *xroom = [self roomWithXMPPRoom:sender];
        if (xroom && ![xroom.roomName isEqualToString:name]) {
            xroom.roomName = name;
            [xroom setModified];
            [xroom saveThreadWithCompletion:^{
                [GlacierAppDelegate.appDelegate.chatRoomViewController resetRoom];
                dispatch_async(moduleQueue, ^{
                    NSString *xuid = xroom.uniqueId;
                    ChatThreadModel *tmodel = [ChatThreadModel getChatThreadWithUniqueId:xuid];
                    if (tmodel) {
                        [tmodel saveThread];
                    }
                });
            }];
        }
        //[sender changeRoomSubject:name];
    }
    
    //Invite buddies
    NSArray<NSString*> *buddyUniqueIds = [self.inviteDictionary objectForKey:sender.roomJID.bare];
    if (buddyUniqueIds) {
        [self.inviteDictionary removeObjectForKey:sender.roomJID.bare];
        [self inviteBuddies:buddyUniqueIds toRoom:sender];
    }

    // Fetch member list. Ideally this would be done after the invites above have been sent to the network, but the messages pass all kinds of async delegates before they are actually sent, so unfortunately we can't wait for that.
    [self performBlockAsync:^{
            [sender fetchMembersList];
            [sender fetchAdminsList];
            [sender fetchOwnersList];
            [sender fetchModeratorsList];
    }];
}

- (void)xmppRoomDidJoin:(XMPPRoom *)sender
{
    // Older prosody servers have a bug where they consider all room as already
    // existing, so the status 201 is never sent.
    if ([self.roomsToConfigure containsObject:sender.roomJID.bare]) {
        [self xmppRoomDidCreate:sender];
    } else {
        // Fetch member list
        [self performBlockAsync:^{
            [sender fetchMembersList];
            [sender fetchAdminsList];
            [sender fetchOwnersList];
            [sender fetchModeratorsList];
        }];
    }
}

- (void)xmppRoomDidLeave:(XMPPRoom *)sender {
    NSString *databaseRoomKey = [ChatRoomModel createUniqueId:self.xmppStream.tag jid:[sender.roomJID bare]];
    ChatRoomModel *room = [ChatRoomModel getXMPPRoomWithUniqueId:databaseRoomKey];
    if (room) {
        [self clearOccupantRolesInRoom:room];
    }
}

// placeholder for better tracking room member list? (next one also)
- (void)xmppRoom:(XMPPRoom *)sender occupantDidJoin:(XMPPJID *)occupantJID withPresence:(XMPPPresence *)presence
{
}

- (void)xmppRoom:(XMPPRoom *)sender occupantDidLeave:(XMPPJID *)occupantJID withPresence:(XMPPPresence *)presence {
}

#pragma mark - Utility

- (void) removeRoomForJID:(nonnull XMPPJID*)jid {
    NSParameterAssert(jid != nil);
    if (!jid) { return; }
    [self performBlockAsync:^{
        [self.rooms removeObjectForKey:jid.bareJID];
    }];
}

- (void) setRoom:(nonnull XMPPRoom*)room forJID:(nonnull XMPPJID*)jid {
    NSParameterAssert(room != nil);
    NSParameterAssert(jid != nil);
    if (!room || !jid) {
        return;
    }
    [self performBlockAsync:^{
        [self.rooms setObject:room forKey:jid.bareJID];
    }];
}

- (nullable XMPPRoom*) roomForJID:(nonnull XMPPJID*)jid {
    NSParameterAssert(jid != nil);
    if (!jid) { return nil; }
    __block XMPPRoom *room = nil;
    [self performBlock:^{
        room = [self.rooms objectForKey:jid.bareJID];
    }];
    return room;
}

- (void) setRoomName:(nonnull XMPPRoom*)room name:(nonnull NSString*)roomname {
    self.updateRoomName = YES;
    [self.tempRoomName setObject:roomname forKey:room.roomJID.bare];
    [room fetchConfigurationForm];
}

#pragma - mark Class Methods
+ (NSXMLElement *)roomNameConfiguration:(DDXMLElement *)configForm withName:(NSString *)roomname
{
    DDXMLElement *form = [configForm copy];
    NSArray<NSXMLElement*> *fields = [form elementsForName:@"field"];
    [fields enumerateObjectsUsingBlock:^(NSXMLElement * _Nonnull field, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *varvalue = [field attributeStringValueForName:@"var"];
        if (varvalue && [varvalue isEqualToString:@"muc#roomconfig_roomname"]) {
            NSXMLElement *value = [field elementForName:@"value"];
            if (value) {
                value.stringValue = roomname;
            } else {
                value = [NSXMLElement elementWithName:@"value"];
                value.stringValue = roomname;
                [field addChild:value];
            }
            *stop = YES;
        }
    }];
    
    return form;
}

+ (NSXMLElement *)defaultRoomConfiguration:(BOOL)ispublicroom roomname:(NSString *)name
{
    NSXMLElement *form = [[NSXMLElement alloc] initWithName:@"x" xmlns:@"jabber:x:data"];

    NSXMLElement *formTypeField = [[NSXMLElement alloc] initWithName:@"field"];
    [formTypeField addAttributeWithName:@"var" stringValue:@"FORM_TYPE"];
    [formTypeField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"http://jabber.org/protocol/muc#roomconfig"]];

    NSXMLElement *publicField = [[NSXMLElement alloc] initWithName:@"field"];
    [publicField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_publicroom"];
    if (ispublicroom) { 
        [publicField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(1)]];
    } else {
        [publicField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(0)]];
    }
    
    NSXMLElement *roomnameField = nil;
    if (name) {
        roomnameField = [[NSXMLElement alloc] initWithName:@"field"];
        [roomnameField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_roomname"];
        [roomnameField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:name]];
    }
    
    NSXMLElement *persistentField = [[NSXMLElement alloc] initWithName:@"field"];
    [persistentField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_persistentroom"];
    [persistentField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(1)]];
    
    NSXMLElement *whoisField = [[NSXMLElement alloc] initWithName:@"field"];
    [whoisField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_whois"];
    [whoisField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"anyone"]];
    
    // whether to allow subscription to room notifications
    NSXMLElement *allowSubscriptionField = [[NSXMLElement alloc] initWithName:@"field"];
    [allowSubscriptionField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_allow_subscription"];
    [allowSubscriptionField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(1)]];

    NSXMLElement *membersOnlyField = [[NSXMLElement alloc] initWithName:@"field"];
    [membersOnlyField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_membersonly"];
    if (ispublicroom) {
        [membersOnlyField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(0)]];
    } else {
        [membersOnlyField addChild:[[NSXMLElement alloc] initWithName:@"value" numberValue:@(1)]];
    }

    NSXMLElement *getMemberListField = [[NSXMLElement alloc] initWithName:@"field"];
    [getMemberListField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_getmemberlist"];
    [getMemberListField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"moderator"]];
    [getMemberListField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"participant"]];
    if (ispublicroom) {
        [getMemberListField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"visitor"]];
    }

    NSXMLElement *presenceBroadcastField = [[NSXMLElement alloc] initWithName:@"field"];
    [presenceBroadcastField addAttributeWithName:@"var" stringValue:@"muc#roomconfig_presencebroadcast"];
    [presenceBroadcastField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"moderator"]];
    [presenceBroadcastField addChild:[[NSXMLElement alloc] initWithName:@"value" stringValue:@"participant"]];

    [form addChild:formTypeField];
    [form addChild:publicField];
    if (name) {
        [form addChild:roomnameField];
    }
    [form addChild:persistentField];
    [form addChild:whoisField];
    [form addChild:membersOnlyField];
    [form addChild:presenceBroadcastField];
    [form addChild:allowSubscriptionField];
    
    return form;
}

@end

