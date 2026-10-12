import Cocoa
import Carbon
import InputMethodKit
import SQLite3

// Client tests: the real controller, dictionary and candidate panel, driven through a fake text field.
// The engine is tests/engine.py, the real backend with a stand-in ranker, so no model is needed.
// scripts/test.sh builds this into build/tests/LayaTests.app with LAYA_DATA_DIR set to a temporary directory.

var checks = 0
var failures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL line \(line): \(message())")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
    check(actual == expected, "\(what): expected \(expected), got \(actual)", line: line)
}

func test(_ name: String, _ body: () -> Void) {
    print("- \(name)")
    body()
}

@discardableResult
func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    return condition()
}

func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

// Settings live in the volatile argument domain, so nothing is written to disk. Learning is off unless a test
// turns it on, so one test's picks cannot reorder another's candidates.
func settings(_ values: [String: Any] = [:]) {
    let base: [String: Any] = ["contextRanking": false, "personalLearning": false, "chinesePunctuation": true,
                               "traditionalChinese": false, "fuzzyPinyin": false, "shiftToggle": true,
                               "horizontalCandidates": false, "usKeyboardLayout": false]
    UserDefaults.standard.setVolatileDomain(base.merging(values) { $1 }, forName: UserDefaults.argumentDomain)
}

enum Key {
    static let space: UInt16 = 49, returnKey: UInt16 = 36, escape: UInt16 = 53, delete: UInt16 = 51
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126, shift: UInt16 = 56
}

// A host text field: committed text, marked (preedit) text, and the caret rectangle it reports.
final class TextField: NSObject, IMKTextInput {
    var text = ""
    var marked = ""
    let caret = NSRect(x: 200, y: 600, width: 1, height: 18)

    func insertText(_ string: Any!, replacementRange: NSRange) {
        text += Self.plain(string)
        marked = ""
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) { marked = Self.plain(string) }
    func selectedRange() -> NSRange { NSRange(location: (text as NSString).length, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        NSAttributedString(string: (text as NSString).substring(with: range))
    }
    func length() -> Int { (text as NSString).length }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        lineRect?.pointee = caret
        return [:]
    }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "com.laya.tests.client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "laya-tests" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { (text as NSString).substring(with: range) }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { caret }

    private static func plain(_ string: Any?) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
}

// One focused text field with Laya active in it.
final class Session {
    let field = TextField()
    let controller = LayaInputController(server: nil, delegate: nil, client: nil)!

    init() { controller.activateServer(field) }

    func end() { controller.deactivateServer(field) }

    // Keys the input method declines reach the host, which inserts their text unless they are shortcuts.
    @discardableResult
    func press(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        let handled = controller.handle(event, client: field)
        if !handled && flags.isDisjoint(with: [.command, .control, .option]) { field.text += characters }
        return handled
    }

    func type(_ keys: String) {
        for key in keys { press(0, String(key)) }
    }

    // A lone tap of the left Shift key.
    func tapShift() {
        for flags in [NSEvent.ModifierFlags.shift, []] {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: Key.shift)!
            _ = controller.handle(event, client: field)
        }
    }

    // Choose a candidate as a user would: page until it shows, then press its number.
    @discardableResult
    func pick(_ word: String) -> Bool {
        for _ in 0..<5 {
            guard let panel = Panel.visible else { return false }
            if let index = panel.words.firstIndex(of: word) {
                type(String(index + 1))
                return true
            }
            type("=")
        }
        return false
    }
}

// The candidate window as a user sees it.
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
    var words: [String] { rows.map(Self.word) }
    var dotted: [String] { rows.filter { $0.attributedTitle.string.hasSuffix("•") }.map(Self.word) }
    var labels: [String] {
        window.contentView!.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    }
    var selected: Int? { rows.firstIndex { ($0.layer?.backgroundColor?.alpha ?? 0) > 0 } }

    // Titles are "  1  你好" (list) or "1 你好" (bar), with a thin space and "•" when Laya moved it up.
    static func word(_ row: NSButton) -> String {
        let title = row.attributedTitle.string.replacingOccurrences(of: "\u{2009}•", with: "")
        return String(title.drop { $0 == " " || $0.isNumber })
    }
}

