//
//  EmptyStateTableView.swift
//
//  Created by Sauvik Dolui on 13/10/17 as SDStateTableView
//    see https://github.com/sauvikdolui/SDStateTableView
//
//  Modified by andyfriedman on 5/19/23.
//

import Foundation
public enum TableViewState {
    case dataAvailable
    case noData(image: UIImage?, title: String?, message: String)
}

@IBDesignable
public class EmptyStateTableView: UITableView {
    
    @IBInspectable
    public var stateViewCenterPositionOffset: CGPoint = CGPoint(x: 0.0, y: -88.0) {
        didSet {
            setUp()
        }
    }
    
    // MARK: Spacing
    @IBInspectable
    public var titleStackSpacing: CGFloat = 8.0 {
        didSet {
            setUp()
        }
    }
    @IBInspectable
    public var imageTitleStackSpacing: CGFloat = 16.0 {
        didSet {
            setUp()
        }
    }
    
    /// Determines whether scrolling is enabled even when there is not data
    ///
    /// Note:   Default value is false, i.e. scrolling is not available when there is not data
    @IBInspectable
    public var shouldScrollWithNoData: Bool = false {
        didSet {
            setUp()
        }
    }
    
    var originalSeparatorStyle =  UITableViewCell.SeparatorStyle.singleLine
    var dataStateTitleLabel = UILabel.autolayoutView()
    var dataStateSubtitleLabel = UILabel.autolayoutView()
    var stateImageView = UIImageView.autolayoutView()
    var stackView: UIStackView =  UIStackView.autolayoutView()
    var titleStackView: UIStackView =  UIStackView.autolayoutView()
    
    public var currentState: TableViewState = .dataAvailable {
        didSet {
            if case TableViewState.dataAvailable  = self.currentState {
                isScrollEnabled = true
            } else {
                // Data is available, let's decide according to the
                // value set to shouldScrollWithNoData
                isScrollEnabled = shouldScrollWithNoData
            }
        }
    }
    
    override public init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        setUp()
    }
    
    public init(frame: CGRect, style: UITableView.Style, centerOffset: CGPoint) {
        super.init(frame: frame, style: style)
        stateViewCenterPositionOffset = centerOffset
        setUp()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder : aDecoder)
        setUp()
    }
    
    
    // MARK: - Custom Setup
    private func setUp() {
        dataStateTitleLabel.textColor = UIColor.darkGray
        dataStateTitleLabel.numberOfLines = 0
        dataStateTitleLabel.textAlignment = .center
        dataStateTitleLabel.lineBreakMode = .byWordWrapping
        dataStateTitleLabel._setWidth(width: UIScreen.main.bounds.width * 0.80)
        dataStateTitleLabel.font = UIFont.boldSystemFont(ofSize: 18.0)
        
        dataStateSubtitleLabel.textColor = UIColor.lightGray
        dataStateSubtitleLabel.numberOfLines = 0
        dataStateSubtitleLabel.textAlignment = .center
        dataStateSubtitleLabel.lineBreakMode = .byWordWrapping
        dataStateSubtitleLabel._setWidth(width: UIScreen.main.bounds.width * 0.80)
        dataStateSubtitleLabel.font = UIFont.systemFont(ofSize: 14.0)
        
        titleStackView.axis  = .vertical
        titleStackView.distribution  = .equalSpacing
        titleStackView.alignment = .center
        titleStackView.spacing = titleStackSpacing
        titleStackView.addArrangedSubview(dataStateTitleLabel)
        titleStackView.addArrangedSubview(dataStateSubtitleLabel)
        
        stackView.axis  = .vertical
        stackView.distribution  = .equalSpacing
        stackView.alignment = .center
        stackView.spacing = imageTitleStackSpacing
        
        stackView.addArrangedSubview(stateImageView)
        stackView.addArrangedSubview(titleStackView)
        addSubview(stackView)
        
        //Constraints
        stackView._setCenterAlignWith(view: self, offset: stateViewCenterPositionOffset)
    }
    
    // Mark: - Deinit
    deinit {
        // Deinitialization code goes here
    }
    
    public func setState(_ state: TableViewState) {
        self.currentState =  state
        reloadData()
        switch state {
        case .dataAvailable:
            configureForData()
        case .noData(let image, let title, let message):
            configureWith(image: image, title: title, message: message)
        }
        self.setNeedsLayout()
    }
    
    private func configureWith(image: UIImage?, title: String?, message: String) {
        
        // Image View
        if let image = image {
            stateImageView.isHidden = false
            stateImageView.image = image
            stateImageView.contentMode = .scaleAspectFill
            // Updates the image width if it is too wide
            if image.size.width > self.bounds.width {
                let newSize = CGSize(width: self.bounds.width, height: image.size.height * (self.bounds.width / image.size.width))
                stateImageView.image = image.imageWith(newSize: newSize)
            }
        } else {
            stateImageView.isHidden  = true
        }
        
        // Title Label
        if let title = title {
            dataStateTitleLabel.isHidden = false
            dataStateTitleLabel.text = title
        } else {
            dataStateTitleLabel.isHidden = true
        }
        
        stackView.isHidden = false
        
        dataStateSubtitleLabel.isHidden = false
        dataStateSubtitleLabel.text = message
    }
    
    private func configureForData() {
        stackView.isHidden = true
    }
}

