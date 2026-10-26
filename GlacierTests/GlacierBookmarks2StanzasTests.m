//
//  GlacierBookmarks2StanzasTests.m
//  GlacierTests
//
//  Wire-format tests for XEP-0402 (Bookmarks 2). These cover the part of the
//  bookmark code that can be tested without a stream: what we put on the wire,
//  what we accept off it, and - the part that matters most - what we refuse to
//  turn into a room.
//

#import <XCTest/XCTest.h>
#import "GlacierBookmarks2Stanzas.h"

@interface GlacierBookmarks2StanzasTests : XCTestCase
@end

@implementation GlacierBookmarks2StanzasTests

#pragma mark - Helpers

- (NSXMLElement *)parse:(NSString *)xml {
    NSError *error = nil;
    NSXMLElement *element = [[NSXMLElement alloc] initWithXMLString:xml error:&error];
    XCTAssertNil(error, @"could not parse test XML: %@", error);
    return element;
}

- (XMPPConferenceBookmark *)bookmarkWithJIDString:(NSString *)jidString
                                             name:(NSString *)name
                                             nick:(NSString *)nick
                                         autoJoin:(BOOL)autoJoin
                                         password:(NSString *)password {
    return [[XMPPConferenceBookmark alloc] initWithJID:[XMPPJID jidWithString:jidString]
                                          bookmarkName:name
                                                  nick:nick
                                              autoJoin:autoJoin
                                              password:password];
}

- (NSString *)valueOfField:(NSString *)var inForm:(NSXMLElement *)form {
    for (NSXMLElement *field in [form elementsForName:@"field"]) {
        if ([[field attributeStringValueForName:@"var"] isEqualToString:var]) {
            return [[field elementForName:@"value"] stringValue];
        }
    }
    return nil;
}

#pragma mark - Serialization

- (void)testItemUsesRoomJIDAsItemID {
    XMPPConferenceBookmark *bookmark = [self bookmarkWithJIDString:@"room@conference.example.com"
                                                              name:@"Testing"
                                                              nick:@"alice"
                                                          autoJoin:YES
                                                          password:@"secret"];
    NSXMLElement *item = [GlacierBookmarks2Stanzas itemElementForBookmark:bookmark];
    XCTAssertEqualObjects(item.name, @"item");
    XCTAssertEqualObjects([item attributeStringValueForName:@"id"], @"room@conference.example.com");

    NSXMLElement *conference = [item elementForName:@"conference" xmlns:GlacierBookmarks2Namespace];
    XCTAssertNotNil(conference);
    // The room JID is the item id in XEP-0402; a jid attribute is the XEP-0048 shape.
    XCTAssertNil([conference attributeStringValueForName:@"jid"]);
    XCTAssertEqualObjects([conference attributeStringValueForName:@"name"], @"Testing");
    XCTAssertEqualObjects([[conference elementForName:@"nick"] stringValue], @"alice");
    XCTAssertEqualObjects([[conference elementForName:@"password"] stringValue], @"secret");
}

- (void)testAutojoinIsSerializedAsTrueOrFalse {
    // -addAttributeWithName:boolValue: emits "1"/"0", which is schema-legal but
    // inconsistent with every other client and with ejabberd itself.
    XMPPConferenceBookmark *joined = [self bookmarkWithJIDString:@"room@conference.example.com"
                                                            name:nil
                                                            nick:nil
                                                        autoJoin:YES
                                                        password:nil];
    NSXMLElement *conference =
        [[GlacierBookmarks2Stanzas itemElementForBookmark:joined] elementForName:@"conference"
                                                                          xmlns:GlacierBookmarks2Namespace];
    XCTAssertEqualObjects([conference attributeStringValueForName:@"autojoin"], @"true");

    XMPPConferenceBookmark *notJoined = [self bookmarkWithJIDString:@"room@conference.example.com"
                                                               name:nil
                                                               nick:nil
                                                           autoJoin:NO
                                                           password:nil];
    NSXMLElement *plain =
        [[GlacierBookmarks2Stanzas itemElementForBookmark:notJoined] elementForName:@"conference"
                                                                             xmlns:GlacierBookmarks2Namespace];
    XCTAssertEqualObjects([plain attributeStringValueForName:@"autojoin"], @"false");
    XCTAssertNil([plain attributeStringValueForName:@"name"]);
    XCTAssertNil([plain elementForName:@"nick"]);
    XCTAssertNil([plain elementForName:@"password"]);
}

