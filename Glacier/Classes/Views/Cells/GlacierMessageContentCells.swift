//
//  GlacierMessageContentCells.swift
//  Glacier
//
//  Crash-hardening subclasses of MessageKit's built-in content cells.
//
//  MessageKit's `MessageContentCell.layoutMessageContainerView(with:)` hard-`fatalError`s
//  (MessageKitError.avatarPositionUnresolved) if it is ever handed layout attributes whose
//  `avatarPosition.horizontal == .natural`. `.natural` is only meant to be resolved inside the
//  size calculator's `configure(attributes:)`, but the default value on a freshly-created
//  `MessagesCollectionViewLayoutAttributes` IS `.natural`. During the typing-indicator section
//  insert (`setTypingIndicatorViewHidden` -> `insertSections`), UIKit runs a bounds-change fade
//  over the existing visible message cells and can apply an *unconfigured* attribute object to a
//  cell — which crashes the app. This was crash Glacier-2026-08-02 (build 1208).
//
//  These subclasses intercept `apply(_:)` and resolve an unconfigured `.natural` to a concrete
//  side before MessageKit can trip its assertion. In the normal (configured) path the value is
//  never `.natural`, so this is a no-op there — zero behavior change except avoiding the crash.
//  They are registered under MessageKit's built-in reuse identifiers (see
//  `configureMessageCollectionView()`), so MessageKit's own dequeue transparently vends them.
//

import UIKit
import MessageKit

extension MessagesCollectionViewLayoutAttributes {
    /// Returns attributes safe to hand to `MessageContentCell` layout. If `avatarPosition.horizontal`
    /// is still `.natural` (an unconfigured attribute), returns a copy resolved to a concrete side so
    /// MessageKit's `layoutMessageContainerView` cannot `fatalError`. Otherwise returns `self` unchanged.
    /// A copy is used so we never mutate an attribute object the layout may be caching.
    func resolvingUnconfiguredAvatarPosition() -> MessagesCollectionViewLayoutAttributes {
        guard avatarPosition.horizontal == .natural else { return self }
        // swiftlint:disable:next force_cast
        let safe = copy() as! MessagesCollectionViewLayoutAttributes
        safe.avatarPosition.horizontal = .cellLeading
        return safe
    }
}

class GlacierTextMessageCell: TextMessageCell {
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        if let attrs = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            super.apply(attrs.resolvingUnconfiguredAvatarPosition())
        } else {
            super.apply(layoutAttributes)
        }
    }
}

class GlacierMediaMessageCell: MediaMessageCell {
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        if let attrs = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            super.apply(attrs.resolvingUnconfiguredAvatarPosition())
        } else {
            super.apply(layoutAttributes)
        }
    }
}

class GlacierLocationMessageCell: LocationMessageCell {
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        if let attrs = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            super.apply(attrs.resolvingUnconfiguredAvatarPosition())
        } else {
            super.apply(layoutAttributes)
        }
    }
}

class GlacierContactMessageCell: ContactMessageCell {
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        if let attrs = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            super.apply(attrs.resolvingUnconfiguredAvatarPosition())
        } else {
            super.apply(layoutAttributes)
        }
    }
}

class GlacierLinkPreviewMessageCell: LinkPreviewMessageCell {
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        if let attrs = layoutAttributes as? MessagesCollectionViewLayoutAttributes {
            super.apply(attrs.resolvingUnconfiguredAvatarPosition())
        } else {
            super.apply(layoutAttributes)
        }
    }
}
