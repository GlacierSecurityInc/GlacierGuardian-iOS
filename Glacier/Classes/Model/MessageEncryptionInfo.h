//
//  MessageEncryptionInfo.h
//  ChatSecure
//
//  Created by David Chiles on 11/10/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

@import Mantle;

NS_ASSUME_NONNULL_BEGIN

// This enum reperesents all the ways a message can be transported.
typedef NS_ENUM(NSUInteger, GlacierMessageTransportSecurity) {
    GlacierMessageTransportSecurityPlaintext = 0,
    GlacierMessageTransportSecurityInvalid = 3,
    GlacierMessageTransportSecurityUnused = 1,
    GlacierMessageTransportSecurityOMEMO = 2
};


@interface MessageEncryptionInfo : MTLModel

- (instancetype) init NS_UNAVAILABLE;

- (instancetype)initWithMessageSecurity:(GlacierMessageTransportSecurity)messageSecurity;
- (instancetype)initPlaintext;
- (instancetype)initWithOMEMODevice:(NSString *)omemoDeviceYapKey collection:(NSString*)collection;

@property (nonatomic, readonly) GlacierMessageTransportSecurity messageSecurity;
@property (nonatomic, strong, nullable, readonly) NSString *omemoDeviceYapKey;
@property (nonatomic, strong, nullable, readonly) NSString *omemoDeviceYapCollection;

@end
NS_ASSUME_NONNULL_END
