import AppKit
import ApplicationServices
import Foundation

/// A small, testable handle around an AX element.  Tests can construct a
/// handle with an arbitrary stable identifier without needing Accessibility
/// permissions or a running target application.
class InlineAXElementHandle: Equatable {
    let identifier: String
    let rawElement: AXUIElement?

    init(identifier: String) {
        self.identifier = identifier
        self.rawElement = nil
    }

    init(rawElement: AXUIElement) {
        self.rawElement = rawElement
        self.identifier = String(describing: ObjectIdentifier(rawElement as AnyObject))
    }

    static func == (lhs: InlineAXElementHandle, rhs: InlineAXElementHandle) -> Bool {
        lhs.identifier == rhs.identifier
    }
}

struct InlineAccessibilityTarget: Equatable {
    let processID: pid_t
    let bundleIdentifier: String?
    let role: String?
    let subrole: String?
    let element: InlineAXElementHandle

    var isSecureTextField: Bool {
        let value = self.subrole ?? ""
        return value == (kAXSecureTextFieldSubrole as String)
            || value.localizedCaseInsensitiveContains("secure")
    }
}

/// Abstracts the AX calls so all coordinator state transitions can be tested
/// with a deterministic fake adapter.
protocol InlineAccessibilityAdapter: AnyObject {
    func focusedTarget() -> InlineAccessibilityTarget?
    func supportsInlineEditing(_ target: InlineAccessibilityTarget) -> Bool
    func isFocused(_ target: InlineAccessibilityTarget) -> Bool
    func value(of target: InlineAccessibilityTarget) -> String?
    func selectedRange(of target: InlineAccessibilityTarget) -> CFRange?
    func setValue(_ value: String, on target: InlineAccessibilityTarget) -> Bool
    func setSelectedRange(_ range: CFRange, on target: InlineAccessibilityTarget) -> Bool
    func restoreFocus(to target: InlineAccessibilityTarget) -> Bool
}

enum InlineBeginRejection: Equatable {
    case alreadyActive
    case noFocusedTarget
    case secureTextField
    case terminal
    case unsupportedTarget
    case invalidSelection
}

enum InlineBeginResult: Equatable {
    case started(sessionID: UUID)
    case rejected(InlineBeginRejection)
}

enum InlineInterruptionReason: Equatable {
    case sessionChanged
    case focusChanged
    case valueChanged
    case caretChanged
    case writeFailed
    case invalidFinalRange
}

enum InlineApplyResult: Equatable {
    case applied(provisionalText: String)
    case ignoredStale
    case frozen
    case notActive
    case interrupted(InlineInterruptionReason)
}

enum InlineFinishResult: Equatable {
    case finished(finalText: String)
    case notActive
    case interrupted(InlineInterruptionReason, finalText: String)
}

enum InlineCancelResult: Equatable {
    case restored
    case notActive
    case interrupted(InlineInterruptionReason)
}

/// Owns one inline dictation session.
///
/// The coordinator deliberately performs no keyboard-event or clipboard
/// fallback.  Once an AX mutation has started, an unsafe state transition
/// stops further mutation; the caller can then copy the final transcription.
@MainActor
final class InlineDictationCoordinator {
    nonisolated static let defaultFreezeAfter: TimeInterval = 12
    nonisolated static let defaultSampleRate = 16_000

    private let adapter: InlineAccessibilityAdapter
    private let freezeAfter: TimeInterval
    private let sampleRate: Int

    private struct Session {
        let id: UUID
        let target: InlineAccessibilityTarget
        let originalValue: String
        let originalSelection: CFRange
        var expectedValue: String
        var expectedSelection: CFRange
        var provisionalRange: CFRange
        var lastSequence: Int?
        var lastSampleCount: Int
        var frozen = false
    }

    private var session: Session?

    init(
        adapter: InlineAccessibilityAdapter,
        freezeAfter: TimeInterval = InlineDictationCoordinator.defaultFreezeAfter,
        sampleRate: Int = InlineDictationCoordinator.defaultSampleRate
    ) {
        self.adapter = adapter
        self.freezeAfter = max(0, freezeAfter)
        self.sampleRate = max(1, sampleRate)
    }

    var activeSessionID: UUID? {
        self.session?.id
    }

    var isActive: Bool {
        self.session != nil
    }

    var isFrozen: Bool {
        self.session?.frozen ?? false
    }

