import Cocoa
import Carbon
import InputMethodKit

// Timed replay through the real controller and panel, not an emulation of the backend queue.
struct Action: Decodable {
    let type: String
    let text: String?
    let ms: Double?
    let key: String?
    let modifiers: [String]?
    let caret: Int?
}

struct Scenario: Decodable {
    let id: String
    let ctx: String
    let raw: String
    let gold: String
    let picks: [String]?
    let actions: [Action]?
}

struct Configuration: Decodable {
    let scenarios: [Scenario]
    let intervalMS: Double
    let pauseMS: Double
    let betweenMS: Double
    let policy: String
    let ranked: Bool
    let learning: Bool
    let horizontal: Bool
    let repeatCount: Int
}

final class TextField: NSObject, IMKTextInput {
    var text: String
    var markRange = NSRange(location: NSNotFound, length: 0)
    var selection: NSRange
    let caret: NSRect

    init(_ text: String) {
        self.text = text
        selection = NSRange(location: (text as NSString).length, length: 0)
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        caret = NSRect(x: frame.minX + 200, y: frame.maxY - 100, width: 1, height: 18)
    }

    var marked: String { markRange.location == NSNotFound ? "" : (text as NSString).substring(with: markRange) }
    var committed: String {
        markRange.location == NSNotFound ? text : (text as NSString).replacingCharacters(in: markRange, with: "")
    }

    private func replace(_ string: Any?, range: NSRange) -> NSRange? {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let target = range.location == NSNotFound ? (markRange.location == NSNotFound ? selection : markRange) : range
        guard target.location <= (text as NSString).length,
              target.length <= (text as NSString).length - target.location else { return nil }
        text = (text as NSString).replacingCharacters(in: target, with: value)
        return NSRange(location: target.location, length: (value as NSString).length)
    }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        guard let range = replace(string, range: replacementRange) else { return }
        selection = NSRange(location: range.location + range.length, length: 0)
        markRange = NSRange(location: NSNotFound, length: 0)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        guard let range = replace(string, range: replacementRange) else { return }
        markRange = range.length == 0 ? NSRange(location: NSNotFound, length: 0) : range
        selection = NSRange(location: range.location + selectionRange.location, length: selectionRange.length)
    }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { markRange }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard range.location != NSNotFound, range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func length() -> Int { (text as NSString).length }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { selection.location }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        lineRect?.pointee = caret
        return [:]
    }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "com.laya.bench.client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "laya-benchmark" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        actualRange?.pointee = range
        return attributedSubstring(from: range)?.string
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { caret }
}

struct Panel {
    let window: NSWindow
    static var visible: Panel? {
        NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "Laya Chinese candidates" }.map(Panel.init)
    }
    var rows: [NSButton] {
        window.contentView!.subviews.compactMap { $0 as? NSButton }
            .filter { !$0.isHidden && $0.action == NSSelectorFromString("candidateClicked:") }
            .sorted { $0.tag < $1.tag }
    }
    static func word(_ row: NSButton) -> String {
        let title = row.attributedTitle.string.replacingOccurrences(of: "\u{2009}•", with: "")
        return String(title.drop { $0 == " " }.drop { $0.isNumber }.drop { $0 == " " })
    }
    var words: [String] { rows.map(Self.word) }
    var promoted: [String] { rows.filter { $0.attributedTitle.string.hasSuffix("•") }.map(Self.word) }
    var onScreen: [String] {
        rows.filter { row in
            let rect = window.convertToScreen(row.convert(row.bounds, to: nil))
            return NSScreen.screens.contains { $0.visibleFrame.contains(rect) }
        }.map(Self.word)
    }
}

final class Replay {
    let field: TextField
    let controller = LayaInputController(server: nil, delegate: nil, client: nil)!
    let started = ProcessInfo.processInfo.systemUptime
    let config: Configuration
    var trace: [[String: Any]] = []
    var observations: [[String: Any]] = []
    var selectionKeys = 0
    var otherKeys = 0
    var typedKeys = 0
    private var lastSlate: [String] = []

