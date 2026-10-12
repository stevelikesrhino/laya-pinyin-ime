"""Backend tests: lookup, ranking, learning and the line protocol. A stand-in replaces the ranking model.

Needs models/dictionary.sqlite3 from scripts/setup.sh. Run with scripts/test.sh.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

import server  # noqa: E402
from dictionary import normalize  # noqa: E402


class Ranker:
    """Stands in for the model: prefers the given words and records the contexts it ranked."""

    def __init__(self, *preferred, alpha=0.0):
        self.preferred, self.alpha, self.contexts = preferred, alpha, []

    def rank(self, context, options):
        self.contexts.append(context)
        return [0.9 if option in self.preferred else 0.01 for option in options]


def setUpModule():
    if not (ROOT / "models/dictionary.sqlite3").is_file():
        raise RuntimeError("models/dictionary.sqlite3 is missing; run scripts/setup.sh first.")


def engine():
    # No model is loaded; ranking tests install a Ranker.
    with mock.patch.object(server.Engine, "_load_model", lambda self: setattr(self, "loading", False)):
        result = server.Engine()
    result.loader.join()
    return result


class EngineTest(unittest.TestCase):
    def setUp(self):
        data = tempfile.TemporaryDirectory()
        self.addCleanup(data.cleanup)
        environment = mock.patch.dict(os.environ, {"LAYA_DATA_DIR": data.name})
        environment.start()
        self.addCleanup(environment.stop)
        self.engine = engine()

    def texts(self, raw, context="", ranked=False, learning=True, limit=12):
        return [c["text"] for c in self.engine.candidates(raw, context, limit, ranked, learning)]


class NormalizeTest(unittest.TestCase):
    def test_letters_offsets_and_breaks(self):
        self.assertEqual(normalize("xi'an"), ("xian", [1, 3, 4, 5], {2}))

    def test_u_umlaut_spellings(self):
        for raw in ("lv", "lü", "lu:"):
            self.assertEqual(normalize(raw)[0], "lv", raw)

    def test_rejects_other_characters(self):
        with self.assertRaises(ValueError):
            normalize("ni3")


class LookupTest(EngineTest):
    def test_common_words_first(self):
        for raw, word in [("nihao", "你好"), ("woaini", "我爱你"), ("zhongguoren", "中国人"), ("z", "在")]:
            self.assertEqual(self.texts(raw)[0], word, raw)

    def test_sentence(self):
        self.assertEqual(self.texts("jintiantianqihenhao")[0], "今天天气很好")

    def test_apostrophe_is_a_syllable_break(self):
        self.assertEqual(self.texts("xi'an")[0], "西安")
        self.assertNotEqual(self.texts("xian")[0], "西安")

    def test_v_spells_u_umlaut(self):
        self.assertIn("绿", self.texts("lv"))

    def test_prefix_candidates_report_consumed_input(self):
        self.assertIn({"text": "你好", "consumed": 5}, self.engine.candidates("nihaoshijie", "", 45, False, False))
        self.assertIn({"text": "你好", "consumed": 6}, self.engine.candidates("ni'haoshijie", "", 45, False, False))

    def test_limit(self):
        self.assertEqual(len(self.texts("shi", limit=5)), 5)


class RankingTest(EngineTest):
    def test_dictionary_order_without_model(self):
        self.assertEqual(self.texts("shili", ranked=True), self.texts("shili"))

    def test_ranker_reorders(self):
        self.engine.model = Ranker("视力")
        self.assertEqual(self.texts("shili", "他的", ranked=True)[0], "视力")
        self.assertEqual(self.texts("shili", "他的")[0], "实力")

    def test_ranks_without_context(self):
        self.engine.model = ranker = Ranker("视力")
        self.assertEqual(self.texts("shili", ranked=True)[0], "视力")
        self.assertIn("", ranker.contexts)

    def test_frequency_prior_weight(self):
        self.engine.model = Ranker("视力", alpha=100.0)
        self.assertEqual(self.texts("shili", ranked=True)[0], "实力")

    def test_only_first_page_is_ranked(self):
        unranked = self.texts("shi", limit=45)
        self.engine.model = Ranker(unranked[10])
        self.assertEqual(self.texts("shi", ranked=True, limit=45), unranked)

    def test_learned_words_stay_first(self):
        self.engine.handle({"op": "learn", "pinyin": "shili", "text": "十里"})
        self.engine.model = Ranker("视力")
        self.assertEqual(self.texts("shili", ranked=True)[:2], ["十里", "视力"])

    def test_ranker_failure_keeps_dictionary_order(self):
        self.engine.model = mock.Mock(alpha=0.0, rank=mock.Mock(side_effect=RuntimeError("broken")))
        with self.assertLogs(level="WARNING"):
            self.assertEqual(self.texts("shili", ranked=True), self.texts("shili"))
        self.assertEqual(self.engine.model_error, "broken")


class PromptTest(unittest.TestCase):
    def test_context_matches_training(self):
        import laya_mlx

        model = laya_mlx.Laya.__new__(laya_mlx.Laya)
        with mock.patch.object(laya_mlx.Laya, "choice", return_value=[0.5, 0.5]) as choice:
            model.rank("", ["实力", "视力"])
            model.rank("一" * 40 + "他的", ["实力", "视力"])
        states = [call.args[0] for call in choice.call_args_list]
        self.assertEqual(states, ["上文：（无）", "上文：" + "一" * 30 + "他的"])


class LearningTest(EngineTest):
    def test_learned_word_comes_first(self):
        self.engine.handle({"op": "learn", "pinyin": "zhang'wei", "text": "张伟"})
        self.assertEqual(self.texts("zhangwei")[0], "张伟")
        self.assertNotIn("张伟", self.texts("zhangwei", learning=False))

    def test_persists_across_restarts(self):
        self.engine.handle({"op": "learn", "pinyin": "zhangwei", "text": "张伟"})
        self.engine = engine()
        self.assertEqual(self.texts("zhangwei")[0], "张伟")

    def test_learning_off_writes_nothing(self):
        self.engine.handle({"op": "learn", "pinyin": "zhangwei", "text": "张伟", "use_learning": False})
        self.assertEqual(self.engine.handle({"op": "status"})["personal_entries"], 0)

    def test_rejects_bad_entries(self):
        for entry in [{"pinyin": "", "text": "张"}, {"pinyin": "zhang", "text": ""}, {"pinyin": "a" * 129, "text": "张"},
                      {"pinyin": "zhang", "text": "张" * 129}, {"pinyin": 1, "text": "张"}]:
            with self.assertRaises(ValueError, msg=entry):
                self.engine.handle({"op": "learn", **entry})


class ProtocolTest(unittest.TestCase):
    def test_one_reply_per_line_and_exit_at_end_of_input(self):
        requests = [{"id": 1, "op": "candidates", "pinyin": "nihao", "context": ""}, "not json", [1, 2],
                    {"id": 4, "op": "unknown"}, {"id": 5, "op": "status"}]
        lines = "".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in requests)
        with tempfile.TemporaryDirectory() as data:
            missing = os.path.join(data, "missing")
            environment = dict(os.environ, LAYA_DATA_DIR=data, LAYA_BASE_MODEL=missing, LAYA_TUNED_MODEL=missing)
            done = subprocess.run([sys.executable, "-B", str(ROOT / "backend/server.py")], input=lines, text=True,
                                  capture_output=True, env=environment, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        replies = [json.loads(line) for line in done.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], [1, None, None, 4, 5])
        self.assertEqual(replies[0]["candidates"][0], {"text": "你好", "consumed": 5})
        self.assertTrue(all("error" in reply for reply in replies[1:4]))
        self.assertFalse(replies[4]["model_loaded"])


if __name__ == "__main__":
    unittest.main()