func personalStore(_ url: URL, _ rows: [(pinyin: String, text: String)]) {
    var db: OpaquePointer?
    sqlite3_open(url.path, &db)
    sqlite3_exec(db, "CREATE TABLE learned (pinyin TEXT NOT NULL, text TEXT NOT NULL, count INTEGER NOT NULL, "
                     + "updated REAL NOT NULL, PRIMARY KEY(pinyin,text)) WITHOUT ROWID", nil, nil, nil)
    for row in rows { sqlite3_exec(db, "INSERT INTO learned VALUES ('\(row.pinyin)','\(row.text)',1,0)", nil, nil, nil) }
    sqlite3_close(db)
}

func engineReady() -> Bool {
    wait(10) {
        BackendClient.shared.warmUp()
        settle(0.05)
        return BackendClient.shared.statusText == "ranking model loaded"
    }
}

guard !IsSecureEventInputEnabled() else {
    print("Secure keyboard entry is on (for example Terminal > Secure Keyboard Entry); turn it off to run these tests.")
    exit(1)
}
let resources = Bundle.main.resourceURL!
let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAYA_DATA_DIR"]!, isDirectory: true)
let dictionaryURL = resources.appendingPathComponent("models/dictionary.sqlite3")
setenv("LAYA_TEST_PREFER", "视力", 1)
NSApplication.shared.setActivationPolicy(.accessory)
LayaSettings.registerDefaults()
settings()

print("Dictionary")

test("common words, sentences and abbreviations come first") {
    let dictionary = PinyinDictionary(dictionary: dictionaryURL, personal: data.appendingPathComponent("none.sqlite3"))!
    for (raw, word) in [("nihao", "你好"), ("woaini", "我爱你"), ("jintiantianqihenhao", "今天天气很好"),
                        ("zhgr", "中国人"), ("xi'an", "西安"), ("z", "在")] {
        equal(dictionary.candidates(raw, limit: 9, useLearning: false).first?.text, word, raw)
    }
    check(dictionary.candidates("xian", limit: 1, useLearning: false).first?.text != "西安", "xian is not xi'an")
    check(dictionary.candidates("lv", limit: 9, useLearning: false).contains { $0.text == "绿" }, "v spells ü")
    check(dictionary.candidates("celue", limit: 9, useLearning: false).first?.text == "策略"
          && dictionary.candidates("jvzi", limit: 9, useLearning: false).first?.text == "句子", "lue spells lüe, jv spells ju")
    check(dictionary.candidates("nihaoshijie", limit: 45, useLearning: false).contains { $0.text == "你好" && $0.consumed == 5 },
          "prefix candidate consumes its own input")
    equal(dictionary.syllableSpaces("zhongguoren"), [5, 8], "preedit spaces")
    equal(dictionary.syllableSpaces("nhm"), [1, 2], "an interjection (hm) is not spaced as a syllable")
}

test("fuzzy pinyin is opt-in") {
    let dictionary = PinyinDictionary(dictionary: dictionaryURL, personal: data.appendingPathComponent("none.sqlite3"))!
    check(!dictionary.candidates("zongguo", limit: 45, useLearning: false).contains { $0.text == "中国" }, "exact by default")
    equal(dictionary.candidates("zongguo", limit: 1, useLearning: false, fuzzy: true).first?.text, "中国", "z = zh")
}

test("learned words come first and can be forgotten") {
    let personal = data.appendingPathComponent("dictionary-test.sqlite3")
    personalStore(personal, [("zhangwei", "张伟")])
    let dictionary = PinyinDictionary(dictionary: dictionaryURL, personal: personal)!
    equal(dictionary.candidates("zhangwei", limit: 1, useLearning: true).first?.text, "张伟", "learned first")
    check(!dictionary.candidates("zhangwei", limit: 45, useLearning: false).contains { $0.text == "张伟" }, "learning off")
    check(!dictionary.forget("zhangwei", text: "长尾"), "dictionary words are not forgotten")
    check(dictionary.forget("zhang'wei", text: "张伟"), "forget a learned word")
    check(!dictionary.candidates("zhangwei", limit: 45, useLearning: true).contains { $0.text == "张伟" }, "forgotten")
    check(!dictionary.forget("zhangwei", text: "张伟"), "nothing left to forget")
}

print("Typing")

