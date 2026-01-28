//  Glacier
//  Created by Prem Pratap Singh on 12/11/25.
//  Copyright © 2025 Glacier. All rights reserved.

import Foundation

extension String {
    
    /**
     Returns initials for strings like user display name. Ex: returns MJ for Micheal Jackson, J for John, etc.
     */
    func getInitials() -> String {
        let nameParts = self.split(separator: " ")
        guard nameParts.count > 1 else {
            return String(nameParts.first?.prefix(1) ?? "").uppercased()
        }
        
        let firstInitial = String(nameParts[0].prefix(1)).uppercased()
        let secondInitial = String(nameParts[1].prefix(1)).uppercased()
        return firstInitial + secondInitial
    }
}
