#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "GlacierICEInterfacePolicy.h"
#import <ifaddrs.h>
#import <stdatomic.h>

@interface ProbeDelegate : NSObject <RTCPeerConnectionDelegate>
@end
@implementation ProbeDelegate
- (void)peerConnection:(RTCPeerConnection *)p didChangeSignalingState:(RTCSignalingState)s {}
- (void)peerConnection:(RTCPeerConnection *)p didAddStream:(RTCMediaStream *)s {}
- (void)peerConnection:(RTCPeerConnection *)p didRemoveStream:(RTCMediaStream *)s {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)p {}
- (void)peerConnection:(RTCPeerConnection *)p didChangeIceConnectionState:(RTCIceConnectionState)s {}
- (void)peerConnection:(RTCPeerConnection *)p didChangeIceGatheringState:(RTCIceGatheringState)s {}
- (void)peerConnection:(RTCPeerConnection *)p didGenerateIceCandidate:(RTCIceCandidate *)c {}
- (void)peerConnection:(RTCPeerConnection *)p didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)c {}
- (void)peerConnection:(RTCPeerConnection *)p didOpenDataChannel:(RTCDataChannel *)c {}
@end

int main(void) {
    @autoreleasepool {
        if (![GlacierICEInterfacePolicy install]) { fprintf(stderr,"FAIL: SDK import was not rebound\n"); return 1; }
        struct ifaddrs *interfaces = NULL;
        if (getifaddrs(&interfaces) == 0) freeifaddrs(interfaces);
        if ([GlacierICEInterfacePolicy enumerationCount] != 0) { fprintf(stderr,"FAIL: policy escaped WebRTC image\n"); return 1; }
        RTCInitializeSSL();
        RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] init];
        RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
        configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
        ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
        RTCPeerConnection *connection = [factory peerConnectionWithConfiguration:configuration
            constraints:[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil] delegate:delegate];
        [connection dataChannelForLabel:@"interface-policy-test" configuration:[[RTCDataChannelConfiguration alloc] init]];
        [connection offerForConstraints:[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil]
            completionHandler:^(RTCSessionDescription *description, NSError *error) {
                if (description && !error) [connection setLocalDescription:description completionHandler:^(NSError *error) {}];
            }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
        while ([deadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        uint64_t count = [GlacierICEInterfacePolicy enumerationCount];
        [connection close];
        if (count == 0) { fprintf(stderr,"FAIL: actual SDK gathering did not call policy\n"); return 1; }
        printf("PASS: real WebRTC ICE gathering used scoped filter %llu times; application enumeration unaffected\n", count);
    }
    return 0;
}
