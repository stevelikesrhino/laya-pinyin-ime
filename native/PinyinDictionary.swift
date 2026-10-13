import Foundation
import SQLite3

// In-process port of backend Engine.candidates(use_model=False), without the engine's multi-word
// phrases and last-syllable completion. Lookups take about a millisecond, so they run synchronously
// on the main thread; Python re-ranks and adds phrases.
final class PinyinDictionary {
    private struct Word {
        let text: String
        let freq: Int64
        let syllables: String

        func accepts(_ breaks: Set<Int>) -> Bool {
            if breaks.isEmpty { return true }
            var offsets = Set<Int>(), length = 0
            for syllable in syllables.split(separator: "'", omittingEmptySubsequences: false).dropLast() {
                length += syllable.unicodeScalars.count
                offsets.insert(length)
            }
            return breaks.isSubset(of: offsets)
        }
    }

    private typealias Step = (start: Int, end: Int, word: Word)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let db: OpaquePointer
    private let total: Double
    private let maxPinyin: Int
    private let exactQuery: OpaquePointer
    private let abbreviatedQuery: OpaquePointer
    private let completeQuery: OpaquePointer
    private let mixedQuery: OpaquePointer
    private var cache: [String: [Word]] = [:]
    private var fuzzyCache: [String: [Word]] = [:]
    private lazy var syllables: Set<String> = {
        var result = Set<String>()
        if let query = Self.prepare(db, "SELECT DISTINCT syllables FROM words WHERE instr(syllables, '''') = 0") {
            while sqlite3_step(query) == SQLITE_ROW { result.insert(Self.text(query, 0)) }
            sqlite3_finalize(query)
        }
        return result
    }()
    // Interjections without a vowel (hm, ng) do not absorb initials, nor are they spaced as syllables: nhm is n+h+m.
    private lazy var spellingPrefixes = Set(syllables.filter { $0.contains(where: "aeiouv".contains) }.flatMap {
        syllable in (1...syllable.count).map { String(syllable.prefix($0)) }
    })
    // Zero-initial syllables typed as their vowel: a for 安 in woaq, e for 而 in eq. Like an initial, a vowel does
    // not split a spelling: ha+o is hao, and wmaq is w+ma+q (wm'aq is w+m+a+q).
    private static let vowels: Set<String> = ["a", "e", "o"]
    private static let initials: Set<String> = ["b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q",
                                                "x", "zh", "ch", "sh", "r", "z", "c", "s", "y", "w"]
    private let personalPath: URL
    private var personal: OpaquePointer?
    private var personalQuery: OpaquePointer?

    init?(dictionary: URL, personal: URL) {
        personalPath = personal
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(dictionary.path)?mode=ro", &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        var meta: [String: String] = [:]
        if let query = Self.prepare(handle, "SELECT key,value FROM metadata") {
            while sqlite3_step(query) == SQLITE_ROW { meta[Self.text(query, 0)] = Self.text(query, 1) }
            sqlite3_finalize(query)
        }
        guard meta["version"] == "4", let total = Double(meta["total"] ?? ""), let maxPinyin = Int(meta["max_pinyin"] ?? ""),
              let exact = Self.prepare(handle, "SELECT text,freq,syllables FROM words WHERE pinyin=? ORDER BY freq DESC LIMIT 48"),
              let abbreviated = Self.prepare(handle, "SELECT text,freq,syllables FROM words WHERE abbr=? ORDER BY freq DESC LIMIT 45"),
              let complete = Self.prepare(handle, "SELECT text,freq,syllables FROM words WHERE pinyin>=? AND pinyin<? "
                                                  + "ORDER BY LENGTH(pinyin),freq DESC LIMIT 45"),
              let mixed = Self.prepare(handle, "SELECT text,freq,syllables FROM words WHERE abbr=? AND syllables GLOB ? "
                                               + "ORDER BY freq DESC LIMIT 45") else {
            sqlite3_close_v2(handle)
            return nil
        }
        self.total = total
        self.maxPinyin = maxPinyin
        exactQuery = exact
        abbreviatedQuery = abbreviated
        completeQuery = complete
        mixedQuery = mixed
    }

