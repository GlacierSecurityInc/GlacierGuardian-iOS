//
//  AttachmentPicker.h
//  ChatSecure
//
//  Created by David Chiles on 1/16/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;
@import UIKit;
@class AttachmentPicker;

NS_ASSUME_NONNULL_BEGIN
@protocol AttachmentPickerDelegate <NSObject>

@required

- (void)attachmentPicker:(AttachmentPicker *)attachmentPicker gotPhoto:(UIImage *)photo withInfo:(NSDictionary *)info;
- (void)attachmentPicker:(AttachmentPicker *)attachmentPicker gotVideoURL:(NSURL *)videoURL;

@optional
- (void) addUploadHUD;

- (void)attachmentPicker:(AttachmentPicker *)attachmentPicker addAdditionalOptions:(UIAlertController *)alertController;

// for sharing location
- (void)attachmentPicker:(AttachmentPicker *)attachmentPicker shareLocationButtonPressed:(NSURL *)locationURL;

// for sending other file types
- (void)attachmentPicker:(AttachmentPicker *)attachmentPicker gotFileURLs:(NSArray <NSURL *>*)fileURLs;

- (void)attachmentPicker:(AttachmentPicker *)attachmentPicker gotGif:(UIImage *)photo withInfo:(NSDictionary *)info;

/** This shoud reutrn an array of media types like kUTTypeImage. This array will be checked against availableMediaTypesForSourceType: To make sure no erronous types are used
 
    For all availbale media types do not implement or return [UIImagePickerController availableMediaTypesForSourceType:sourceType]
 */
- (NSArray <NSString *>*)attachmentPicker:(AttachmentPicker *)attachmentPicker preferredMediaTypesForSource:(UIImagePickerControllerSourceType)source;

@end

@interface AttachmentPicker : NSObject <UIImagePickerControllerDelegate, UIDocumentPickerDelegate> 
/** Use this to store any extra info you might need later in the delegate callback. */
@property (nonatomic, nullable) id tag;

@property (nonatomic, weak, readonly) UIViewController<UIPopoverPresentationControllerDelegate> *parentViewController;
@property (nonatomic, weak, readonly) id<AttachmentPickerDelegate> delegate;

- (instancetype)initWithParentViewController:(UIViewController<UIPopoverPresentationControllerDelegate> *)parentViewController delegate:(id<AttachmentPickerDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)showAlertControllerFromSourceView:(UIView *)senderView withCompletion:( void (^ _Nullable )(void))completion;
- (void) showGifController;
- (void) showFilePicker;
- (void) showShareLocation;


@end
NS_ASSUME_NONNULL_END