    init(_ scenario: Scenario, _ config: Configuration) {
        self.config = config
        field = TextField(scenario.ctx)
        controller.activateServer(field)
    }

    var raw: String { controller.originalString(field)?.string ?? "" }

    func capture(_ event: String) {
        let panel = Panel.visible
        let words = panel?.words ?? []
        trace.append(["event": event, "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                      "raw": raw, "marked": field.marked, "text": field.committed, "document": field.text,
                      "displayed": words, "on_screen": panel?.onScreen ?? [],
                      "promoted": panel?.promoted ?? []])
        lastSlate = words
    }

    func pause(_ ms: Double) {
        let until = ProcessInfo.processInfo.systemUptime + ms / 1000
        while ProcessInfo.processInfo.systemUptime < until {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: min(0.005, until - ProcessInfo.processInfo.systemUptime)))
            if (Panel.visible?.words ?? []) != lastSlate { capture("slate_change") }
        }
    }

    @discardableResult
    func press(_ code: UInt16, _ text: String = "", _ flags: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: 0, context: nil, characters: text,
                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        let handled = controller.handle(event, client: field)
        if !handled && flags.isDisjoint(with: [.command, .control, .option]) {
            if code == 51 && field.selection.location > 0 {
                // Host Backspace removes one composed character, including a surrogate pair.
                let range = (field.text as NSString).rangeOfComposedCharacterSequence(at: field.selection.location - 1)
                field.insertText("", replacementRange: range)
            } else {
                field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        capture("key:" + (text.isEmpty ? String(code) : text))
        return handled
    }

    func type(_ text: String) {
        let began = ProcessInfo.processInfo.systemUptime
        for (index, key) in text.enumerated() {
            let due = began + Double(index) * config.intervalMS / 1000
            pause(max(0, (due - ProcessInfo.processInfo.systemUptime) * 1000))
            press(0, String(key))
            typedKeys += 1
        }
    }

    func observe(_ gold: String) {
        let panel = Panel.visible
        let words = panel?.words ?? []
        observations.append(["gold": gold, "raw": raw,
                             "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                             "displayed": words, "on_screen": panel?.onScreen ?? [],
                             "top1": words.first == gold, "top3": words.prefix(3).contains(gold),
                             "visible": panel?.onScreen.contains(gold) ?? false,
                             "panel_width": panel?.window.frame.width ?? 0,
                             "panel_height": panel?.window.frame.height ?? 0,
                             "promoted": panel?.promoted ?? []])
        capture("before_selection")
    }

    func pick(_ gold: String) -> Bool {
        observe(gold)
        var previous: [String] = []
        for _ in 0..<64 {
            guard let panel = Panel.visible else { return false }
            let rows = panel.rows
            if let row = rows.first(where: { Panel.word($0) == gold }), panel.onScreen.contains(gold) {
                selectionKeys += 1
                press(0, String(row.tag + 1))
                return true
            }
            let words = panel.words
            if words.isEmpty || words == previous { return false }
            previous = words
            selectionKeys += 1
            press(0, "=")
        }
        return false
    }

    func action(_ action: Action) -> Bool {
        switch action.type {
        case "type": type(action.text ?? "")
        case "wait": pause(action.ms ?? config.pauseMS)
        case "pick": return pick(action.text ?? "")
        case "host":
            // Mutations by the host bypass the controller, exercising stale-conversion guards.
            if let text = action.text {
                field.text = text
                field.markRange = NSRange(location: NSNotFound, length: 0)
                field.selection = NSRange(location: (text as NSString).length, length: 0)
            }
            if let caret = action.caret {
                guard caret >= 0 && caret <= (field.text as NSString).length else { return false }
                field.selection = NSRange(location: caret, length: 0)
            }
            capture("host_mutation")
        case "key":
            let codes: [String: UInt16] = ["space": 49, "return": 36, "escape": 53, "backspace": 51,
                                          "tab": 48, "left": 123, "right": 124, "down": 125, "up": 126,
                                          "pageDown": 121, "pageUp": 116]
            guard let code = codes[action.key ?? ""] else { return false }
            let modifiers: [String: NSEvent.ModifierFlags] = ["shift": .shift, "control": .control,
                                                             "option": .option, "command": .command]
            let flags = (action.modifiers ?? []).reduce(NSEvent.ModifierFlags()) { $0.union(modifiers[$1] ?? []) }
            if code == 49 && flags.isEmpty { selectionKeys += 1 }
            else { otherKeys += 1 }
            press(code, action.text ?? (code == 49 ? " " : ""), flags)
        default: return false
        }
        return true
    }
}

func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

guard !IsSecureEventInputEnabled() else { fail("Secure Keyboard Entry is on; turn it off before replay.") }
guard let path = ProcessInfo.processInfo.environment["LAYA_BENCH_CONFIG"] else { fail("Missing benchmark config.") }
let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
NSApplication.shared.setActivationPolicy(.accessory)
LayaSettings.registerDefaults()
UserDefaults.standard.setVolatileDomain(["contextRanking": config.ranked, "personalLearning": config.learning,
    "chinesePunctuation": true, "traditionalChinese": false, "fuzzyPinyin": false, "shiftToggle": true,
    "horizontalCandidates": config.horizontal, "usKeyboardLayout": false], forName: UserDefaults.argumentDomain)

if config.ranked || config.learning {
    let deadline = Date(timeIntervalSinceNow: 60)
    while Date() < deadline && BackendClient.shared.statusText != "ranking model loaded" {
        BackendClient.shared.warmUp()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        if BackendClient.shared.statusText.hasPrefix("dictionary fallback:") {
            if config.ranked { fail(BackendClient.shared.statusText) }
            break
        }
    }
    guard BackendClient.shared.statusText == "ranking model loaded"
            || !config.ranked && BackendClient.shared.statusText.hasPrefix("dictionary fallback:") else {
        fail("Backend warm-up failed: " + BackendClient.shared.statusText)
    }
}

for iteration in 0..<config.repeatCount {
    for scenario in config.scenarios {
        let replay = Replay(scenario, config)
        var found = true
        if let actions = scenario.actions {
            for action in actions { if !replay.action(action) { found = false; break } }
        } else {
            replay.type(scenario.raw)
            replay.pause(config.pauseMS)
            if config.policy == "space" {
                replay.observe(scenario.gold)
                replay.selectionKeys += 1
                replay.press(49, " ")
            } else {
                for gold in scenario.picks ?? [scenario.gold] {
                    if !replay.pick(gold) { found = false; break }
                    if !replay.raw.isEmpty { replay.pause(config.pauseMS) }
                }
            }
        }
        let output = replay.field.committed.hasPrefix(scenario.ctx)
            ? String(replay.field.committed.dropFirst(scenario.ctx.count)) : replay.field.committed
        try emit(["id": scenario.id, "iteration": iteration, "ctx": scenario.ctx, "raw": scenario.raw,
                  "scripted_actions": scenario.actions != nil || scenario.picks != nil,
                  "gold": scenario.gold, "output": output, "remaining": replay.raw,
                  "exact": output == scenario.gold && replay.raw.isEmpty, "selection_found": found,
                  "typed_keys": replay.typedKeys, "selection_keys": replay.selectionKeys,
                  "editing_or_control_keys": replay.otherKeys,
                  "elapsed_ms": (ProcessInfo.processInfo.systemUptime - replay.started) * 1000,
                  "observations": replay.observations, "trace": replay.trace])
        replay.press(53)
        replay.controller.deactivateServer(replay.field)
        replay.pause(config.betweenMS)
    }
}
BackendClient.shared.shutdown()
