"""Pinyin lexicon, bounded sentence decoding, and local personal vocabulary."""

import functools
import importlib.metadata
import itertools
import logging
import math
import os
import re
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

CHINESE = re.compile(r"^[\u3400-\u9fff]+$")
CACHE_VERSION = "4"
# Keep in step with PinyinDictionary.swift.
INITIALS = frozenset(("b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
                      "zh", "ch", "sh", "r", "z", "c", "s", "y", "w"))
# Zero-initial syllables typed as their vowel: a for 安 in woaq, e for 而 in eq. Like an initial, a vowel does not
# split a spelling: ha+o is hao, and wmaq is w+ma+q (wm'aq is w+m+a+q).
VOWELS = frozenset("aeo")
# Mixed phrases: syllables per word, words per spelling (for the unigram lattice, and for the model-guided search,
# which can afford more), letters per key, and the log-prior cost of each syllable typed as an initial or vowel.
PHRASE_SPAN = 4
PHRASE_WORDS = 9
PROPOSAL_WORDS = 16
PHRASE_LETTERS = 32
INITIAL_COST = 1.0
# The last syllable may still be incomplete (ha for 好, qio for 穷): the log-prior cost of reading it so, after
# Rime's kCompletionPenalty.
COMPLETION_COST = 3.0


def normalize(raw):
    """Return ASCII pinyin, original-string offsets, and explicit syllable breaks."""
    letters, ends, boundaries = [], [], set()
    i = 0
    while i < len(raw):
        char = raw[i].lower()
        if char == "u" and i + 1 < len(raw) and raw[i + 1] == ":":
            char = "v"
            i += 1
        if char == "ü":
            char = "v"
        if "a" <= char <= "z":
            letters.append(char)
            ends.append(i + 1)
        elif char in "'’ ":
            if letters:
                boundaries.add(len(letters))
                ends[-1] = i + 1
        else:
            raise ValueError("pinyin must contain Latin letters or syllable separators")
        i += 1
    boundaries.discard(len(letters))
    # ü has no key: lue and nue spell lüe (略), and jv, qv, xv, yv spell ju, qu, xu, yu. Not across an apostrophe.
    for i in range(1, len(letters)):
        if i in boundaries:
            continue
        if letters[i] == "v" and letters[i - 1] in "jqxy":
            letters[i] = "u"
        elif letters[i] == "u" and letters[i - 1] in "nl" and letters[i + 1:i + 2] == ["e"] and i + 1 not in boundaries:
            letters[i] = "v"
    return "".join(letters), ends, boundaries


@dataclass(frozen=True)
class Word:
    text: str
    freq: int
    syllables: str

    def accepts(self, breaks):
        if not breaks:
            return True
        offsets, length = set(), 0
        for syllable in self.syllables.split("'")[:-1]:
            length += len(syllable)
            offsets.add(length)
        return breaks.issubset(offsets)


