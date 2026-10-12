import Foundation
import Darwin

struct LayaCandidate: Decodable {
    let text: String
    let consumed: Int
}

struct BackendReply: Decodable {
    let id: Int
    let candidates: [LayaCandidate]?
    let model_status: String?
    let error: String?
}

// A private child process, not a network service. All state is main-queue confined.
final class BackendClient {
    static let shared = BackendClient()
    private(set) var statusText = "Starting local engine…"
    // A user stop holds until resume(); requests then fail fast instead of relaunching.
    private(set) var stopped = false

    private struct Request {
        let id: Int
        let owner: UUID?
        let data: Data
        let completion: (BackendReply?) -> Void
    }

    private let io = DispatchQueue(label: "com.laya.inputmethod.pipe")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var waiting: [Request] = []
    private var active: Request?
    private var timeout: DispatchWorkItem?

    private init() {
        // A dead child must produce an EPIPE error, not terminate the input method.
        signal(SIGPIPE, SIG_IGN)
    }

    func warmUp() {
        request(["op": "status"]) { _ in }
    }

    func candidates(owner: UUID, pinyin: String, context: String, ranked: Bool,
                    completion: @escaping (BackendReply?) -> Void) {
        // Only the newest not-yet-started composition for this session matters.
        waiting.removeAll { $0.owner == owner }
        request(["op": "candidates", "pinyin": pinyin, "context": context,
                 "limit": 45, "use_model": ranked,
                 "use_learning": UserDefaults.standard.bool(forKey: "personalLearning")],
                owner: owner, completion: completion)
    }

    func cancel(owner: UUID) {
        waiting.removeAll { $0.owner == owner }
    }

    func stop() {
        stopped = true
        fail("Engine stopped by user — dictionary input remains available")
    }

    func resume() {
        stopped = false
        warmUp()
    }

    func learn(pinyin: String, text: String) {
        guard waiting.count < 32 else { return }
        request(["op": "learn", "pinyin": pinyin, "text": text]) { _ in }
    }

    private func request(_ payload: [String: Any], owner: UUID? = nil,
                         completion: @escaping (BackendReply?) -> Void) {
        sequence += 1
        var payload = payload
        payload["id"] = sequence
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(nil)
            return
        }
        data.append(10)
        waiting.append(Request(id: sequence, owner: owner, data: data, completion: completion))
        drain()
    }

    private func start() -> Bool {
        if stopped { return false }
        if process?.isRunning == true { return true }
        guard let resources = Bundle.main.resourceURL else { return false }
        let python = resources.appendingPathComponent("runtime/bin/python3")
        let server = resources.appendingPathComponent("backend/server.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: server.path) else {
            statusText = "Engine missing — run setup and rebuild"
            return false
        }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-u", server.path]
        child.currentDirectoryURL = resources
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONHOME")
        env["PYTHONPATH"] = resources.appendingPathComponent("python").path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["LAYA_DICTIONARY"] = resources.appendingPathComponent("models/dictionary.sqlite3").path
        env["LAYA_BASE_MODEL"] = resources.appendingPathComponent("models/multilingual").path
        env["LAYA_TUNED_MODEL"] = resources.appendingPathComponent("models/laya-chinese-tuned/laya_ime.safetensors").path
        child.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        // Diagnostics contain no protocol messages or surrounding document text.
        child.standardError = FileHandle.standardError
        let reader = stdoutPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // At EOF the source fires continuously; detach it so a dead pipe cannot spin.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.receive(data)
            }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.fail("Engine stopped — will retry on next input")
            }
        }
        process = child
        input = stdinPipe.fileHandleForWriting
        output = reader
        do {
            try child.run()
            statusText = "Loading local dictionary and model…"
            return true
        } catch {
            fail("Could not launch local engine")
            return false
        }
    }

    private func drain() {
        guard active == nil, !waiting.isEmpty else { return }
        guard start() else {
            let requests = waiting
            waiting.removeAll()
            requests.forEach { $0.completion(nil) }
            return
        }
        let request = waiting.removeFirst()
        active = request
        let watchdog = DispatchWorkItem { [weak self] in
            self?.fail("Engine timed out — raw input remains available")
        }
        timeout = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: watchdog)
        guard let input else { fail("Engine input unavailable"); return }
        io.async { [weak self] in
            do { try input.write(contentsOf: request.data) }
            catch {
                DispatchQueue.main.async {
                    guard let self, self.input === input else { return }
                    self.fail("Engine connection closed")
                }
            }
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else {
            fail("Invalid engine response")
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let reply = try? JSONDecoder().decode(BackendReply.self, from: line),
                  let request = active, request.id == reply.id else { continue }
            timeout?.cancel()
            timeout = nil
            active = nil
            if let status = reply.model_status { statusText = status }
            if reply.error != nil { statusText = "Engine error — dictionary fallback" }
            request.completion(reply)
            drain()
        }
    }

    private func fail(_ message: String) {
        statusText = message
        let callbacks = ([active].compactMap { $0 } + waiting).map(\.completion)
        active = nil
        waiting.removeAll()
        stopProcess()
        callbacks.forEach { $0(nil) }
    }

    private func stopProcess() {
        timeout?.cancel()
        timeout = nil
        output?.readabilityHandler = nil
        let child = process
        process = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        buffer.removeAll()
        if child?.isRunning == true { child?.terminate() }
    }

    func shutdown() {
        waiting.removeAll()
        active = nil
        stopProcess()
    }
}