    func begin(sessionID: UUID = UUID()) -> InlineBeginResult {
        guard self.session == nil else {
            // A second begin is never allowed to replace a live target
            // snapshot. The existing session remains the only active one.
            return .rejected(.alreadyActive)
        }
        guard let target = self.adapter.focusedTarget() else {
            return .rejected(.noFocusedTarget)
        }
        if target.isSecureTextField {
            return .rejected(.secureTextField)
        }
        if Self.terminalBundleIdentifiers.contains(target.bundleIdentifier?.lowercased() ?? "") {
            return .rejected(.terminal)
        }
        guard Self.supportedBundleIdentifiers.contains(target.bundleIdentifier?.lowercased() ?? "") else {
            return .rejected(.unsupportedTarget)
        }
        guard self.adapter.supportsInlineEditing(target) else {
            return .rejected(.unsupportedTarget)
        }
        guard let value = self.adapter.value(of: target),
              let selection = self.adapter.selectedRange(of: target),
              Self.isValid(selection, in: value)
        else {
            return .rejected(.invalidSelection)
        }
        guard self.adapter.isFocused(target) else {
            return .rejected(.noFocusedTarget)
        }

        self.session = Session(
            id: sessionID,
            target: target,
            originalValue: value,
            originalSelection: selection,
            expectedValue: value,
            expectedSelection: selection,
            provisionalRange: selection,
            lastSequence: nil,
            lastSampleCount: 0
        )
        return .started(sessionID: sessionID)
    }

    func apply(_ update: ASRPartialUpdate) -> InlineApplyResult {
        guard var current = self.session else { return .notActive }
        guard update.sessionID == current.id else { return .ignoredStale }
        if let lastSequence = current.lastSequence, update.sequence <= lastSequence {
            return .ignoredStale
        }
        guard update.sampleCount >= current.lastSampleCount else {
            return .ignoredStale
        }
        guard !current.frozen else { return .frozen }

        if let reason = self.revalidate(current) {
            self.session = nil
            return .interrupted(reason)
        }

        if let scopeLimit = update.scope.maxSeconds,
           self.hasReachedFreeze(sampleCount: update.sampleCount, scopeLimit: scopeLimit)
        {
            current.frozen = true
            current.lastSequence = update.sequence
            current.lastSampleCount = update.sampleCount
            self.session = current
            return .frozen
        }

        guard let replacement = Self.replacing(
            in: current.expectedValue,
            range: current.provisionalRange,
            with: update.text
        ) else {
            self.session = nil
            return .interrupted(.invalidFinalRange)
        }

        let nextSelection = CFRange(
            location: current.provisionalRange.location + (update.text as NSString).length,
            length: 0
        )
        guard self.write(replacement, selection: nextSelection, to: current.target, restoring: current) else {
            self.session = nil
            return .interrupted(.writeFailed)
        }

        current.expectedValue = replacement
        current.expectedSelection = nextSelection
        current.provisionalRange = CFRange(
            location: current.provisionalRange.location,
            length: (update.text as NSString).length
        )
        current.lastSequence = update.sequence
        current.lastSampleCount = update.sampleCount
        self.session = current
        return .applied(provisionalText: update.text)
    }

    func finish(finalText: String) -> InlineFinishResult {
        guard let current = self.session else { return .notActive }
        guard let reason = self.revalidate(current) else {
            guard let replacement = Self.replacing(
                in: current.expectedValue,
                range: current.provisionalRange,
                with: finalText
            ) else {
                self.session = nil
                return .interrupted(.invalidFinalRange, finalText: finalText)
            }
            let nextSelection = CFRange(
                location: current.provisionalRange.location + (finalText as NSString).length,
                length: 0
            )
            guard self.write(replacement, selection: nextSelection, to: current.target, restoring: current) else {
                self.session = nil
                return .interrupted(.writeFailed, finalText: finalText)
            }
            self.session = nil
            return .finished(finalText: finalText)
        }
        self.session = nil
        return .interrupted(reason, finalText: finalText)
    }

    func cancel() -> InlineCancelResult {
        guard let current = self.session else { return .notActive }
        guard let reason = self.revalidate(current) else {
            guard self.write(
                current.originalValue,
                selection: current.originalSelection,
                to: current.target,
                restoring: current
            ) else {
                self.session = nil
                return .interrupted(.writeFailed)
            }
            self.session = nil
            return .restored
        }
        self.session = nil
        return .interrupted(reason)
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.terminal",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "dev.warp.warp",
        "dev.warp.warp-stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    private static let supportedBundleIdentifiers: Set<String> = [
        "com.google.chrome",
        "com.hnc.discord",
        "com.openai.codex",
        "notion.id",
    ]

    private enum ValidationFailure: Equatable {
        case focusChanged
        case valueChanged
        case caretChanged
    }

    private func revalidate(_ current: Session) -> InlineInterruptionReason? {
        guard self.adapter.isFocused(current.target) else { return .focusChanged }
        guard let value = self.adapter.value(of: current.target), value == current.expectedValue else {
            return .valueChanged
        }
        guard let selection = self.adapter.selectedRange(of: current.target),
              Self.sameRange(selection, current.expectedSelection)
        else {
            return .caretChanged
        }
        return nil
    }

