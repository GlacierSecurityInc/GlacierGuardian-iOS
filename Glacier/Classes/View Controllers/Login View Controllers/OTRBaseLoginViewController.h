//
//  OTRBaseLoginViewController.h
//  ChatSecure
//
//  Created by David Chiles on 5/12/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import XLForm;
@class ChatAccountModel;
#import "OTRLoginHandler.h"

NS_ASSUME_NONNULL_BEGIN
@interface OTRBaseLoginViewController : XLFormViewController

@property (nonatomic, strong, nullable) ChatAccountModel *account;
@property (nonatomic, strong) id<OTRBaseLoginViewControllerHandlerProtocol> loginHandler;

@property (nonatomic) BOOL showsCancelButton;
/** If true, do not allow editing of the form */
@property (nonatomic) BOOL readOnly;

/**
 * Creates a view for logging in with an existing local & remote account.
 *
 * @param An account to use to create the view
 * @return A configured OTRBaseLoginViewController
 */
- (instancetype) initWithAccount:(ChatAccountModel*)account;

#pragma mark - Superclass Overrides
// The below methods can be overridden by subclasses

/** Attempts to login with existing account or create/register account via form values. */
- (void)loginButtonPressed:(id)sender;

/** This is called after login succeeds and by default will push the next onboarding view controller */
- (void) handleSuccessWithNewAccount:(ChatAccountModel*)account sender:(id)sender;

/** This is called after login succeeds and by default will push the next onboarding view controller */
- (void) handleError:(NSError*)error;


@end
NS_ASSUME_NONNULL_END
