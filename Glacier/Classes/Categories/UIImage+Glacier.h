//
//  UIImage+Glacier.h
//  Glacier
//

@import UIKit;

NS_ASSUME_NONNULL_BEGIN
@interface UIImage (Glacier)

+ (UIImage *)rectCropWithImage:(UIImage *)image cropSize:(CGSize)newSize;
/** Square-crops image to shortest side. */
+ (UIImage *)squareCropImage:(UIImage *)image;
/** Square-crops then scales down to maxSize if needed. */
+ (UIImage *)prepareForAvatarUpload:(UIImage *)image maxSize:(CGFloat)size;

@end
NS_ASSUME_NONNULL_END