- (void)testBookmarkWithoutJIDIsNotPublishable {
    XMPPConferenceBookmark *jidless = [[XMPPConferenceBookmark alloc] init];
    XCTAssertNil([GlacierBookmarks2Stanzas itemElementForBookmark:jidless]);
    XCTAssertNil([GlacierBookmarks2Stanzas publishPubSubElementForBookmark:jidless
                                                       withPublishOptions:NO]);
    XCTAssertNil([GlacierBookmarks2Stanzas retractPubSubElementForJID:nil]);
}

#pragma mark - Parsing

- (void)testBookmarkParsing {
    NSXMLElement *items = [self parse:@"<items node='urn:xmpp:bookmarks:1'>"
                                       "<item id='one@conference.example.com'>"
                                       "  <conference xmlns='urn:xmpp:bookmarks:1' autojoin='true' name='One'>"
                                       "    <nick>alice</nick><password>pw</password>"
                                       "  </conference>"
                                       "</item>"
                                       "<item id='two@conference.example.com'>"
                                       "  <conference xmlns='urn:xmpp:bookmarks:1' autojoin='1'/>"
                                       "</item>"
                                       "<item id='three@conference.example.com'>"
                                       "  <conference xmlns='urn:xmpp:bookmarks:1' autojoin='false'/>"
                                       "</item>"
                                       "<item id='four@conference.example.com'>"
                                       "  <conference xmlns='urn:xmpp:bookmarks:1'/>"
                                       "</item>"
                                       "<item id='five@conference.example.com/phone'>"
                                       "  <conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/>"
                                       "</item>"
                                       "</items>"];
    NSArray<XMPPConferenceBookmark *> *bookmarks =
        [GlacierBookmarks2Stanzas bookmarksFromItemsElement:items];
    XCTAssertEqual(bookmarks.count, 5u);

    XCTAssertEqualObjects(bookmarks[0].jid.bare, @"one@conference.example.com");
    XCTAssertTrue(bookmarks[0].autoJoin);
    XCTAssertEqualObjects(bookmarks[0].bookmarkName, @"One");
    XCTAssertEqualObjects(bookmarks[0].nick, @"alice");
    XCTAssertEqualObjects(bookmarks[0].password, @"pw");
    // ejabberd and older clients write 1/0.
    XCTAssertTrue(bookmarks[1].autoJoin);
    XCTAssertFalse(bookmarks[2].autoJoin);
    // XEP-0402 defaults autojoin to false.
    XCTAssertFalse(bookmarks[3].autoJoin);
    // A resource on the item id is not part of the room JID.
    XCTAssertEqualObjects(bookmarks[4].jid.bare, @"five@conference.example.com");
    XCTAssertNil(bookmarks[4].jid.resource);
}

- (void)testMalformedItemsAreSkipped {
    NSXMLElement *items = [self parse:@"<items node='urn:xmpp:bookmarks:1'>"
                                       "<item id=''><conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/></item>"
                                       "<item><conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/></item>"
                                       "<item id='conference.example.com'><conference xmlns='urn:xmpp:bookmarks:1'/></item>"
                                       "<item id='ok@conference.example.com'/>"
                                       "<item id='ok@conference.example.com'><conference xmlns='storage:bookmarks'/></item>"
                                       "</items>"];
    XCTAssertEqual([GlacierBookmarks2Stanzas bookmarksFromItemsElement:items].count, 0u);
    XCTAssertEqual([GlacierBookmarks2Stanzas bookmarksFromItemsElement:nil].count, 0u);
    XCTAssertEqual([GlacierBookmarks2Stanzas retractedJIDsFromItemsElement:nil].count, 0u);
}

