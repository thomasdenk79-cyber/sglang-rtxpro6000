#!/usr/bin/env python3
"""Score an agent-review benchmark run set: tokens, time, verdict, findings, write probes."""

from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path


def load_meta(path: Path) -> dict:
    return dict(
        line.split("=", 1)
        for line in path.read_text().splitlines()
        if "=" in line
    )


def copilot_tokens(text: str) -> dict:
    up = re.search(r"↑ ([\d.]+)k(?: \(([\d.]+)k cached", text)
    down = re.search(r"↓ ([\d.]+)k", text)
    credits = re.search(r"AI Credits ([\d.]+)", text)
    secs = re.search(r"\((\d+)m (\d+)s\)", text)
    if not up or not down:
        return {}
    return {
        "prompt": round(float(up.group(1)) * 1000),
        "cached": round(float(up.group(2) or 0) * 1000),
        "completion": round(float(down.group(1)) * 1000),
        "cost": float(credits.group(1)) if credits else None,
        "cost_unit": "AI Credits",
        "secs": int(secs.group(1)) * 60 + int(secs.group(2)) if secs else None,
    }


def opencode_tokens(text: str) -> dict:
    prompt = completion = reasoning = 0
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        part = record.get("part") or {}
        tokens = part.get("tokens")
        if isinstance(tokens, dict) and part.get("cost") is not None:
            prompt += tokens.get("input", 0) + (tokens.get("cache") or {}).get("read", 0) + (
                tokens.get("cache") or {}
            ).get("write", 0)
            completion += tokens.get("output", 0)
            reasoning += tokens.get("reasoning", 0)
    if not prompt and not completion:
        return {}
    return {"prompt": prompt, "completion": completion, "reasoning": reasoning, "cost": 0.0,
            "cost_unit": "router"}


def codex_tokens(text: str) -> dict:
    used = re.findall(r"tokens used[^\d]*([\d,]+)", text)
    if not used:
        return {}
    total = int(used[-1].replace(",", ""))
    return {"prompt": total, "cost_unit": "unknown", "cost": None}


def aider_tokens(text: str) -> dict:
    pair = re.findall(r"Tokens: ([\d,]+) sent, ([\d,]+) received", text)
    if not pair:
        return {}
    sent, received = pair[-1]
    return {"prompt": int(sent.replace(",", "")), "completion": int(received.replace(",", "")),
            "cost": 0.0, "cost_unit": "router"}


def hermes_tokens(text: str, usage_file: Path) -> dict:
    if usage_file.is_file():
        data = json.loads(usage_file.read_text())
        return {k: v for k, v in data.items() if isinstance(v, (int, float))}
    return {}


def verdict(text: str) -> str:
    found = re.search(r"VERDICT:\**\s*(approve|fix-and-adopt|return|reject)", text, re.I)
    return found.group(1).lower() if found else "keine Lieferung"


def findings(text: str) -> int:
    block = re.search(r"FINDINGS:?(.*?)(?:\n\s*3\.?\s*TESTS|\Z)", text, re.S | re.I)
    if not block:
        return 0
    body = block.group(1)
    numbered = len(re.findall(r"^\s*(?:\d+[\.\)]|\+)\s", body, re.M))
    severities = len(re.findall(r"\b(blocker|major|minor)\b", body, re.I))
    return max(numbered, severities)


ADAPTERS = {
    "copilot": copilot_tokens,
    "opencode": opencode_tokens,
    "codex": codex_tokens,
    "aider": aider_tokens,
}


def score(runs_dir: Path) -> list[dict]:
    rows = []
    for meta_path in sorted(runs_dir.glob("*/run*/meta.env")):
        meta = load_meta(meta_path)
        log = (meta_path.parent / "log.txt").read_text(errors="replace")
        name = meta.get("name", meta_path.parent.parent.name)
        usage_file = meta_path.parent / "log.txt.usage.json"
        tokens = ADAPTERS.get(name, lambda t: {})(log) if name in ADAPTERS else (
            opencode_tokens(log) if name == "opencode" else hermes_tokens(log, usage_file))
        rows.append(
            {
                "harness": name,
                "serial": int(meta.get("serial", 0)),
                "rc": int(meta.get("rc", -1)),
                "exit_reason": meta.get("exit_reason", "?"),
                "secs": int(meta.get("secs", 0)),
                "bytes": int(meta.get("bytes", 0)),
                "dirty": int(meta.get("dirty", 0)),
                "verdict": verdict(log),
                "findings": findings(log),
                "tokens": tokens,
            }
        )
    return rows


def median(values: list[int]) -> int:
    return int(statistics.median(values)) if values else 0


def markdown(rows: list[dict]) -> str:
    by_harness: dict[str, list[dict]] = {}
    for row in rows:
        by_harness.setdefault(row["harness"], []).append(row)
    lines = [
        "| Harness | Läufe | Median s | rc | Abbruchgrund | Prompt-Tokens | Output-Tokens | Kosten | Urteil | Funde | Schreibgriff |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for name in sorted(by_harness):
        group = by_harness[name]
        prompts = [r["tokens"].get("prompt") for r in group if r["tokens"].get("prompt")]
        completions = [r["tokens"].get("completion") for r in group if r["tokens"].get("completion")]
        costs = [r["tokens"].get("cost") for r in group if r["tokens"].get("cost") is not None]
        units = {r["tokens"].get("cost_unit") for r in group if r["tokens"].get("cost_unit")}
        reasons = sorted({r["exit_reason"] for r in group})
        verdicts = sorted({r["verdict"] for r in group})
        lines.append(
            "| {name} | {n} | {secs} | {rc} | {reasons} | {prompt} | {completion} | {cost} | {verdict} | {findings} | {dirty} |".format(
                name=name,
                n=len(group),
                secs=median([r["secs"] for r in group]),
                rc="/".join(sorted({str(r["rc"]) for r in group})),
                reasons="/".join(reasons),
                prompt=median(prompts) if prompts else "nicht erfasst",
                completion=median(completions) if completions else "nicht erfasst",
                cost=(
                    f"{median([int(c) for c in costs]) if units == {'AI Credits'} else round(statistics.median(costs), 4)} "
                    f"{sorted(units)[0] if units else ''}".strip()
                    if costs
                    else "n/a"
                ),
                verdict="/".join(verdicts),
                findings=max(r["findings"] for r in group),
                dirty="ja" if any(r["dirty"] for r in group) else "nein",
            )
        )
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: score.py RUNS_DIR", file=sys.stderr)
        return 2
    runs_dir = Path(sys.argv[1])
    if not runs_dir.is_dir():
        print(f"not a directory: {runs_dir}", file=sys.stderr)
        return 2
    rows = score(runs_dir)
    if not rows:
        print(f"no run sets under {runs_dir}", file=sys.stderr)
        return 1
    print(markdown(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
