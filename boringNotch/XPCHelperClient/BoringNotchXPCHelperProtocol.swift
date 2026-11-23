//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // CodexBar integration (the helper is unsandboxed, so it can read CodexBar's
    // shared widget snapshot and run the `codexbar` CLI on behalf of the app)
    func codexBarSnapshot(with reply: @escaping (Data?) -> Void)
    func codexBarUsage(_ provider: String, with reply: @escaping (Data?) -> Void)
    func codexBarCost(_ provider: String, with reply: @escaping (Data?) -> Void)
    func codexBarConfig(with reply: @escaping (Data?) -> Void)
    func codexBarAccounts(with reply: @escaping (Data?) -> Void)
    func codexBarIcon(_ provider: String, with reply: @escaping (Data?) -> Void)
}