test("pinyin shows as spaced preedit with candidates; Space commits the first") {
    let session = Session()
    session.type("nihao")
    equal(session.field.marked, "ni hao", "preedit")
    equal(Panel.visible?.words.first, "你好", "first candidate")
    session.press(Key.space, " ")
    equal(session.field.text, "你好", "committed")
    equal(session.field.marked, "", "preedit cleared")
    check(Panel.visible == nil, "panel hidden after commit")
    session.end()
}

test("number keys choose; Return keeps the letters; Escape discards") {
    let session = Session()
    session.type("nihao")
    let second = Panel.visible?.words[1]
    session.type("2")
    equal(session.field.text, second ?? "", "number 2")
    session.type("nihao")
    session.press(Key.returnKey, "\r")
    equal(session.field.text, (second ?? "") + "nihao", "Return")
    session.type("nihao")
    session.press(Key.escape, "\u{1b}")
    equal(session.field.text, (second ?? "") + "nihao", "Escape")
    equal(session.field.marked, "", "Escape clears preedit")
    session.end()
}

test("Delete and arrow keys edit the pinyin") {
    let session = Session()
    session.type("nihaoo")
    session.press(Key.delete)
    equal(session.field.marked, "ni hao", "Delete")
    session.press(Key.escape, "\u{1b}")
    session.type("nhao")
    for _ in 0..<3 { session.press(Key.left) }
    session.type("i")
    equal(session.field.marked, "ni hao", "insert at cursor")
    session.end()
}

test("picking part of the input keeps the rest composing") {
    let session = Session()
    session.type("nihaoshijie")
    check(session.pick("你好"), "你好 offered as a prefix")
    equal(session.field.text, "你好", "committed part")
    equal(session.field.marked, "shi jie", "rest still composing")
    equal(Panel.visible?.words.first, "世界", "candidates for the rest")
    session.end()
}

test("Chinese punctuation, paired quotes, and decimals stay ASCII") {
    let session = Session()
    session.type("nihao,")
    equal(session.field.text, "你好，", "comma commits and converts")
    session.type("\"\"")
    equal(session.field.text, "你好，“”", "quotes alternate")
    session.type("3.14")
    equal(session.field.text, "你好，“”3.14", "decimal point")
    session.end()
}

test("Shift+letter types a capital; shortcuts commit and pass through") {
    let session = Session()
    session.type("nihao")
    session.press(0, "A", .shift)
    equal(session.field.text, "你好A", "capital")
    session.type("nihao")
    check(!session.press(0, "a", .command), "Command-A goes to the app")
    equal(session.field.text, "你好A你好", "composition committed first")
    session.end()
}

test("a lone Shift switches to English and back") {
    let session = Session()
    session.tapShift()
    check(Panel.visible?.labels.contains("英") == true, "英 badge")
    session.type("hello")
    equal(session.field.text, "hello", "English letters pass through")
    session.tapShift()
    session.type("nihao")
    equal(session.field.marked, "ni hao", "Chinese again")
    session.end()
}

test("Traditional Chinese output") {
    settings(["traditionalChinese": true])
    let session = Session()
    session.type("zhongguo")
    session.press(Key.space, " ")
    equal(session.field.text, "中國", "converted")
    session.end()
    settings()
}

print("Candidate panel")

test("vertical list: heading, numbering, selection, paging, placement") {
    let session = Session()
    session.type("shi")
    guard let panel = Panel.visible else { check(false, "panel shown"); return }
    check(panel.labels.contains("shi"), "pinyin heading")
    check(panel.labels.contains { $0.hasPrefix("Laya · ") && $0.hasSuffix("1/5") }, "footer with page count")
    equal(panel.rows.count, 9, "rows")
    check(panel.rows.first?.attributedTitle.string.hasPrefix("  1  ") == true, "numbered")
    equal(panel.selected, 0, "first selected")
    session.press(Key.down)
    equal(panel.selected, 1, "Down moves the selection")
    let first = panel.words
    session.type("=")
    check(panel.words != first && panel.labels.contains { $0.hasSuffix("2/5") }, "= shows the next page")
    session.type("-")
    equal(panel.words, first, "- goes back")
    let frame = panel.window.frame, caret = session.field.caret
    check(abs(frame.minX - caret.minX) < 1
          && (abs(frame.maxY - (caret.minY - 6)) < 1 || abs(frame.minY - (caret.maxY + 6)) < 1),
          "placed at the caret: \(frame)")
    session.end()
}