    deinit {
        for query in [exactQuery, abbreviatedQuery, completeQuery, mixedQuery, personalQuery] { sqlite3_finalize(query) }
        sqlite3_close_v2(personal)
        sqlite3_close_v2(db)
    }

    func candidates(_ raw: String, limit: Int, useLearning: Bool, fuzzy: Bool = false) -> [LayaCandidate] {
        guard let (key, offsets, breaks) = Self.normalize(raw), !key.isEmpty, key.count <= 128 else { return [] }
        var result: [LayaCandidate] = [], seen = Set<String>()
        func add(_ text: String, _ length: Int) {
            guard result.count < limit, seen.insert(text).inserted else { return }
            result.append(LayaCandidate(text: text, consumed: offsets[length - 1]))
        }
        let whole = String(decoding: key, as: UTF8.self)
        let personal = useLearning && breaks.isEmpty ? learned(whole) : []
        var exact = fuzzy ? fuzzyWords(key, breaks) : words(exactQuery, "e" + whole, whole).filter { $0.accepts(breaks) }
        var abbreviated = breaks.isEmpty ? abbreviatedWords(whole) : []
        var completed = words(completeQuery, "c" + whole, whole, whole + "{").filter { $0.accepts(breaks) }
        // A lone consonant is normally an initial, not a rare syllabic n/m reading.
        let initial = key.count == 1 && !"aoe".utf8.contains(key[0])
        var mixed = mixedWords(key, breaks)
        if !exact.isEmpty && !initial { exact = personalize(exact, personal) }
        else if !abbreviated.isEmpty { abbreviated = personalize(abbreviated, personal) }
        else if !completed.isEmpty || mixed.isEmpty { completed = personalize(completed, personal) }
        // Mixed input (zhwei): learned words compete with the words it spells, as the engine prices them.
        else { mixed = personalize(mixed, personal) }
        if initial {
            for word in abbreviated { add(word.text, key.count) }
        }
        for word in exact { add(word.text, key.count) }
        for word in abbreviated { add(word.text, key.count) }
        for word in mixed { add(word.text, key.count) }
        for word in completed { add(word.text, key.count) }
        for entry in personal { add(entry.text, key.count) }
        for (_, path) in sentences(key, breaks, fuzzy: fuzzy) {
            add(path.map(\.word.text).joined(), key.count)
        }
        // Prefix candidates let the client commit a phrase and retain the unconsumed input.
        var ends: [Int] = [], groups: [Int: [Word]] = [:]
        for (end, word) in matches(key, 0, breaks, fuzzy: fuzzy) where end < key.count {
            if groups[end] == nil { ends.append(end) }
            groups[end, default: []].append(word)
        }
        for end in ends {
            let personal = useLearning && breaks.isEmpty ? learned(String(decoding: key[..<end], as: UTF8.self)) : []
            for word in personalize(groups[end]!, personal) { add(word.text, end) }
        }
        // Keep page one intact, but leave room on later pages for less-used personal spellings.
        let tail = personal.filter { entry in !result.contains { $0.text == entry.text } }
            .prefix(max(0, limit - 9)).map { LayaCandidate(text: $0.text, consumed: offsets[key.count - 1]) }
        if !tail.isEmpty { result = Array(result.prefix(max(9, limit - tail.count))) + tail }
        return result
    }

