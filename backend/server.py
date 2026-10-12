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

from dictionary import INITIAL_COST, Dictionary, Personal, normalize

# Candidates the model re-ranks, by list. Wider windows put more of the right words on page 1 once the model is
# trained on that many options; the rest keep dictionary order. abbreviated() returns at most 45, so all of it is
# ranked. Completions were not evaluated beyond 9.
EXACT_WINDOW = 32
ABBREVIATED_WINDOW = 45
COMPLETION_WINDOW = 9
# Phrases composed for mixed input that the model ranks as whole options in one call, and how many may go before the
# best whole-key word (and after it, when that word is abbreviated or completed).
PHRASE_WINDOW = 16
PHRASE_SHOWN = 3
# The model-guided phrase search: hypotheses expanded per round (one batched model call), rounds (so words per
# phrase), proposals added to the phrase pool, and the finished count past which no better-bounded round is run.
PROPOSAL_BEAM = 3
PROPOSAL_ROUNDS = 3
PROPOSAL_KEEP = 8
PROPOSAL_STOP = 4


def next_words(edges, future, position):
    # One step of the phrase search: the lattice words at a letter position that can still finish the key, and each
    # distinct text's best unigram score, the options and priors the model ranks.
    words = [(end, unigram, word) for end, unigram, word in edges.get(position, ()) if end in future]
    priors = {}
    for _, unigram, word in words:
        priors[word.text] = max(unigram, priors.get(word.text, unigram))
    return words, priors


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

    def _rank(self, context, words, window):
        # The model only needs rank(context, options) -> probabilities and a prior weight, alpha.
        if self.model is None or len(words) < 2:
            return words
        # Heteronyms can list a text more than once; rank each text once, as in training, keeping its first entry.
        unique = {}
        for word in words:
            unique.setdefault(word.text, word)
        words = list(unique.values())
        head = words[:window]
        try:
            total = sum(word.freq for word in head)
            priors = [math.log(word.freq / total) for word in head]
            probs, = self._ask("word", [(context, [w.text for w in head], priors)])
            alpha = self._alpha("word")
            scores = [math.log(max(prob, 1e-12)) + alpha * prior for prob, prior in zip(probs, priors)]
            order = sorted(range(len(head)), key=lambda i: scores[i], reverse=True)
            return [head[i] for i in order] + words[window:]
        except Exception as error:
            self.model_error = str(error)
            self.model = None
            logging.warning("model inference failed, using dictionary: %s", error)
            return words

    def _ask(self, kind, requests):
        # Every model call: (context, texts, priors) per request -> probabilities. kind is "word", "phrase" or "step";
        # the training data generator overrides this to record what the model is shown. Models without rank_many
        # (the test stand-in) answer one request at a time.
        with self.model_lock:
            if len(requests) > 1 and hasattr(self.model, "rank_many"):
                return self.model.rank_many([(context, texts) for context, texts, _ in requests])
            return [self.model.rank(context, texts) for context, texts, _ in requests]

    def _alpha(self, kind):
        # A checkpoint may weigh the prior per kind of call; alpha otherwise.
        return getattr(self.model, "alphas", {}).get(kind, self.model.alpha)

    def _propose(self, context, key, breaks):
        # Phrases the unigram lattice cannot reach because a frequent word crowds out the one the context wants
        # (zuihdwd after 我们相信: every 最后... outranks 最好的味道). A beam search over the lattice, left to right,
        # where the model ranks the words that can follow each hypothesis in its context. Hypotheses are ordered by
        # their score plus alpha times the best unigram completion, a bound on any phrase they can become; once
        # PROPOSAL_STOP finished phrases beat the best bound, the search stops (no further round could reach that top).
        edges, future, depth = self.dictionary.lattice(key, breaks)
        if depth.get(0, PROPOSAL_ROUNDS + 1) > PROPOSAL_ROUNDS:
            return {}
        alpha = self._alpha("step")
        # Open hypotheses by (position, text): (bound, score, prior). Finished phrases by text: (score, prior).
        open_ = {(0, ""): (alpha * future[0], 0.0, 0.0)}
        finished = {}
        for _ in range(PROPOSAL_ROUNDS):
            ranked = sorted(open_, key=open_.get, reverse=True)
            if not ranked or (len(finished) >= PROPOSAL_STOP and open_[ranked[0]][0]
                              < sorted(finished.values(), reverse=True)[PROPOSAL_STOP - 1][0]):
                break
            batch = [(position, text, open_.pop((position, text))) for position, text in ranked[:PROPOSAL_BEAM]]
            steps = [next_words(edges, future, position) for position, _, _ in batch]
            requests = [(context + text, list(priors), list(priors.values()))
                        for (_, text, _), (_, priors) in zip(batch, steps)]
            for (_, text, (_, score, prior)), (words, _), (_, texts, _), probs in zip(
                    batch, steps, requests, self._ask("step", requests)):
                logp = dict(zip(texts, (math.log(max(p, 1e-12)) for p in probs)))
                for end, unigram, word in words:
                    phrase, scored = text + word.text, (score + logp[word.text] + alpha * unigram, prior + unigram)
                    if end == len(key):
                        if phrase not in finished or finished[phrase] < scored:
                            finished[phrase] = scored
                    elif (end, phrase) not in open_ or open_[end, phrase][1] < scored[0]:
                        open_[end, phrase] = (scored[0] + alpha * future[end],) + scored
        best = sorted(finished.items(), key=lambda item: item[1], reverse=True)[:PROPOSAL_KEEP]
        return {text: prior for text, (_, prior) in best}

    def _phrases(self, context, key, breaks, use_model, top):
        # Whole-key phrases for input mixing full syllables and initials (zuihdwd), best first, ranked together with
        # the best whole-key word (top: text and log prior) if there is one. The model ranks them as whole options, as
        # it does abbreviated words; if it fails, the prior order stands.
        paths = self.dictionary.phrases(key, breaks, PHRASE_WINDOW)
        if not paths:
            return []
        priors = {"".join(step[-1].text for step in steps): score for score, steps in paths}
        if top is not None:
            priors.setdefault(*top)
        if use_model and self.model is not None:
            try:
                for text, prior in self._propose(context, key, breaks).items():
                    priors.setdefault(text, prior)
            except Exception as error:
                logging.warning("phrase proposals failed: %s", error)
        texts = sorted(priors, key=priors.get, reverse=True)
        if use_model and self.model is not None:
            try:
                probs, = self._ask("phrase", [(context, texts, [priors[text] for text in texts])])
                alpha = self._alpha("phrase")
                scores = {text: math.log(max(prob, 1e-12)) + alpha * priors[text] for text, prob in zip(texts, probs)}
                texts.sort(key=scores.get, reverse=True)
            except Exception as error:
                logging.warning("phrase ranking failed: %s", error)
        return texts

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
        learned = len(result)
        exact = [word for word in self.dictionary.exact(key) if word.accepts(breaks)]
        abbreviated = list(self.dictionary.abbreviated(key)) if not breaks else []
        initial = len(key) == 1 and key not in "aoe"
        if use_model:
            exact = self._rank(context, exact, EXACT_WINDOW)
            if not exact or initial:
                abbreviated = self._rank(context, abbreviated, ABBREVIATED_WINDOW)
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
            completed = self._rank(context, completed, COMPLETION_WINDOW)
        for word in completed:
            add(word.text, len(key))
        whole = len(result)

        sentences = self.dictionary.sentences(key, breaks)
        if sentences and len(sentences[0][1]) > 1 and use_model and self.model is not None:
            # The checkpoint ranks words, not entire sentences. Apply it at word boundaries.
            text, preceding = [], context
            for index, (start, end, word) in enumerate(sentences[0][1]):
                if index < 3:
                    inside = {p - start for p in breaks if start < p < end}
                    alternatives = [w for w in self.dictionary.exact(key[start:end]) if w.accepts(inside)]
                    alternatives = self._rank(preceding, alternatives, EXACT_WINDOW)
                    if alternatives:
                        word = alternatives[0]
                text.append(word.text)
                preceding = (preceding + word.text)[-32:]
            add("".join(text), len(key))
        for _, path in sentences:
            add("".join(item[2].text for item in path), len(key))
        top, follow = None, 0
        word = next((word for word in exact + abbreviated + completed
                     if whole > learned and word.text == result[learned]["text"]), None)
        if word is not None:
            # Priced as the lattice prices a word: each syllable typed as an initial costs INITIAL_COST. The dictionary
            # abbreviates every syllable by its first letter (社会主义 is shzy); a completion abbreviates its last.
            initials = 0 if word in exact else 1 if word in completed else word.syllables.count("'") + 1
            top = (word.text, math.log(word.freq / self.dictionary.total) - INITIAL_COST * initials)
            follow = 0 if word in exact else PHRASE_SHOWN
        elif sentences and len(result) > whole:
            # Full pinyin reaches the phrase stage when its last syllable may be incomplete (jintiantianqihenha);
            # the sentence then competes in the same ranking rather than trailing every phrase. Its prior is the
            # unigram path's, close to that of the model's word choices above.
            top = (result[whole]["text"], sentences[0][0])
        phrases = self._phrases(context, key, breaks, use_model, top)

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
        # Phrases ranked above the best whole-key word go before it (shm: 什么 before 三河马), at most a few so that
        # the dictionary's list stays on page 1, and a few follow an abbreviated or completed word. Full pinyin keeps
        # its own words next: 实力 after 视力, not a completion of shili. A listed phrase moves up; learned words stay
        # first.
        learned_texts = {candidate["text"] for candidate in result[:learned]}
        phrases = [text for text in phrases if text not in learned_texts]
        if top is not None and phrases:
            at = phrases.index(top[0])
            rest = phrases[PHRASE_SHOWN:at] + phrases[at + 1:]
            phrases = phrases[:min(at, PHRASE_SHOWN)] + [top[0]] + rest[:follow]
        position = learned
        for text in phrases:
            index = next((i for i, candidate in enumerate(result) if candidate["text"] == text), len(result))
            if index >= position:
                del result[index:index + 1]
                result.insert(position, {"text": text, "consumed": offsets[len(key) - 1]})
                position += 1
        del result[limit:]
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
