#!/usr/bin/env python3
"""Fetch the exact qwen3-tts.cpp and GGML revisions, then apply the iOS spike patch."""

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "upstream"
PATCH = ROOT / "patches" / "qwen-ios-static.patch"
QWEN_URL = "https://github.com/predict-woo/qwen3-tts.cpp.git"
QWEN_SHA = "b3ba14077cf1b3e11b86e5f84aa9184605c89b28"
GGML_SHA = "3af5f5760e19a96427f5f7a93b79cbdf3d4b265b"


def git(*args: str, cwd: Path | None = None, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, check=check, text=True, capture_output=True
    )
    return result.stdout.strip()


def main() -> None:
    if not UPSTREAM.exists():
        subprocess.run(
            ["git", "clone", QWEN_URL, str(UPSTREAM)], check=True
        )

    if not (UPSTREAM / ".git").exists():
        raise SystemExit("upstream/ exists but is not a Git checkout; refusing to replace it.")

    current_qwen = git("rev-parse", "HEAD", cwd=UPSTREAM)
    dirty = git("status", "--porcelain", cwd=UPSTREAM)
    if dirty:
        allowed_modified = {
            "CMakeLists.txt",
            "src/gguf_loader.h",
            "src/gguf_loader.cpp",
            "src/qwen3tts_c_api.h",
            "src/qwen3tts_c_api.cpp",
        }
        changed = set(git("diff", "--name-only", cwd=UPSTREAM).splitlines())
        staged = git("diff", "--cached", "--name-only", cwd=UPSTREAM)
        untracked = git("ls-files", "--others", "--exclude-standard", cwd=UPSTREAM)
        reverse_check = subprocess.run(
            ["git", "apply", "--reverse", "--check", str(PATCH)],
            cwd=UPSTREAM,
            capture_output=True,
        )
        if (current_qwen != QWEN_SHA or not changed or not changed <= allowed_modified
                or staged or untracked or reverse_check.returncode != 0):
            raise SystemExit(
                "upstream/ has changes beyond the recognized local spike patch; "
                "refusing to modify or discard that checkout."
            )
    else:
        git("checkout", "--detach", QWEN_SHA, cwd=UPSTREAM)
    git("submodule", "update", "--init", "--recursive", cwd=UPSTREAM)

    actual_qwen = git("rev-parse", "HEAD", cwd=UPSTREAM)
    actual_ggml = git("rev-parse", "HEAD:ggml", cwd=UPSTREAM)
    if actual_qwen != QWEN_SHA:
        raise SystemExit(f"Unexpected qwen3-tts.cpp revision: {actual_qwen}")
    if actual_ggml != GGML_SHA:
        raise SystemExit(f"Unexpected GGML gitlink revision: {actual_ggml}")

    applied = subprocess.run(
        ["git", "apply", "--check", str(PATCH)], cwd=UPSTREAM, capture_output=True
    )
    if applied.returncode == 0:
        subprocess.run(["git", "apply", str(PATCH)], cwd=UPSTREAM, check=True)
    else:
        already_applied = subprocess.run(
            ["git", "apply", "--reverse", "--check", str(PATCH)],
            cwd=UPSTREAM,
            capture_output=True,
        )
        if already_applied.returncode != 0:
            raise SystemExit(
                "Pinned upstream files differ from the expected patch context; "
                "refusing to apply an unreviewed source edit."
            )

    print(f"qwen3-tts.cpp: {actual_qwen}")
    print(f"ggml submodule: {actual_ggml}")
    print("Applied/reused the local iOS-only CMake and backend-observability patch.")


if __name__ == "__main__":
    main()