    // Raw-string indices where the preedit should show a space between syllables ("nihao" -> [2]).
    func syllableSpaces(_ raw: String) -> Set<Int> {
        guard let (key, ends, breaks) = Self.normalize(raw), key.count > 1 else { return [] }
        // Fewest tokens wins; full syllables beat bare initials, which beat unknown letters.
        var best: [(cost: Double, cut: Int)] = Array(repeating: (.infinity, 0), count: key.count + 1)
        best[0] = (0, 0)
        for end in 1...key.count {
            for start in max(0, end - 6)..<end where best[start].cost < .infinity {
                if breaks.contains(where: { start < $0 && $0 < end }) { continue }
                let token = String(decoding: key[start..<end], as: UTF8.self)
                let cost: Double
                if syllables.contains(token) && token.contains(where: "aeiouv".contains) { cost = 1 }
                else if Self.initials.contains(token) { cost = 1.1 }
                else if end == key.count && spellingPrefixes.contains(token) { cost = 1.05 }
                else if end - start == 1 { cost = 2 }
                else { continue }
                if best[start].cost + cost < best[end].cost { best[end] = (best[start].cost + cost, start) }
            }
        }
        var spaces = Set<Int>(), position = best[key.count].cut
        while position > 0 {
            if !breaks.contains(position) { spaces.insert(ends[position - 1]) }
            position = best[position].cut
        }
        return spaces
    }

    private func abbreviatedWords(_ key: String) -> [Word] {
        var result = words(abbreviatedQuery, "a" + key, key)
        if ["zh", "ch", "sh"].contains(key) {
            // A lone digraph also reaches one-syllable words, alongside two-syllable abbreviations.
            result += words(mixedQuery, "i" + key, String(key.prefix(1)), key + "*")
            result.sort { $0.freq > $1.freq }
        }
        return result
    }

    private func personalize(_ words: [Word], _ learned: [(text: String, weight: Double)]) -> [Word] {
        guard !learned.isEmpty else { return words }
        // SQLite keys rows by bytes, Swift strings by canonical equivalence: two stored texts may collide here.
        let weights = Dictionary(learned.map { ($0.text, $0.weight) }, uniquingKeysWith: max)
        let maximum = words.map(\.freq).max() ?? 1
        let texts = Set(words.map(\.text))
        // A new personal word: each recent pick counts as twice the best word, fading to nothing as it ages.
        var boosted = learned.prefix(3).filter { !texts.contains($0.text) }.map {
            Word(text: $0.text, freq: max(1, Int64(2 * Double(maximum) * ($0.weight - 1))), syllables: "")
        }
        boosted += words.filter { weights[$0.text] != nil }.map {
            Word(text: $0.text, freq: max(1, Int64(Double($0.freq) * weights[$0.text]!)), syllables: $0.syllables)
        }
        // Unlearned completions keep their shortest-spelling-first order.
        var result = words.filter { weights[$0.text] == nil }
        for word in boosted.sorted(by: { $0.freq > $1.freq }) {
            let index = result.firstIndex { $0.freq < word.freq } ?? result.count
            result.insert(word, at: index)
        }
        return result
    }

    // Mixed full and abbreviated syllables, e.g. zhgr or zgren for 中国人.
    private func mixedWords(_ key: [UInt8], _ breaks: Set<Int>) -> [Word] {
        var result: [Word] = [], seen = Set<String>()
        let extends = { (token: String) in Self.initials.contains(token) || Self.vowels.contains(token) }
        for tokens in tokenizations(key, breaks)
        where tokens.count > 1 && tokens.contains(where: extends) && !tokens.allSatisfy({ $0.count == 1 && extends($0) }) {
            let abbr = tokens.map { String($0.prefix(1)) }.joined()
            let pattern = tokens.map { extends($0) ? $0 + "*" : $0 }.joined(separator: "'")
            for word in words(mixedQuery, "m" + pattern, abbr, pattern) where seen.insert(word.text).inserted {
                result.append(word)
            }
        }
        result.sort { $0.freq > $1.freq }
        return Array(result.prefix(45))
    }

