"""Offline MLX inference for Laya's ModernBERT encoder and decision head."""

import json
import os
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
from tokenizers import Tokenizer

INSTRUCTIONS = "拼音输入法：根据上文，哪个候选词最可能是用户想输入的下一个词？"


def model_paths():
    # scripts/prepare_models.py fills models/; the app bundle passes its own copies through the environment.
    root = Path(__file__).resolve().parent.parent
    base = Path(os.environ.get("LAYA_BASE_MODEL", str(root / "models/multilingual"))).expanduser()
    tuned = Path(os.environ.get(
        "LAYA_TUNED_MODEL", str(root / "models/laya-chinese-tuned/laya_ime.safetensors"))).expanduser()
    for path in (base / "model.safetensors", base / "encoder/config.json",
                 base / "tokenizer/tokenizer.json", base / "rl_agent_config.json", tuned):
        if not path.is_file():
            raise FileNotFoundError(f"missing model file: {path}")
    return base, tuned


class Laya:
    def __init__(self, base=None, finetuned=None):
        if base is None or finetuned is None:
            default_base, default_tuned = model_paths()
            base, finetuned = base or default_base, finetuned or default_tuned
        base, finetuned = Path(base), Path(finetuned)
        self.cfg = json.loads((base / "rl_agent_config.json").read_text())
        self.encoder_cfg = json.loads((base / "encoder/config.json").read_text())
        self.tok = Tokenizer.from_file(str(base / "tokenizer/tokenizer.json"))
        self.tok.no_padding()
        self.tok.no_truncation()
        tokens = json.loads((base / "tokenizer/tokenizer_config.json").read_text())
        self.cls_id = self.tok.token_to_id(tokens["cls_token"])
        self.sep_id = self.tok.token_to_id(tokens["sep_token"])
        self.mask_token = tokens["mask_token"]
        self.mask_id = self.tok.token_to_id(self.mask_token)
        self.weights = mx.load(str(base / "model.safetensors"))
        tuned = mx.load(str(finetuned))
        required = {k for k in self.weights if k.startswith((
            "encoder.layers.", "encoder.final_norm.", "head.", "type_emb.", "scorer.",
        ))}
        if not required.issubset(tuned):
            raise ValueError("incomplete tuned checkpoint")
        if any(k not in self.weights or self.weights[k].shape != v.shape for k, v in tuned.items()):
            raise ValueError("tuned checkpoint does not match base model")
        self.weights.update(tuned)
        mx.eval(self.weights)
        self.alpha = 0.2
        blend = finetuned.with_name("blend.json")
        if blend.is_file():
            self.alpha = float(json.loads(blend.read_text())["alpha"])
        self.nheads = self.encoder_cfg["num_attention_heads"]
        self.dim = self.encoder_cfg["hidden_size"] // self.nheads
        self.eps = self.encoder_cfg.get("norm_eps", 1e-5)

    def encode(self, state, instructions, options):
        # Match rl_common.build_sequence, including option/head truncation.
        encode = lambda text: self.tok.encode(text, add_special_tokens=False).ids
        head = encode("choice question: " + instructions.replace(self.mask_token, " "))
        option_ids = [[self.mask_id] + encode(" " + word.replace(self.mask_token, " "))[:48]
                      for word in options]
        budget = self.cfg["head_max_len"] - sum(map(len, option_ids))
        if budget < 16:
            per = max(4, (self.cfg["head_max_len"] - 16) // max(1, len(options)))
            option_ids = [ids[:per] for ids in option_ids]
            budget = self.cfg["head_max_len"] - sum(map(len, option_ids))
        ids = [self.cls_id] + head[:max(8, budget)] + [self.sep_id]
        markers = []
        for option in option_ids:
            markers.append(len(ids))
            ids.extend(option)
        ids.append(self.sep_id)
        room = max(0, self.cfg["max_len"] - len(ids) - 1)
        ids.extend(encode(state.replace(self.mask_token, " "))[:room])
        ids.append(self.sep_id)
        if len(ids) > self.cfg["max_len"] or any(p >= len(ids) for p in markers):
            raise ValueError("too many options for model input")
        return ids, markers

    def _linear(self, x, name):
        x = x @ self.weights[name + ".weight"].T
        bias = self.weights.get(name + ".bias")
        return x if bias is None else x + bias

    def _norm(self, x, name, eps=None):
        return mx.fast.layer_norm(x, self.weights[name + ".weight"],
                                  self.weights.get(name + ".bias"), self.eps if eps is None else eps)

    def _attention(self, x, prefix, mask=None, rope_base=None, head=False):
        if head:
            qkv = x @ self.weights[prefix + ".in_proj_weight"].T
            qkv = qkv + self.weights[prefix + ".in_proj_bias"]
        else:
            qkv = self._linear(x, prefix + ".Wqkv")
        batch, length, _ = x.shape
        q, k, v = mx.split(qkv.reshape(batch, length, 3, self.nheads, self.dim), 3, axis=2)
        q, k, v = (a.squeeze(2).transpose(0, 2, 1, 3) for a in (q, k, v))
        if rope_base is not None:
            q = mx.fast.rope(q, self.dim, traditional=False, base=rope_base, scale=1.0, offset=0)
            k = mx.fast.rope(k, self.dim, traditional=False, base=rope_base, scale=1.0, offset=0)
        out = mx.fast.scaled_dot_product_attention(q, k, v, scale=self.dim ** -0.5, mask=mask)
        out = out.transpose(0, 2, 1, 3).reshape(batch, length, -1)
        return self._linear(out, prefix + (".out_proj" if head else ".Wo"))

    def logits(self, ids, markers):
        x = self.weights["encoder.embeddings.tok_embeddings.weight"][mx.array([ids])]
        x = self._norm(x, "encoder.embeddings.norm")
        pos = mx.arange(len(ids))
        window = self.encoder_cfg["local_attention"] // 2
        local_mask = mx.abs(pos[:, None] - pos[None, :]) <= window
        layer_types = self.encoder_cfg.get("layer_types")
        for i in range(self.encoder_cfg["num_hidden_layers"]):
            prefix = f"encoder.layers.{i}"
            kind = layer_types[i] if layer_types else (
                "full_attention" if i % self.encoder_cfg["global_attn_every_n_layers"] == 0
                else "sliding_attention")
            rope = self.encoder_cfg.get("rope_parameters", {}).get(kind, {})
            theta = rope.get("rope_theta", self.encoder_cfg.get(
                "global_rope_theta" if kind == "full_attention" else "local_rope_theta", 160000))
            normalized = x if i == 0 else self._norm(x, prefix + ".attn_norm")
            x = x + self._attention(normalized, prefix + ".attn",
                                    None if kind == "full_attention" else local_mask, theta)
            a, gate = mx.split(self._linear(self._norm(x, prefix + ".mlp_norm"), prefix + ".mlp.Wi"), 2, axis=-1)
            x = x + self._linear(nn.gelu(a) * gate, prefix + ".mlp.Wo")
        x = self._norm(x, "encoder.final_norm") + self.weights["type_emb.weight"][0]
        for i in range(self.cfg["head_layers"]):
            prefix = f"head.layers.{i}"
            x = x + self._attention(self._norm(x, prefix + ".norm1", 1e-5),
                                    prefix + ".self_attn", head=True)
            a = self._linear(self._norm(x, prefix + ".norm2", 1e-5), prefix + ".linear1")
            x = x + self._linear(mx.maximum(a, 0), prefix + ".linear2")
        x = self._norm(x[:, mx.array(markers), :], "scorer.0", 1e-5)
        x = nn.gelu(self._linear(x, "scorer.1"))
        return self._linear(x, "scorer.3")[0, :, 0].astype(mx.float32)

    def rank(self, context, options):
        """Choice probabilities for options after the preceding text; training wrote no context as （无）."""
        return self.choice("上文：" + (context[-32:] or "（无）"), INSTRUCTIONS, options)

    def choice(self, state, instructions, options):
        if len(options) < 2:
            return [1.0] * len(options)
        ids, markers = self.encode(state, instructions, options)
        logits = self.logits(ids, markers)
        temperature = self.cfg.get("temperature", [1.0])[0]
        buckets = self.cfg.get("temperature_by_options", {})
        bucket = "2" if len(options) == 2 else "3-5" if len(options) <= 5 else "6-10" if len(options) <= 10 else "11+"
        temperature = buckets.get("choice:" + bucket, temperature)
        probs = mx.softmax(logits / temperature)
        mx.eval(probs)
        return probs.tolist()
