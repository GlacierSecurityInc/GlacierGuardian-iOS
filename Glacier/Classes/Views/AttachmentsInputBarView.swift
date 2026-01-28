//
//  AttachmentsInputBarView.swift
//  Glacier
//
//  Created by andyfriedman on 8/21/23.
//  Copyright © 2023 Glacier. All rights reserved.
//

//
//  CameraInputBarAccessoryView.swift
//  ChatExample
//
//  Created by Mohannad on 12/25/20.
//  Modified by andyfriedman on 8/21/23.
//  Copyright © 2020 MessageKit. All rights reserved.
//

import InputBarAccessoryView
import UIKit
import PhotosUI

// MARK: - CameraInputBarAccessoryViewDelegate

protocol AttachmentsInputBarViewDelegate: InputBarAccessoryViewDelegate {
    func inputBar(_ inputBar: InputBarAccessoryView, didPressSendButtonWith attachments: [AttachmentManager.Attachment])
    func didPressPlus(with inputBar: InputBarAccessoryView)
    func didChooseVideo(with url: URL)
}

extension AttachmentsInputBarViewDelegate {
  func inputBar(_: InputBarAccessoryView, didPressSendButtonWith _: [AttachmentManager.Attachment]) { }
}

// MARK: - CameraInputBarAccessoryView

class AttachmentsInputBarView: InputBarAccessoryView {
    
  // MARK: Lifecycle
    //var attachmentPicker: OTRAttachmentPicker?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Internal

  lazy var attachmentManager: AttachmentManager = { [unowned self] in
    let manager = AttachmentManager()
    manager.delegate = self
    return manager
  }()

  func configure() {
      let plus = makeButton()
      setLeftStackViewWidthConstant(to: 35, animated: true)
      setRightStackViewWidthConstant(to: 54, animated: true)
      setStackViewItems([plus], forStack: .left, animated: false)
      inputPlugins = [attachmentManager]
  }

  override func didSelectSendButton() {
    if attachmentManager.attachments.count > 0 {
      (delegate as? AttachmentsInputBarViewDelegate)?
        .inputBar(self, didPressSendButtonWith: attachmentManager.attachments)
    }
    else {
      delegate?.inputBar(self, didPressSendButtonWith: inputTextView.text)
    }
  }

  // MARK: Private

  private func makeButton() -> InputBarButtonItem {
    InputBarButtonItem()
        .configure {
            $0.spacing = .fixed(10)
            $0.image = UIImage(systemName: "plus")?.withRenderingMode(.alwaysTemplate)
            $0.setSize(CGSize(width: 30, height: 30), animated: false)
            $0.tintColor = UIColor.bubbleBlue()
        }.onTouchUpInside { [weak self] _ in
            guard let self = self else { return }
            (self.delegate as? AttachmentsInputBarViewDelegate)?.didPressPlus(with: self)
        }
  }
}

// MARK: PHPickerViewControllerDelegate
extension AttachmentsInputBarView: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        
        getRootViewController()?.dismiss(animated: true, completion: nil)
        inputAccessoryView?.isHidden = false*/
    }
}

