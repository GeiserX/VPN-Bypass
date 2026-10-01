// LogFilter.swift
// The level filter and search on Settings > Logs: which entries show, the count line above
// them, what an empty result says, where a search term is highlighted, and what Copy puts on
// the clipboard. Kept pure so the Logs page's wording and state are unit-tested.

import Foundation

/// The three choices of the Logs page's segmented control.
enum LogLevelFilter: String, CaseIterable, Identifiable {
    /// Every entry.
    case all
    /// Warnings and errors, so one click shows everything that needs a look.
    case warnings
    /// Errors only.
    case errors

    var id: String { rawValue }

    func admits(_ level: RouteManager.LogEntry.LogLevel) -> Bool {
        switch self {
        case .all: return true
        case .warnings: return level == .warning || level == .error
        case .errors: return level == .error
        }
    }

    /// The segment's label, in the app's language.
    var title: String { title(in: .main) }

    func title(in bundle: Bundle) -> String {
        switch self {
        case .all: return String(localized: "All", bundle: bundle)
        case .warnings: return String(localized: "Warnings", bundle: bundle)
        case .errors: return String(localized: "Errors", bundle: bundle)
        }
    }

    /// The control's name for VoiceOver; the label itself stays hidden.
    static var controlName: String { controlName(in: .main) }

    static func controlName(in bundle: Bundle) -> String {
        String(localized: "Log level", bundle: bundle)
    }

    /// The control's one tooltip. macOS shows a single tooltip for the whole segmented
    /// control, so it describes all three choices and says that Warnings includes errors.
    static var controlHelp: String { controlHelp(in: .main) }

    static func controlHelp(in bundle: Bundle) -> String {
        String(localized: "All: every entry. Warnings: warnings and errors. Errors: errors only.", bundle: bundle)
    }
}

/// What the Logs page shows: a level and a search term.
struct LogFilter: Equatable {
    var level: LogLevelFilter = .all
    var query: String = ""

    /// The search term without the spaces around it; empty means no search.
    var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when the filter hides anything at all.
    var isActive: Bool { level != .all || !term.isEmpty }

    func matches(_ entry: RouteManager.LogEntry) -> Bool {
        guard level.admits(entry.level) else { return false }
        return term.isEmpty || Self.ranges(of: term, in: entry.message).isEmpty == false
    }

    /// The entries that show, in the order given (the log keeps newest first).
    func apply(_ entries: [RouteManager.LogEntry]) -> [RouteManager.LogEntry] {
        isActive ? entries.filter(matches) : entries
    }

    /// The line above the list: "214 entries" with no filter, "3 of 214 entries" with one.
    func countLine(shown: Int, total: Int) -> String { countLine(shown: shown, total: total, in: .main) }

    func countLine(shown: Int, total: Int, in bundle: Bundle) -> String {
        if !isActive {
            return total == 1 ? String(localized: "1 entry", bundle: bundle)
                : String(localized: "\(total) entries", bundle: bundle)
        }
        return String(localized: "\(shown) of \(total) entries", bundle: bundle)
    }

    /// What the list says when the filter hides every entry. Nil while something shows, or
    /// when there is no filter (the page then shows its own "No activity yet").
    func emptyLine(shown: Int) -> String? { emptyLine(shown: shown, in: .main) }

    func emptyLine(shown: Int, in bundle: Bundle) -> String? {
        guard shown == 0, isActive else { return nil }
        if !term.isEmpty {
            switch level {
            case .all: return String(localized: "No entries match “\(term)”.", bundle: bundle)
            case .warnings: return String(localized: "No warnings or errors match “\(term)”.", bundle: bundle)
            case .errors: return String(localized: "No errors match “\(term)”.", bundle: bundle)
            }
        }
        switch level {
        case .all: return nil
        case .warnings: return String(localized: "No warnings or errors.", bundle: bundle)
        case .errors: return String(localized: "No errors.", bundle: bundle)
        }
    }

    /// Where `term` appears in `message`, ignoring case and accents, without overlaps.
    static func ranges(of term: String, in message: String) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = message.startIndex
        while from < message.endIndex,
              let r = message.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                    range: from..<message.endIndex) {
            found.append(r)
            from = r.upperBound
        }
        return found
    }

    /// What Copy puts on the clipboard: the entries that show, one line each, newest first.
    static func clipboardText(_ entries: [RouteManager.LogEntry], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { log in
            "[\(formatter.string(from: log.timestamp))] [\(log.level.rawValue)] \(log.message)"
        }.joined(separator: "\n")
    }
}
