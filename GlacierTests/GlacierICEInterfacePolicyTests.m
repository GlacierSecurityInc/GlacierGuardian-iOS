//
//  GlacierICEInterfacePolicyTests.m
//  GlacierTests
//
//  Guards the WebRTC import rebinding against SDK upgrades. If install fails,
//  WebRTCClient disables cellular ICE entirely, so a WebRTC bump that changes
//  the framework's layout would quietly break cellular calling. This test
//  turns that into a test failure instead.
//

#import <XCTest/XCTest.h>
#import "GlacierICEInterfacePolicy.h"

@interface GlacierICEInterfacePolicyTests : XCTestCase
@end

@implementation GlacierICEInterfacePolicyTests

- (void)testInstallRebindsWebRTCImports {
    XCTAssertTrue([GlacierICEInterfacePolicy install],
                  @"WebRTC's getifaddrs/bind imports were not rebound. The SDK layout likely changed; "
                  @"cellular ICE would be disabled. Re-check the rebinder against the new WebRTC build "
                  @"and repeat the physical cellular validation.");
}

@end