    // Splits into syllables, bare initials and vowels. An initial or vowel must not be the start of a longer
    // spelling: s+h is sh, xia+n is xian, zh+ang is zhang, ha+o is hao.
    private func tokenizations(_ key: [UInt8], _ breaks: Set<Int>) -> [[String]] {
        var memo: [String: [[String]]] = [:]
        func from(_ start: Int, after previous: String) -> [[String]] {
            if start == key.count { return [[]] }
            let memoKey = "\(start)|\(previous)"
            if let done = memo[memoKey] { return done }
            var result: [[String]] = []
            // Longest token first, up to the next apostrophe: ha|o or xi|a|ng would fill the cap on long keys.
            let stop = min(key.count, start + 6, breaks.filter { $0 > start }.min() ?? key.count)
            for end in stride(from: stop, to: start, by: -1) {
                let token = String(decoding: key[start..<end], as: UTF8.self)
                let initial = Self.initials.contains(token) || Self.vowels.contains(token)
                let next = end < key.count ? String(UnicodeScalar(key[end])) : ""
                // An apostrophe ends the spelling: xia'n is xia+n.
                if initial ? (previous.isEmpty || breaks.contains(start) || !spellingPrefixes.contains(previous + token))
                                 && (next.isEmpty || breaks.contains(end) || !spellingPrefixes.contains(token + next))
                           : syllables.contains(token) {
                    for rest in from(end, after: token) where result.count < 8 { result.append([token] + rest) }
                }
            }
            memo[memoKey] = result
            return result
        }
        return from(0, after: "")
    }

    // Return ASCII pinyin, original-string offsets, and explicit syllable breaks.
    private static func normalize(_ raw: String) -> ([UInt8], [Int], Set<Int>)? {
        let chars = Array(raw)
        var letters: [UInt8] = [], ends: [Int] = [], boundaries = Set<Int>()
        var i = 0
        while i < chars.count {
            var char = chars[i].lowercased()
            if char == "u" && i + 1 < chars.count && chars[i + 1] == ":" {
                char = "v"
                i += 1
            }
            if char == "ü" { char = "v" }
            if char.count == 1, let byte = char.utf8.first, char.utf8.count == 1, (97...122).contains(byte) {
                letters.append(byte)
                ends.append(i + 1)
            } else if char == "'" || char == "’" || char == " " {
                if !letters.isEmpty {
                    boundaries.insert(letters.count)
                    ends[ends.count - 1] = i + 1
                }
            } else {
                return nil
            }
            i += 1
        }
        boundaries.remove(letters.count)
        // ü has no key: lue and nue spell lüe (略), and jv, qv, xv, yv spell ju, qu, xu, yu. Not across an apostrophe.
        let (j, l, n, q, u, v, x, y, e) = (UInt8(ascii: "j"), UInt8(ascii: "l"), UInt8(ascii: "n"), UInt8(ascii: "q"),
                                           UInt8(ascii: "u"), UInt8(ascii: "v"), UInt8(ascii: "x"), UInt8(ascii: "y"),
                                           UInt8(ascii: "e"))
        for i in letters.indices.dropFirst() where !boundaries.contains(i) {
            if letters[i] == v && [j, q, x, y].contains(letters[i - 1]) {
                letters[i] = u
            } else if letters[i] == u && [n, l].contains(letters[i - 1]) && i + 1 < letters.count
                        && letters[i + 1] == e && !boundaries.contains(i + 1) {
                letters[i] = v
            }
        }
        return (letters, ends, boundaries)
    }

    private func words(_ query: OpaquePointer, _ cacheKey: String, _ arguments: String...) -> [Word] {
        if let words = cache[cacheKey] { return words }
        sqlite3_reset(query)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(query, Int32(index + 1), argument, -1, Self.transient)
        }
        var words: [Word] = [], status = sqlite3_step(query)
        while status == SQLITE_ROW {
            words.append(Word(text: Self.text(query, 0), freq: sqlite3_column_int64(query, 1),
                              syllables: Self.text(query, 2)))
            status = sqlite3_step(query)
        }
        sqlite3_reset(query)
        // A failed step returns a truncated list; serve it once but never cache it.
        guard status == SQLITE_DONE else { return words }
        if cache.count >= 16384 { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = words
        return words
    }

