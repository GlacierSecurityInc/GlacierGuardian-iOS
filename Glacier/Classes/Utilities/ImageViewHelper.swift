//  Glacier
//  Created by andyfriedman on 7/14/22.
//  Copyright © 2022 Glacier. All rights reserved.

import Agrume
import UIKit

@objc final class ImageViewHelper: NSObject {
  
    @objc public func openImage(_ image: UIImage, from:UIViewController) {
        let agrume = Agrume(image: image, background: .blurred(.regular))
        agrume.onLongPress = agrume.makeSaveToLibraryLongPressGesture
        agrume.show(from: from)
    }
    
    @objc public static func imageIsGif(_ image:UIImage) -> Bool {
        if let imgdata = image.imageData {
            let imgFormat = imgdata.imageFormat
            if imgFormat == .gif {
                return true
            }
        } 
        
        return false
    }
}

@objc public extension UIImage {
    // Redraws itself to the new size
    @objc func scaleImageWith(newSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let image = renderer.image { _ in
            self.draw(in: CGRect.init(origin: CGPoint.zero, size: newSize))
        }
            
        return image
    }
    
    static func getCircular(image: UIImage, diameter:UInt, highlightedColor:UIColor?) -> UIImage
    {
        let size = CGSizeMake(CGFloat(diameter), CGFloat(diameter))
        let imageRect = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: imageRect.size)

        let newImage = renderer.image { ctx in
            let cgContext = ctx.cgContext
            let imgPath = UIBezierPath(ovalIn: imageRect)
            imgPath.addClip()
            image.draw(in: imageRect)
            
            if let color = highlightedColor {
                color.setFill()
                cgContext.fillEllipse(in: imageRect)
            }
        }
        return newImage
    }
    
    @objc static func getImageWithInitials(_ initials: String, backgroundColor: UIColor, textColor: UIColor, font: UIFont, diameter:UInt) -> UIImage
    {
        let size = CGSizeMake(CGFloat(diameter), CGFloat(diameter))
        let frame = CGRect(origin: .zero, size: size)

        let attributes = [NSAttributedString.Key.font:font,
                          NSAttributedString.Key.foregroundColor:textColor]

        let textFrame = initials.boundingRect(with: frame.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)

        let frameMidPoint = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame))
        let textFrameMidPoint = CGPointMake(CGRectGetMidX(textFrame), CGRectGetMidY(textFrame))

        let dx = frameMidPoint.x - textFrameMidPoint.x
        let dy = frameMidPoint.y - textFrameMidPoint.y
        let drawPoint = CGPointMake(dx, dy)
        
        let renderer = UIGraphicsImageRenderer(size: frame.size)
        let image = renderer.image { ctx in
            let cgContext = ctx.cgContext
            backgroundColor.setFill()
            cgContext.fill(frame)
            initials.draw(at: drawPoint, withAttributes: attributes)
        }

        return UIImage.getCircular(image:image, diameter:diameter, highlightedColor:nil)
    }
}
