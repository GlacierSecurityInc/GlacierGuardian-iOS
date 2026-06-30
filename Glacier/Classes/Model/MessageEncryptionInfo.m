//
//  MessageEncryptionInfo.m
//  ChatSecure
//
//  Created by David Chiles on 11/10/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

#import "MessageEncryptionInfo.h"

@implementation MessageEncryptionInfo


- (instancetype)initWithMessageSecurity:(GlacierMessageTransportSecurity)messageSecurity
{
    if (self = [super init]) {
        _messageSecurity = messageSecurity;
    }
    return self;
}

- (instancetype)initPlaintext {
    return [self initWithMessageSecurity:GlacierMessageTransportSecurityPlaintext];
}

- (instancetype)initWithOMEMODevice:(nonnull NSString *)omemoDeviceYapKey collection:(nonnull NSString *)collection {
    if (self = [self initWithMessageSecurity:GlacierMessageTransportSecurityOMEMO]) {
        _omemoDeviceYapKey = omemoDeviceYapKey;
        _omemoDeviceYapCollection = collection;
    }
    return self;
}

@end
