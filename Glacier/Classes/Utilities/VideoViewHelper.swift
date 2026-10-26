//
//  VideoViewHelper.swift
//  Glacier
//
//  Adds a "Save" affordance to the video player so incoming videos can be saved
//  to the user's photo library, mirroring the save-to-library option for images.
//

import AVKit
import MBProgressHUD
import ObjectiveC
import Photos
import UIKit

@objc final class VideoViewHelper: NSObject {

    private let videoItem: ChatVideoItem
    private let buddyUniqueId: String?
    private weak var playerVC: AVPlayerViewController?

    private init(videoItem: ChatVideoItem, buddyUniqueId: String?) {
        self.videoItem = videoItem
        self.buddyUniqueId = buddyUniqueId
    }

    // Retains the helper for the lifetime of the player it is attached to.
    private static var helperKey: UInt8 = 0

    /// Adds a "Save" button to the video player that lets the user save the video
    /// to their photo library (after a confirmation prompt).
    @objc static func addSaveButton(to playerVC: AVPlayerViewController,
                                    videoItem: ChatVideoItem,
                                    buddyUniqueId: String?) {
        let helper = VideoViewHelper(videoItem: videoItem, buddyUniqueId: buddyUniqueId)
        helper.playerVC = playerVC
        objc_setAssociatedObject(playerVC, &helperKey, helper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // Free up the top-right corner (where our button sits) from the PiP control.
        playerVC.allowsPictureInPicturePlayback = false
        helper.installButton()
    }

    private func installButton() {
        guard let container = playerVC?.view else { return }

        let symbol = UIImage(systemName: "square.and.arrow.down",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))

        let button: UIButton
        // AVKit places its top control row at the safe-area top on iOS 26, but ~8pt lower
        // on earlier versions, so match the row per-OS.
        let topInset: CGFloat
        if #available(iOS 26.0, *) {
            // Match the player's other controls: a circular Liquid Glass icon button.
            var config = UIButton.Configuration.glass()
            config.image = symbol
            config.cornerStyle = .capsule
            config.baseForegroundColor = .white
            button = UIButton(configuration: config)
            topInset = 0
        } else {
            // Pre-Liquid Glass (e.g. iOS 18): the player's other controls are borderless
            // plain icons, so match that — just a white icon with a shadow for legibility.
            button = UIButton(type: .system)
            button.setImage(symbol, for: .normal)
            button.tintColor = .white
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.5
            button.layer.shadowRadius = 3
            button.layer.shadowOffset = .zero
            topInset = 8
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: topInset),
            // Sit to the left of the player's built-in volume control in the top-right corner.
            button.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -72),
            // Square + capsule corners = a circle that matches the other control buttons.
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalTo: button.widthAnchor)
        ])
    }

    // MARK: - Save flow

    @objc private func saveTapped() {
        guard let playerVC = playerVC else { return }

        // For security/privacy, warn the user before writing a decrypted copy to their device.
        let alert = UIAlertController(title: "Save to Storage?",
                                      message: "Saving this video to your device will allow any other apps on your device to access it.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            self?.saveVideoToPhotoLibrary()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        playerVC.present(alert, animated: true)
    }

    private func saveVideoToPhotoLibrary() {
        guard let playerVC = playerVC, let buddyUniqueId = buddyUniqueId else {
            showFailureAlert()
            return
        }

        // The HUD covers the player's view and absorbs touches, so the user can't
        // dismiss the player or scrub mid-save and short-circuit the export.
        let hud = MBProgressHUD.showAdded(to: playerVC.view, animated: true)
        hud.label.text = "Saving…"
        // Keep it up long enough to register even when a small video saves near-instantly,
        // so it never just flashes.
        hud.minShowTime = 0.7
        hud.isUserInteractionEnabled = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Preserve the original container format where possible.
            let pathExtension = (self.videoItem.getFilename() as NSString?)?.pathExtension
            let ext = (pathExtension?.isEmpty == false) ? pathExtension! : "mp4"
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)

            do {
                // Streams the decrypted bytes to a temp file without loading it all into memory.
                try MediaFileManager.shared.exportChatItem(self.videoItem, buddyUniqueId: buddyUniqueId, toFileURL: destURL)
            } catch {
                DDLogError("VideoViewHelper failed to export video: \(error)")
                DispatchQueue.main.async {
                    hud.hide(animated: true)
                    self.showFailureAlert()
                }
                return
            }

            self.writeToPhotoLibrary(fileURL: destURL, hud: hud)
        }
    }

    private func writeToPhotoLibrary(fileURL: URL, hud: MBProgressHUD) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }

            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: fileURL)
                DispatchQueue.main.async {
                    hud.hide(animated: true)
                    self.showPermissionDeniedAlert()
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }, completionHandler: { [weak self] success, error in
                // Never leave the decrypted copy behind.
                try? FileManager.default.removeItem(at: fileURL)
                DispatchQueue.main.async {
                    if success {
                        // Transform the existing "Saving…" HUD into the confirmation so the
                        // two never overlap (and minShowTime still applies to the spinner).
                        hud.mode = .customView
                        hud.customView = UIImageView(image: UIImage(systemName: "checkmark.circle"))
                        hud.label.text = "Saved to Photos"
                        hud.isUserInteractionEnabled = false
                        hud.hide(animated: true, afterDelay: 1.5)
                    } else {
                        hud.hide(animated: true)
                        if let error = error {
                            DDLogError("VideoViewHelper failed to save video to library: \(error)")
                        }
                        self?.showFailureAlert()
                    }
                }
            })
        }
    }

    // MARK: - Feedback

    private func showFailureAlert() {
        guard let playerVC = playerVC else { return }
        let alert = UIAlertController(title: "Unable to Save",
                                      message: "There was a problem saving this video. Please try again.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        playerVC.present(alert, animated: true)
    }

    private func showPermissionDeniedAlert() {
        guard let playerVC = playerVC else { return }
        let alert = UIAlertController(title: "Photos Access Needed",
                                      message: "To save videos, allow access to your photo library in Settings.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        playerVC.present(alert, animated: true)
    }
}
