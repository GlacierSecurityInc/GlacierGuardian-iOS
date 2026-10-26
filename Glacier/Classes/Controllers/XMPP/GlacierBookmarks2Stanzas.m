//
//  GlacierBookmarks2Stanzas.m
//  Glacier
//
//  See GlacierBookmarks2Stanzas.h.
//

#import "GlacierBookmarks2Stanzas.h"

NSString *const GlacierBookmarks2Namespace = @"urn:xmpp:bookmarks:1";
NSString *const GlacierBookmarks2NotifyFeature = @"urn:xmpp:bookmarks:1+notify";
NSString *const GlacierPubSubNamespace = @"http://jabber.org/protocol/pubsub";
NSString *const GlacierPubSubEventNamespace = @"http://jabber.org/protocol/pubsub#event";

static NSString *const GlacierPubSubPublishOptionsFormType = @"http://jabber.org/protocol/pubsub#publish-options";
static NSString *const GlacierDataFormsNamespace = @"jabber:x:data";
static NSString *const GlacierStanzasNamespace = @"urn:ietf:params:xml:ns:xmpp-stanzas";

@implementation GlacierBookmarks2Stanzas

#pragma mark - Requests

+ (NSXMLElement *)fetchPubSubElement {
    NSXMLElement *items = [NSXMLElement elementWithName:@"items"];
    [items addAttributeWithName:@"node" stringValue:GlacierBookmarks2Namespace];
    NSXMLElement *pubsub = [NSXMLElement elementWithName:@"pubsub" xmlns:GlacierPubSubNamespace];
    [pubsub addChild:items];
    return pubsub;
}

+ (nullable NSXMLElement *)publishPubSubElementForBookmark:(XMPPConferenceBookmark *)bookmark
                                        withPublishOptions:(BOOL)includePublishOptions {
    NSXMLElement *item = [self itemElementForBookmark:bookmark];
    if (item == nil) { return nil; }

    NSXMLElement *publish = [NSXMLElement elementWithName:@"publish"];
    [publish addAttributeWithName:@"node" stringValue:GlacierBookmarks2Namespace];
    [publish addChild:item];

    NSXMLElement *pubsub = [NSXMLElement elementWithName:@"pubsub" xmlns:GlacierPubSubNamespace];
    [pubsub addChild:publish];
    if (includePublishOptions) {
        [pubsub addChild:[self publishOptionsElement]];
    }
    return pubsub;
}

+ (nullable NSXMLElement *)retractPubSubElementForJID:(nullable XMPPJID *)jid {
    NSString *jidString = jid.bare;
    if (jidString.length == 0) { return nil; }

    NSXMLElement *item = [NSXMLElement elementWithName:@"item"];
    [item addAttributeWithName:@"id" stringValue:jidString];

    NSXMLElement *retract = [NSXMLElement elementWithName:@"retract"];
    [retract addAttributeWithName:@"node" stringValue:GlacierBookmarks2Namespace];
    // Ask for a notification so our other devices hear about it even if the
    // node was created without notify_retract.
    [retract addAttributeWithName:@"notify" stringValue:@"true"];
    [retract addChild:item];

    NSXMLElement *pubsub = [NSXMLElement elementWithName:@"pubsub" xmlns:GlacierPubSubNamespace];
    [pubsub addChild:retract];
    return pubsub;
}

+ (nullable NSXMLElement *)itemElementForBookmark:(XMPPConferenceBookmark *)bookmark {
    NSString *jidString = bookmark.jid.bare;
    if (jidString.length == 0) { return nil; }

    NSXMLElement *conference = [NSXMLElement elementWithName:@"conference"
                                                       xmlns:GlacierBookmarks2Namespace];
    // Serialized as "true"/"false" rather than the "1"/"0" that
    // -addAttributeWithName:boolValue: emits: both are schema-legal, but every
    // other client and ejabberd itself write the words.
    [conference addAttributeWithName:@"autojoin"
                         stringValue:bookmark.autoJoin ? @"true" : @"false"];
    if (bookmark.bookmarkName.length > 0) {
        [conference addAttributeWithName:@"name" stringValue:bookmark.bookmarkName];
    }
    if (bookmark.nick.length > 0) {
        [conference addChild:[NSXMLElement elementWithName:@"nick" stringValue:bookmark.nick]];
    }
    if (bookmark.password.length > 0) {
        [conference addChild:[NSXMLElement elementWithName:@"password" stringValue:bookmark.password]];
    }

    NSXMLElement *item = [NSXMLElement elementWithName:@"item"];
    // In XEP-0402 the room JID is the item id, not an attribute.
    [item addAttributeWithName:@"id" stringValue:jidString];
    [item addChild:conference];
    return item;
}

#pragma mark - Responses and events

+ (nullable NSXMLElement *)itemsElementFromFetchResult:(nullable NSXMLElement *)iqElement {
    NSXMLElement *pubsub = [iqElement elementForName:@"pubsub" xmlns:GlacierPubSubNamespace];
    return [self ourNodeItemsElementIn:pubsub];
}

+ (nullable NSXMLElement *)itemsElementFromEventMessage:(nullable NSXMLElement *)messageElement {
    NSXMLElement *event = [messageElement elementForName:@"event" xmlns:GlacierPubSubEventNamespace];
    return [self ourNodeItemsElementIn:event];
}

+ (nullable NSXMLElement *)ourNodeItemsElementIn:(nullable NSXMLElement *)parent {
    if (parent == nil) { return nil; }
    NSXMLElement *items = [parent elementForName:@"items"];
    if (items == nil) { return nil; }
    if (![[items attributeStringValueForName:@"node"] isEqualToString:GlacierBookmarks2Namespace]) {
        return nil;
    }
    return items;
}

