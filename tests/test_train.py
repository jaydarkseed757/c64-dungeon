import json
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_train_checkpoint_resume(tmp_path):
    rows = [{"task": "ROOM", "ctx": ["TASK:ROOM", "LOC:CRYPT"], "text": "a cold crypt."},
            {"task": "EVENT", "ctx": ["TASK:EVENT", "ENV:DRIP"], "text": "water drips."}] * 20
    data = tmp_path / "d.jsonl"
    data.write_text("".join(json.dumps(r) + "\n" for r in rows))
    cfg = {"name": "t", "device": "cpu",
           "model": {"ctx_len": 32, "d_model": 16, "n_layers": 1, "n_heads": 1, "d_ff": 32},
           "data": {"train": str(data), "val": str(data)},
           "train": {"seed": 1, "steps": 10, "batch": 8, "lr": 3e-3, "min_lr": 3e-4, "warmup": 2,
                     "weight_decay": 0.0, "grad_clip": 1.0, "log_every": 5, "eval_every": 5}}
    cfg_path = tmp_path / "c.yaml"
    cfg_path.write_text(yaml.safe_dump(cfg))
    out = tmp_path / "ck"
    run = [sys.executable, str(ROOT / "python/train.py"), "--config", str(cfg_path), "--out-dir", str(out)]
    subprocess.run(run, check=True, capture_output=True)
    first = [json.loads(l) for l in (out / "log.jsonl").open()]
    assert [r["step"] for r in first] == [5, 10]
    subprocess.run(run + ["--resume", "--steps", "15"], check=True, capture_output=True)
    log = [json.loads(l) for l in (out / "log.jsonl").open()]
    assert [r["step"] for r in log] == [5, 10, 15]
    assert (out / "best.pt").exists() and (out / "samples.txt").exists()
    assert log[-1]["val_loss"] < log[0]["val_loss"] < 5.3   # learning continues across resume; ln(197)=5.28
