//
//  GifHelper.swift
//  Glacier
//
//  Created by andyfriedman on 7/5/22.
//  Copyright © 2022 Glacier. All rights reserved.
//

import Foundation
import SwiftyGif

@objc open class GifHelper: NSObject {
    
    @objc public static func isGifImage(_ url: URL)->Bool {
        if url.pathExtension.lowercased() == "gif" {
            return true
        }
        return false
    }
    
    /*@objc public static func isGifImage(_ filepath: String)->Bool {
        if (filepath.lowercased().hasSuffix("gif")) {
            return true
        }
        return false
    }*/
    
    @objc public static func getGifImageView(_ gif: UIImage)->UIImageView {
        return UIImageView(gifImage: gif, loopCount: -1)
    }
    
    @objc public static func getGifImage(_ data: Data)->UIImage? {
        
        do {
            let gif = try UIImage(gifData: data)
            return gif
        } catch {
            print(error)
        }
        
        return nil
    }
    
    @objc public static func getGifSize(_ data: Data)->CGSize {
        if let imageSource = CGImageSourceCreateWithData(data as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)  {
            let image = UIImage(cgImage: cgImage)
            return image.size
        }
        return CGSize(width: 0, height: 0)
    }
    
    @objc public static func getImageData(_ image: UIImage)->Data? {
        return image.imageData
    }
    
    /*@objc public func getResizedImage(_ gif: UIImage, maxSize: CGRect) -> UIImage {
        gif.size.width
        if gif.size.width > size.width || gif.size.height > size.height {
            let availableRect = AVFoundation.AVMakeRect(aspectRatio: gif.size, insideRect: .init(origin: .zero, size: maxSize))
            let targetSize = availableRect.size

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

            let resized = renderer.image { (context) in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
    }*/
}
