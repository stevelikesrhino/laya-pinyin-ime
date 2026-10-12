# Laya 拼音

一个适用于 Apple Silicon 上 macOS 的简体中文拼音输入法。候选词来自应用内部的本地词典；可选的本地模型会利用前文对它们重新排序，输入内容不上云。

## 构建与安装

需要 macOS 26.2+、Xcode 命令行工具和 [uv](https://github.com/astral-sh/uv)。

```sh
scripts/setup.sh                  # Python 运行时、词典；无排序模型
scripts/setup.sh --model SOURCE   # 同时获取排序模型
scripts/build.sh                  # 构建 build/LayaIME.app
scripts/install.sh                # 安装到 ~/Library/Input Methods；请先切换离开 Laya
scripts/uninstall.sh
```

然后在 系统设置 > 键盘 > 文本输入 中添加 Laya 拼音。

## 排序模型

模型不包含在本仓库中。`--model SOURCE` 可接受一个本地目录，或一个 Hugging Face 仓库（`owner/name[@revision]`），其中包含 `laya_ime.safetensors` 和 `blend.json`，后者是在固定版本的 [convaiinnovations/laya](https://huggingface.co/convaiinnovations/laya) 基座模型上微调得到的 head；该基座模型会一并下载。没有模型时，候选词保持词典顺序。引擎只需要模型提供 `rank(context, options)` 和先验权重 `alpha`（`backend/server.py`、`backend/laya_mlx.py`）。

## 测试

```sh
scripts/test.sh
```

后端测试（`tests/test_backend.py`）覆盖查找、排序、学习和引擎协议。客户端测试（`tests/client/main.swift`）通过模拟文本框驱动真实的输入控制器和候选面板，并以 `tests/engine.py`（真实后端加上一个替身排序器）作为引擎。不需要模型；测试运行时，候选面板会在屏幕上短暂出现。

## 打包

```sh
scripts/package.sh   # dist/LayaIME-<version>.zip：包含 install.sh 和 uninstall.sh 的应用
```

ad-hoc 签名，无公证。

## 目录结构

- `native/`：InputMethodKit 客户端（Swift）：按键处理、词典查找、候选面板、设置
- `backend/`：本地引擎（Python）：词典构建、重排、个人词库
- `scripts/`：设置、构建、安装、测试、打包

## 许可证

MIT，见 [LICENSE](LICENSE)。本许可证不涵盖排序模型：convaiinnovations/laya 基础模型以及基于它调优得到的 head 均为 Apache 2.0。

# Laya 拼音

A Simplified Chinese pinyin input method for macOS on Apple Silicon. Candidates come from a local dictionary
inside the app; an optional local model re-ranks them using the preceding text. Typing never leaves the Mac.

## Build and install

Requires macOS 26.2+, Xcode command line tools, and [uv](https://github.com/astral-sh/uv).

```sh
scripts/setup.sh                  # Python runtime, dictionary; no ranking model
scripts/setup.sh --model SOURCE   # also fetch a ranking model
scripts/build.sh                  # build/LayaIME.app
scripts/install.sh                # ~/Library/Input Methods; switch away from Laya first
scripts/uninstall.sh
```

Then add Laya 拼音 in System Settings > Keyboard > Text Input.

## Ranking model

The model is not part of this repository. `--model SOURCE` takes a local directory or a Hugging Face repo
(`owner/name[@revision]`) with `laya_ime.safetensors` and `blend.json`, a head tuned on the pinned
[convaiinnovations/laya](https://huggingface.co/convaiinnovations/laya) base, which is downloaded alongside.
Without a model, candidates keep dictionary order. The engine needs only `rank(context, options)` and a prior
weight `alpha` from a model (`backend/server.py`, `backend/laya_mlx.py`).

## Tests

```sh
scripts/test.sh
```

Backend tests (`tests/test_backend.py`) cover lookup, ranking, learning and the engine protocol. Client tests
(`tests/client/main.swift`) drive the real input controller and candidate panel through a fake text field,
with `tests/engine.py`, the real backend plus a stand-in ranker, as the engine. No model is needed; the panel
briefly appears on screen while they run.

## Package

```sh
scripts/package.sh   # dist/LayaIME-<version>.zip: the app with install.sh and uninstall.sh
```

The app is ad-hoc signed, not notarized.

## Layout

- `native/`: the InputMethodKit client (Swift): key handling, dictionary lookup, candidate panel, settings
- `backend/`: the local engine (Python): dictionary build, re-ranking, personal vocabulary
- `scripts/`: setup, build, install, test, package

## License

MIT, see [LICENSE](LICENSE). The ranking model is not covered: the convaiinnovations/laya base model and heads
tuned from it are Apache 2.0.
