//
//  UserReactionDetailsViewController.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 28/10/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit

/**
 This is data object for containing user name, avatar image and list of reaction emojis
 */
struct UserReactionDetails: Identifiable {
    let id: String = UUID().uuidString
    let isSelf: Bool
    let displayName: String
    let avatarImage: Data?
    var reactions: [String]
}

/**
 It informs the parent view about user interactions with the reaction emojis
 */
protocol UserReactionDetailsViewDelegate {
    func didTapOn(reaction: String, completion: @escaping () -> Void)
}

/**
 This view presents the list of user reaction details (avtar image, name, reaction emojis, etc)
 */
final class UserReactionDetailsViewController: UIViewController {
    
    // MARK: - Private properties
    
    private var reactionDetails: [UserReactionDetails] = []
    private var delegate: UserReactionDetailsViewDelegate?
    
    // MARK: - UI controls
    
    private lazy var reactionDetailsTableView: UITableView = {
        let tableView = UITableView()
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.separatorStyle = .none
        tableView.rowHeight = 50
        tableView.estimatedRowHeight = UITableView.automaticDimension
        tableView.register(UserReactionDetailsTableViewCell.self, forCellReuseIdentifier: UserReactionDetailsTableViewCell.identifier)
        tableView.dataSource = self
        return tableView
    }()
    
    // MARK: - Initializer
    
    convenience init(reactionDetails: [UserReactionDetails], delegate: UserReactionDetailsViewDelegate?) {
        self.init()
        self.reactionDetails = reactionDetails.sorted { $0.displayName < $1.displayName }
        self.delegate = delegate
    }
    
    // MARK: - Lifecycle methods
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.configureView()
    }
    
    // MARK: - Private methods
    
    private func configureView() {
        self.view.backgroundColor = .systemBackground
        
        self.view.addSubview(self.reactionDetailsTableView)
        NSLayoutConstraint.activate([
            self.reactionDetailsTableView.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 24),
            self.reactionDetailsTableView.leftAnchor.constraint(equalTo: self.view.leftAnchor, constant: 16),
            self.reactionDetailsTableView.rightAnchor.constraint(equalTo: self.view.rightAnchor, constant: -16),
            self.reactionDetailsTableView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: 24)
        ])
    }
}


// MARK: - Table view data source methods

extension UserReactionDetailsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.reactionDetails.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard !self.reactionDetails.isEmpty,
              let cell = tableView.dequeueReusableCell(
                withIdentifier: UserReactionDetailsTableViewCell.identifier,
                for: indexPath) as? UserReactionDetailsTableViewCell else {
            return UserReactionDetailsTableViewCell()
        }
        cell.reactionDetails = self.reactionDetails[indexPath.row]
        cell.delegate = self.delegate
        cell.cellDelegate = self
        return cell
    }
}

// MARK: - User reaction table view cell delegate methods

extension UserReactionDetailsViewController: UserReactionDetailsTableViewCellDelegate {
    func didRemoveAllReactions(for id: String) {
        guard let index = self.reactionDetails.firstIndex(where: { $0.id == id }) else { return }
        self.reactionDetails.remove(at: index)
        self.reactionDetailsTableView.beginUpdates()
        self.reactionDetailsTableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .fade)
        self.reactionDetailsTableView.endUpdates()
    }
}
