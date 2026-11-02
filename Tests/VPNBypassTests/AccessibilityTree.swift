// AccessibilityTree.swift
// SwiftUI draws its buttons itself, so a test finds them the way VoiceOver does: with an
// accessibility client switched on, and each getter sent by name, since SwiftUI's nodes answer
// them without declaring the protocol to Swift (as in UnknownVPNRenderTests).

import AppKit
import XCTest

@MainActor
enum AccessibilityTree {
    /// Every element under `root` (a window or a view), with an accessibility client switched on
    /// while the tree is read.
    static func elements(under root: NSObject, settle: () -> Void) -> [NSObject] {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasClient = (NSApplication.shared.accessibilityAttributeValue(attribute) as? Bool) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApplication.shared.accessibilitySetValue(wasClient, forAttribute: attribute) }
        settle()
        var found: [NSObject] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 80, let object = element as? NSObject else { return }
            found.append(object)
            (get("accessibilityChildren", of: object) as? [Any] ?? []).forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return found
    }

    static func get(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }

    static func label(_ object: NSObject) -> String? { nonEmpty(get("accessibilityLabel", of: object) as? String) }
    /// SwiftUI hands `accessibilityHint` to VoiceOver as the element's help.
    static func hint(_ object: NSObject) -> String? { nonEmpty(get("accessibilityHelp", of: object) as? String) }
    static func role(_ object: NSObject) -> String? { get("accessibilityRole", of: object) as? String }

    static func isSelected(_ object: NSObject) -> Bool {
        guard object.responds(to: NSSelectorFromString("isAccessibilitySelected")) else { return false }
        return (object.value(forKey: "accessibilitySelected") as? NSNumber)?.boolValue ?? false
    }

    /// The element's frame in screen coordinates.
    static func frame(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }

    /// Presses the element as VoiceOver's VO-Space does.
    static func press(_ object: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(object.responds(to: selector), "\(label(object) ?? "?") cannot be pressed")
        _ = object.perform(selector)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