- (void)testRetractionParsing {
    NSXMLElement *items = [self parse:@"<items node='urn:xmpp:bookmarks:1'>"
                                       "<retract id='gone@conference.example.com'/>"
                                       "<retract id='also@conference.example.com/phone'/>"
                                       "<retract/>"
                                       "<retract id=''/>"
                                       "<retract id='conference.example.com'/>"
                                       "</items>"];
    NSArray<XMPPJID *> *jids = [GlacierBookmarks2Stanzas retractedJIDsFromItemsElement:items];
    XCTAssertEqual(jids.count, 2u);
    XCTAssertEqualObjects(jids[0].bare, @"gone@conference.example.com");
    XCTAssertEqualObjects(jids[1].bare, @"also@conference.example.com");
}

#pragma mark - Routing

- (void)testOnlyOurNodesEventsAreRecognized {
    NSXMLElement *ours = [self parse:@"<message from='me@example.com'>"
                                      "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                                      "<items node='urn:xmpp:bookmarks:1'>"
                                      "<item id='room@conference.example.com'>"
                                      "<conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/>"
                                      "</item></items></event></message>"];
    NSXMLElement *items = [GlacierBookmarks2Stanzas itemsElementFromEventMessage:ours];
    XCTAssertNotNil(items);
    XCTAssertEqual([GlacierBookmarks2Stanzas bookmarksFromItemsElement:items].count, 1u);

    NSXMLElement *otherNode = [self parse:@"<message from='me@example.com'>"
                                           "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                                           "<items node='urn:xmpp:avatar:metadata'><item id='x'/></items>"
                                           "</event></message>"];
    XCTAssertNil([GlacierBookmarks2Stanzas itemsElementFromEventMessage:otherNode]);

    NSXMLElement *chat = [self parse:@"<message from='someone@example.com'><body>hi</body></message>"];
    XCTAssertNil([GlacierBookmarks2Stanzas itemsElementFromEventMessage:chat]);
    XCTAssertNil([GlacierBookmarks2Stanzas itemsElementFromEventMessage:nil]);
    XCTAssertFalse([GlacierBookmarks2Stanzas isNodePurgeOrDeleteEventMessage:chat]);
    XCTAssertFalse([GlacierBookmarks2Stanzas isNodePurgeOrDeleteEventMessage:nil]);
}

