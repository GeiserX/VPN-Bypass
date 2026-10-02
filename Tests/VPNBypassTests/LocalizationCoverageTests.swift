// LocalizationCoverageTests.swift
// Strings that shipped in 5.0.0 with no Spanish or French entry, so a Mac set to either
// language showed them in English. scripts/check-localizations.py checks every key in Sources/;
// these tests pin the ones a user meets when something is wrong, and the specifier order of the
// sentences built from parts.

import XCTest
@testable import VPNBypassCore

final class LocalizationCoverageTests: XCTestCase {

    /// A language folder from the source tree; a test run has no app bundle to take it from.
    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    private func text(_ key: String, _ bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private let helperRepair = [
        "The privileged helper is not running — no routes are being enforced. Open Settings → Status to repair it.",
        "Can't refresh: the privileged helper is not running. Open Settings → Status to repair it.",
    ]

    func testTheHelperRepairNotificationsAreTranslated() throws {
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for key in helperRepair + ["Helper not running — nothing is being routed", "Fix…",
                                       "The privileged helper isn't ready, so no routes could be applied."] {
                XCTAssertNotEqual(text(key, bundle), key, "\(language) leaves \"\(key)\" in English")
            }
        }
    }

    /// The notification sends the user to a page by name, so it has to use the names the
    /// translated Settings window shows.
    func testTheRepairNotificationsNameThePagesAsSettingsShowsThem() throws {
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            let path = "\(text("Settings", bundle)) → \(text("Status", bundle))"
            for key in helperRepair {
                XCTAssertTrue(text(key, bundle).contains(path), "\(language): \"\(text(key, bundle))\" does not say \(path)")
            }
        }
        XCTAssertTrue(text(helperRepair[0], try lproj("es")).contains("Ajustes → Estado"))
        XCTAssertTrue(text(helperRepair[0], try lproj("fr")).contains("Réglages → État"))
    }

    func testTheRoutesAndRulesPagesAreTranslated() throws {
        // Form labels and the name hint went through a String, which nothing looked up; they are now keys.
        let keys = ["System Routes", "Your physical connection", "Upstream Host", "Upstream Port", "Proxy port on peer",
                    "e.g. Residential Proxy", "e.g. Work VPN",
                    "Tailscale Peer", "Routing Rules", "Match", "Pattern", "Edit Rule", "No rules yet",
                    "Primary VPN (automatic)"]
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for key in keys {
                XCTAssertNotEqual(text(key, bundle), key, "\(language) leaves \"\(key)\" in English")
            }
        }
    }

    /// Settings > Status shows the helper install error, and the route and rule editors show their
    /// validation error, through a String; String(localized:) is what makes them keys.
    func testTheHelperInstallAndEditorErrorsAreTranslated() throws {
        let keys = ["Not running from app bundle", "Helper binary not found in app bundle",
                    "Helper plist not found in app bundle", "Failed to create AppleScript",
                    "Name is required.", "Select a Tailscale peer (or enter its 100.x IP).", "Upstream host is required.",
                    "Port must be a number between 1 and 65535.", "Select a service.", "Pattern is required.",
                    "Enter a valid IPv4 address (e.g. 10.0.0.5).", "Enter a valid IPv4 CIDR range (e.g. 10.0.0.0/8).",
                    "Select a route."]
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for key in keys {
                XCTAssertNotEqual(text(key, bundle), key, "\(language) leaves \"\(key)\" in English")
            }
        }
        XCTAssertEqual(text("Direct", try lproj("es")), "Directo")
    }

    /// The route row's type badge and status, the rule row's match badge and the rule's route
    /// chip went through a String, which Text shows as it is, so 5.0.1 drew the rule badges and
    /// "Choose Route" in English.
    @MainActor
    func testTheRouteAndRuleBadgesAreTranslated() throws {
        let es = try lproj("es"), fr = try lproj("fr")
        let direct = Route(name: "Direct", egress: .direct)
        let primaryVPN = Route(name: "VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))

        XCTAssertEqual(RouteRow.typeLabel(.direct, in: es), "Directo")
        XCTAssertEqual(RouteRow.typeLabel(.proxySOCKS5, in: fr), "SOCKS5")
        XCTAssertEqual(RouteRow.nonListenerStatusLabel(direct, in: es), "directo")
        XCTAssertEqual(RouteRow.nonListenerStatusLabel(primaryVPN, in: es), "VPN principal")
        XCTAssertEqual(RouteRow.nonListenerStatusLabel(primaryVPN, in: fr), "VPN principal")
        XCTAssertNotEqual(RouteRow.nonListenerStatusLabel(direct, in: fr), "direct")

        XCTAssertEqual(RuleRow.matchLabel(.domain, in: es), "DOMINIO")
        XCTAssertEqual(RuleRow.matchLabel(.service, in: es), "SERVICIO")
        XCTAssertEqual(RuleRow.matchLabel(.domain, in: fr), "DOMAINE")
        XCTAssertEqual(RuleRow.matchLabel(.suffix, in: fr), "SUFFIXE")
        XCTAssertEqual(RuleRow.matchLabel(.process, in: fr), "PROCESSUS")
        XCTAssertEqual(RuleRow.matchLabel(.cidr, in: es), "CIDR")

        XCTAssertEqual(RouteChip.displayName(nil, vpnName: nil, in: es), "Elegir ruta")
        XCTAssertEqual(RouteChip.displayName(nil, vpnName: nil, in: fr), "Choisir une route")
        XCTAssertEqual(RouteChip.displayName(direct, vpnName: nil, in: es), "Directo")
    }

    /// `.unknown`'s raw value is the English placeholder "Unknown VPN"; the Routes page, the
    /// rule chips and the dropdown show their own localized "VPN" in its place.
    func testAnUnknownVPNHasNoNameToShow() {
        XCTAssertNil(VPNType.unknown.knownName)
        XCTAssertEqual(VPNType.wireGuard.knownName, "WireGuard")
        XCTAssertEqual(Route(name: "", egress: .vpnDefault).friendlyName(vpnName: VPNType.unknown.knownName), "VPN")
    }

    /// The Remove All Routes question is built from parts; the translation must put each part in its place.
    func testTheRemoveAllQuestionKeepsItsPartsInOrder() throws {
        let es = try lproj("es"), fr = try lproj("fr")
        let whatES = String(format: text("Your %@ and %@", es), "2 servicios", "1 dominio")
        XCTAssertEqual(String(format: text("%@ will go through the VPN %@.", es), whatES, text("until you refresh routes", es)),
                       "Lo que tienes en la lista (2 servicios y 1 dominio) pasará por la VPN hasta que actualices las rutas.")
        let whatFR = String(format: text("Your %@", fr), "2 services")
        XCTAssertEqual(String(format: text("%@ will go through the VPN %@.", fr), whatFR, text("until you refresh routes", fr)),
                       "Ce que vous avez listé (2 services) passera par le VPN jusqu'à ce que vous actualisiez les routes.")
        XCTAssertEqual(String(format: text("%lld/%lld active", es), 1, 3), "1/3 activas")
        XCTAssertEqual(String(format: text("%@ · %@ — not connected", fr), "Cisco", "utun4"), "Cisco · utun4 — non connecté")
    }
}
