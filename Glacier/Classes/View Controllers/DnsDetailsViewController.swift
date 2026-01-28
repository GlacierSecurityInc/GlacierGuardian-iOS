//  Glacier
//  Created by andyfriedman on 9/24/24.
//  Copyright © 2024 Glacier. All rights reserved.

import UIKit
import WireGuardKit

open class DnsDetailsViewController: UITableViewController {
    
    @IBOutlet weak var tunnelDnsCell: UITableViewCell!
    
    var tunnel: TunnelContainer?
    var tunnelViewModel: TunnelViewModel?
    var onDemandViewModel: ActivateOnDemandViewModel?
    var tunnelsMgr: TunnelsManager?
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        guard let tun = WireGuardManager.shared().tunnelsManager?.tunnelInOperation() else {
            self.dismiss(animated: true, completion: nil)
            return
        }
        
        self.tunnelsMgr = WireGuardManager.shared().tunnelsManager
        self.tunnel = tun
        self.tunnelViewModel = TunnelViewModel(tunnelConfiguration: tun.tunnelConfiguration)
        self.onDemandViewModel = ActivateOnDemandViewModel(tunnel: tun)
        
        
        self.title = tunnelViewModel?.interfaceData[.name]
        self.tunnelDnsCell.detailTextLabel?.text = self.tunnelViewModel!.interfaceData[.dns]
    }
    
    @IBAction func restoreOriginalDns(_ sender: Any) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment.left
        let addmsg = "\nAre you sure you want to restore to the original DNS address?"
        let alert = UIAlertController(title: NSLocalizedString("Restore DNS Setting", comment: "Restore DNS"), message: addmsg, preferredStyle: .alert)
        
        let messageText = NSMutableAttributedString(
            string: addmsg,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paragraphStyle,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
            ]
        )
            
        alert.setValue(messageText, forKey: "attributedMessage")
        alert.addAction(UIAlertAction(title: NSLocalizedString("Restore DNS", comment: "Restore DNS button"), style: .default, handler: {(action: UIAlertAction!) in
            
            if let dns = self.tunnelsMgr?.getOriginalDns(self.tunnel!.name) {
                self.tunnelViewModel?.interfaceData[.dns] = dns
                self.tunnelDnsCell.detailTextLabel?.text = dns
                self.saveUpdatedTunnel()
            }
            //runtimeConfig?
            self.tableView.reloadData()
        }))
        
        self.present(alert, animated: true, completion: nil)
    }
    
    @IBAction func editDnsSetting(_ sender: Any) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = NSTextAlignment.left
        
        // get current DNS
        let dnsholder = tunnelViewModel?.interfaceData[.dns]
        let addmsg = "\nThis will change the DNS address for the current profile."
        
        let alert = UIAlertController(title: NSLocalizedString("DNS Setting", comment: "DNS to use"), message: addmsg, preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel button"), style: .default, handler: nil))
        
        let messageText = NSMutableAttributedString(
            string: addmsg,
            attributes: [
                NSAttributedString.Key.paragraphStyle: paragraphStyle,
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13)
            ]
        )
            
        alert.setValue(messageText, forKey: "attributedMessage")
        alert.addAction(UIAlertAction(title: NSLocalizedString("Set DNS", comment: "Set DNS button"), style: .default, handler: {(action: UIAlertAction!) in
            let firstTextField = alert.textFields![0] as UITextField
            var dns = firstTextField.placeholder
            if ((firstTextField.text?.count)! > 1) {
                dns = firstTextField.text
            }
            
            if let dns = dns {
                self.tunnelViewModel?.interfaceData[.dns] = dns
                self.tunnelDnsCell.detailTextLabel?.text = dns
                self.saveUpdatedTunnel()
            }
            //runtimeConfig?
            self.tableView.reloadData()
        }))
        alert.addTextField(configurationHandler: {(textField: UITextField!) in
            textField.placeholder = dnsholder
            textField.isSecureTextEntry = false
        })
        
        self.present(alert, animated: true, completion: nil)
    }
    
    func saveUpdatedTunnel() {
        if let tunnelSaveResult = tunnelViewModel?.save() {
            switch tunnelSaveResult {
            case .error(let errorMessage):
                let alertTitle = (tunnelViewModel?.interfaceData.validatedConfiguration == nil || tunnelViewModel?.interfaceData.validatedName == nil) ?
                "Invalid interface" : "Invalid peer"
                ErrorPresenter.showErrorAlert(title: alertTitle, message: errorMessage, from: self)
                tableView.reloadData() // Highlight erroring fields
            case .saved(let tunnelConfiguration):
                if let onDemandOption = onDemandViewModel?.toOnDemandOption() {
                    // We're modifying an existing tunnel
                    WireGuardManager.shared().tunnelsManager?.modify(tunnel: tunnel!, tunnelConfiguration: tunnelConfiguration, onDemandOption: onDemandOption) { [weak self] error in
                        if let error = error {
                            ErrorPresenter.showErrorAlert(error: error, from: self)
                        }
                    }
                }
            }
        }
    }
    
    override open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if let original = self.tunnelsMgr?.getOriginalDns(self.tunnel!.name) {
            let current = self.tunnelViewModel!.interfaceData[.dns]
            if original == current {
                return 2
            }
        }
        
        return super.tableView(tableView, numberOfRowsInSection: section)
    }
}
