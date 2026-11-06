//
//  RoomAttachmentWebViewController.swift
//  ChatSecureCore
//
//  Created by Andy Friedman on 5/13/19.
//  Copyright © 2019 GlacierSecurity. All rights reserved.

import UIKit
import UniformTypeIdentifiers
@preconcurrency import WebKit

open class RoomAttachmentWebViewController: UIViewController, WKUIDelegate {
    
    var webView: WKWebView!
    var attachUrl: URL
    var attachData: Data?
    var baseUrl: URL
    
    var saveUrl: URL
    var saving: Bool

    // Attachment content is supplied by whoever sent it, so the viewer treats it as
    // untrusted: no page JavaScript, no persistent web storage, no remote fetches, and
    // no navigation away from the attachment inside the app's own chrome.
    private var initialNavigationAllowed = false
    private static let ruleListIdentifier = "GlacierAttachmentBlockRemote"
    // Block every http(s)/ws(s) load except the localhost MediaServer (GCDWebServer
    // reports its URL as http://localhost:<port>/). Non-network schemes (file:, data:,
    // blob:, about:, x-apple-ql-id: for QuickLook-converted documents) are left alone
    // so local rendering keeps working. WebKit's url-filter regex has no `|`, hence
    // one rule per pattern.
    private static let blockRemoteRules = #"""
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://localhost(:[0-9]+)?/"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^https?://127\\.0\\.0\\.1(:[0-9]+)?/"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """#

    @objc public init(url:URL, data:Data?, baseurl:URL) {
        attachUrl = url
        saveUrl = attachUrl
        attachData = data
        baseUrl = baseurl
        saving = false
        super.init(nibName: nil, bundle: nil)
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override open func loadView() {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webConfiguration.dataDetectorTypes = []
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.allowsLinkPreview = false
        webView.uiDelegate = self
        webView.navigationDelegate = self
        view = webView
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        // The rule list must be installed before the first load, so the load waits for it.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier,
            encodedContentRuleList: Self.blockRemoteRules) { [weak self] ruleList, error in
                guard let self = self else { return }
                if let ruleList = ruleList {
                    self.webView.configuration.userContentController.add(ruleList)
                } else {
                    // The rules are static, so this only fails if they are edited badly.
                    // JavaScript stays off and navigation stays restricted either way.
                    DDLogError("Attachment viewer content rules failed to compile: \(String(describing: error))")
                }
                self.loadAttachment()
            }

        saving = false
        let saveButton = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveFile(_:)))
        self.navigationItem.rightBarButtonItem = saveButton
    }

    private func loadAttachment() {
        if let data = attachData {
            let type = UTType(tag: attachUrl.pathExtension, tagClass: .filenameExtension, conformingTo: nil)
            let contentType = type?.preferredMIMEType ?? "nil"
            // In-memory content is self-contained. A remote base URL would only give
            // sender-supplied content that server's origin, and the rule list blocks it.
            let base = baseUrl.isFileURL ? baseUrl : URL(string: "about:blank")!
            webView.load(data, mimeType: contentType, characterEncodingName: "UTF-8", baseURL: base)
        } else {
            if (attachUrl.isFileURL) {
                webView.loadFileURL(attachUrl, allowingReadAccessTo: attachUrl)
            } else {
                let myRequest = URLRequest(url: attachUrl)
                webView.load(myRequest)
            }
        }
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if (saving) {
            return
        }
        
        if (attachUrl.isFileURL) {
            do {
                try FileManager.default.removeItem(at: attachUrl)
            } catch {
                print("Could not delete local file: \(error)")
            }
        } else if (saveUrl.isFileURL) {
            do {
                try FileManager.default.removeItem(at: saveUrl)
            } catch {
                print("Could not delete local file: \(error)")
            }
        }
        
        attachData = nil
    }
    
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        saving = false
    }
    
    @objc private func saveFile(_ sender: Any) {
        saving = true
        
        saveUrl = attachUrl
        if (!attachUrl.isFileURL) {
            if let storedUrl = self.tryStoreLocal() {
                saveUrl = storedUrl
            }
        }
        
        if (saveUrl.isFileURL) {
            let activityViewController = UIActivityViewController(activityItems: [saveUrl], applicationActivities: nil)
            activityViewController.completionWithItemsHandler = { (activity, success, items, error) in
                if (success) {
                    let msg = self.saveUrl.lastPathComponent + " has been saved!"
                    let alert = UIAlertController(title: "File Saved", message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"), style: .default, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                } else if (error != nil) {
                    self.saveAlert()
                }
            }
            self.present(activityViewController, animated: true, completion: nil)
        } else {
            saveAlert()
        }
    }
    
    private func tryStoreLocal() -> URL? {
        
        if (attachData == nil) {
            do {
                attachData = try Data(contentsOf: attachUrl)
            } catch {
                // contents could not be loaded
                saveAlert()
                return nil
            }
            
            if (attachData == nil) {
                saveAlert()
                return nil
            }
        }
        
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fileurl = paths[0].appendingPathComponent(attachUrl.lastPathComponent)
        
        do {
            try attachData!.write(to: fileurl, options: .atomic)//, encoding: String.Encoding.utf8)
        } catch {
            // failed to write file – bad permissions, bad filename, missing permissions, or more likely it can't be converted to the encoding
            DDLogError("Something went wrong storing data locally")
            saveAlert()
            return nil
        }
        
        return fileurl
    }
    
    private func saveAlert() {
        let alert = UIAlertController(title: "Cannot Save", message: "There is a problem trying to save this file", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"), style: .default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }
}

extension RoomAttachmentWebViewController: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print(error)
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error)
    {
        print(error)
    }
    
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        // The first main-frame navigation is the load this controller issued itself.
        if !initialNavigationAllowed && navigationAction.targetFrame?.isMainFrame == true {
            initialNavigationAllowed = true
            decisionHandler(.allow)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // A link the user tapped (e.g. in a PDF) goes to the system browser, where the
        // real address is visible, rather than replacing the attachment in-app.
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                UIApplication.shared.open(url)
            }
            return
        }

        // Anything else the document tries on its own (form posts, meta refresh,
        // iframes) may only stay on non-network schemes such as about: or data:
        // (x-apple-ql-id: is WebKit's scheme for QuickLook-converted Office documents).
        switch url.scheme?.lowercased() {
        case "about", "data", "blob", "x-apple-ql-id":
            decisionHandler(navigationAction.navigationType == .formSubmitted ||
                            navigationAction.navigationType == .formResubmitted ? .cancel : .allow)
        default:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {

        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            // do something else with `navigationResponse.response`
            let alert = UIAlertController(title: "Cannot Open", message: "Unable to open attachment", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"), style: .default, handler: { (action: UIAlertAction) -> Void in
                self.navigationController?.popViewController(animated: true);
            }))
            self.present(alert, animated: true, completion: nil)
        }
    }
}
