//  Glacier
//  Created by andyfriedman on 11/9/23.
//  Copyright © 2023 Glacier. All rights reserved.

import Foundation

@objc class Colors: NSObject {
    @objc static func color(with status: ThreadStatus) -> UIColor? {
        var color = UIColor.clear
        if !GlacierInfo.showsColorForStatus {
            return color
        }
        
        switch status {
        case .unknown, .offline:
            break
        case .away:
            color =  UIColor(red: 0.901, green: 0.527, blue: 0.23, alpha: 1.0)
            break
        case .extendedaway, .donotdisturb:
            color =  UIColor(red: 0.734, green: 0.124, blue: 0.124, alpha: 1.0)
            break
        case .available:
            color =  UIColor(red: 0.083, green: 0.767, blue: 0.194, alpha: 1.0)
            break
        }
        
        return color
    }
}

extension UIColor {
    
    @objc static func bubbleBlue() -> UIColor {
        return UIColor(red: 60, green: 92, blue: 207)
    }
    
    @objc static func appleBlue() -> UIColor {
        return UIColor(red: 0, green: 122, blue: 255) 
    }

    @objc static func bubbleLightGray() -> UIColor {
        return UIColor.systemGray4
    }
}

extension UIImage {
    func imageMasked(with color:UIColor) -> UIImage? {
        let imageRect = CGRect(origin: .zero, size: self.size)
        let renderer = UIGraphicsImageRenderer(size: imageRect.size)
        let maskImage = self.cgImage

        let img = renderer.image { ctx in
            let cgContext = ctx.cgContext
            cgContext.translateBy(x: 0, y: imageRect.height)
            cgContext.scaleBy(x: 1.0, y: -1.0)
            cgContext.clip(to: imageRect, mask: maskImage!)
            color.setFill()
            cgContext.fill(imageRect)
        }
        
        return img
    }
}