    private func matches(_ key: [UInt8], _ start: Int, _ breaks: Set<Int>, fuzzy: Bool = false) -> [(Int, Word)] {
        var result: [(Int, Word)] = []
        for end in stride(from: min(key.count, start + maxPinyin), to: start, by: -1) {
            let inside = Set(breaks.filter { start < $0 && $0 < end }.map { $0 - start })
            if fuzzy {
                for word in fuzzyWords(Array(key[start..<end]), inside).prefix(9) { result.append((end, word)) }
                continue
            }
            let piece = String(decoding: key[start..<end], as: UTF8.self)
            for word in words(exactQuery, "e" + piece, piece).prefix(9) where word.accepts(inside) {
                result.append((end, word))
            }
        }
        return result
    }

    // Exact words plus fuzzy-pinyin readings (z/zh, c/ch, s/sh, n/l, an/ang, en/eng, in/ing).
    // Fuzzy readings take a 1/100 frequency penalty, the same as rare heteronym readings.
    private func fuzzyWords(_ piece: [UInt8], _ breaks: Set<Int>) -> [Word] {
        let whole = String(decoding: piece, as: UTF8.self)
        let cacheKey = whole + "|" + breaks.sorted().map(String.init).joined(separator: ",")
        if let words = fuzzyCache[cacheKey] { return words }
        var result = words(exactQuery, "e" + whole, whole).filter { $0.accepts(breaks) }
        var seen = Set(result.map(\.text))
        for segmentation in segmentations(piece, breaks) {
            var spellings: [[String]] = [[]]
            for syllable in segmentation {
                spellings = Array(spellings.lazy.flatMap { head in self.variants(syllable).map { head + [$0] } }.prefix(16))
            }
            for spelling in spellings where spelling != segmentation {
                let joined = spelling.joined(), reading = spelling.joined(separator: "'")
                for word in words(exactQuery, "e" + joined, joined)
                where word.syllables == reading && seen.insert(word.text).inserted {
                    result.append(Word(text: word.text, freq: max(1, word.freq / 100), syllables: word.syllables))
                }
            }
        }
        result.sort { $0.freq > $1.freq }
        result = Array(result.prefix(48))
        if fuzzyCache.count >= 16384 { fuzzyCache.removeAll(keepingCapacity: true) }
        fuzzyCache[cacheKey] = result
        return result
    }

    // Splits into known syllables that place a boundary at every explicit break.
    private func segmentations(_ piece: [UInt8], _ breaks: Set<Int>) -> [[String]] {
        var memo: [Int: [[String]]] = [piece.count: [[]]]
        func from(_ start: Int) -> [[String]] {
            if let done = memo[start] { return done }
            var result: [[String]] = []
            for end in (start + 1)...min(piece.count, start + 6) {
                let syllable = String(decoding: piece[start..<end], as: UTF8.self)
                if syllables.contains(syllable) {
                    for rest in from(end) where result.count < 8 { result.append([syllable] + rest) }
                }
                if breaks.contains(end) { break }
            }
            memo[start] = result
            return result
        }
        return from(0)
    }

    private func variants(_ syllable: String) -> [String] {
        var heads = [syllable]
        for (long, short) in [("zh", "z"), ("ch", "c"), ("sh", "s"), ("n", "l")] {
            if syllable.hasPrefix(long) { heads.append(short + syllable.dropFirst(long.count)) }
            else if syllable.hasPrefix(short) { heads.append(long + syllable.dropFirst(short.count)) }
        }
        var result: [String] = []
        for head in heads {
            result.append(head)
            if ["ang", "eng", "ing"].contains(where: head.hasSuffix) { result.append(String(head.dropLast())) }
            else if ["an", "en", "in"].contains(where: head.hasSuffix) { result.append(head + "g") }
        }
        return result.filter { $0 == syllable || syllables.contains($0) }
    }

