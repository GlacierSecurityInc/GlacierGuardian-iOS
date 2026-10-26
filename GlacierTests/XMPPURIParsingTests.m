//
//  XMPPURIParsingTests.m
//  GlacierTests
//
//  Regression coverage for GUA 03 (Sept 2026 assessment). A crafted xmpp:// deep link
//  terminated Guardian: XMPPURI.parseURIString: measured the authority against the first
//  "/" after "://" and used the result without checking it, so a URI with no such "/" -
//  which is the ordinary shape, xmpp://user@example.com - produced a range of
//  NSNotFound - 7 and blew up inside substringWithRange:.
//
//  Two things had to be true for that to reach a user, and these tests cover the parser
//  half. The other half was that Guardian claimed the xmpp scheme at all; it no longer
//  does (Glacier/Info.plist), which is what actually closes the reported attack path.
//
//  Every test here asserts "does not throw" first. Guardian has no caller for XMPPURI any
//  more, so the parsed values matter less than the parser's refusal to abort the process -
//  but the valid-input cases are pinned too, because the fix must not quietly change what
//  a well-formed URI parses to.
//

#import <XCTest/XCTest.h>
@import XMPPFramework;

@interface XMPPURIParsingTests : XCTestCase
@end

@implementation XMPPURIParsingTests

#pragma mark - Helpers

/// Parses without letting an NSException escape, so one bad input fails its own test
/// instead of tearing down the whole run.
- (XMPPURI *)parse:(NSString *)uriString {
    XMPPURI *uri = nil;
    @try {
        uri = [[XMPPURI alloc] initWithURIString:uriString];
    } @catch (NSException *exception) {
        XCTFail(@"parsing %@ raised %@: %@", uriString, exception.name, exception.reason);
    }
    return uri;
}

#pragma mark - The reported crash

- (void)testAuthorityWithoutPathDoesNotThrow {
    // The exact URI from the assessment.
    XMPPURI *uri = [self parse:@"xmpp://assessment-invalid@example.invalid"];
    XCTAssertEqualObjects(uri.accountJID.bare, @"assessment-invalid@example.invalid");
    XCTAssertNil(uri.jid, @"an authority with no path names no target");
}

- (void)testDegenerateAuthorityFormsDoNotThrow {
    for (NSString *input in @[@"xmpp://", @"://", @"xmpp://@", @"xmpp://///", @"xmpp:://///"]) {
        XMPPURI *uri = [self parse:input];
        XCTAssertNil(uri.jid, @"%@ should not yield a JID", input);
    }
}

- (void)testEmptyAndSchemeOnlyInputDoNotThrow {
    XCTAssertNil([self parse:@""].jid);
    XCTAssertNil([self parse:@"xmpp:"].jid);
}

- (void)testOversizedAuthorityWithoutPathDoesNotThrow {
    NSMutableString *input = [NSMutableString stringWithString:@"xmpp://"];
    for (NSUInteger i = 0; i < 4096; i++) {
        [input appendString:@"a"];
    }
    XCTAssertNil([self parse:input].jid);
}

- (void)testUnicodeAuthorityWithoutPathDoesNotThrow {
    XMPPURI *uri = [self parse:@"xmpp://ромео@монтекки.рф"];
    XCTAssertEqualObjects(uri.accountJID.bare, @"ромео@монтекки.рф");
}

#pragma mark - Valid input still parses the way it did

- (void)testAuthorityFormWithPath {
    XMPPURI *uri = [self parse:@"xmpp://guest@example.com/support@example.com"];
    XCTAssertEqualObjects(uri.accountJID.bare, @"guest@example.com");
    XCTAssertEqualObjects(uri.jid.bare, @"support@example.com");
    XCTAssertNil(uri.queryAction);
}

- (void)testAuthorityFormWithPathAndQueryAction {
    XMPPURI *uri = [self parse:@"xmpp://guest@example.com/support@example.com?message"];
    XCTAssertEqualObjects(uri.accountJID.bare, @"guest@example.com");
    XCTAssertEqualObjects(uri.jid.bare, @"support@example.com");
    XCTAssertEqualObjects(uri.queryAction, @"message");
}

- (void)testPlainForm {
    XMPPURI *uri = [self parse:@"xmpp:romeo@montague.net"];
    XCTAssertEqualObjects(uri.jid.bare, @"romeo@montague.net");
    XCTAssertNil(uri.accountJID);
}

- (void)testPlainFormWithQueryAction {
    XMPPURI *uri = [self parse:@"xmpp:romeo@montague.net?subscribe"];
    XCTAssertEqualObjects(uri.jid.bare, @"romeo@montague.net");
    XCTAssertEqualObjects(uri.queryAction, @"subscribe");
}

- (void)testQueryParametersArePercentDecoded {
    XMPPURI *uri = [self parse:@"xmpp:romeo@montague.net?message;subject=Test%20Message"];
    XCTAssertEqualObjects(uri.queryAction, @"message");
    XCTAssertEqualObjects(uri.queryParameters[@"subject"], @"Test Message");
}

#pragma mark - Malformed query structure

- (void)testMalformedQueryStructureDoesNotThrow {
    // Broken percent-encoding, an empty query, duplicated and trailing delimiters. None of
    // these crashed before the fix; they are here so the next change to this parser has to
    // keep clearing them.
    NSArray<NSString *> *inputs = @[@"xmpp:romeo@montague.net?",
                                    @"xmpp:romeo@montague.net?message;subject=%ZZ",
                                    @"xmpp:romeo@montague.net?message;;;;",
                                    @"xmpp:romeo@montague.net?message;novalue",
                                    @"xmpp:romeo@montague.net?message;a=b=c"];
    for (NSString *input in inputs) {
        XCTAssertEqualObjects([self parse:input].jid.bare, @"romeo@montague.net",
                              @"%@ should still resolve its JID", input);
    }
}

- (void)testBrokenPercentEncodingDropsOnlyThatParameter {
    XMPPURI *uri = [self parse:@"xmpp:romeo@montague.net?message;subject=%ZZ;body=fine"];
    XCTAssertNil(uri.queryParameters[@"subject"]);
    XCTAssertEqualObjects(uri.queryParameters[@"body"], @"fine");
}

@end
