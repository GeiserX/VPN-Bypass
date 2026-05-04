// NotificationPreferencesTests.swift
// Unit tests for NotificationManager.Preferences Codable conformance and LogEntry.LogLevel enum.

import XCTest
@testable import VPNBypassCore

// MARK: - NotificationManager.Preferences Codable Tests

/// Tests encoding, decoding, backward compatibility, and error handling for the Preferences struct.
final class NotificationPreferencesTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Round-trip: All True

    func testRoundTripAllTrue() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: true,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: true,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.notificationsEnabled, true)
        XCTAssertEqual(decoded.silentNotifications, true)
        XCTAssertEqual(decoded.notifyOnVPNConnect, true)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, true)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, true)
        XCTAssertEqual(decoded.notifyOnRouteFailure, true)
    }

    // MARK: - Round-trip: All False

    func testRoundTripAllFalse() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: false,
            silentNotifications: false,
            notifyOnVPNConnect: false,
            notifyOnVPNDisconnect: false,
            notifyOnRoutesApplied: false,
            notifyOnRouteFailure: false
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.notificationsEnabled, false)
        XCTAssertEqual(decoded.silentNotifications, false)
        XCTAssertEqual(decoded.notifyOnVPNConnect, false)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, false)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, false)
        XCTAssertEqual(decoded.notifyOnRouteFailure, false)
    }

    // MARK: - Round-trip: Mixed Values

    func testRoundTripMixedValues() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: false,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: false,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: false
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.notificationsEnabled, true)
        XCTAssertEqual(decoded.silentNotifications, false)
        XCTAssertEqual(decoded.notifyOnVPNConnect, true)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, false)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, true)
        XCTAssertEqual(decoded.notifyOnRouteFailure, false)
    }

    func testRoundTripAlternateMixedValues() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: false,
            silentNotifications: true,
            notifyOnVPNConnect: false,
            notifyOnVPNDisconnect: true,
            notifyOnRoutesApplied: false,
            notifyOnRouteFailure: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.notificationsEnabled, false)
        XCTAssertEqual(decoded.silentNotifications, true)
        XCTAssertEqual(decoded.notifyOnVPNConnect, false)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, true)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, false)
        XCTAssertEqual(decoded.notifyOnRouteFailure, true)
    }

    func testRoundTripOnlySilentNotificationsTrue() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: false,
            silentNotifications: true,
            notifyOnVPNConnect: false,
            notifyOnVPNDisconnect: false,
            notifyOnRoutesApplied: false,
            notifyOnRouteFailure: false
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.silentNotifications, true)
        XCTAssertEqual(decoded.notificationsEnabled, false)
    }

    // MARK: - Backward Compatibility: Missing silentNotifications

    func testDecodeMissingSilentNotificationsDefaultsToFalse() throws {
        let json: [String: Any] = [
            "notificationsEnabled": true,
            "notifyOnVPNConnect": true,
            "notifyOnVPNDisconnect": true,
            "notifyOnRoutesApplied": false,
            "notifyOnRouteFailure": true
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.silentNotifications, false, "Missing silentNotifications should default to false")
        XCTAssertEqual(decoded.notificationsEnabled, true)
        XCTAssertEqual(decoded.notifyOnVPNConnect, true)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, true)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, false)
        XCTAssertEqual(decoded.notifyOnRouteFailure, true)
    }

    func testDecodeMissingSilentNotificationsAllFieldsFalse() throws {
        let json: [String: Any] = [
            "notificationsEnabled": false,
            "notifyOnVPNConnect": false,
            "notifyOnVPNDisconnect": false,
            "notifyOnRoutesApplied": false,
            "notifyOnRouteFailure": false
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.silentNotifications, false)
    }

    // MARK: - Default Values (App Defaults)

    func testAppDefaultValues() throws {
        let defaults = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: false,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: true,
            notifyOnRoutesApplied: false,
            notifyOnRouteFailure: true
        )
        let data = try encoder.encode(defaults)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.notificationsEnabled, true)
        XCTAssertEqual(decoded.silentNotifications, false)
        XCTAssertEqual(decoded.notifyOnVPNConnect, true)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, true)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, false)
        XCTAssertEqual(decoded.notifyOnRouteFailure, true)
    }

    // MARK: - JSON Structure Verification

    func testEncodedJSONContainsAllKeys() throws {
        let prefs = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: true,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: true,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: true
        )
        let data = try encoder.encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["notificationsEnabled"])
        XCTAssertNotNil(json["silentNotifications"])
        XCTAssertNotNil(json["notifyOnVPNConnect"])
        XCTAssertNotNil(json["notifyOnVPNDisconnect"])
        XCTAssertNotNil(json["notifyOnRoutesApplied"])
        XCTAssertNotNil(json["notifyOnRouteFailure"])
        XCTAssertEqual(json.count, 6, "Encoded JSON should have exactly 6 keys")
    }

    func testEncodedJSONValueTypes() throws {
        let prefs = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: false,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: false,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: false
        )
        let data = try encoder.encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["notificationsEnabled"] as? Bool, true)
        XCTAssertEqual(json["silentNotifications"] as? Bool, false)
        XCTAssertEqual(json["notifyOnVPNConnect"] as? Bool, true)
        XCTAssertEqual(json["notifyOnVPNDisconnect"] as? Bool, false)
        XCTAssertEqual(json["notifyOnRoutesApplied"] as? Bool, true)
        XCTAssertEqual(json["notifyOnRouteFailure"] as? Bool, false)
    }

    // MARK: - Missing Required Fields (Should Throw)

    func testDecodeMissingNotificationsEnabledThrows() {
        let json: [String: Any] = [
            "silentNotifications": false,
            "notifyOnVPNConnect": true,
            "notifyOnVPNDisconnect": true,
            "notifyOnRoutesApplied": false,
            "notifyOnRouteFailure": true
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try decoder.decode(NotificationManager.Preferences.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected keyNotFound for notificationsEnabled, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "notificationsEnabled")
        }
    }

    func testDecodeMissingNotifyOnVPNConnectThrows() {
        let json: [String: Any] = [
            "notificationsEnabled": true,
            "silentNotifications": false,
            "notifyOnVPNDisconnect": true,
            "notifyOnRoutesApplied": false,
            "notifyOnRouteFailure": true
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try decoder.decode(NotificationManager.Preferences.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected keyNotFound for notifyOnVPNConnect, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "notifyOnVPNConnect")
        }
    }

    func testDecodeMissingNotifyOnVPNDisconnectThrows() {
        let json: [String: Any] = [
            "notificationsEnabled": true,
            "silentNotifications": false,
            "notifyOnVPNConnect": true,
            "notifyOnRoutesApplied": false,
            "notifyOnRouteFailure": true
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try decoder.decode(NotificationManager.Preferences.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected keyNotFound for notifyOnVPNDisconnect, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "notifyOnVPNDisconnect")
        }
    }

    func testDecodeMissingNotifyOnRoutesAppliedThrows() {
        let json: [String: Any] = [
            "notificationsEnabled": true,
            "silentNotifications": false,
            "notifyOnVPNConnect": true,
            "notifyOnVPNDisconnect": true,
            "notifyOnRouteFailure": true
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try decoder.decode(NotificationManager.Preferences.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected keyNotFound for notifyOnRoutesApplied, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "notifyOnRoutesApplied")
        }
    }

    func testDecodeMissingNotifyOnRouteFailureThrows() {
        let json: [String: Any] = [
            "notificationsEnabled": true,
            "silentNotifications": false,
            "notifyOnVPNConnect": true,
            "notifyOnVPNDisconnect": true,
            "notifyOnRoutesApplied": false
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try decoder.decode(NotificationManager.Preferences.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected keyNotFound for notifyOnRouteFailure, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "notifyOnRouteFailure")
        }
    }

    func testDecodeEmptyJSONThrows() {
        let json: [String: Any] = [:]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try decoder.decode(NotificationManager.Preferences.self, from: data))
    }

    // MARK: - Extra Fields Ignored

    func testDecodeWithExtraFieldsSucceeds() throws {
        let json: [String: Any] = [
            "notificationsEnabled": true,
            "silentNotifications": true,
            "notifyOnVPNConnect": false,
            "notifyOnVPNDisconnect": true,
            "notifyOnRoutesApplied": false,
            "notifyOnRouteFailure": true,
            "futureField": "should be ignored",
            "anotherNewField": 42
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.notificationsEnabled, true)
        XCTAssertEqual(decoded.silentNotifications, true)
        XCTAssertEqual(decoded.notifyOnVPNConnect, false)
        XCTAssertEqual(decoded.notifyOnVPNDisconnect, true)
        XCTAssertEqual(decoded.notifyOnRoutesApplied, false)
        XCTAssertEqual(decoded.notifyOnRouteFailure, true)
    }

    // MARK: - Silent Notifications Preserved

    func testSilentNotificationsTruePreservedThroughRoundTrip() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: true,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: true,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.silentNotifications, true, "silentNotifications=true must survive round-trip")
    }

    func testSilentNotificationsFalsePreservedThroughRoundTrip() throws {
        let original = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: false,
            notifyOnVPNConnect: true,
            notifyOnVPNDisconnect: true,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(NotificationManager.Preferences.self, from: data)
        XCTAssertEqual(decoded.silentNotifications, false, "silentNotifications=false must survive round-trip")
    }

    // MARK: - Memberwise Init Values

    func testMemberwiseInitSetsAllFields() {
        let prefs = NotificationManager.Preferences(
            notificationsEnabled: true,
            silentNotifications: true,
            notifyOnVPNConnect: false,
            notifyOnVPNDisconnect: false,
            notifyOnRoutesApplied: true,
            notifyOnRouteFailure: false
        )
        XCTAssertEqual(prefs.notificationsEnabled, true)
        XCTAssertEqual(prefs.silentNotifications, true)
        XCTAssertEqual(prefs.notifyOnVPNConnect, false)
        XCTAssertEqual(prefs.notifyOnVPNDisconnect, false)
        XCTAssertEqual(prefs.notifyOnRoutesApplied, true)
        XCTAssertEqual(prefs.notifyOnRouteFailure, false)
    }
}

// MARK: - LogEntry.LogLevel Tests

/// Tests for the RouteManager.LogEntry.LogLevel raw-value enum.
final class LogLevelTests: XCTestCase {

    // MARK: - Raw Values

    func testInfoRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.info.rawValue, "INFO")
    }

    func testSuccessRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.success.rawValue, "SUCCESS")
    }

    func testWarningRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.warning.rawValue, "WARNING")
    }

    func testErrorRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.error.rawValue, "ERROR")
    }

    // MARK: - Init from rawValue

    func testInitFromValidRawValues() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "INFO"), .info)
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "SUCCESS"), .success)
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "WARNING"), .warning)
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "ERROR"), .error)
    }

    func testInitFromInvalidRawValueReturnsNil() {
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: "TRACE"))
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: "DEBUG"))
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: "FATAL"))
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: ""))
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: "info"))
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: "Info"))
    }
}
