"""Pinyin lexicon, bounded sentence decoding, and local personal vocabulary."""

import functools
import importlib.metadata
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
            choices.sort(key=lambda item: item[0], reverse=True)
            unique, seen = [], set()
            for choice in choices:
                text = "".join(item[2].text for item in choice[1])
                if text not in seen:
                    unique.append(choice)
                    seen.add(text)
                    if len(unique) == width:
                        break
            if unique:
                beams[start] = unique
        return beams.get(0, [])


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