    private func hasReachedFreeze(sampleCount: Int, scopeLimit: TimeInterval) -> Bool {
        let limit = min(self.freezeAfter, max(0, scopeLimit))
        guard limit > 0 else { return true }
        return Double(max(0, sampleCount)) / Double(self.sampleRate) >= limit
    }

    /// Writes the value before its caret. If the caret write fails after the
    /// value write, restore only when the target still contains exactly the
    /// value and selection that this operation expected. This avoids erasing a
    /// user's edit made concurrently with an AX call.
    private func write(
        _ value: String,
        selection: CFRange,
        to target: InlineAccessibilityTarget,
        restoring current: Session
    ) -> Bool {
        guard self.adapter.setValue(value, on: target) else {
            if self.adapter.value(of: target) == value {
                _ = self.adapter.setValue(current.expectedValue, on: target)
                _ = self.adapter.setSelectedRange(current.expectedSelection, on: target)
            }
            return false
        }
        guard self.adapter.setSelectedRange(selection, on: target) else {
            guard self.adapter.value(of: target) == value,
                  let range = self.adapter.selectedRange(of: target),
                  Self.sameRange(range, current.expectedSelection)
            else { return false }
            _ = self.adapter.setValue(current.expectedValue, on: target)
            _ = self.adapter.setSelectedRange(current.expectedSelection, on: target)
            return false
        }
        guard self.adapter.value(of: target) == value,
              let range = self.adapter.selectedRange(of: target),
              Self.sameRange(range, selection)
        else {
            // A verification failure is handled like a failed caret write.
            // Restore is attempted only if the current value is still ours.
            if self.adapter.value(of: target) == value {
                _ = self.adapter.setValue(current.expectedValue, on: target)
                _ = self.adapter.setSelectedRange(current.expectedSelection, on: target)
            }
            return false
        }
        return true
    }

    private static func isValid(_ range: CFRange, in value: String) -> Bool {
        range.location >= 0
            && range.length >= 0
            && range.location <= (value as NSString).length
            && range.length <= (value as NSString).length - range.location
    }

    private static func sameRange(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private static func replacing(in value: String, range: CFRange, with replacement: String) -> String? {
        guard self.isValid(range, in: value) else { return nil }
        let nsValue = value as NSString
        return nsValue.replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
    }
}

/// Production Accessibility adapter. It is intentionally small: all policy
/// (terminal/secure-field rejection and session safety) remains in the
/// coordinator, while this type only translates AX values and ranges.
final class SystemInlineAccessibilityAdapter: InlineAccessibilityAdapter {
    func focusedTarget() -> InlineAccessibilityTarget? {
        guard AXIsProcessTrusted(), let element = self.focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return InlineAccessibilityTarget(
            processID: pid,
            bundleIdentifier: app?.bundleIdentifier,
            role: self.stringAttribute(kAXRoleAttribute as CFString, from: element),
            subrole: self.stringAttribute(kAXSubroleAttribute as CFString, from: element),
            element: InlineAXElementHandle(rawElement: element)
        )
    }

    func supportsInlineEditing(_ target: InlineAccessibilityTarget) -> Bool {
        guard let element = target.element.rawElement,
              Self.supportedRoles.contains(target.role ?? ""),
              self.value(of: target) != nil,
              self.selectedRange(of: target) != nil
        else { return false }
        var valueSettable = DarwinBoolean(false)
        var rangeSettable = DarwinBoolean(false)
        let valueResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &valueSettable
        )
        let rangeResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeSettable
        )
        return valueResult == .success && rangeResult == .success
            && valueSettable.boolValue && rangeSettable.boolValue
    }

    func isFocused(_ target: InlineAccessibilityTarget) -> Bool {
        guard let focusedElement = self.focusedElement(),
              let targetElement = target.element.rawElement
        else { return false }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &focusedPID) == .success else { return false }
        return focusedPID == target.processID && CFEqual(focusedElement, targetElement)
    }

    func value(of target: InlineAccessibilityTarget) -> String? {
        guard let element = target.element.rawElement else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? String
    }

    func selectedRange(of target: InlineAccessibilityTarget) -> CFRange? {
        guard let element = target.element.rawElement else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    func setValue(_ value: String, on target: InlineAccessibilityTarget) -> Bool {
        guard let element = target.element.rawElement else { return false }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
    }

    func setSelectedRange(_ range: CFRange, on target: InlineAccessibilityTarget) -> Bool {
        guard let element = target.element.rawElement else { return false }
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        ) == .success
    }

    func restoreFocus(to target: InlineAccessibilityTarget) -> Bool {
        guard AXIsProcessTrusted(), let element = target.element.rawElement else { return false }
        let appElement = AXUIElementCreateApplication(target.processID)
        return AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        ) == .success
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
            let raw,
            CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private static let supportedRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
    ]
}
