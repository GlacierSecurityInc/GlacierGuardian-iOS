//
//  GlacierBookmarks2Module.m
//  Glacier
//
//  See GlacierBookmarks2Module.h for what this is and why it exists.
//

#import "GlacierBookmarks2Module.h"
@import CocoaLumberjack;
#import "GlacierLog.h"

static const NSTimeInterval GlacierBookmarks2IQTimeout = 30.0;

@interface GlacierBookmarks2Module ()

@property (nonatomic, strong, nullable) XMPPIDTracker *tracker;

/**
 * Whether the next publish should carry <publish-options>.
 *
 * Whichever client first publishes to the node decides its configuration,
 * because ejabberd only applies publish-options on node creation. So we pin the
 * XEP-0402 configuration when we have evidence the node does not exist yet, and
 * otherwise stay out of the way: publish-options are preconditions, and sending
 * them against a node another client already created with a different
 * configuration would fail the publish outright.
 */
@property (nonatomic) BOOL shouldPinNodeConfiguration;

@end

@implementation GlacierBookmarks2Module

#pragma mark - XMPPModule overrides

- (BOOL)activate:(XMPPStream *)aXmppStream {
    if (![super activate:aXmppStream]) {
        return NO;
    }
    [self performBlockAsync:^{
        self.tracker = [[XMPPIDTracker alloc] initWithStream:self.xmppStream
                                               dispatchQueue:self.moduleQueue];
    }];
    return YES;
}

- (void)deactivate {
    [self performBlock:^{
        [self.tracker removeAllIDs];
        self.tracker = nil;
        self.shouldPinNodeConfiguration = NO;
    }];
    [super deactivate];
}

#pragma mark - Fetch

- (void)fetchBookmarks {
    [self performBlockAsync:^{
        XMPPStream *stream = self.xmppStream;
        if (!stream.isAuthenticated || self.tracker == nil) {
            DDLogInfo(@"Bookmarks 2: not fetching, module is not ready");
            return;
        }

        XMPPIQ *iq = [XMPPIQ iqWithType:@"get"
                              elementID:[XMPPStream generateUUID]
                                  child:[GlacierBookmarks2Stanzas fetchPubSubElement]];

        __weak typeof(self) weakSelf = self;
        // XMPPIDTracker leaves the entry in place when a timeout fires, so a
        // late response can invoke the block a second time.
        __block BOOL handled = NO;
        [self.tracker addElement:iq block:^(id obj, id<XMPPTrackingInfo> info) {
            if (handled) { return; }
            handled = YES;
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) { return; }
            [strongSelf handleFetchResponse:[obj isKindOfClass:[XMPPIQ class]] ? obj : nil];
        } timeout:GlacierBookmarks2IQTimeout];

        [stream sendElement:iq];
    }];
}

/** Runs on moduleQueue. `responseIq` is nil on timeout. */
- (void)handleFetchResponse:(nullable XMPPIQ *)responseIq {
    if (responseIq != nil && [[responseIq type] isEqualToString:@"result"]) {
        NSXMLElement *items = [GlacierBookmarks2Stanzas itemsElementFromFetchResult:responseIq];
        if (items == nil) {
            // A result we can't read is not evidence about the node either way.
            DDLogWarn(@"Bookmarks 2: unexpected fetch result %@", responseIq.compactXMLString);
            [multicastDelegate glacierBookmarks2:self didNotFetchBookmarks:responseIq nodeMissing:NO];
            return;
        }
        self.shouldPinNodeConfiguration = NO;
        NSArray<XMPPConferenceBookmark *> *bookmarks =
            [GlacierBookmarks2Stanzas bookmarksFromItemsElement:items];
        DDLogInfo(@"Bookmarks 2: fetched %lu bookmark(s)", (unsigned long)bookmarks.count);
        [multicastDelegate glacierBookmarks2:self didFetchBookmarks:bookmarks];
        return;
    }

    BOOL nodeMissing = [GlacierBookmarks2Stanzas isNodeMissingErrorIQ:responseIq];
    if (nodeMissing) {
        self.shouldPinNodeConfiguration = YES;
    }
    DDLogWarn(@"Bookmarks 2: fetch failed (nodeMissing=%@) %@",
              nodeMissing ? @"YES" : @"NO",
              responseIq ? responseIq.compactXMLString : @"timed out");
    [multicastDelegate glacierBookmarks2:self didNotFetchBookmarks:responseIq nodeMissing:nodeMissing];
}

#pragma mark - Publish

- (void)publishBookmarks:(NSArray<XMPPConferenceBookmark *> *)bookmarks {
    if (bookmarks.count == 0) { return; }
    [self performBlockAsync:^{
        for (XMPPConferenceBookmark *bookmark in bookmarks) {
            [self sendPublishForBookmark:bookmark withPublishOptions:self.shouldPinNodeConfiguration];
        }
    }];
}