test("horizontal bar: arrows move and page") {
    settings(["horizontalCandidates": true])
    let session = Session()
    session.type("shi")
    guard let panel = Panel.visible else { check(false, "panel shown"); return }
    check(!panel.labels.contains("shi"), "no heading in the bar")
    check(panel.rows[1].frame.minX > panel.rows[0].frame.maxX, "candidates side by side")
    let first = panel.words
    session.press(Key.right)
    equal(panel.selected, 1, "Right moves")
    session.press(Key.down)
    check(panel.words != first, "Down pages")
    session.press(Key.up)
    session.press(Key.right)
    let chosen = panel.words[panel.selected ?? 0]
    session.press(Key.space, " ")
    equal(session.field.text, chosen, "Space commits the selection")
    session.end()
    settings()
}

test("clicking a candidate commits it") {
    let session = Session()
    session.type("nihao")
    let third = Panel.visible?.words[2]
    Panel.visible?.rows[2].performClick(nil)
    equal(session.field.text, third ?? "", "clicked")
    session.end()
}

print("Engine")

test("learning: a phrase built from parts is learned whole; Shift-Delete forgets it") {
    settings(["personalLearning": true])
    let session = Session()
    session.type("zhangwei")
    check(session.pick("张"), "pick 张")
    equal(session.field.marked, "wei", "rest composing")
    check(session.pick("伟"), "pick 伟")
    equal(session.field.text, "张伟", "committed")
    let personal = PinyinDictionary(dictionary: dictionaryURL, personal: data.appendingPathComponent("personal.sqlite3"))!
    check(wait { personal.candidates("zhangwei", limit: 1, useLearning: true).first?.text == "张伟" }, "phrase learned")
    session.type("zhangwei")
    equal(Panel.visible?.words.first, "张伟", "offered first")
    settings()
    session.press(Key.delete)
    session.type("i")
    check(Panel.visible?.words.contains("张伟") == false, "learning off hides it")
    settings(["personalLearning": true])
    session.press(Key.delete)
    session.type("i")
    session.press(Key.delete, "", .shift)
    check(Panel.visible?.words.contains("张伟") == false, "Shift-Delete forgets")
    let before = Panel.visible?.words
    session.press(Key.delete, "", .shift)
    equal(Panel.visible?.words, before, "dictionary words stay")
    session.end()
    settings()
}

test("ranking reorders without preceding text and marks what it moved up") {
    settings(["contextRanking": true])
    check(engineReady(), "engine ready: \(BackendClient.shared.statusText)")
    let session = Session()
    session.type("shili")
    check(wait { Panel.visible?.words.first == "视力" }, "stand-in ranker's choice first")
    equal(Panel.visible?.dotted ?? [], ["视力"], "only the promoted candidate is marked")
    let label = Panel.visible?.rows.first?.accessibilityLabel() ?? ""
    check(label.hasSuffix(", ranked by Laya"), "accessibility label: \(label)")
    session.end()
    settings()
}

test("a manual selection is never reordered") {
    settings(["contextRanking": true])
    let session = Session()
    session.type("shil")
    settle()
    session.type("i")
    session.press(Key.down)
    settle()
    equal(Panel.visible?.words.first, "实力", "dictionary order kept")
    equal(Panel.visible?.selected, 1, "selection kept")
    session.end()
    settings()
}

test("typing continues while the engine is down, and it restarts") {
    settings(["contextRanking": true])
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    kill.arguments = ["-9", "-f", resources.appendingPathComponent("backend/server.py").path]
    try? kill.run()
    kill.waitUntilExit()
    check(wait { BackendClient.shared.statusText.hasPrefix("Engine stopped") }, "crash noticed")
    let session = Session()
    session.type("nihao")
    equal(Panel.visible?.words.first, "你好", "dictionary still answers")
    session.press(Key.space, " ")
    equal(session.field.text, "你好", "committed")
    check(engineReady(), "engine restarted")
    BackendClient.shared.stop()
    session.type("shili")
    settle()
    equal(Panel.visible?.words.first, "实力", "stopped engine: dictionary order")
    session.press(Key.escape, "\u{1b}")
    BackendClient.shared.resume()
    session.end()
    settings()
}

BackendClient.shared.shutdown()
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