- (void)testPurgeAndDeleteDetection {
    NSXMLElement *purge = [self parse:@"<message from='me@example.com'>"
                                       "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                                       "<purge node='urn:xmpp:bookmarks:1'/></event></message>"];
    XCTAssertTrue([GlacierBookmarks2Stanzas isNodePurgeOrDeleteEventMessage:purge]);

    NSXMLElement *deleted = [self parse:@"<message from='me@example.com'>"
                                         "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                                         "<delete node='urn:xmpp:bookmarks:1'/></event></message>"];
    XCTAssertTrue([GlacierBookmarks2Stanzas isNodePurgeOrDeleteEventMessage:deleted]);

    NSXMLElement *otherNode = [self parse:@"<message from='me@example.com'>"
                                           "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                                           "<purge node='urn:xmpp:avatar:data'/></event></message>"];
    XCTAssertFalse([GlacierBookmarks2Stanzas isNodePurgeOrDeleteEventMessage:otherNode]);
}

- (void)testFetchResultRouting {
    NSXMLElement *result = [self parse:@"<iq type='result' id='1'>"
                                        "<pubsub xmlns='http://jabber.org/protocol/pubsub'>"
                                        "<items node='urn:xmpp:bookmarks:1'>"
                                        "<item id='room@conference.example.com'>"
                                        "<conference xmlns='urn:xmpp:bookmarks:1' autojoin='true' name='Room'/>"
                                        "</item></items></pubsub></iq>"];
    NSXMLElement *items = [GlacierBookmarks2Stanzas itemsElementFromFetchResult:result];
    XCTAssertNotNil(items);
    XCTAssertEqual([GlacierBookmarks2Stanzas bookmarksFromItemsElement:items].count, 1u);

    // An existing but empty node is a readable result with no bookmarks, which
    // is different from a result we cannot read at all.
    NSXMLElement *empty = [self parse:@"<iq type='result' id='1'>"
                                       "<pubsub xmlns='http://jabber.org/protocol/pubsub'>"
                                       "<items node='urn:xmpp:bookmarks:1'/></pubsub></iq>"];
    XCTAssertNotNil([GlacierBookmarks2Stanzas itemsElementFromFetchResult:empty]);
    XCTAssertEqual([GlacierBookmarks2Stanzas bookmarksFromItemsElement:
                        [GlacierBookmarks2Stanzas itemsElementFromFetchResult:empty]].count, 0u);

    NSXMLElement *wrongNode = [self parse:@"<iq type='result' id='1'>"
                                           "<pubsub xmlns='http://jabber.org/protocol/pubsub'>"
                                           "<items node='storage:bookmarks'/></pubsub></iq>"];
    XCTAssertNil([GlacierBookmarks2Stanzas itemsElementFromFetchResult:wrongNode]);
    XCTAssertNil([GlacierBookmarks2Stanzas itemsElementFromFetchResult:
                      [self parse:@"<iq type='result' id='1'/>"]]);
    XCTAssertNil([GlacierBookmarks2Stanzas itemsElementFromFetchResult:nil]);
}

#pragma mark - Error classification

- (void)testMissingNodeErrors {
    for (NSString *condition in @[@"item-not-found", @"feature-not-implemented", @"service-unavailable"]) {
        NSString *xml = [NSString stringWithFormat:@"<iq type='error' id='1'><error type='cancel'>"
                                                    "<%@ xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
                                                    "</error></iq>", condition];
        XCTAssertTrue([GlacierBookmarks2Stanzas isNodeMissingErrorIQ:[self parse:xml]],
                      @"%@ should mean the node is missing", condition);
    }
}

- (void)testTransientErrorsAreNotAMissingNode {
    // This distinction is what keeps a transient failure from looking like an
    // empty bookmark store.
    for (NSString *condition in @[@"forbidden", @"internal-server-error", @"not-authorized"]) {
        NSString *xml = [NSString stringWithFormat:@"<iq type='error' id='1'><error type='cancel'>"
                                                    "<%@ xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
                                                    "</error></iq>", condition];
        XCTAssertFalse([GlacierBookmarks2Stanzas isNodeMissingErrorIQ:[self parse:xml]],
                       @"%@ should not mean the node is missing", condition);
    }
    // A timeout arrives as a nil IQ.
    XCTAssertFalse([GlacierBookmarks2Stanzas isNodeMissingErrorIQ:nil]);
    XCTAssertFalse([GlacierBookmarks2Stanzas isNodeMissingErrorIQ:
                        [self parse:@"<iq type='result' id='1'/>"]]);
}

#pragma mark - Request shapes

- (void)testFetchRequestShape {
    NSXMLElement *pubsub = [GlacierBookmarks2Stanzas fetchPubSubElement];
    XCTAssertEqualObjects(pubsub.name, @"pubsub");
    XCTAssertEqualObjects([pubsub xmlns], GlacierPubSubNamespace);
    XCTAssertEqualObjects([[pubsub elementForName:@"items"] attributeStringValueForName:@"node"],
                          GlacierBookmarks2Namespace);
}

- (void)testPublishOptionsArePinnedOnlyWhenAsked {
    XMPPConferenceBookmark *bookmark = [self bookmarkWithJIDString:@"room@conference.example.com"
                                                              name:@"Room"
                                                              nick:nil
                                                          autoJoin:YES
                                                          password:nil];
    NSXMLElement *plain = [GlacierBookmarks2Stanzas publishPubSubElementForBookmark:bookmark
                                                                withPublishOptions:NO];
    XCTAssertEqualObjects([[plain elementForName:@"publish"] attributeStringValueForName:@"node"],
                          GlacierBookmarks2Namespace);
    // publish-options are preconditions: sending them against a node another
    // client already created with a different config would fail the publish.
    XCTAssertNil([plain elementForName:@"publish-options"]);

    NSXMLElement *pinned = [GlacierBookmarks2Stanzas publishPubSubElementForBookmark:bookmark
                                                                 withPublishOptions:YES];
    NSXMLElement *form = [[pinned elementForName:@"publish-options"] elementForName:@"x"
                                                                             xmlns:@"jabber:x:data"];
    XCTAssertNotNil(form);
    XCTAssertEqualObjects([form attributeStringValueForName:@"type"], @"submit");
    XCTAssertEqualObjects([self valueOfField:@"FORM_TYPE" inForm:form],
                          @"http://jabber.org/protocol/pubsub#publish-options");
    XCTAssertEqualObjects([self valueOfField:@"pubsub#persist_items" inForm:form], @"true");
    XCTAssertEqualObjects([self valueOfField:@"pubsub#max_items" inForm:form], @"max");
    XCTAssertEqualObjects([self valueOfField:@"pubsub#send_last_published_item" inForm:form], @"never");
    XCTAssertEqualObjects([self valueOfField:@"pubsub#access_model" inForm:form], @"whitelist");
    XCTAssertEqualObjects([self valueOfField:@"pubsub#notify_delete" inForm:form], @"true");
    XCTAssertEqualObjects([self valueOfField:@"pubsub#notify_retract" inForm:form], @"true");
}

- (void)testRetractRequestShape {
    NSXMLElement *pubsub = [GlacierBookmarks2Stanzas retractPubSubElementForJID:
                                [XMPPJID jidWithString:@"room@conference.example.com/phone"]];
    NSXMLElement *retract = [pubsub elementForName:@"retract"];
    XCTAssertEqualObjects([retract attributeStringValueForName:@"node"], GlacierBookmarks2Namespace);
    XCTAssertEqualObjects([retract attributeStringValueForName:@"notify"], @"true");
    XCTAssertEqualObjects([[retract elementForName:@"item"] attributeStringValueForName:@"id"],
                          @"room@conference.example.com");
}

#pragma mark - Round trip

- (void)testPublishedItemParsesBackToTheSameBookmark {
    XMPPConferenceBookmark *original = [self bookmarkWithJIDString:@"room@conference.example.com"
                                                              name:@"Round Trip"
                                                              nick:@"bob"
                                                          autoJoin:YES
                                                          password:@"pw"];
    NSXMLElement *item =
        [[[GlacierBookmarks2Stanzas publishPubSubElementForBookmark:original withPublishOptions:YES]
            elementForName:@"publish"] elementForName:@"item"];
    NSXMLElement *items = [self parse:[NSString stringWithFormat:@"<items node='%@'>%@</items>",
                                       GlacierBookmarks2Namespace, item.XMLString]];
    NSArray<XMPPConferenceBookmark *> *parsed =
        [GlacierBookmarks2Stanzas bookmarksFromItemsElement:items];
    XCTAssertEqual(parsed.count, 1u);
    XCTAssertEqualObjects(parsed[0].jid.bare, original.jid.bare);
    XCTAssertEqualObjects(parsed[0].bookmarkName, original.bookmarkName);
    XCTAssertEqualObjects(parsed[0].nick, original.nick);
    XCTAssertEqualObjects(parsed[0].password, original.password);
    XCTAssertEqual(parsed[0].autoJoin, original.autoJoin);
}

@end