    // A unigram word lattice, not a generative model. Keep alternative segmentations.
    private func sentences(_ key: [UInt8], _ breaks: Set<Int>, fuzzy: Bool = false, width: Int = 6) -> [(Double, [Step])] {
        var beams: [Int: [(Double, [Step])]] = [key.count: [(0, [])]]
        for start in stride(from: key.count - 1, through: 0, by: -1) {
            var choices: [(Double, [Step])] = []
            for (end, word) in matches(key, start, breaks, fuzzy: fuzzy) {
                guard let rests = beams[end] else { continue }
                let score = log(Double(word.freq) / total)
                for (restScore, rest) in rests {
                    choices.append((score + restScore, [(start, end, word)] + rest))
                }
            }
            // Stable descending sort, matching Python's sort(reverse=True).
            choices.sort { $0.0 > $1.0 }
            var unique: [(Double, [Step])] = [], seen = Set<String>()
            for choice in choices where seen.insert(choice.1.map(\.word.text).joined()).inserted {
                unique.append(choice)
                if unique.count == width { break }
            }
            if !unique.isEmpty { beams[start] = unique }
        }
        return beams[0] ?? []
    }

    // Remove a learned entry; the only write the client makes to the backend's personal.sqlite3.
    func forget(_ raw: String, text: String) -> Bool {
        guard let (key, _, _) = Self.normalize(raw), !key.isEmpty else { return false }
        _ = learned("")  // opens the store if it exists
        guard let personal else { return false }
        sqlite3_exec(personal, "PRAGMA query_only=0", nil, nil, nil)
        defer { sqlite3_exec(personal, "PRAGMA query_only=1", nil, nil, nil) }
        guard let query = Self.prepare(personal, "DELETE FROM learned WHERE pinyin=? AND text=?") else { return false }
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, String(decoding: key, as: UTF8.self), -1, Self.transient)
        sqlite3_bind_text(query, 2, text, -1, Self.transient)
        return sqlite3_step(query) == SQLITE_DONE && sqlite3_changes(personal) > 0
    }

    // personal.sqlite3 belongs to the Python backend; read it, and only once it exists.
    private func learned(_ key: String) -> [(text: String, weight: Double)] {
        if personalQuery == nil {
            guard FileManager.default.fileExists(atPath: personalPath.path) else { return [] }
            // Read-write without CREATE so a missing file stays missing; query_only forbids writes.
            var handle: OpaquePointer?
            if sqlite3_open_v2("file:\(personalPath.path)?mode=rw", &handle,
                               SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle,
               sqlite3_exec(handle, "PRAGMA query_only=1", nil, nil, nil) == SQLITE_OK,
               let query = Self.prepare(handle, "SELECT text,1.0+MIN(count,7)/(1.0+MAX(0,?-updated)/(30.0*24*60*60)) AS weight "
                                                + "FROM learned WHERE pinyin=? ORDER BY weight DESC,updated DESC LIMIT 45") {
                sqlite3_busy_timeout(handle, 50)
                personal = handle
                personalQuery = query
            } else {
                sqlite3_close_v2(handle)
                return []
            }
        }
        guard let query = personalQuery else { return [] }
        sqlite3_reset(query)
        sqlite3_bind_double(query, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(query, 2, key, -1, Self.transient)
        var entries: [(text: String, weight: Double)] = []
        while sqlite3_step(query) == SQLITE_ROW { entries.append((Self.text(query, 0), sqlite3_column_double(query, 1))) }
        sqlite3_reset(query)
        return entries
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var query: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK ? query : nil
    }

    private static func text(_ query: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(query, column).map { String(cString: $0) } ?? ""
    }
}