fileprivate extension UIImage {
    // Redraws itself to the new size
    func imageWith(newSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let image = renderer.image { _ in
            self.draw(in: CGRect.init(origin: CGPoint.zero, size: newSize))
        }
            
        return image
    }
}

public extension UIView {
    
    // UIView class function to create an view with
    // translateAutoResizingMaskIntoConstraints is disabled
    class func autolayoutView() -> Self {
        let view = self.init()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

public extension UIEdgeInsets {
    init(margin: CGFloat) {
        self.init()
        self.top = margin
        self.bottom = margin
        self.left = margin
        self.right = margin
    }
    init(sidePadding: CGFloat, verticalPadding: CGFloat) {
        self.init()
        self.top = verticalPadding
        self.bottom = verticalPadding
        self.left = sidePadding
        self.right = sidePadding
    }
}

public extension UIView {
    
    // Alignments
    func _setLeftAlignWith(view: UIView, offset: CGFloat = 0.0) {
        // Leading will be same
        _setAttribute(attribute: .leading, toView: view, targetAttribute: .leading, constant: offset)
    }
    func _setRightAlignWith(view: UIView, offset: CGFloat = 0.0) {
        // Trailings will be same
        _setAttribute(attribute: .trailing, toView: view, targetAttribute: .trailing, constant: offset)
    }
    func _setTopAlignWith(view: UIView, offset: CGFloat = 0.0) {
        // Top will be same
        _setAttribute(attribute: .top, toView: view, targetAttribute: .top, constant: offset)
    }
    func _setBottomAlignWith(view: UIView, offset: CGFloat = 0.0) {
        //Bottom will be same
        _setAttribute(attribute: .bottom, toView: view, targetAttribute: .bottom, constant: offset)
    }
    func _setCenterXAlignWith(view: UIView, offset: CGFloat = 0.0) {
        _setAttribute(attribute: .centerX, toView: view, targetAttribute: .centerX, constant: offset)
    }
    func _setCenterYAlignWith(view: UIView, offset: CGFloat = 0.0) {
        _setAttribute(attribute: .centerY, toView: view, targetAttribute: .centerY, constant: offset)
    }
    func _setCenterAlignWith(view: UIView, offset: CGPoint = CGPoint(x: 0.0, y: 0.0)) {
        _setCenterXAlignWith(view: view, offset: offset.x)
        _setCenterYAlignWith(view: view, offset: offset.y)
    }
    
    
    // Positioning
    func _setLeadingFromRightEdgeOf(view: UIView, offset: CGFloat = 8.0) {
        _setAttribute(attribute: .leading, toView: view, targetAttribute: .trailing, constant: offset)
    }
    func _setTrailingFromLeftEdgeOf(view: UIView, offset: CGFloat = 8.0) {
        _setAttribute(attribute: .trailing, toView: view, targetAttribute: .leading, constant: offset)
    }
    
    func _setTopFromBottomEdgeOf(view: UIView, offset: CGFloat = 8.0) {
        _setAttribute(attribute: .top, toView: view, targetAttribute: .bottom, constant: offset)
    }
    
