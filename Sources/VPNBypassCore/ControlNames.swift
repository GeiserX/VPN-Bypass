// ControlNames.swift
// The names VoiceOver reads for icon-only buttons, and the dropdown's keyboard shortcuts
// (proposal 9 of #119). Pure, so the wording and the keys are unit-tested.

import AppKit
import SwiftUI

/// The spoken name of an icon-only button that acts on one row: "Delete en.wikipedia.org".
/// A trash can or a pencil says nothing about which row it belongs to, and VoiceOver reads
/// the rows' buttons one after another.
enum ControlNames {
    static func delete(_ name: String) -> String { delete(name, in: .main) }

    /// An editor's blank line has no name yet, and "Delete " would read as a cut-off word.
    static func delete(_ name: String, in bundle: Bundle) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? String(localized: "Delete", bundle: bundle)
                            : String(localized: "Delete \(name)", bundle: bundle)
    }

    static func edit(_ name: String) -> String { edit(name, in: .main) }

    static func edit(_ name: String, in bundle: Bundle) -> String {
        String(localized: "Edit \(name)", bundle: bundle)
    }

    // The dropdown rows' actions (flow fix 5): the hover button's spoken name, the right-click
    // menu's item and the VoiceOver rotor's action are the same words.

    static func turnOff(_ name: String, in bundle: Bundle = .main) -> String {
        String(localized: "Turn Off \(name)", bundle: bundle)
    }

    static func retry(_ name: String, in bundle: Bundle = .main) -> String {
        String(localized: "Retry \(name)", bundle: bundle)
    }

    static func showInSettings(_ name: String, in bundle: Bundle = .main) -> String {
        String(localized: "Show \(name) in Settings", bundle: bundle)
    }

    static func copyAddresses(_ name: String, in bundle: Bundle = .main) -> String {
        String(localized: "Copy the Addresses of \(name)", bundle: bundle)
    }

    /// A tooltip with the control's shortcut after its name, as macOS writes it: "Settings (⌘,)".
    static func help(_ name: String, shortcut: String) -> String { "\(name) (\(shortcut))" }
}

/// The dropdown's keyboard shortcuts. Each one sits on a control that is always there (⌘N on
/// the add field, ⌘R on Refresh, ⌘, on the gear, ⌘P and ⌘Q on hidden buttons), because a SwiftUI `Menu` only answers its
/// items' keys while it is open; the "…" menu lists ⌘Q on its Quit item, the Pause menu ⌘P on For 1 Hour.
enum DropdownShortcut: CaseIterable {
    case addSite, refreshRoutes, settings, quit, pause

    var key: KeyEquivalent {
        switch self {
        case .addSite: return "n"
        case .refreshRoutes: return "r"
        case .settings: return ","
        case .quit: return "q"
        case .pause: return "p"
        }
    }

    var modifiers: EventModifiers { .command }

    /// The key as a menu writes it: ⌘N, ⌘R, ⌘, ⌘Q and ⌘P.
    var symbol: String { "⌘" + String(key.character).uppercased() }

    /// The menu item's title.
    var title: String { title(in: .main) }

    func title(in bundle: Bundle) -> String {
        switch self {
        case .addSite: return String(localized: "Add a Site", bundle: bundle)
        case .refreshRoutes: return String(localized: "Refresh Routes", bundle: bundle)
        case .settings: return String(localized: "Settings…", bundle: bundle)
        case .quit: return String(localized: "Quit VPN Bypass", bundle: bundle)
        // Pauses for an hour, or resumes when paused (`PauseShortcut`).
        case .pause: return String(localized: "Pause or Resume", bundle: bundle)
        }
    }

    /// The tooltip of the button that carries the shortcut: "Settings (⌘,)".
    func help(_ name: String) -> String { ControlNames.help(name, shortcut: symbol) }

    /// Whether the event is a held key's repeat. Only key events have `isARepeat`; reading it
    /// on a mouse click raises, so a click is never a repeat.
    static func isKeyRepeat(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.isARepeat
    }
}

extension View {
    func keyboardShortcut(_ shortcut: DropdownShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}

/// The dropdown footer's gear button: the icon, its name for VoiceOver, its shortcut, and the
/// shortcut in the tooltip.
struct DropdownIconButton: View {
    /// The footer icons' hit area, larger than the glyph so a click near it lands.
    static let hitSize: CGFloat = 24

    let systemImage: String
    let name: String
    let shortcut: DropdownShortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: Self.hitSize, height: Self.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help(shortcut.help(name))
        .accessibilityLabel(name)
    }
}
