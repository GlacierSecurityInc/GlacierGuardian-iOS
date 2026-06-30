//
//  GlacierXMPPError.h
//  Off the Record
//
//  Created by David Chiles on 1/14/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

@import Foundation;
@import KissXML;

NS_ASSUME_NONNULL_BEGIN
extern NSString *const GlacierXMPPErrorDomain;
extern NSString *const GlacierXMPPXMLErrorKey;
extern NSString *const GlacierXMPPSSLTrustResultKey;
extern NSString *const GlacierXMPPSSLCertificateDataKey;
extern NSString *const GlacierXMPPSSLHostnameKey;

typedef NS_ENUM(NSInteger, GlacierXMPPErrorCode) {
    GlacierXMPPErrorCodeUnsupportedAction,
    GlacierXMPPErrorCodeSSLError,
    GlacierXMPPErrorCodeDomainError
};

@interface GlacierXMPPError : NSObject

+ (nullable NSString *)errorStringWithSSLStatus:(OSStatus)status;
+ (nullable NSString *)errorStringWithTrustResultType:(SecTrustResultType)resultType;
+ (NSError *)errorForXMLElement:(NSXMLElement *)xmlError;
+ (NSError *)errorForTrustResult:(SecTrustResultType)trustResultType withCertData:(NSData *)certData hostname:(NSString *)hostName;

@end
NS_ASSUME_NONNULL_END
