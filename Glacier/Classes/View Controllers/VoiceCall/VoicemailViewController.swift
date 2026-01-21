//
//  VoicemailViewController.swift
//  Glacier
//
//  Created by andyfriedman on 3/3/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation
import MBProgressHUD

public protocol VMUpdateDelegate {
    func vmStatusUpdated(_ vmsid:String, status:String)
}

open class VoicemailViewController: UITableViewController, UITabBarDelegate {
    
    var vmRecords = [VoicemailRecord]()
    var myNumber: String?
    var spinnerHUD: MBProgressHUD?
    
    let dateFormatter = DateFormatter()
    let inputFormatter = DateFormatter()
    var emptySet = false
    
    /*public init() {
        super.init(nibName:nil, bundle:nil)
    }*/
    
    /*required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }*/
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        self.tableView = EmptyStateTableView(frame: .zero, style: .plain, centerOffset: CGPoint(x: 0.0, y: -64.0))
        self.tableView.register(VoicemailCell.self, forCellReuseIdentifier: VoicemailCell.reuseIdentifier)
        
        var titleColor = UIColor.label
        if let acctrec = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord {
            self.navigationItem.title = (acctrec.displayName ?? acctrec.phoneNumber)! + " Voicemail"
            self.myNumber = acctrec.phoneNumber
            if let colorstr = acctrec.color {
                titleColor = UIColor.UIColorFromString(string: colorstr)
            }
        }
        
        let appearance = UINavigationBarAppearance.init()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = GlobalTheme.shared.lightThemeColor
        appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
        self.navigationController?.navigationBar.standardAppearance = appearance
        self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
        self.navigationController?.navigationBar.tintColor = titleColor
        
        // Hide any default left bar button and add a custom button
        self.navigationItem.hidesBackButton = true
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )
        
        self.dateFormatter.dateFormat = "MM/dd/yyyy hh:mm a"
        self.inputFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        
        self.initData()
        
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.rowHeight = VoicemailCell.voicemailCellSize
    }
    
    override open func viewWillAppear(_ animated:Bool) {
        super.viewWillAppear(animated)
        self.vmRecords = TwilioBackendManager.sharedMgr().selectedRecordings
        self.tableView.reloadData()
        if let acctrec = TwilioBackendManager.sharedMgr().selectedAccount?.grdbRecord {
            let title = (acctrec.displayName ?? acctrec.phoneNumber)! + " Voicemail"
            self.myNumber = acctrec.phoneNumber
            if self.navigationItem.title != title {
                self.navigationItem.title = title
                if let colorstr = acctrec.color, let appearance = self.navigationController?.navigationBar.standardAppearance {
                    let titleColor = UIColor.UIColorFromString(string: colorstr)
                    appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor : titleColor]
                    self.navigationController?.navigationBar.standardAppearance = appearance
                    self.navigationController?.navigationBar.scrollEdgeAppearance = appearance
                    self.navigationController?.navigationBar.tintColor = titleColor
                }
            }
        }
    }
    
    func initData() {
        let tmgr = TwilioBackendManager.sharedMgr()
        //self.vmRecords = tmgr.selectedRecordings
        tmgr.queryForVMInfo()
        //if self.vmRecords.count == 0 {
        //    self.addSpinnerHUD("Retrieving voicemail (be patient)...")
        //}
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            //self.removeSpinnerHUD()
            self.vmRecords = tmgr.selectedRecordings
            self.tableView.reloadData()
        }
    }
    
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        
        if self.vmRecords.count == 0 && emptySet == false {
            DispatchQueue.main.async {
                self.emptySet = true
                if let emptyView = tableView as? EmptyStateTableView {
                    let img = UIImage.init(named: "glacier", in: GlacierInfo.resourcesBundle, with: nil)
                    let title = "No Voicemails"
                    let subtitle = "When you have voicemails for this number,\nyou'll see them here."
                    emptyView.setState(.noData(image: img, title: title, message: subtitle))
                    emptyView.separatorStyle = .none
                }
            }
        } else if self.vmRecords.count != 0 && emptySet == true {
            DispatchQueue.main.async {
                self.emptySet = false
                if let emptyView = tableView as? EmptyStateTableView {
                    emptyView.setState(.dataAvailable)
                    emptyView.separatorStyle = .singleLine
                }
            }
        }
        
        return self.vmRecords.count
    }
    
    override open func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return super.tableView(tableView, heightForHeaderInSection: section)
    }

    override open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: VoicemailCell.reuseIdentifier) as! VoicemailCell

        cell.contentView.setNeedsUpdateConstraints()
        
        //cell.accountLabel.text = self.callRecords[indexPath.row].contact.phoneNumber
        let rec = self.vmRecords[indexPath.row]
        let from = rec.contact?.name ?? rec.from
        cell.nameLabel.text = from
        if rec.status == "unread" || rec.status == "new" {
            cell.markUnread()
        } else {
            cell.markRead()
        }
        if var dateString = rec.time, let date = inputFormatter.date(from: dateString) {
            dateString = dateFormatter.string(from: date)
            cell.dateLabel.text = dateString
        }
        if let dur = rec.duration, let intdur = Int(dur) {
            cell.durationLabel.text = formatTime(seconds: intdur)
        }

        return cell
    }
    
    func formatTime(seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        
        // Format the minutes and seconds to always show two digits
        return String(format: "%01d:%02d", minutes, remainingSeconds)
    }

    override open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard self.vmRecords.count > 0 else { return }
        
        let rec = self.vmRecords[indexPath.row]
        let vmplayerVC = VMPlayerViewController.init()
        vmplayerVC.vmUpdateDelegate = self
        vmplayerVC.voicemailRec = rec
        
        if let dur = rec.duration, let intdur = Int(dur) {
            vmplayerVC.voicemailDuration = intdur
        }
        
        if var dateString = rec.time, let date = inputFormatter.date(from: dateString) {
            dateString = dateFormatter.string(from: date)
            vmplayerVC.voicemailTime = dateString
        }

        self.navigationController?.pushViewController(vmplayerVC, animated: true)
    }
    
    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }
}

extension VoicemailViewController: VMUpdateDelegate {
    public func vmStatusUpdated(_ vmsid:String, status:String) {
        var newRecords = [VoicemailRecord]()
        for vmrec in self.vmRecords {
            if vmsid != vmrec.recordingSid {
                newRecords.append(vmrec)
            }
        }
        TwilioBackendManager.sharedMgr().selectedRecordings = newRecords
        self.vmRecords = newRecords
        self.tableView.reloadData()
    }
}

extension VoicemailViewController {
    public func addSpinnerHUD(_ message:String) {
        DispatchQueue.main.async {
            if (self.spinnerHUD == nil) {
                self.spinnerHUD = MBProgressHUD.showAdded(to: self.view, animated: true)
                self.spinnerHUD?.label.text = message
            }
        }
    }
    
    func removeSpinnerHUD() {
        DispatchQueue.main.async {
            if let hud = self.spinnerHUD {
                hud.removeFromSuperview()
                self.spinnerHUD = nil
            }
        }
    }
}
