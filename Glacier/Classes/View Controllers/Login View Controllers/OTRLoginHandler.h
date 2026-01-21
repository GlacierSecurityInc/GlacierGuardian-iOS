//
//  OTRLoginHandler.h
//  ChatSecure
//
//  Created by David Chiles on 6/17/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;
@class XLFormDescriptor, ChatAccountModel;

@protocol OTRBaseLoginViewControllerHandlerProtocol <NSObject>

@required
- (void)performActionWithValidForm:(XLFormDescriptor *)form account:(ChatAccountModel *)account progress:(void (^)(NSInteger progress, NSString *summaryString))progress completion:(void (^)(ChatAccountModel *account, NSError *error))completion;
- (void)moveAccountValues:(ChatAccountModel *)account intoForm:(XLFormDescriptor *)form;

@end

@interface OTRLoginHandler : NSObject

+ (id<OTRBaseLoginViewControllerHandlerProtocol>)loginHandlerForAccount:(ChatAccountModel *)account;

@end
