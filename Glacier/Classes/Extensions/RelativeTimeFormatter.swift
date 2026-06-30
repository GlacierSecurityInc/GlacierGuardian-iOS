//
//  RelativeTimeFormatter.swift
//  Glacier
//
//  Created by Codex on 2026-02-04.
//

import Foundation

enum RelativeTimeFormatter {
    private static let pastFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
    
    private static let abbreviatedPastFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func pastString(since date: Date, relativeTo reference: Date = Date()) -> String {
        return pastFormatter.localizedString(for: date, relativeTo: reference)
    }
    
    static func abbreviatedPastString(since date: Date, relativeTo reference: Date = Date()) -> String {
        let interval = date.timeIntervalSince(reference)
        if abs(interval) < 60 {
            return "just now"
        }
        return abbreviatedPastFormatter.localizedString(for: date, relativeTo: reference)
    }

    static func timeLeftString(from interval: TimeInterval) -> String? {
        let seconds = Int(interval.rounded(.down))
        guard seconds > 0 else { return nil }

        if seconds < 60 {
            return "\(seconds) s left"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min left"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hrs left"
        }

        let days = hours / 24
        if days < 7 {
            return "\(days) d left"
        }

        let weeks = days / 7
        return "\(weeks) wks left"
    }
}