    func _setBottomFromTopEdgeOf(view: UIView, offset: CGFloat = 8.0) {
        _setAttribute(attribute: .bottom, toView: view, targetAttribute: .top, constant: offset)
    }
    
    // Size
    func _setWidthEqualTo(view: UIView, offset: CGFloat = 0.0) {
        _setAttribute(attribute: .width, toView: view, targetAttribute: .width, constant: offset)
    }
    func _setHeightEqualTo(view: UIView, offset: CGFloat = 0.0) {
        _setAttribute(attribute: .height, toView: view, targetAttribute: .height, constant: offset)
    }
    func _setSizeEqualTo(view: UIView, offset: CGPoint = CGPoint(x:0.0, y: 0.0)) {
        _setWidthEqualTo(view: view, offset: offset.x)
        _setHeightEqualTo(view: view, offset: offset.y)
    }
    
}



// MARK: VIEW MANUPULAITION WITH RESPECT TO ONE'S SUPER VIEW
public extension UIView {
    
    
    func _setTop(topPadding: CGFloat) {
        let contraint = constraintFor(attribute: .top, toView: superview,
                                      toAttribute: .top, constraint: topPadding)
        superview?.addConstraint(contraint)
        
    }
    func _setLeft(sidePadding: CGFloat) {
        let contraint = constraintFor(attribute: .left, toView: superview,
                                      toAttribute: .left, constraint: sidePadding)
        superview?.addConstraint(contraint)
        
    }
    // Fixed Width
    func _setWidth(width: CGFloat) {
        let widthContraint = constraintFor(attribute: .width, toView: nil,
                                           toAttribute: .notAnAttribute, constraint: width)
        superview?.addConstraint(widthContraint)
    }
    func _setWidth(sidePadding: CGFloat) {
        _setAttribute(attribute: .leading, padding: sidePadding)
        _setAttribute(attribute: .trailing, padding: -sidePadding)
    }
    func _setHeight(verticalPadding: CGFloat) {
        _setAttribute(attribute: .top, padding: verticalPadding)
        _setAttribute(attribute: .bottom, padding: -verticalPadding)
    }
    // Fixed Height
    func _setHeight(height: CGFloat) {
        let heightConstraint = constraintFor(attribute: .height, toView: nil,
                                             toAttribute: .notAnAttribute, constraint: height)
        superview?.addConstraint(heightConstraint)
    }
    // Fixed Size
    func _setSize(size: CGSize?) {
        guard let size = size else {
            // Going to return assuming size has been set
            return
        }
        _setWidth(width: size.width)
        _setHeight(height: size.height)
    }
    
    // Equal Size
    func _setEqualWidth() {
        let widthContraint = constraintFor(attribute: .width, toView: superview,
                                           toAttribute: .width, constraint: 0.0)
        superview?.addConstraint(widthContraint)
    }
    // Fixed Height
    func _setEqualHeight() {
        let heightConstraint = constraintFor(attribute: .height, toView: superview,
                                             toAttribute: .height, constraint: 0.0)
        superview?.addConstraint(heightConstraint)
    }
    // Fixed Size
    func _setEqualSize() {
        _setEqualWidth()
        _setEqualHeight()
    }
    
    
    //
    func _layoutWith(size: CGSize?, topLeftOffset: CGPoint) {
        
        _setSize(size: size)
        
        // Leading constraint
        _setAttribute(attribute: .leading, padding: topLeftOffset.x)
        // Top Contraint
        _setAttribute(attribute: .top, padding: topLeftOffset.y)
    }
    
    func _layoutWith(size: CGSize?, topRightOffset: CGPoint) {
        
        _setSize(size: size)
        
        // Trailting constraint
        _setAttribute(attribute: .trailing, padding: -topRightOffset.x)
        // Top Contraint
        _setAttribute(attribute: .top, padding: topRightOffset.y)
    }
    func _layoutWith(size: CGSize?, bottomLeftOffset: CGPoint) {
        _setSize(size: size)
        
        // Leading constraint
        _setAttribute(attribute: .leading, padding: bottomLeftOffset.x)
        // Bottom Contraint
        _setAttribute(attribute: .bottom, padding: -bottomLeftOffset.y)
    }
    
