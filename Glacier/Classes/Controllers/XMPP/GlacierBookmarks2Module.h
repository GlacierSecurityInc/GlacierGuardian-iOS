//
//  GlacierBookmarks2Module.h
//  Glacier
//
//  XEP-0402: PEP Native Bookmarks (`urn:xmpp:bookmarks:1`).
//
//  XMPPFramework only implements the deprecated XEP-0048 private-XML flavor
//  (XMPPBookmarksModule), which has no notification mechanism, so bookmark
//  changes made on another device only became visible to iOS at the next
//  authenticate. This module speaks XEP-0402 directly: an explicit fetch of the
//  node at login, live PEP events afterwards, and per-item publish/retract
//  instead of a whole-document replace.
//
//  The wire format lives in GlacierBookmarks2Stanzas.
//

@import Foundation;
@import XMPPFramework;

#import "GlacierBookmarks2Stanzas.h"

NS_ASSUME_NONNULL_BEGIN

@class GlacierBookmarks2Module;

@protocol GlacierBookmarks2Delegate <NSObject>
@optional

/**
 * Result of an explicit -fetchBookmarks. `bookmarks` is the full node content,
 * which may legitimately be empty.
 */
- (void)glacierBookmarks2:(GlacierBookmarks2Module *)sender
        didFetchBookmarks:(NSArray<XMPPConferenceBookmark *> *)bookmarks;

/**
 * An explicit -fetchBookmarks failed. `nodeMissing` is YES when the failure
 * means "there is no such node here" (item-not-found, or a server that does not
 * implement pubsub/PEP) rather than a transient error, so the caller can tell
 * "nothing to sync" apart from "we don't know".
 */
- (void)glacierBookmarks2:(GlacierBookmarks2Module *)sender
     didNotFetchBookmarks:(nullable XMPPIQ *)errorIq
              nodeMissing:(BOOL)nodeMissing;

/** Items published to the node, delivered live over PEP. */
- (void)glacierBookmarks2:(GlacierBookmarks2Module *)sender
      didReceiveBookmarks:(NSArray<XMPPConferenceBookmark *> *)bookmarks;

/** Items retracted from the node, delivered live over PEP. */
- (void)glacierBookmarks2:(GlacierBookmarks2Module *)sender
didReceiveRetractionsForJIDs:(NSArray<XMPPJID *> *)jids;

@end

@interface GlacierBookmarks2Module : XMPPModule

/**
 * Sends an explicit items request for the bookmarks node. ejabberd creates the
 * node with `send_last_published_item: never`, so there is no presence-triggered
 * delivery of the current items and the node has to be read on purpose.
 */
- (void)fetchBookmarks;

/** Publishes one pubsub item per bookmark. Bookmarks without a JID are skipped. */
- (void)publishBookmarks:(NSArray<XMPPConferenceBookmark *> *)bookmarks;

/** Retracts one pubsub item per JID. */
- (void)retractBookmarksForJIDs:(NSArray<XMPPJID *> *)jids;

@end

NS_ASSUME_NONNULL_END
