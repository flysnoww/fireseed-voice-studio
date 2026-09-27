#!/usr/bin/env python3
"""Fetch the pinned official HF model and run the pinned GGUF conversion scripts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "upstream"
MODEL_ID = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"
MODEL_REVISION = "dab70521e0956e3db91fb887d36c9a07d21ebc0b"
OFFICIAL_QWEN_CODE_REVISION = "022e286b98fbec7e1e916cb940cdf532cd9f488e"
QWEN_SHA = "b3ba14077cf1b3e11b86e5f84aa9184605c89b28"
GGML_SHA = "3af5f5760e19a96427f5f7a93b79cbdf3d4b265b"
EXPECTED_INPUTS = {
    "model.safetensors": "180b3b10eb1c9f1b4db7806d5475bae3071c0243c299d49926bab1da3b6946f6",
    "speech_tokenizer/model.safetensors": "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258",
}
EXPECTED_PACKAGES = {
    "huggingface_hub": "0.36.2",
    "numpy": "2.5.3",
    "safetensors": "0.8.0",
    "torch": "2.7.0",
    "tqdm": "4.70.1",
}
ASSET_DIR = ROOT / "model" / "assets"
SOURCE_DIR = ASSET_DIR / "Qwen3-TTS-12Hz-0.6B-Base"
OUTPUTS = [
    ASSET_DIR / "qwen3-tts-0.6b-f16.gguf",
    ASSET_DIR / "qwen3-tts-tokenizer-f16.gguf",
]
MANIFEST_PATH = ASSET_DIR / "conversion-manifest.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_versions() -> dict[str, str]:
    return {name: importlib.metadata.version(name) for name in EXPECTED_PACKAGES}


def validate_or_refuse_existing_outputs(input_hashes: dict[str, str]) -> dict | None:
    present = [path.is_file() for path in OUTPUTS]
    if not any(present) and not MANIFEST_PATH.exists():
        return None
    if not all(present) or not MANIFEST_PATH.is_file():
        raise SystemExit(
            "Existing or partial GGUF outputs have no complete conversion manifest; "
            "preserving them. Move them outside model/assets before a fresh conversion."
        )
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    expected = {
        "model_revision": MODEL_REVISION,
        "qwen3_tts_cpp_revision": QWEN_SHA,
        "ggml_revision": GGML_SHA,
        "source_sha256": input_hashes,
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise SystemExit(
            "Existing GGUF manifest belongs to different source pins; preserving outputs. "
            "Move model/assets outputs aside before reconverting."
        )
    for path, output in zip(OUTPUTS, manifest.get("outputs", [])):
        if output.get("path") != path.name or output.get("sha256") != sha256(path):
            raise SystemExit(
                f"Existing GGUF does not match its manifest: {path}; preserving it."
            )
    if len(manifest.get("outputs", [])) != len(OUTPUTS):
        raise SystemExit("Existing manifest has an incomplete output list; preserving outputs.")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", default=sys.executable, help="Pinned conversion venv Python")
    args = parser.parse_args()

    actual_packages = package_versions()
    for name, expected in EXPECTED_PACKAGES.items():
        if actual_packages[name].split("+", 1)[0] != expected:
            raise SystemExit(
                f"{name} version {actual_packages[name]} does not match pinned {expected}."
            )

    if not UPSTREAM.is_dir():
        raise SystemExit("Run scripts/prepare_source.py first.")
    actual_qwen = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=UPSTREAM, text=True
    ).strip()
    actual_ggml = subprocess.check_output(
        ["git", "rev-parse", "HEAD:ggml"], cwd=UPSTREAM, text=True
    ).strip()
    if actual_qwen != QWEN_SHA or actual_ggml != GGML_SHA:
        raise SystemExit(f"Unexpected source pins: qwen={actual_qwen}, ggml={actual_ggml}")

    import huggingface_hub

    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    huggingface_hub.snapshot_download(
        repo_id=MODEL_ID,
        revision=MODEL_REVISION,
        local_dir=str(SOURCE_DIR),
        allow_patterns=[
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "preprocessor_config.json",
            "speech_tokenizer/*",
        ],
    )

    input_hashes: dict[str, str] = {}
    for relative_path, expected_hash in EXPECTED_INPUTS.items():
        path = SOURCE_DIR / relative_path
        if not path.is_file():
            raise SystemExit(f"Missing pinned model asset: {path}")
        actual_hash = sha256(path)
        input_hashes[relative_path] = actual_hash
        if actual_hash != expected_hash:
            raise SystemExit(f"SHA-256 mismatch for {relative_path}: {actual_hash}")

    existing = validate_or_refuse_existing_outputs(input_hashes)
    if existing is not None:
        print(json.dumps(existing, indent=2))
        return

    env = os.environ.copy()
    gguf_python_path = str(UPSTREAM / "ggml" / "gguf-py")
    old_python_path = env.get("PYTHONPATH")
    env["PYTHONPATH"] = os.pathsep.join(
        part for part in (gguf_python_path, old_python_path) if part
    )
    setup_script = UPSTREAM / "scripts" / "setup_pipeline_models.py"
    subprocess.run(
        [
            args.python,
            str(setup_script),
            "--models-dir",
            str(ASSET_DIR),
            "--skip-download",
            "--coreml",
            "off",
        ],
        cwd=UPSTREAM,
        env=env,
        check=True,
    )

    output_records = []
    for output in OUTPUTS:
        if not output.is_file():
            raise SystemExit(f"Converter did not create expected output: {output}")
        output_records.append(
            {"path": output.name, "bytes": output.stat().st_size, "sha256": sha256(output)}
        )

    manifest = {
        "prepared_at_utc": datetime.now(timezone.utc).isoformat(),
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "model_license": "Apache-2.0",
        "official_qwen3_tts_code_reference": OFFICIAL_QWEN_CODE_REVISION,
        "qwen3_tts_cpp_revision": QWEN_SHA,
        "ggml_revision": GGML_SHA,
        "conversion": "pinned setup_pipeline_models.py; F16; CoreML export off",
        "python": sys.version,
        "python_packages": package_versions(),
        "source_sha256": input_hashes,
        "outputs": output_records,
    }
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
