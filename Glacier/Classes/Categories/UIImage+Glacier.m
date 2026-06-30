//
//  UIImage+Glacier.m
//  Glacier
//

#import "UIImage+Glacier.h"
#import "Glacier-Swift.h"

@implementation UIImage (Glacier)

+ (UIImage *)squareCropImage:(UIImage *)image
{
    CGFloat width = image.size.width;
    CGFloat height = image.size.height;

    if (width == height) {
        return image;
    }

    CGFloat size = MIN(width, height);
    CGFloat x = roundf((width - size) / 2.0);
    CGFloat y = roundf((height - size) / 2.0);
    CGRect cropRect = CGRectMake(x, y, size, size);
    CGAffineTransform rectTransform = [self imageTransform:image];
    cropRect = CGRectApplyAffineTransform(cropRect, rectTransform);
    cropRect = CGRectMake(roundf(cropRect.origin.x), roundf(cropRect.origin.y), roundf(cropRect.size.width), roundf(cropRect.size.height));

    CGImageRef newImageRef = CGImageCreateWithImageInRect(image.CGImage, cropRect);
    UIImage *newImage = [UIImage imageWithCGImage:newImageRef scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(newImageRef);
    return newImage;
}

+ (UIImage *)rectCropWithImage:(UIImage *)scaledimg cropSize:(CGSize)newSize
{
    CGFloat scaledWidth = scaledimg.size.width;
    CGFloat scaledHeight = scaledimg.size.height;
    CGFloat x = roundf((scaledWidth - newSize.width) / 2.0);
    CGFloat y = roundf((scaledHeight - newSize.height) / 2.0);
    CGRect cropRect = CGRectMake(x, y, newSize.width, newSize.height);
    CGAffineTransform rectTransform = [self imageTransform:scaledimg];
    cropRect = CGRectApplyAffineTransform(cropRect, rectTransform);
    cropRect = CGRectMake(roundf(cropRect.origin.x), roundf(cropRect.origin.y), roundf(cropRect.size.width), roundf(cropRect.size.height));

    CGImageRef newImageRef = CGImageCreateWithImageInRect(scaledimg.CGImage, cropRect);
    UIImage *newImage = [UIImage imageWithCGImage:newImageRef scale:scaledimg.scale orientation:scaledimg.imageOrientation];
    CGImageRelease(newImageRef);
    return newImage;
}

// https://github.com/gekitz/GKImagePicker/blob/e788d9f3fba5595c98dfa0bbbc1dd4e897c1ccf8/GKClasses/GKImageCropView.m#L149
+ (CGAffineTransform)imageTransform:(UIImage *)image {
    CGAffineTransform rectTransform;
    switch (image.imageOrientation)
    {
        case UIImageOrientationLeft:
            rectTransform = CGAffineTransformTranslate(CGAffineTransformMakeRotation(M_PI_2), 0, -image.size.height);
            break;
        case UIImageOrientationRight:
            rectTransform = CGAffineTransformTranslate(CGAffineTransformMakeRotation(-M_PI_2), -image.size.width, 0);
            break;
        case UIImageOrientationDown:
            rectTransform = CGAffineTransformTranslate(CGAffineTransformMakeRotation(-M_PI), -image.size.width, -image.size.height);
            break;
        default:
            rectTransform = CGAffineTransformIdentity;
    }
    return CGAffineTransformScale(rectTransform, image.scale, image.scale);
}

+ (UIImage *)prepareForAvatarUpload:(UIImage *)image maxSize:(CGFloat)size
{
    UIImage *croppedImage = [self squareCropImage:image];
    if (croppedImage.size.height > size) {
        return [croppedImage scaleImageWithNewSize:CGSizeMake(size, size)];
    }
    return croppedImage;
}

@end