+ (BOOL)isNodePurgeOrDeleteEventMessage:(nullable NSXMLElement *)messageElement {
    NSXMLElement *event = [messageElement elementForName:@"event" xmlns:GlacierPubSubEventNamespace];
    if (event == nil) { return NO; }
    for (NSString *name in @[@"purge", @"delete"]) {
        NSXMLElement *element = [event elementForName:name];
        if (element != nil &&
            [[element attributeStringValueForName:@"node"] isEqualToString:GlacierBookmarks2Namespace]) {
            return YES;
        }
    }
    return NO;
}

+ (NSArray<XMPPConferenceBookmark *> *)bookmarksFromItemsElement:(nullable NSXMLElement *)items {
    if (items == nil) { return @[]; }
    NSMutableArray<XMPPConferenceBookmark *> *bookmarks = [[NSMutableArray alloc] init];
    for (NSXMLElement *item in [items elementsForName:@"item"]) {
        NSXMLElement *conference = [item elementForName:@"conference"
                                                  xmlns:GlacierBookmarks2Namespace];
        if (conference == nil) { continue; }
        XMPPJID *jid = [self roomJIDFromItemID:[item attributeStringValueForName:@"id"]];
        if (jid == nil) { continue; }

        BOOL autoJoin = [conference attributeBoolValueForName:@"autojoin" withDefaultValue:NO];
        NSString *name = [conference attributeStringValueForName:@"name"];
        NSString *nick = [[conference elementForName:@"nick"] stringValue];
        NSString *password = [[conference elementForName:@"password"] stringValue];
        XMPPConferenceBookmark *bookmark =
            [[XMPPConferenceBookmark alloc] initWithJID:jid
                                           bookmarkName:name
                                                   nick:nick
                                               autoJoin:autoJoin
                                               password:password];
        [bookmarks addObject:bookmark];
    }
    return bookmarks;
}

+ (NSArray<XMPPJID *> *)retractedJIDsFromItemsElement:(nullable NSXMLElement *)items {
    if (items == nil) { return @[]; }
    NSMutableArray<XMPPJID *> *jids = [[NSMutableArray alloc] init];
    for (NSXMLElement *retract in [items elementsForName:@"retract"]) {
        XMPPJID *jid = [self roomJIDFromItemID:[retract attributeStringValueForName:@"id"]];
        if (jid != nil) {
            [jids addObject:jid];
        }
    }
    return jids;
}

+ (BOOL)isNodeMissingErrorIQ:(nullable NSXMLElement *)iqElement {
    NSXMLElement *error = [iqElement elementForName:@"error"];
    if (error == nil) { return NO; }
    // item-not-found: no such node. feature-not-implemented/service-unavailable:
    // this server has no PEP for us to read. In all three cases there is no node
    // content we are failing to see, which is different from a transient error.
    return [error elementForName:@"item-not-found" xmlns:GlacierStanzasNamespace] != nil ||
           [error elementForName:@"feature-not-implemented" xmlns:GlacierStanzasNamespace] != nil ||
           [error elementForName:@"service-unavailable" xmlns:GlacierStanzasNamespace] != nil;
}

+ (nullable XMPPJID *)roomJIDFromItemID:(nullable NSString *)itemID {
    if (itemID.length == 0) { return nil; }
    XMPPJID *jid = [XMPPJID jidWithString:itemID];
    // A room JID always has a node part. Anything else is not something we can
    // join, and a domain-only id would collide with every room on that service.
    if (jid.user.length == 0 || jid.domain.length == 0) { return nil; }
    return jid.bareJID;
}

#pragma mark - Node configuration

/**
 * The XEP-0402 node configuration, sent as publish-options so ejabberd applies
 * it when it auto-creates the node on our first publish. Whichever client
 * publishes first decides the configuration, because ejabberd only applies
 * publish-options on node creation, so it is worth pinning deliberately.
 */
+ (NSXMLElement *)publishOptionsElement {
    NSXMLElement *form = [NSXMLElement elementWithName:@"x" xmlns:GlacierDataFormsNamespace];
    [form addAttributeWithName:@"type" stringValue:@"submit"];

    NSXMLElement *formType = [NSXMLElement elementWithName:@"field"];
    [formType addAttributeWithName:@"var" stringValue:@"FORM_TYPE"];
    [formType addAttributeWithName:@"type" stringValue:@"hidden"];
    [formType addChild:[NSXMLElement elementWithName:@"value"
                                         stringValue:GlacierPubSubPublishOptionsFormType]];
    [form addChild:formType];

    [self addField:@"pubsub#persist_items" value:@"true" toForm:form];
    // "max" is accepted by ejabberd 24.10 (mod_pubsub:check_opt_range/3 has an
    // explicit `max -> true` clause).
    [self addField:@"pubsub#max_items" value:@"max" toForm:form];
    [self addField:@"pubsub#send_last_published_item" value:@"never" toForm:form];
    [self addField:@"pubsub#access_model" value:@"whitelist" toForm:form];
    [self addField:@"pubsub#notify_delete" value:@"true" toForm:form];
    [self addField:@"pubsub#notify_retract" value:@"true" toForm:form];

    NSXMLElement *publishOptions = [NSXMLElement elementWithName:@"publish-options"];
    [publishOptions addChild:form];
    return publishOptions;
}

+ (void)addField:(NSString *)var value:(NSString *)value toForm:(NSXMLElement *)form {
    NSXMLElement *field = [NSXMLElement elementWithName:@"field"];
    [field addAttributeWithName:@"var" stringValue:var];
    [field addChild:[NSXMLElement elementWithName:@"value" stringValue:value]];
    [form addChild:field];
}

@end
