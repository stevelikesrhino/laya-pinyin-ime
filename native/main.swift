import Cocoa
import InputMethodKit
import Carbon

private let inputMethodBundleID = "com.laya.inputmethod.Laya"
private let inputModeID = "com.laya.inputmethod.Laya.Hans"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("LayaIME: \(message)\n".utf8))
    exit(1)
}

private func inputSources(includeAllInstalled: Bool = true) -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: inputMethodBundleID] as CFDictionary
    guard let result = TISCreateInputSourceList(filter, includeAllInstalled) else { return [] }
    guard let sources = result.takeRetainedValue() as? [TISInputSource] else { return [] }
    // A mode's parent must be enabled first; enumeration order is not guaranteed.
    return sources.sorted {
        let left = sourceText($0, kTISPropertyInputSourceType) == kTISTypeKeyboardInputMode as String
        let right = sourceText($1, kTISPropertyInputSourceType) == kTISTypeKeyboardInputMode as String
        if left != right { return !left }
        return sourceText($0, kTISPropertyInputSourceID) < sourceText($1, kTISPropertyInputSourceID)
    }
}

private func sourceText(_ source: TISInputSource, _ key: CFString) -> String {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func sourceFlag(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
}

private func checkStatus(_ status: OSStatus, _ operation: String) {
    if status != noErr { fail("\(operation) failed (OSStatus \(status)).") }
}

// Maintenance commands never start the IMK server or change the selected source.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, command.hasPrefix("--") {
    switch command {
    case "--register":
        guard arguments.count == 2 else { fail("Usage: LayaIME --register /path/to/LayaIME.app") }
        let location = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/LayaIME.app").standardizedFileURL
        guard location == expected,
              Bundle(url: location)?.bundleIdentifier == inputMethodBundleID else {
            fail("Registration is restricted to ~/Library/Input Methods/LayaIME.app.")
        }
        checkStatus(TISRegisterInputSource(location as CFURL), "Register input source")
        print("Registered LayaIME. The current input source was not changed.")
    case "--enable":
        // Default-state flags do not prove availability; the parent can still be disabled.
        let available = inputSources(includeAllInstalled: false).contains {
            sourceText($0, kTISPropertyInputSourceID) == inputModeID
        }
        if available {
            print("Laya 拼音 is available for manual selection in the input menu.")
        } else {
            guard let mode = inputSources().first(where: {
                sourceText($0, kTISPropertyInputSourceID) == inputModeID
            }) else { fail("The Laya input mode is not registered; reinstall or log out and back in.") }
            // Modern macOS routes third-party requests to Settings for user approval.
            // Request the selectable mode, never its non-selectable container.
            checkStatus(TISEnableInputSource(mode), "Request input-source approval")
            print("Requested macOS approval for Laya 拼音; this does not confirm it is enabled.")
            print("Complete Add in System Settings > Keyboard > Text Input > Edit > + > Chinese, Simplified.")
            print("The current input source was not changed. Use --status to verify availability afterward.")
        }
    case "--disable":
        let sources = inputSources()
        guard !sources.contains(where: { sourceFlag($0, kTISPropertyInputSourceIsSelected) }) else {
            fail("Switch to another input source before uninstalling LayaIME.")
        }
        for source in sources.reversed() where sourceFlag(source, kTISPropertyInputSourceIsEnabled) {
            checkStatus(TISDisableInputSource(source), "Disable input source")
        }
        print("Disabled LayaIME.")
    case "--stop":
        guard !inputSources().contains(where: { sourceFlag($0, kTISPropertyInputSourceIsSelected) }) else {
            fail("Switch to another input source before stopping LayaIME.")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: inputMethodBundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        for application in running {
            guard application.terminate() else { fail("Could not request termination of the running LayaIME app.") }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard running.allSatisfy({ $0.isTerminated }) else {
            fail("The running app did not stop. Nothing will be replaced; quit LayaIME and retry.")
        }
    case "--status":
        let sources = inputSources()
        let available = Set(inputSources(includeAllInstalled: false).map { sourceText($0, kTISPropertyInputSourceID) })
        if sources.isEmpty { print("LayaIME: not registered") }
        for source in sources {
            let enabled = sourceFlag(source, kTISPropertyInputSourceIsEnabled)
            let selected = sourceFlag(source, kTISPropertyInputSourceIsSelected)
            let identifier = sourceText(source, kTISPropertyInputSourceID)
            let name = sourceText(source, kTISPropertyLocalizedName)
            print("\(identifier) [\(name)]: availableInInputMenu=\(available.contains(identifier)) flagEnabled=\(enabled) selected=\(selected)")
        }
    case "--settings":
        break
    default:
        fail("Unknown command \(command).")
    }
    if command != "--settings" { exit(0) }
}

final class LayaApplicationDelegate: NSObject, NSApplicationDelegate {
    private var inputMethodServer: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LayaSettings.registerDefaults()
        if arguments.first == "--settings" {
            LayaSettings.shared.show()
            return
        }
        guard let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              let identifier = Bundle.main.bundleIdentifier,
              NSClassFromString("LayaInputController") != nil,
              let server = IMKServer(name: connection, bundleIdentifier: identifier) else {
            fail("Cannot initialize InputMethodKit; verify the bundle metadata and controller class.")
        }
        inputMethodServer = server
        BackendClient.shared.warmUp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        arguments.first == "--settings"
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackendClient.shared.shutdown()
    }
}

let application = NSApplication.shared
let applicationDelegate = LayaApplicationDelegate()
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
