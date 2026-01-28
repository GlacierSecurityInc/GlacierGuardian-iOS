//
//  Date+Formatting.swift
//  Glacier
//
//  Created by Prem Pratap Singh on 25/09/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import Foundation

extension Date {
    
    /*
     Formats the date into string format like - "Wed 9:37 AM".
     */
    func formattedAsShortWeekdayTime(timeZone: TimeZone? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E h:mm a"
        formatter.timeZone = timeZone ?? TimeZone.current
        return formatter.string(from: self)
    }
}
