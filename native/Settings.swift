import Cocoa

final class LayaSettings: NSObject {
    static let shared = LayaSettings()
    private var window: NSWindow?
    private var toggles: [NSButton] = []
    private var statusLabel: NSTextField?

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "contextRanking": true,
            "personalLearning": true,
            "chinesePunctuation": true,
            "traditionalChinese": false,
            "fuzzyPinyin": false,
            "shiftToggle": true,
            "horizontalCandidates": true,
            "usKeyboardLayout": true,
        ])
    }

    func show() {
        Self.registerDefaults()
        if window == nil { makeWindow() }
        for toggle in toggles {
            toggle.state = UserDefaults.standard.bool(forKey: toggle.identifier!.rawValue) ? .on : .off
        }
        statusLabel?.stringValue = BackendClient.shared.statusText
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Laya 拼音 Settings"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
        ])

        let title = NSTextField(labelWithString: "Local Chinese input, powered by Laya")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)
        for (key, title) in [
            ("contextRanking", "Rank candidates with the local model, using preceding text"),
            ("personalLearning", "Remember my candidate selections on this Mac"),
            ("chinesePunctuation", "Use Chinese punctuation"),
            ("traditionalChinese", "Output Traditional Chinese"),
            ("fuzzyPinyin", "Fuzzy pinyin (z/zh, c/ch, s/sh, n/l, an/ang, en/eng, in/ing)"),
            ("shiftToggle", "Press Shift alone to switch Chinese/English"),
            ("horizontalCandidates", "Horizontal candidate bar"),
            ("usKeyboardLayout", "Type pinyin with the U.S. keyboard layout (applies on next activation)"),
        ] {
            let toggle = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeSetting(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(key)
            toggles.append(toggle)
            stack.addArrangedSubview(toggle)
        }

        let help = NSTextField(wrappingLabelWithString:
            "Space: selected candidate · 1–9: select · ↑/↓: move (horizontal bar: ←/→ move, ↑/↓ page)\nReturn: literal pinyin · Shift-Delete: forget a learned word · Esc: discard · Shift or Shift-Space: Chinese/English · Shift-letter: capital\n-/=: pages · ←/→: edit (vertical list) · v: ü · apostrophe: syllable boundary\nAll ranking and learning stay on this Mac. Disabling learning stops reading and writing saved choices, but keeps existing history."
        )
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help)
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        statusLabel = status
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(NSButton(title: "Show Local Data…", target: self, action: #selector(showLocalData)))
        self.window = window
    }

    @objc private func changeSetting(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }

    @objc private func showLocalData() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LayaIME", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) }
        }
    }
}