    func _layoutWith(size: CGSize?, bottomRightOffset: CGPoint) {
        
        _setSize(size: size)
        
        // Trailting constraint
        _setAttribute(attribute: .trailing, padding: -bottomRightOffset.x)
        // Bottom Contraint
        _setAttribute(attribute: .bottom, padding: -bottomRightOffset.y)
    }
    func _layoutWith(size: CGSize?, centerOffset: CGPoint) {
        
        _setSize(size: size)
        
        // CenterX constraint
        _setAttribute(attribute: .centerX, padding: centerOffset.x)
        // CenterY Contraint
        _setAttribute(attribute: .centerY, padding: centerOffset.y)
    }
    
    // Helper for laying out in super view
    func _setAttribute(attribute: NSLayoutConstraint.Attribute, padding: CGFloat) {
        let paddingConstraint = constraintFor(attribute: attribute, toView: superview, toAttribute: attribute, constraint: padding)
        superview?.addConstraint(paddingConstraint)
    }
    // Helper in laying out wrt another View
    func _setAttribute(attribute: NSLayoutConstraint.Attribute, toView: UIView,
                              targetAttribute: NSLayoutConstraint.Attribute, constant: CGFloat = 0.0) {
        
        let paddingConstraint = constraintFor(attribute: attribute, toView: toView, toAttribute: targetAttribute, constraint: constant)
        superview?.addConstraint(paddingConstraint)
        
    }
    
    func _layoutInSuper(margin: CGFloat){
        _layoutInSuper(edgeInset: UIEdgeInsets(margin: margin))
    }
    func _layoutInSuper(percentage: CGFloat) {
        guard let parent = self.superview else {
            debugPrint("Error: Super view not found, can not layout")
            return
        }
        
        let multiplier = percentage / 100.0
        // Center X
        let centerXContraint = constraintFor(attribute: .centerX, toView: parent, toAttribute: .centerX)
        // Center Y
        let centerYContraint = constraintFor(attribute: .centerY, toView: parent, toAttribute: .centerY)
        
        // Width
        let widthConstraint = constraintFor(attribute: .width, toView: parent, toAttribute: .width, multiplier: multiplier)
        // Height
        let heightConstraint = constraintFor(attribute: .height, toView: parent, toAttribute: .height, multiplier: multiplier)
        
        parent.addConstraints([centerXContraint, centerYContraint,
                               widthConstraint, heightConstraint])
    }
    
    func _layoutInSuper(edgeInset: UIEdgeInsets) {
        
        guard let parent = self.superview else {
            debugPrint("Error: Super view not found, can not layout")
            return
        }
        // Adding Leading Constant
        let leadingConstraint = constraintFor(attribute: .leading, toView: parent, toAttribute: .leading, constraint: edgeInset.left)
        
        // Adding Trailing Constant
        let trailingConstraint = constraintFor(attribute: .trailing, toView: parent, toAttribute: .trailing, constraint: -edgeInset.right)
        
        // Adding Top Constant
        let topConstraint = constraintFor(attribute: .top, toView: parent, toAttribute: .top, constraint: edgeInset.top)
        
        // Adding Bottom Constant
        let bottomConstraint = constraintFor(attribute: .bottom, toView: parent, toAttribute: .bottom, constraint: -edgeInset.bottom)
        
        parent.addConstraints([leadingConstraint, trailingConstraint,
                               topConstraint, bottomConstraint])
        
    }
    
    // MARK: HELPER
    func constraintFor(attribute: NSLayoutConstraint.Attribute,
                              relatedBy: NSLayoutConstraint.Relation = .equal,
                              toView: UIView?, toAttribute: NSLayoutConstraint.Attribute,
                       multiplier: CGFloat = 1.0, constraint: CGFloat = 0.0) -> NSLayoutConstraint {
        
        return NSLayoutConstraint(item: self,
                                  attribute: attribute,
                                  relatedBy: relatedBy,
                                  toItem: toView,
                                  attribute: toAttribute,
                                  multiplier: multiplier,
                                  constant: constraint)
        
    }
}
