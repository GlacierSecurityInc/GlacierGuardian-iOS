//
//  GlacierBookmarks2Stanzas.h
//  Glacier
//
//  Wire format for XEP-0402: PEP Native Bookmarks (`urn:xmpp:bookmarks:1`).
//
//  Pure element building and parsing, with no stream, queue or delegate
//  involvement, so it can be exercised directly by tests. GlacierBookmarks2Module
//  is the part that talks to the server.
//

@import Foundation;
@import XMPPFramework;

NS_ASSUME_NONNULL_BEGIN

/** `urn:xmpp:bookmarks:1` — the XEP-0402 node and element namespace. */
extern NSString *const GlacierBookmarks2Namespace;
/** Disco feature that asks the server to push node updates to us over PEP. */
extern NSString *const GlacierBookmarks2NotifyFeature;
/** `http://jabber.org/protocol/pubsub` */
extern NSString *const GlacierPubSubNamespace;
/** `http://jabber.org/protocol/pubsub#event` */
extern NSString *const GlacierPubSubEventNamespace;

/**
 * Bookmarks are modelled with XMPPConferenceBookmark so the room-side code that
 * consumes them is unchanged between the two bookmark protocols. Only the wire
 * format differs: in XEP-0402 the room JID is the pubsub item id rather than an
 * attribute of the <conference> element.
 */
@interface GlacierBookmarks2Stanzas : NSObject

/** `<pubsub><items node='urn:xmpp:bookmarks:1'/></pubsub>` */
+ (NSXMLElement *)fetchPubSubElement;

/**
 * `<pubsub><publish node='...'><item id='room@service'>…</item></publish></pubsub>`,
 * or nil if the bookmark has no JID. Include publish-options only when the node
 * may not exist yet: they are preconditions, so sending them against a node
 * another client already created with a different configuration fails the publish.
 */
+ (nullable NSXMLElement *)publishPubSubElementForBookmark:(XMPPConferenceBookmark *)bookmark
                                        withPublishOptions:(BOOL)includePublishOptions;

/** `<pubsub><retract node='...' notify='true'><item id='room@service'/></retract></pubsub>`, or nil for an empty JID. */
+ (nullable NSXMLElement *)retractPubSubElementForJID:(nullable XMPPJID *)jid;

/** `<item id='room@service'><conference .../></item>`, or nil if the bookmark has no JID. */
+ (nullable NSXMLElement *)itemElementForBookmark:(XMPPConferenceBookmark *)bookmark;

/** The `<items>` element of a pubsub IQ result for our node, or nil if this isn't one. */
+ (nullable NSXMLElement *)itemsElementFromFetchResult:(nullable NSXMLElement *)iqElement;

/** The `<items>` element of a PEP event message for our node, or nil if this isn't one. */
+ (nullable NSXMLElement *)itemsElementFromEventMessage:(nullable NSXMLElement *)messageElement;

/** YES if a PEP event message purges or deletes our node. */
+ (BOOL)isNodePurgeOrDeleteEventMessage:(nullable NSXMLElement *)messageElement;

/** Bookmarks parsed out of a pubsub `<items>` element. Malformed items are skipped. */
+ (NSArray<XMPPConferenceBookmark *> *)bookmarksFromItemsElement:(nullable NSXMLElement *)items;

/** Bare JIDs of the `<retract>` children of a pubsub `<items>` element. */
+ (NSArray<XMPPJID *> *)retractedJIDsFromItemsElement:(nullable NSXMLElement *)items;

/** YES if the error IQ means the bookmarks node does not exist or is unsupported. */
+ (BOOL)isNodeMissingErrorIQ:(nullable NSXMLElement *)iqElement;

/** Bare room JID for a pubsub item id, or nil if it isn't a usable room JID. */
+ (nullable XMPPJID *)roomJIDFromItemID:(nullable NSString *)itemID;

@end

NS_ASSUME_NONNULL_END
