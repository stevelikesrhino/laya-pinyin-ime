#!/usr/bin/env python3
"""Newline-delimited JSON backend for the native InputMethodKit client."""

import argparse
import json
import logging
import math
import os
import sys
import threading
from pathlib import Path

from dictionary import Dictionary, Personal, normalize


class Engine:
    def __init__(self):
        root = Path(__file__).resolve().parent.parent
        data = Path(os.environ.get("LAYA_DATA_DIR", str(
            Path.home() / "Library/Application Support/LayaIME"))).expanduser()
        bundled = root / "models/dictionary.sqlite3"
        dictionary = Path(os.environ.get("LAYA_DICTIONARY", str(
            bundled if bundled.is_file() else data / "dictionary.sqlite3"))).expanduser()
        self.dictionary = Dictionary(dictionary)
        self.personal = Personal(data / "personal.sqlite3")
        self.model = None
        self.model_error = None
        self.loading = True
        self.model_lock = threading.Lock()
        self.loader = threading.Thread(target=self._load_model, name="laya-model", daemon=True)
        self.loader.start()

    def _load_model(self):
        try:
            from laya_mlx import Laya

            model = Laya()
            # Compile/evaluate an actual choice before declaring the model ready.
            with self.model_lock:
                model.rank("我正在学习", ["中文", "忠文"])
                self.model = model
        except Exception as error:
            self.model_error = str(error)
            logging.warning("model unavailable, using dictionary: %s", error)
        finally:
            self.loading = False

    def model_status(self):
        if self.loading:
            return "loading ranking model; dictionary available"
        if self.model is not None:
            return "ranking model loaded"
        return "dictionary fallback: " + (self.model_error or "model unavailable")

    def _rank(self, context, words):
        # The model only needs rank(context, options) -> probabilities and a prior weight, alpha.
        if self.model is None or len(words) < 2:
            return words
        head = words[:9]
        try:
            with self.model_lock:
                probs = self.model.rank(context, [w.text for w in head])
            total = sum(word.freq for word in head)
            scores = [math.log(max(prob, 1e-12)) + self.model.alpha * math.log(word.freq / total)
                      for word, prob in zip(head, probs)]
            order = sorted(range(len(head)), key=lambda i: scores[i], reverse=True)
            return [head[i] for i in order] + words[9:]
        except Exception as error:
            self.model_error = str(error)
            self.model = None
            logging.warning("model inference failed, using dictionary: %s", error)
            return words

    def candidates(self, raw, context, limit, use_model=True, use_learning=True):
        key, offsets, breaks = normalize(raw)
        if not key:
            return []
        if len(key) > 128:
            raise ValueError("pinyin is limited to 128 letters")
        result, seen = [], set()

        def add(text, length):
            if text not in seen and len(result) < limit:
                result.append({"text": text, "consumed": offsets[length - 1]})
                seen.add(text)

        if use_learning and not breaks:
            for text, _ in self.personal.lookup(key):
                add(text, len(key))
        exact = [word for word in self.dictionary.exact(key) if word.accepts(breaks)]
        abbreviated = list(self.dictionary.abbreviated(key)) if not breaks else []
        initial = len(key) == 1 and key not in "aoe"
        if use_model:
            exact = self._rank(context, exact)
            if not exact or initial:
                abbreviated = self._rank(context, abbreviated)
        # A lone consonant is normally an initial, not a rare syllabic n/m reading.
        if initial:
            for word in abbreviated:
                add(word.text, len(key))
        for word in exact:
            add(word.text, len(key))

        # Prefer real dictionary completions over dubious concatenations of rare characters.
        for word in abbreviated:
            add(word.text, len(key))
        completed = [word for word in self.dictionary.complete(key) if word.accepts(breaks)]
        if use_model and not exact and not abbreviated:
            completed = self._rank(context, completed)
        for word in completed:
            add(word.text, len(key))

        sentences = self.dictionary.sentences(key, breaks)
        if sentences and len(sentences[0][1]) > 1 and use_model and self.model is not None:
            # The checkpoint ranks words, not entire sentences. Apply it at word boundaries.
            text, preceding = [], context
            for index, (start, end, word) in enumerate(sentences[0][1]):
                if index < 3:
                    inside = {p - start for p in breaks if start < p < end}
                    alternatives = [w for w in self.dictionary.exact(key[start:end]) if w.accepts(inside)]
                    alternatives = self._rank(preceding, alternatives)
                    if alternatives:
                        word = alternatives[0]
                text.append(word.text)
                preceding = (preceding + word.text)[-32:]
            add("".join(text), len(key))
        for _, path in sentences:
            add("".join(item[2].text for item in path), len(key))

        # Prefix candidates let the client commit a phrase and retain the unconsumed input.
        prefix_groups = {}
        for end, word in self.dictionary.matches(key, 0, breaks):
            if end < len(key):
                prefix_groups.setdefault(end, []).append(word)
        for end, words in prefix_groups.items():
            if use_learning and not breaks:
                for text, _ in self.personal.lookup(key[:end]):
                    add(text, end)
            for word in words:
                add(word.text, end)
        return result

    def handle(self, request):
        operation = request.get("op", "candidates")
        if operation == "candidates":
            raw, context = request.get("pinyin", ""), request.get("context", "")
            if not isinstance(raw, str) or not isinstance(context, str):
                raise ValueError("pinyin and context must be strings")
            limit = request.get("limit", 45)
            if not isinstance(limit, int) or isinstance(limit, bool):
                raise ValueError("limit must be an integer")
            candidates = self.candidates(raw, context, max(1, min(45, limit)),
                                         request.get("use_model", True) is not False,
                                         request.get("use_learning", True) is not False)
            return {"candidates": candidates, "model_status": self.model_status()}
        if operation == "learn":
            raw, text = request.get("pinyin", ""), request.get("text", "")
            if not isinstance(raw, str) or not isinstance(text, str):
                raise ValueError("pinyin and text must be strings")
            key, _, _ = normalize(raw)
            if not key or len(key) > 128 or not text or len(text) > 128:
                raise ValueError("invalid personal vocabulary entry")
            if request.get("use_learning", True) is not False:
                self.personal.learn(key, text)
            return {"ok": True, "persistent": self.personal.persistent, "model_status": self.model_status()}
        if operation == "status":
            return {"model_status": self.model_status(), "model_loaded": self.model is not None,
                    "dictionary_words": self.dictionary.word_count,
                    "personal_entries": self.personal.count(), "personal_persistent": self.personal.persistent}
        raise ValueError("unknown operation")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dictionary", metavar="PATH")
    args = parser.parse_args()
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING, format="%(levelname)s: %(message)s")
    if args.build_dictionary:
        Dictionary.build(args.build_dictionary)
        print(str(Path(args.build_dictionary).resolve()))
        return
    try:
        engine = Engine()
    except Exception as error:
        # Preserve the protocol on startup errors rather than writing a traceback to stdout.
        logging.error("backend startup failed: %s", error)
        engine = None
        startup_error = str(error)
    for line in sys.stdin:
        request = None
        try:
            if len(line) > 16384:
                raise ValueError("request is too large")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be a JSON object")
            if engine is None:
                response = {"candidates": [], "error": startup_error,
                            "model_status": "dictionary unavailable"}
            else:
                response = engine.handle(request)
        except Exception as error:
            response = {"candidates": [], "error": str(error),
                        "model_status": engine.model_status() if engine else "backend unavailable"}
        response["id"] = request.get("id") if isinstance(request, dict) else None
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
