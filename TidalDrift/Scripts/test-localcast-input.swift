#!/usr/bin/env swift

// Test LocalCast input injection locally
// Run with: swift Scripts/test-localcast-input.swift

import Foundation
import CoreGraphics
import ApplicationServices

print("🧪 LocalCast Input Test")
print("========================")
print("")

// Check Accessibility permission first
let hasAccessibility = AXIsProcessTrusted()
print("Accessibility Permission: \(hasAccessibility ? "✅ GRANTED" : "❌ DENIED")")

if !hasAccessibility {
    print("")
    print("⚠️  Accessibility permission is REQUIRED for input injection!")
    print("   Go to: System Settings > Privacy & Security > Accessibility")
    print("   Add Terminal (or the app running this script)")
    print("")
    
    // Prompt for permission
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    AXIsProcessTrustedWithOptions(options as CFDictionary)
    
    print("Waiting 5 seconds for you to grant permission...")
    Thread.sleep(forTimeInterval: 5)
    
    if !AXIsProcessTrusted() {
        print("❌ Still no permission. Exiting.")
        exit(1)
    }
}

print("")
print("Testing CGEvent creation and injection...")
print("")

// Get display info
let displayID = CGMainDisplayID()
let width = CGDisplayPixelsWide(displayID)
let height = CGDisplayPixelsHigh(displayID)
print("Display: \(width)x\(height)")

// Test 1: Create a mouse move event
print("")
print("Test 1: Creating mouse move event...")
let testPoint = CGPoint(x: 100, y: 100)
if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: testPoint, mouseButton: .left) {
    print("  ✅ Mouse move event CREATED successfully")
    moveEvent.post(tap: .cghidEventTap)
    print("  ✅ Mouse move event POSTED to cghidEventTap")
} else {
    print("  ❌ FAILED to create mouse move event!")
}

Thread.sleep(forTimeInterval: 0.5)

// Test 2: Create a mouse click
print("")
print("Test 2: Creating mouse click at center of screen...")
let centerPoint = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)

if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: centerPoint, mouseButton: .left) {
    print("  ✅ Mouse DOWN event CREATED at (\(Int(centerPoint.x)), \(Int(centerPoint.y)))")
    downEvent.post(tap: .cghidEventTap)
    print("  ✅ Mouse DOWN event POSTED")
} else {
    print("  ❌ FAILED to create mouse DOWN event!")
}

Thread.sleep(forTimeInterval: 0.1)

if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: centerPoint, mouseButton: .left) {
    print("  ✅ Mouse UP event CREATED")
    upEvent.post(tap: .cghidEventTap)
    print("  ✅ Mouse UP event POSTED")
} else {
    print("  ❌ FAILED to create mouse UP event!")
}

// Test 3: Create a key press (letter 'a' = keycode 0)
print("")
print("Test 3: Creating key press (letter 'a')...")
print("  ⚠️  This will type 'a' in the focused app!")
Thread.sleep(forTimeInterval: 1)

if let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
    print("  ✅ Key DOWN event CREATED (keyCode=0, 'a')")
    keyDownEvent.post(tap: .cghidEventTap)
    print("  ✅ Key DOWN event POSTED")
} else {
    print("  ❌ FAILED to create key DOWN event!")
}

Thread.sleep(forTimeInterval: 0.05)

if let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
    print("  ✅ Key UP event CREATED")
    keyUpEvent.post(tap: .cghidEventTap)
    print("  ✅ Key UP event POSTED")
} else {
    print("  ❌ FAILED to create key UP event!")
}

print("")
print("========================")
print("Test complete!")
print("")
print("If you saw the mouse move to (100,100) then center,")
print("and an 'a' was typed, input injection is WORKING.")
print("")
print("If nothing happened but events were 'POSTED',")
print("there may be a system-level block on the events.")