// MARK: UIImagePickerControllerDelegate, UINavigationControllerDelegate
extension AttachmentsInputBarView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  @objc
  func showImagePickerControllerActionSheet() {
      //self.attachmentPicker?.showAlertController(fromSourceView: self)
      let photoLibraryAction = UIAlertAction(title: "Choose From Library", style: .default) { [weak self] _ in
          self?.showImagePickerController(sourceType: .photoLibrary)
      }

      let cameraAction = UIAlertAction(title: "Take From Camera", style: .default) { [weak self] _ in
          self?.showImagePickerController(sourceType: .camera)
      }

      let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
      let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
      alert.addAction(photoLibraryAction)
      alert.addAction(cameraAction)
      alert.addAction(cancelAction)

      UIApplication.shared.delegate?.window??.rootViewController?.present(alert, animated: true, completion: nil)
  }

  func showImagePickerController(sourceType: UIImagePickerController.SourceType) {
      let imgPicker = UIImagePickerController()
      imgPicker.delegate = self
      //imgPicker.allowsEditing = true
      imgPicker.sourceType = sourceType
    
      if sourceType == .photoLibrary {
          let mediaTypes = UIImagePickerController.availableMediaTypes(for: .photoLibrary) ?? []
          imgPicker.mediaTypes = mediaTypes
      }
      
      imgPicker.presentationController?.delegate = self
      inputAccessoryView?.isHidden = true
      getRootViewController()?.present(imgPicker, animated: true, completion: nil)
      
  }

  func imagePickerController(
    _: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any])
  {
    if let editedImage = info[UIImagePickerController.InfoKey.editedImage] as? UIImage {
      // self.sendImageMessage(photo: editedImage)
      inputPlugins.forEach { _ = $0.handleInput(of: editedImage) }
    }
    else if let originImage = info[UIImagePickerController.InfoKey.originalImage] as? UIImage {
      inputPlugins.forEach { _ = $0.handleInput(of: originImage) }
      // self.sendImageMessage(photo: originImage)
    } else if let videoUrl = info[.mediaURL] as? NSURL {
        //handleVideo
        //self.handleVideoPicked(videoUrl)
        (self.delegate as? AttachmentsInputBarViewDelegate)?.didChooseVideo(with: videoUrl as URL)
        //inputPlugins.forEach { _ = $0.handleInput(of: videoUrl) }
    }
    getRootViewController()?.dismiss(animated: true, completion: nil)
    inputAccessoryView?.isHidden = false
  }

  func imagePickerControllerDidCancel(_: UIImagePickerController) {
    getRootViewController()?.dismiss(animated: true, completion: nil)
    inputAccessoryView?.isHidden = false
  }

  func getRootViewController() -> UIViewController? {
    (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController
  }
}

// MARK: AttachmentManagerDelegate

extension AttachmentsInputBarView: AttachmentManagerDelegate {
  // MARK: - AttachmentManagerDelegate

  func attachmentManager(_: AttachmentManager, shouldBecomeVisible: Bool) {
    setAttachmentManager(active: shouldBecomeVisible)
  }

  func attachmentManager(_ manager: AttachmentManager, didReloadTo _: [AttachmentManager.Attachment]) {
    sendButton.isEnabled = manager.attachments.count > 0
  }

  func attachmentManager(_ manager: AttachmentManager, didInsert _: AttachmentManager.Attachment, at _: Int) {
    sendButton.isEnabled = manager.attachments.count > 0
  }

  func attachmentManager(_ manager: AttachmentManager, didRemove _: AttachmentManager.Attachment, at _: Int) {
    sendButton.isEnabled = manager.attachments.count > 0
  }

  func attachmentManager(_: AttachmentManager, didSelectAddAttachmentAt _: Int) {
    showImagePickerControllerActionSheet()
  }

  // MARK: - AttachmentManagerDelegate Helper

  func setAttachmentManager(active: Bool) {
    let topStackView = topStackView
    if active, !topStackView.arrangedSubviews.contains(attachmentManager.attachmentView) {
      topStackView.insertArrangedSubview(attachmentManager.attachmentView, at: topStackView.arrangedSubviews.count)
      topStackView.layoutIfNeeded()
    } else if !active, topStackView.arrangedSubviews.contains(attachmentManager.attachmentView) {
      topStackView.removeArrangedSubview(attachmentManager.attachmentView)
      topStackView.layoutIfNeeded()
    }
  }
}

// MARK: UIAdaptivePresentationControllerDelegate

extension AttachmentsInputBarView: UIAdaptivePresentationControllerDelegate {
  // Swipe to dismiss image modal
  public func presentationControllerWillDismiss(_: UIPresentationController) {
    isHidden = false
  }
}

public class VideoAttachment {
    public let thumbnail: UIImage

    public init(thumbnail: UIImage) {
        self.thumbnail = thumbnail
    }
}
