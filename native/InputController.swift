import Cocoa
import Carbon
import InputMethodKit

@objc(LayaInputController)
final class LayaInputController: IMKInputController {
    private let session = UUID()
    private let replacement = NSRange(location: NSNotFound, length: 0)
    private var textClient: IMKTextInput?
    private var pinyin = ""
    private var cursor = 0
    private var context = ""
    private var recentText = ""
    private var candidates: [LayaCandidate] = []
    private var promoted: Set<String> = []  // candidates Laya's re-rank moved up or composed
    private var parts: [(pinyin: String, text: String)] = []  // picks so far within one typed span
    private var selected = 0
    private var generation = 0
    private var active = false
    private var paletteHidden = false
    private var english = false
    private var selectionLocked = false
    private var waiting = false
    private var openingDoubleQuote = true
    private var openingSingleQuote = true
    private var caretRect: NSRect?
    private var hostLevel = 0
    private var changedAt: TimeInterval = 0
    private var shiftDownAt: TimeInterval?
    private let pageSize = 9
    // Lookups are synchronous; the Python engine is only consulted to re-rank.
    private static let dictionary: PinyinDictionary? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        // LAYA_DATA_DIR is shared with the engine, which inherits this environment.
        let data = ProcessInfo.processInfo.environment["LAYA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/LayaIME", isDirectory: true)
        return PinyinDictionary(dictionary: resources.appendingPathComponent("models/dictionary.sqlite3"),
                                personal: data.appendingPathComponent("personal.sqlite3"))
    }()
    private lazy var panel: CandidatePanel = {
        let panel = CandidatePanel()
        panel.onSelect = { [weak self] index in
            guard let self else { return }
            self.choose(self.selected / self.pageSize * self.pageSize + index)
        }
        panel.onPage = { [weak self] delta in self?.changePage(delta) }
        return panel
    }()

    override func activateServer(_ sender: Any!) {
        textClient = sender as? IMKTextInput
        active = true
        recentText = ""
        openingDoubleQuote = true
        openingSingleQuote = true
        if UserDefaults.standard.bool(forKey: "usKeyboardLayout") {
            textClient?.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.US")
        }
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        commitBest()
        active = false
        reset()
        recentText = ""
        textClient = nil
        super.deactivateServer(sender)
    }

    override func inputControllerWillClose() {
        commitBest()
        reset()
        active = false
        textClient = nil
        super.inputControllerWillClose()
    }

    override func hidePalettes() { paletteHidden = true; panel.hide() }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        if event.type == .flagsChanged {
            // A lone, quick Shift press and release toggles Chinese/English, as in Apple's Pinyin.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
            let shiftKey = event.keyCode == 56 || event.keyCode == 60
            let now = ProcessInfo.processInfo.systemUptime
            if shiftKey && flags == .shift {
                shiftDownAt = now
            } else if shiftKey, flags.isEmpty, let down = shiftDownAt, now - down < 0.5,
                      UserDefaults.standard.bool(forKey: "shiftToggle"), !IsSecureEventInputEnabled() {
                shiftDownAt = nil
                textClient = client
                toggleMode(literal: true)
            } else {
                shiftDownAt = nil
            }
            return false
        }
        guard event.type == .keyDown else { return false }
        shiftDownAt = nil
        textClient = client
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.keyCode
        let text = event.characters ?? ""

        // Secure fields normally bypass IMK entirely; do not inspect or rank their text.
        if IsSecureEventInputEnabled() {
            commitRaw()
            recentText = ""
            return false
        }

        if key == 49 && flags.contains(.shift) && flags.isDisjoint(with: [.command, .control, .option]) {
            toggleMode(literal: false)
            return true
        }
        if !flags.isDisjoint(with: [.command, .control, .option]) {
            commitBest()
            recentText = ""
            return false
        }
        if english || flags.contains(.capsLock) {
            commitRaw()
            recentText = ""
            return false
        }

        if !pinyin.isEmpty {
            // The horizontal bar uses ←/→ for candidates and ↑/↓ for pages, as in Apple's Pinyin.
            let bar = UserDefaults.standard.bool(forKey: "horizontalCandidates") && !candidates.isEmpty
            switch key {
            case 123 where bar: moveSelection(-1); return true
            case 124 where bar: moveSelection(1); return true
            case 126 where bar: changePage(-1); return true
            case 125 where bar: changePage(1); return true
            case 53: cancel(); return true                      // Escape discards preedit.
            case 36, 76: commitRaw(); return true              // Return preserves literal pinyin.
            case 49: choose(selected); return true
            case 51 where flags.contains(.shift) && candidates.indices.contains(selected):
                // Shift-Delete forgets a learned word; dictionary words stay.
                let candidate = candidates[selected]
                if Self.dictionary?.forget(String(pinyin.prefix(candidate.consumed)), text: candidate.text) == true {
                    changed()
                } else { NSSound.beep() }
                return true
            case 51:
                guard cursor > 0 else { return true }
                let index = pinyin.index(pinyin.startIndex, offsetBy: cursor - 1)
                pinyin.remove(at: index)
                cursor -= 1
                changed()
                return true
            case 117:
                if cursor < pinyin.count {
                    pinyin.remove(at: pinyin.index(pinyin.startIndex, offsetBy: cursor))
                    changed()
                }
                return true
            case 123: cursor = max(0, cursor - 1); mark(); return true
            case 124: cursor = min(pinyin.count, cursor + 1); mark(); return true
            case 115: cursor = 0; mark(); return true
            case 119: cursor = pinyin.count; mark(); return true
            case 126: moveSelection(-1); return true
            case 125: moveSelection(1); return true
            case 116: changePage(-1); return true
            case 121: changePage(1); return true
            case 48: moveSelection(flags.contains(.shift) ? -1 : 1); return true
            default: break
            }
            if text == "-" || text == "[" { changePage(-1); return true }
            if text == "=" || text == "]" { changePage(1); return true }
            if text.count == 1, let number = Int(text), (1...9).contains(number) {
                let index = selected / pageSize * pageSize + number - 1
                if index < candidates.count { choose(index) }
                else if candidates.isEmpty { commitRaw(); insert(text) }
                else { NSSound.beep() }
                return true
            }
        }

        // Shift+letter types the capital directly, finishing any composition first.
        if flags.contains(.shift), text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
           (65...90).contains(scalar.value) {
            commitBest()
            insert(text)
            return true
        }
        let lower = text.lowercased()
        if lower.unicodeScalars.count == 1, let scalar = lower.unicodeScalars.first,
           (97...122).contains(scalar.value) || lower == "ü" {
            if pinyin.isEmpty {
                context = UserDefaults.standard.bool(forKey: "contextRanking") ? precedingText() : ""
            }
            guard pinyin.count < 128 else { NSSound.beep(); return true }
            let letter = lower == "ü" ? "v" : lower
            pinyin.insert(contentsOf: letter, at: pinyin.index(pinyin.startIndex, offsetBy: cursor))
            cursor += 1
            changed()
            return true
        }
        if text == "'", !pinyin.isEmpty {
            guard cursor > 0, pinyin.count < 128 else { return true }
            let before = pinyin[pinyin.index(pinyin.startIndex, offsetBy: cursor - 1)]
            if before != "'" {
                pinyin.insert("'", at: pinyin.index(pinyin.startIndex, offsetBy: cursor))
                cursor += 1
                changed()
            }
            return true
        }
        if let punctuation = punctuation(for: text) {
            commitBest()
            insert(punctuation)
            return true
        }
        if !pinyin.isEmpty {
            commitBest()
        }
        // Navigation or text entered by the host invalidates our fallback context.
        recentText = ""
        return false
    }

    override func commitComposition(_ sender: Any!) {
        if let client = sender as? IMKTextInput { textClient = client }
        commitBest()
        recentText = ""
    }

    override func composedString(_ sender: Any!) -> Any! { pinyin as NSString }

    override func originalString(_ sender: Any!) -> NSAttributedString! {
        NSAttributedString(string: pinyin)
    }

    private func changed() {
        paletteHidden = false
        generation += 1
        BackendClient.shared.cancel(owner: session)
        selected = 0
        selectionLocked = false
        if pinyin.isEmpty { cancel(); return }
        mark()
        changedAt = ProcessInfo.processInfo.systemUptime
        promoted = []
        if let dictionary = Self.dictionary {
            let defaults = UserDefaults.standard
            candidates = dictionary.candidates(pinyin, limit: 45, useLearning: defaults.bool(forKey: "personalLearning"),
                                               fuzzy: defaults.bool(forKey: "fuzzyPinyin"))
            waiting = false
        } else {
            candidates = []
            waiting = true
        }
        showCandidates()
        let rank = UserDefaults.standard.bool(forKey: "contextRanking")
        if waiting || rank { fetch(ranked: rank, revision: generation) }
    }

    private func fetch(ranked: Bool, revision: Int) {
        let input = pinyin
        BackendClient.shared.candidates(owner: session, pinyin: input,
                                        context: ranked ? context : "", ranked: ranked) { [weak self] reply in
            guard let self, self.active, self.generation == revision, self.pinyin == input else { return }
            self.waiting = false
            // A late re-rank would reorder a list the user is already reading; keep it.
            let late = ranked && ProcessInfo.processInfo.systemUptime - self.changedAt > 0.15
            // Never replace a usable list with an error reply or override a manual selection.
            if !self.selectionLocked, !late, reply?.error == nil, let result = reply?.candidates {
                // Reject malformed backend offsets; never allow a response to drop keystrokes.
                var merged = result.filter {
                    !$0.text.isEmpty && $0.consumed > 0 && $0.consumed <= input.count
                }
                let reranked = Set(merged.map(\.text))
                let local = self.candidates.map(\.text)
                // Lone digraphs rank a wider pool than the local 45. Its leftovers lost that ranking; they must
                // not displace the model's winner. Other local-only choices (e.g. fuzzy readings) stay near their slots.
                let digraph = ["zh", "ch", "sh"].contains(input.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                for (index, candidate) in self.candidates.enumerated()
                where !merged.contains(where: { $0.text == candidate.text }) {
                    merged.insert(candidate, at: ranked && digraph ? merged.count : min(index, merged.count))
                }
                // Mark what the model placed ahead of its dictionary position, or composed itself.
                self.promoted = reply?.ranked == true && !local.isEmpty ? Set(merged.indices.filter {
                    reranked.contains(merged[$0].text) && (local.firstIndex(of: merged[$0].text) ?? .max) > $0
                }.map { merged[$0].text }) : []
                self.candidates = merged
                self.selected = 0
            }
            self.showCandidates()
        }
    }

    private func mark() {
        let (shown, caret) = displayPinyin()
        textClient?.setMarkedText(shown, selectionRange: NSRange(location: caret, length: 0),
                                  replacementRange: replacement)
    }

    // Pinyin with spaces between syllables ("ni hao"), and the cursor mapped into it.
    private func displayPinyin() -> (String, Int) {
        let spaces = Self.dictionary?.syllableSpaces(pinyin) ?? []
        var shown = "", caret = cursor
        for (index, character) in pinyin.enumerated() {
            if spaces.contains(index) {
                shown += " "
                if index < cursor { caret += 1 }
            }
            shown.append(character)
        }
        return (shown, caret)
    }

    private func toggleMode(literal: Bool) {
        if literal { commitRaw() } else { commitBest() }
        english.toggle()
        guard let client = textClient else { return }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect != .zero { panel.flash(english ? "英" : "中", caret: rect, windowLevel: Int(client.windowLevel())) }
    }

    private func showCandidates() {
        guard active, !paletteHidden, !pinyin.isEmpty, let client = textClient else { panel.hide(); return }
        let page = selected / pageSize
        let start = page * pageSize
        let shown = candidates.dropFirst(start).prefix(pageSize)
        let words = shown.map { displayText($0.text) }
        let marked = Set(shown.enumerated().filter { promoted.contains($0.element.text) }.map(\.offset))
        // Hosts move the marked text (scroll, reflow, async layout after insert); re-query
        // every time, but keep the last good rect when a host transiently reports zero.
        if caretRect == nil { hostLevel = Int(client.windowLevel()) }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if rect != .zero { caretRect = rect }
        let status: String
        if waiting { status = "Looking up…" }
        else if candidates.isEmpty { status = "Return: literal input" }
        else if UserDefaults.standard.bool(forKey: "traditionalChinese") { status = "繁 · Space to select" }
        else { status = "Space to select" }
        panel.show(pinyin: displayPinyin().0, candidates: words, marked: marked, selected: selected % pageSize,
                   page: page, pageCount: (candidates.count + pageSize - 1) / pageSize,
                   status: status, caret: caretRect ?? .zero, windowLevel: hostLevel,
                   horizontal: UserDefaults.standard.bool(forKey: "horizontalCandidates"))
    }

    private func moveSelection(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        selectionLocked = true
        selected = max(0, min(candidates.count - 1, selected + delta))
        showCandidates()
    }

    private func changePage(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        selectionLocked = true
        let page = max(0, min((candidates.count - 1) / pageSize, selected / pageSize + delta))
        selected = page * pageSize
        showCandidates()
    }

    private func choose(_ index: Int) {
        guard !pinyin.isEmpty else { return }
        guard candidates.indices.contains(index) else { commitRaw(); return }
        let candidate = candidates[index]
        let consumed = String(pinyin.prefix(candidate.consumed))
        let remainder = String(pinyin.dropFirst(candidate.consumed)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let word = displayText(candidate.text)
        reset()
        insert(word)
        if UserDefaults.standard.bool(forKey: "personalLearning") {
            BackendClient.shared.learn(pinyin: consumed, text: candidate.text)
        }
        parts.append((consumed, candidate.text))
        if remainder.isEmpty {
            learnParts()
        } else {
            context = UserDefaults.standard.bool(forKey: "contextRanking") ? precedingText() : ""
            pinyin = remainder
            cursor = remainder.count
            changed()
        }
    }

    // A name or phrase built from several picks is learned whole, so it is one candidate next time.
    private func learnParts() {
        defer { parts = [] }
        guard parts.count > 1, UserDefaults.standard.bool(forKey: "personalLearning") else { return }
        BackendClient.shared.learn(pinyin: parts.map(\.pinyin).joined(), text: parts.map(\.text).joined())
    }

    private func commitBest() {
        guard !pinyin.isEmpty else { return }
        // External commits finish the entire marked span, including unconverted suffixes.
        if candidates.indices.contains(selected) {
            let candidate = candidates[selected]
            let literal = String(pinyin.dropFirst(candidate.consumed)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            let output = displayText(candidate.text) + literal
            reset()
            insert(output)
            // Punctuation, shortcuts and focus changes accept the default implicitly; do not reinforce it.
            parts = []
        } else { commitRaw() }
    }

    private func commitRaw() {
        guard !pinyin.isEmpty else { return }
        let raw = pinyin
        reset()
        parts = []
        insert(raw)
    }

    private func cancel() {
        reset()
        parts = []
        // Clearing marked text with an empty insert leaves stale preedit in some hosts.
        textClient?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: replacement)
    }

    private func reset() {
        generation += 1
        BackendClient.shared.cancel(owner: session)
        pinyin = ""
        cursor = 0
        candidates = []
        promoted = []
        selected = 0
        waiting = false
        context = ""
        caretRect = nil
        panel.hide()
    }

    private func insert(_ text: String) {
        textClient?.insertText(text, replacementRange: replacement)
        recentText = String((recentText + text).suffix(32))
    }

    private func precedingText() -> String {
        guard !IsSecureEventInputEnabled(), let client = textClient else { return "" }
        let range = client.selectedRange()
        if range.location != NSNotFound {
            if range.location == 0 { return "" }
            let length = min(64, range.location)
            if let substring = client.attributedSubstring(from: NSRange(location: range.location - length, length: length)) {
                return String(substring.string.suffix(32))
            }
        }
        return recentText
    }

    private func displayText(_ text: String) -> String {
        guard UserDefaults.standard.bool(forKey: "traditionalChinese") else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    private func punctuation(for text: String) -> String? {
        guard UserDefaults.standard.bool(forKey: "chinesePunctuation") else { return nil }
        if text == ".", pinyin.isEmpty, precedingText().last?.isNumber == true { return nil }
        if text == "\"" {
            defer { openingDoubleQuote.toggle() }
            return openingDoubleQuote ? "“" : "”"
        }
        if text == "'" {
            defer { openingSingleQuote.toggle() }
            return openingSingleQuote ? "‘" : "’"
        }
        return [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
                "(": "（", ")": "）", "[": "【", "]": "】", "<": "《", ">": "》",
                "\\": "、", "~": "～", "^": "……", "_": "——"][text]
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Laya")
        let mode = NSMenuItem(title: english ? "Chinese mode (Shift)" : "English mode (Shift)",
                              action: #selector(toggleEnglish(_:)), keyEquivalent: "")
        menu.addItem(mode)
        let traditional = NSMenuItem(title: "Traditional Chinese", action: #selector(toggleTraditional(_:)), keyEquivalent: "")
        traditional.state = UserDefaults.standard.bool(forKey: "traditionalChinese") ? .on : .off
        menu.addItem(traditional)
        let engine = BackendClient.shared.stopped
        menu.addItem(NSMenuItem(title: engine ? "Start Local Engine" : "Stop Local Engine",
                                action: #selector(toggleEngine(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Laya Settings…", action: #selector(openSettings(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func toggleEnglish(_ sender: Any?) { toggleMode(literal: false) }
    @objc private func toggleTraditional(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "traditionalChinese"), forKey: "traditionalChinese")
        showCandidates()
    }
    @objc private func toggleEngine(_ sender: Any?) {
        if BackendClient.shared.stopped { BackendClient.shared.resume() } else { BackendClient.shared.stop() }
    }
    @objc private func openSettings(_ sender: Any?) { LayaSettings.shared.show() }
}