class Dictionary:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self.build(self.path)
        self.db = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)
        meta = dict(self.db.execute("SELECT key,value FROM metadata"))
        if meta.get("version") != CACHE_VERSION:
            raise ValueError("unsupported dictionary cache version; rebuild dictionary")
        self.total = int(meta["total"])
        self.word_count = int(meta["count"])
        self.max_pinyin = int(meta["max_pinyin"])

    @staticmethod
    def build(path):
        import jieba
        from pypinyin import Style, lazy_pinyin, pinyin

        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
        db = sqlite3.connect(temporary)
        try:
            db.executescript("""
                CREATE TABLE words (
                    pinyin TEXT NOT NULL, text TEXT NOT NULL, freq INTEGER NOT NULL,
                    syllables TEXT NOT NULL, abbr TEXT NOT NULL,
                    PRIMARY KEY (pinyin,text)
                ) WITHOUT ROWID;
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            rows = []
            source = Path(jieba.__file__).parent / "dict.txt"
            with source.open(encoding="utf-8") as lines:
                for line in lines:
                    text, freq, *_ = line.split()
                    if not CHINESE.fullmatch(text) or len(text) > 12:
                        continue
                    freq = max(1, int(freq))
                    if len(text) == 1:
                        readings = [[syllable] for syllable in pinyin(text, style=Style.NORMAL, heteronym=True)[0]]
                    else:
                        readings = [lazy_pinyin(text, style=Style.NORMAL)]
                    for index, reading in enumerate(readings):
                        key = "".join(reading).replace("ü", "v")
                        if not key.isascii() or not key.isalpha():
                            continue
                        # Rare alternate character readings must not inherit the common reading's prior.
                        reading_freq = freq if index == 0 else max(1, freq // 100)
                        rows.append((key, text, reading_freq, "'".join(reading), "".join(s[0] for s in reading)))
                    if len(rows) >= 4096:
                        db.executemany("INSERT OR IGNORE INTO words VALUES (?,?,?,?,?)", rows)
                        rows.clear()
            db.executemany("INSERT OR IGNORE INTO words VALUES (?,?,?,?,?)", rows)
            # Jieba is a segmentation lexicon: common conversational phrases are underrepresented.
            phrases = {"你好": 5000, "你好吗": 3000, "您好": 3000, "谢谢": 5000,
                       "再见": 3000, "对不起": 3000, "没关系": 2000, "我爱你": 2000,
                       "早上好": 1500, "晚上好": 1500, "中国人": 3000,
                       "拼音输入法": 1000, "中文输入法": 1000}
            for text, freq in phrases.items():
                reading = lazy_pinyin(text, style=Style.NORMAL)
                db.execute("""INSERT INTO words VALUES (?,?,?,?,?)
                    ON CONFLICT(pinyin,text) DO UPDATE SET freq=MAX(freq,excluded.freq)""",
                           ("".join(reading), text, freq, "'".join(reading), "".join(s[0] for s in reading)))
            db.execute("CREATE INDEX words_abbr ON words(abbr)")
            count, total, maximum = db.execute("SELECT COUNT(*),SUM(freq),MAX(LENGTH(pinyin)) FROM words").fetchone()
            metadata = {"version": CACHE_VERSION, "count": str(count), "total": str(total),
                        "max_pinyin": str(maximum), "jieba": importlib.metadata.version("jieba"),
                        "pypinyin": importlib.metadata.version("pypinyin")}
            db.executemany("INSERT INTO metadata VALUES (?,?)", metadata.items())
            db.commit()
            db.close()
            temporary.replace(path)
        except Exception:
            db.close()
            temporary.unlink(missing_ok=True)
            raise

    @functools.lru_cache(maxsize=8192)
    def exact(self, key):
        rows = self.db.execute(
            "SELECT text,freq,syllables FROM words WHERE pinyin=? ORDER BY freq DESC LIMIT 48", (key,),
        )
        return tuple(Word(*row) for row in rows)

    @functools.lru_cache(maxsize=2048)
    def abbreviated(self, key):
        rows = self.db.execute(
            "SELECT text,freq,syllables FROM words WHERE abbr=? ORDER BY freq DESC LIMIT 45", (key,),
        )
        return tuple(Word(*row) for row in rows)

    @functools.lru_cache(maxsize=2048)
    def complete(self, key):
        # Indexed range rather than LIKE: this stays fast for short, frequent prefixes.
        rows = self.db.execute(
            "SELECT text,freq,syllables FROM words WHERE pinyin>=? AND pinyin<? "
            "ORDER BY LENGTH(pinyin),freq DESC LIMIT 45", (key, key + "{"),
        )
        return tuple(Word(*row) for row in rows)

    @functools.lru_cache(maxsize=8192)
    def spelled(self, abbr, pattern, limit=PHRASE_WORDS):
        # Words whose syllables match a typed spelling: full syllables literal, initials as zh*, d* ...
        rows = self.db.execute(
            "SELECT text,freq,syllables FROM words WHERE abbr=? AND syllables GLOB ? ORDER BY freq DESC LIMIT ?",
            (abbr, pattern, limit),
        )
        return tuple(Word(*row) for row in rows)

    @functools.cached_property
    def syllables(self):
        return frozenset(row[0] for row in self.db.execute(
            "SELECT DISTINCT syllables FROM words WHERE instr(syllables, '''') = 0"))

    @functools.cached_property
    def syllable_prefixes(self):
        # Interjections without a vowel (hm, ng) do not absorb initials: nhm is n+h+m.
        return frozenset(syllable[:end] for syllable in self.syllables if any(v in syllable for v in "aeiouv")
                         for end in range(1, len(syllable) + 1))

    @functools.cached_property
    def partial(self):
        # Proper prefixes of syllables (ha of hao, qio of qiong): what the last token may still become.
        return frozenset(syllable[:end] for syllable in self.syllables if any(v in syllable for v in "aeiouv")
                         for end in range(1, len(syllable)))

    def extends(self, token, final):
        # Whether a token may stand for more than its letters: an initial, a vowel, or the last token while its
        # syllable may still be being typed (ha for hao).
        return token in INITIALS or token in VOWELS or (final and token in self.partial)

    def mixed(self, tokens):
        # Whether a tokenization belongs to the phrase stage: some token is extended. One token is a plain lookup,
        # and full pinyin is sentences().
        return len(tokens) > 1 and any(self.extends(token, k == len(tokens) - 1) for k, token in enumerate(tokens))

    def words(self, span, final, limit=PHRASE_WORDS):
        # Words spelling a run of tokens, each with the cost of the tokens it extends: 0 where the syllable is the
        # token (哈 for ha), INITIAL_COST for an initial and for any vowel (啊 or 安 for a, so that ay is 奥运 rather
        # than 啊哟), COMPLETION_COST for a completed last syllable.
        last, abbr = len(span) - 1, "".join(token[0] for token in span)
        tokens = [token + "*" if self.extends(token, final and k == last) else token for k, token in enumerate(span)]
        found = self.spelled(abbr, "'".join(tokens), limit)
        if tokens[-1] != span[-1] and span[-1] in self.syllables and span[-1] not in INITIALS:
            # The syllable as typed (哈 for ha) must not be crowded out of the limit by what it may become (好 还 号).
            found = tuple(dict.fromkeys(self.spelled(abbr, "'".join(tokens[:-1] + [span[-1]]), limit) + found))
        for word in found:
            cost = 0.0
            for token, syllable in zip(span, word.syllables.split("'")):
                if token in VOWELS:
                    cost += INITIAL_COST
                elif syllable != token:
                    cost += INITIAL_COST if token in INITIALS else COMPLETION_COST
            yield word, cost

    def tokenizations(self, key, breaks):
        # Splits into syllables, bare initials and vowels, at most 8 ways; the last token may be the start of a
        # syllable (qio). An initial or vowel must not be the start of a longer spelling: s+h is sh, xia+n is xian,
        # zh+ang is zhang, ha+o is hao.
        memo = {}

        def split(start, previous):
            if start == len(key):
                return [[]]
            if (start, previous) not in memo:
                result = []
                # Longest token first, up to the next apostrophe: ha|o or xi|a|ng would fill the cap on long keys.
                stop = min([len(key), start + 6] + [b for b in breaks if b > start])
                for end in range(stop, start, -1):
                    token, following = key[start:end], key[end:end + 1]
                    if token in INITIALS or token in VOWELS:
                        # An apostrophe ends the spelling: xia'n is xia+n.
                        fits = (not previous or start in breaks or previous + token not in self.syllable_prefixes) \
                            and (not following or end in breaks or token + following not in self.syllable_prefixes)
                    else:
                        fits = token in self.syllables or (end == len(key) and token in self.partial)
                    if fits:
                        result.extend([token] + rest for rest in split(end, token)[:8 - len(result)])
                memo[start, previous] = result
            return memo[start, previous]

        return split(0, "")

    def phrases(self, key, breaks, width=6):
        # Whole-key phrases from full syllables and initials (zuihdwd -> 最好的味道): a unigram lattice over each
        # way of splitting the key, scored by unigram frequency less the costs of words(). Steps are (start, end,
        # word), as in sentences().
        if len(key) > PHRASE_LETTERS:
            return []
        paths = []
        for tokens in self.tokenizations(key, breaks):
            if not self.mixed(tokens):
                continue
            ends = list(itertools.accumulate(map(len, tokens)))
            starts = [0] + ends[:-1]
            beams = {len(tokens): [(0.0, [])]}
            for i in range(len(tokens) - 1, -1, -1):
                choices = []
                for j in range(i + 1, min(len(tokens), i + PHRASE_SPAN) + 1):
                    if j not in beams:
                        continue
                    for word, cost in self.words(tokens[i:j], j == len(tokens)):
                        score = math.log(word.freq / self.total) - cost
                        choices.extend((score + rest_score, [(starts[i], ends[j - 1], word)] + rest)
                                       for rest_score, rest in beams[j])
                if choices:
                    beams[i] = _distinct(choices, width)
            paths.extend(beams.get(0, []))
        return _distinct(paths, width)

    def lattice(self, key, breaks, limit=PROPOSAL_WORDS):
        # The phrase lattice over letter positions, merged across tokenizations: edges[start] lists (end, score,
        # word) with the unigram score of phrases(); future[position] is the best score to the end from there and
        # depth[position] the fewest words. Empty when the key has no mixed tokenization.
        edges = {}
        if len(key) > PHRASE_LETTERS:
            return edges, {}, {}
        for tokens in self.tokenizations(key, breaks):
            if not self.mixed(tokens):
                continue
            ends = list(itertools.accumulate(map(len, tokens)))
            starts = [0] + ends[:-1]
            for i in range(len(tokens)):
                for j in range(i + 1, min(len(tokens), i + PHRASE_SPAN) + 1):
                    for word, cost in self.words(tokens[i:j], j == len(tokens), limit):
                        score = math.log(word.freq / self.total) - cost
                        at = edges.setdefault(starts[i], {})
                        if (ends[j - 1], word.text) not in at or at[ends[j - 1], word.text][0] < score:
                            at[ends[j - 1], word.text] = (score, word)
        edges = {start: [(end, score, word) for (end, _), (score, word) in at.items()]
                 for start, at in edges.items()}
        future, depth = {len(key): 0.0}, {len(key): 0}
        for position in range(len(key) - 1, -1, -1):
            reached = [(score + future[end], depth[end] + 1) for end, score, _ in edges.get(position, ())
                       if end in future]
            if reached:
                future[position] = max(score for score, _ in reached)
                depth[position] = min(words for _, words in reached)
        return edges, future, depth

    def matches(self, key, start, breaks):
        for end in range(min(len(key), start + self.max_pinyin), start, -1):
            inside = {p - start for p in breaks if start < p < end}
            for word in self.exact(key[start:end])[:9]:
                if word.accepts(inside):
                    yield end, word

    def sentences(self, key, breaks, width=6):
        # A unigram word lattice, not a generative model. Keep alternative segmentations.
        beams = {len(key): [(0.0, [])]}
        for start in range(len(key) - 1, -1, -1):
            choices = []
            for end, word in self.matches(key, start, breaks):
                if end not in beams:
                    continue
                score = math.log(word.freq / self.total)
                for rest_score, rest in beams[end]:
                    choices.append((score + rest_score, [(start, end, word)] + rest))
            if choices:
                beams[start] = _distinct(choices, width)
        return beams.get(0, [])


def _distinct(paths, width):
    # The best (score, steps) path for each text.
    unique, seen = [], set()
    for path in sorted(paths, key=lambda item: item[0], reverse=True):
        text = "".join(step[-1].text for step in path[1])
        if text not in seen:
            unique.append(path)
            seen.add(text)
            if len(unique) == width:
                break
    return unique


class Personal:
    def __init__(self, path):
        self.persistent = True
        try:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            self.db = sqlite3.connect(path)
            self.db.execute("PRAGMA busy_timeout=1000")
            self.db.execute("PRAGMA journal_mode=WAL")
            self._schema()
        except (OSError, sqlite3.Error) as error:
            logging.warning("personal dictionary is not writable: %s", error)
            self.persistent = False
            self.db = sqlite3.connect(":memory:")
            self._schema()

    def _schema(self):
        self.db.execute("""CREATE TABLE IF NOT EXISTS learned (
            pinyin TEXT NOT NULL, text TEXT NOT NULL, count INTEGER NOT NULL,
            updated REAL NOT NULL, PRIMARY KEY(pinyin,text)
        ) WITHOUT ROWID""")
        self.db.commit()

    def learn(self, key, text):
        self.db.execute("""INSERT INTO learned VALUES (?,?,1,?)
            ON CONFLICT(pinyin,text) DO UPDATE SET count=count+1,updated=excluded.updated""",
                        (key, text, time.time()))
        self.db.commit()

    def lookup(self, key):
        return self.db.execute(
            "SELECT text,count FROM learned WHERE pinyin=? ORDER BY count DESC,updated DESC LIMIT 45", (key,),
        ).fetchall()

    def count(self):
        return self.db.execute("SELECT COUNT(*) FROM learned").fetchone()[0]
