"""Engine for the client tests: the real backend and protocol, with a stand-in for the ranking model.

The stand-in prefers the words listed in LAYA_TEST_PREFER (comma-separated) and ignores frequency.
"""
import os
import sys

sys.path.insert(0, os.environ["LAYA_BACKEND"])
import server  # noqa: E402


class Ranker:
    alpha = 0.0

    def rank(self, context, options):
        preferred = os.environ.get("LAYA_TEST_PREFER", "").split(",")
        return [0.9 if option in preferred else 0.01 for option in options]


def load(engine):
    engine.model, engine.loading = Ranker(), False


server.Engine._load_model = load
server.main()