/** Runs on moduleQueue. */
- (void)sendPublishForBookmark:(XMPPConferenceBookmark *)bookmark
            withPublishOptions:(BOOL)includeOptions {
    XMPPStream *stream = self.xmppStream;
    if (!stream.isAuthenticated || self.tracker == nil) {
        DDLogInfo(@"Bookmarks 2: not publishing %@, module is not ready", bookmark.jid.bare);
        return;
    }
    NSXMLElement *pubsub = [GlacierBookmarks2Stanzas publishPubSubElementForBookmark:bookmark
                                                                  withPublishOptions:includeOptions];
    if (pubsub == nil) { return; }
    XMPPIQ *iq = [XMPPIQ iqWithType:@"set"
                          elementID:[XMPPStream generateUUID]
                              child:pubsub];

    NSString *jidString = bookmark.jid.bare;
    __weak typeof(self) weakSelf = self;
    __block BOOL handled = NO;
    [self.tracker addElement:iq block:^(id obj, id<XMPPTrackingInfo> info) {
        if (handled) { return; }
        handled = YES;
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        XMPPIQ *responseIq = [obj isKindOfClass:[XMPPIQ class]] ? obj : nil;
        if (responseIq != nil && [[responseIq type] isEqualToString:@"result"]) {
            strongSelf.shouldPinNodeConfiguration = NO;
            DDLogInfo(@"Bookmarks 2: published %@", jidString);
            return;
        }
        if (includeOptions) {
            // The node already exists with a different configuration
            // (precondition-not-met), or the server rejected our options. Retry
            // once without them so the item still lands on a node another
            // client created.
            strongSelf.shouldPinNodeConfiguration = NO;
            DDLogWarn(@"Bookmarks 2: publish with publish-options failed for %@, retrying without: %@",
                      jidString, responseIq ? responseIq.compactXMLString : @"timed out");
            [strongSelf sendPublishForBookmark:bookmark withPublishOptions:NO];
            return;
        }
        DDLogWarn(@"Bookmarks 2: failed to publish %@: %@",
                  jidString, responseIq ? responseIq.compactXMLString : @"timed out");
    } timeout:GlacierBookmarks2IQTimeout];

    [stream sendElement:iq];
}

#pragma mark - Retract

- (void)retractBookmarksForJIDs:(NSArray<XMPPJID *> *)jids {
    if (jids.count == 0) { return; }
    [self performBlockAsync:^{
        XMPPStream *stream = self.xmppStream;
        if (!stream.isAuthenticated || self.tracker == nil) {
            DDLogInfo(@"Bookmarks 2: not retracting, module is not ready");
            return;
        }
        for (XMPPJID *jid in jids) {
            NSXMLElement *pubsub = [GlacierBookmarks2Stanzas retractPubSubElementForJID:jid];
            if (pubsub == nil) { continue; }
            NSString *jidString = jid.bare;
            XMPPIQ *iq = [XMPPIQ iqWithType:@"set"
                                  elementID:[XMPPStream generateUUID]
                                      child:pubsub];

            __block BOOL handled = NO;
            [self.tracker addElement:iq block:^(id obj, id<XMPPTrackingInfo> info) {
                if (handled) { return; }
                handled = YES;
                XMPPIQ *responseIq = [obj isKindOfClass:[XMPPIQ class]] ? obj : nil;
                if (responseIq != nil && [[responseIq type] isEqualToString:@"result"]) {
                    DDLogInfo(@"Bookmarks 2: retracted %@", jidString);
                    return;
                }
                DDLogWarn(@"Bookmarks 2: failed to retract %@: %@",
                          jidString, responseIq ? responseIq.compactXMLString : @"timed out");
            } timeout:GlacierBookmarks2IQTimeout];

            [stream sendElement:iq];
        }
    }];
}

#pragma mark - XMPPStreamDelegate

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq {
    NSString *type = [iq type];
    if (![type isEqualToString:@"result"] && ![type isEqualToString:@"error"]) {
        return NO;
    }
    // Responses to a request without a "to" can arrive with no "from" at all,
    // which XMPPIDTracker's sender validation cannot check.
    if (iq.from == nil) {
        return [self.tracker invokeForID:[iq elementID] withObject:iq];
    }
    return [self.tracker invokeForElement:iq withObject:iq];
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)message {
    NSXMLElement *items = [GlacierBookmarks2Stanzas itemsElementFromEventMessage:message];
    BOOL purgedOrDeleted = [GlacierBookmarks2Stanzas isNodePurgeOrDeleteEventMessage:message];
    if (items == nil && !purgedOrDeleted) { return; }

    // PEP events for our own bookmarks come from our own bare JID. Anything
    // else claiming to carry our bookmarks is not ours to act on.
    XMPPJID *from = message.from;
    XMPPJID *myJID = sender.myJID;
    if (from == nil || myJID == nil ||
        ![from isEqualToJID:myJID options:XMPPJIDCompareBare]) {
        DDLogWarn(@"Bookmarks 2: ignoring event from unexpected sender %@", from.bare);
        return;
    }

    if (purgedOrDeleted) {
        // Deliberately not propagated: a purge or a node deletion says nothing
        // about individual rooms, and bookmark state never removes local data.
        DDLogWarn(@"Bookmarks 2: node was purged or deleted server-side, ignoring");
        return;
    }

    NSArray<XMPPConferenceBookmark *> *bookmarks =
        [GlacierBookmarks2Stanzas bookmarksFromItemsElement:items];
    NSArray<XMPPJID *> *retractedJIDs =
        [GlacierBookmarks2Stanzas retractedJIDsFromItemsElement:items];
    DDLogInfo(@"Bookmarks 2: event with %lu item(s) and %lu retraction(s)",
              (unsigned long)bookmarks.count, (unsigned long)retractedJIDs.count);

    if (bookmarks.count > 0) {
        [multicastDelegate glacierBookmarks2:self didReceiveBookmarks:bookmarks];
    }
    if (retractedJIDs.count > 0) {
        [multicastDelegate glacierBookmarks2:self didReceiveRetractionsForJIDs:retractedJIDs];
    }
}

- (void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error {
    [self.tracker removeAllIDs];
}

@end
