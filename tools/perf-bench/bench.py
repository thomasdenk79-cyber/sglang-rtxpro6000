#!/usr/bin/env python3
"""Benchmark c1-c8 (ryangu00 category naming) against the production engine.

Sequential, stdlib-only client for the OpenAI-compatible endpoint; streams,
records TTFT/wall/tok-s from engine usage, auto-scores deterministic gold.
Conditions (model, sampling, power limit, git head) land in meta.json.
"""
import argparse
import json
import re
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request

ALPHA = "ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL".split()


def load_bank(path):
    items = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                items.append(json.loads(line))
    return items


def make_haystack(spec):
    lines = []
    for i in range(spec["paragraphs"]):
        lines.append(
            f"Paragraph {i}. Station {ALPHA[i % len(ALPHA)]}-{i % 97} logged "
            f"humidity {10 + (i * 7) % 89}% and wind {(i * 13) % 40} km/h at "
            f"sector {(i * 11) % 360}. Clerk {(i * 3) % 9} filed routine entry "
            f"{i * 17 % 1000}. No action."
        )
    ins = int(spec["paragraphs"] * spec["depth"])
    lines[ins:ins] = ["IMPORTANT: " + spec["needle"]]
    return "\n".join(lines)


def open_stream(base, key, payload, timeout):
    req = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
        },
    )
    return urllib.request.urlopen(req, timeout=timeout)


def chat(base, key, model, messages, max_tokens, tools=None, extra=None,
         timeout=480):
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": 1.0,
        "top_p": 0.95,
    }
    if tools:
        payload["tools"] = tools
    if extra:
        payload.update(extra)
    t0 = time.perf_counter()
    t_first = None
    t_last = None
    content = []
    reason = []
    usage = {}
    tool_calls = {}
    with open_stream(base, key, payload, timeout) as resp:
        for raw in resp:
            if not raw.startswith(b"data:"):
                continue
            data = raw[5:].strip()
            if data == b"[DONE]":
                break
            obj = json.loads(data)
            if obj.get("usage"):
                usage = obj["usage"]
            choices = obj.get("choices") or [{}]
            delta = choices[0].get("delta") or {}
            piece = delta.get("content")
            rp = delta.get("reasoning_content")
            if (piece or rp) and t_first is None:
                t_first = time.perf_counter()
            if piece:
                content.append(piece)
            if rp:
                reason.append(rp)
            for tc in delta.get("tool_calls") or []:
                slot = tool_calls.setdefault(tc.get("index", 0),
                                             {"id": "", "name": "", "args": ""})
                if tc.get("id"):
                    slot["id"] = tc["id"]
                fn = tc.get("function") or {}
                if fn.get("name"):
                    slot["name"] += fn["name"]
                if fn.get("arguments"):
                    slot["args"] += fn["arguments"]
            t_last = time.perf_counter()
    wall = time.perf_counter() - t0
    ttft = (t_first - t0) if t_first is not None else wall
    gen = (t_last - t_first) if (t_first and t_last and t_last > t_first) else 0
    n_out = usage.get("completion_tokens") or sum(
        len(x) for x in content + reason
    ) // 4
    n_in = usage.get("prompt_tokens") or 0
    return {
        "content": "".join(content),
        "reasoning": "".join(reason),
        "tool_calls": [tool_calls[k] for k in sorted(tool_calls)],
        "usage": usage,
        "wall_s": round(wall, 3),
        "ttft_s": round(ttft, 3),
        "prompt_tokens": n_in,
        "completion_tokens": n_out,
        "prefill_tps": round(n_in / ttft, 1) if ttft > 0.2 and n_in else None,
        "decode_tps": round(n_out / gen, 1) if gen > 0.2 and n_out else None,
    }


def parse_json_block(text):
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    cand = m.group(1) if m else text
    m2 = re.search(r"\{.*\}", cand, re.S)
    if not m2:
        return None
    try:
        return json.loads(m2.group(0))
    except Exception:
        return None


def score_contains(item, r):
    text = r["content"].lower()
    hits = [g.lower() in text for g in item["gold"]]
    return round(100 * sum(hits) / len(hits)), {"gold": item["gold"]}


def score_number(item, r):
    nums = re.findall(r"-?\d+(?:\.\d+)?", r["content"])
    ok = bool(nums) and abs(float(nums[-1]) - float(item["gold"])) < 0.51
    return (100 if ok else 0), {"last_number": nums[-1] if nums else None}


def score_jsonfields(item, r):
    obj = parse_json_block(r["content"])
    if obj is None:
        return 0, {"error": "no json"}
    gold = item["gold"]
    pts = []
    for k, v in gold.items():
        got = obj.get(k)
        if isinstance(v, (int, float)):
            ok = got is not None and abs(float(got) - float(v)) < 0.05
        else:
            ok = got is not None and str(got).strip().lower() == str(v).lower()
        pts.append(ok)
    return round(100 * sum(pts) / len(pts)), {"got": obj}


def score_toolcall(item, r):
    calls = r["tool_calls"]
    if not calls:
        return 0, {"error": "no tool call"}
    first = calls[0]
    name_ok = first["name"] == item["gold"]["name"]
    args_ok = False
    detail = {}
    try:
        args = json.loads(first["args"] or "{}")
        detail = args
        args_ok = all(
            str(args.get(k, "")).strip().lower() == str(v).strip().lower()
            for k, v in item["gold"]["args_subset"].items()
        )
    except Exception:
        pass
    score = (60 if name_ok else 0) + (40 if args_ok else 0)
    return score, {"name": first["name"], "args": detail}


def score_unittest(item, r):
    m = re.findall(r"```(?:python)?\s*(.*?)```", r["content"], re.S)
    if not m:
        return 0, {"error": "no code block"}
    with tempfile.TemporaryDirectory() as td:
        with open(td + "/solution.py", "w", encoding="utf-8") as f:
            f.write(m[-1])
        with open(td + "/test.py", "w", encoding="utf-8") as f:
            f.write(item["test"])
        try:
            p = subprocess.run(
                [sys.executable, "test.py"], cwd=td, timeout=15,
                capture_output=True, text=True,
                env={"PYTHONPATH": td, "PATH": "/usr/bin:/bin"},
            )
        except subprocess.TimeoutExpired:
            return 0, {"error": "test timeout"}
    ok = p.returncode == 0
    return (100 if ok else 0), {"stderr": p.stderr[-300:] if not ok else ""}


def check_checklist(c, content):
    body = content.strip()
    if c.startswith("valid_json"):
        return parse_json_block(body) is not None
    if c.startswith("keys:"):
        obj = parse_json_block(body) or {}
        return all(k in obj for k in c[5:].split(","))
    m = re.match(r"(attendees|decisions)_len:(\d+)", c)
    if m:
        obj = parse_json_block(body) or {}
        v = obj.get(m.group(1))
        return isinstance(v, list) and len(v) == int(m.group(2))
    if c.startswith("no_word:"):
        return re.search(r"\b" + re.escape(c[8:]) + r"\b", body, re.I) is None
    m = re.match(r"date:(.+)", c)
    if m:
        obj = parse_json_block(body) or {}
        return obj.get("date") == m.group(1)
    m = re.match(r"lines:(\d+)", c)
    if m:
        lines = [l for l in body.splitlines() if l.strip()]
        return len(lines) == int(m.group(1))
    if c == "all_bullet":
        lines = [l for l in body.splitlines() if l.strip()]
        return bool(lines) and all(l.startswith("- ") for l in lines)
    m = re.match(r"word_count:(\w+):(\d+)", c)
    if m:
        return len(re.findall(r"\b" + m.group(1) + r"\b", body, re.I)) == int(m.group(2))
    if c == "no_heading":
        return not any(l.lstrip().startswith("#") for l in body.splitlines())
    m = re.match(r"md_table_header:(.+)", c)
    if m:
        return body.strip().splitlines()[0].strip() == m.group(1)
    m = re.match(r"table_rows:(\d+)", c)
    if m:
        rows = [l for l in body.splitlines()
                if l.strip().startswith("|") and not set(l) <= set("|-: ")]
        return len(rows) == int(m.group(1)) + 1
    if c == "last_row_serve_zero":
        rows = [l for l in body.splitlines() if l.strip().startswith("|")]
        if not rows:
            return False
        cells = [x.strip() for x in rows[-1].strip().strip("|").split("|")]
        return "serve" in cells[0].lower() and cells[1] == "0"
    if c == "nothing_after":
        lines = body.splitlines()
        idx = [i for i, l in enumerate(lines) if l.strip().startswith("|")]
        return bool(idx) and not any(l.strip() for l in lines[idx[-1] + 1:])
    return False


def score_checklist(item, r):
    pts = [check_checklist(c, r["content"]) for c in item["checks"]]
    return round(100 * sum(pts) / len(pts)), {"checks": dict(zip(item["checks"], pts))}


def run_agentic(item, base, key, model, timeout):
    msgs = []
    parts = []
    score = 0
    last = None
    for step in item["script"]:
        msgs.append({"role": "user", "content": step["user"]})
        last = chat(base, key, model, msgs, item.get("max_tokens", 1024),
                    tools=item.get("tools"), timeout=timeout)
        parts.append(last)
        calls = [c for c in last["tool_calls"] if c["name"]]
        if step["expect_tool"]:
            ok = bool(calls) and calls[0]["name"] == step["expect_tool"]
            score += 50 if ok else 0
            if calls:
                msg = {"role": "assistant", "content": last["content"] or None,
                       "tool_calls": [{"id": c["id"] or "call_x", "type": "function",
                                       "function": {"name": c["name"], "arguments": c["args"]}}
                                      for c in calls]}
                msgs.append(msg)
                msgs.append({"role": "tool",
                             "tool_call_id": calls[0]["id"] or "call_x",
                             "content": step.get("tool_result", "ok")})
            else:
                msgs.append({"role": "assistant", "content": last["content"]})
        else:
            score += 50 if not calls else 0
            msgs.append({"role": "assistant", "content": last["content"]})
    fin = item["script"][-1].get("expect_final_contains")
    detail = {"final_contains_ok": (fin is None) or (last and fin.lower() in last["content"].lower())}
    detail["tool_names"] = [p["tool_calls"][0]["name"] for p in parts
                            if p and p["tool_calls"]]
    return score, detail, parts


def score_agentic(item, r):
    return r["agentic_score"], r["agentic_detail"]


SCORERS = {
    "contains": score_contains,
    "number": score_number,
    "jsonfields": score_jsonfields,
    "toolcall": score_toolcall,
    "unittest": score_unittest,
    "checklist": score_checklist,
}
MEDIAN_CATS = {"c2-longctx": 2, "c3-tool": 2, "c7-agentic-if": 3}


def run_item(item, args, key):
    rec = {"id": item["id"], "cat": item["cat"], "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        extra = None
        if args.effort:
            extra = {"chat_template_kwargs": {"enable_thinking": True,
                                              "preserve_thinking": True,
                                              "reasoning_effort": args.effort}}
        if item["scorer"] == "agentic":
            score, detail, parts = run_agentic(item, args.base, key, args.model,
                                               args.timeout)
            r = parts[-1]
            rec.update({"score": score, "detail": detail,
                        "wall_s": round(sum(p["wall_s"] for p in parts), 3),
                        "ttft_s": r["ttft_s"],
                        "prompt_tokens": sum(p["prompt_tokens"] for p in parts),
                        "completion_tokens": sum(p["completion_tokens"] for p in parts),
                        "prefill_tps": r["prefill_tps"], "decode_tps": r["decode_tps"]})
            return rec
        messages = list(item.get("messages") or [])
        if "haystack" in item:
            messages = [{"role": "user", "content": make_haystack(item["haystack"])}]
        if item.get("question") and not messages:
            msgs = []
            if item.get("context"):
                msgs.append({"role": "user", "content": item["context"]})
            msgs.append({"role": "user", "content": item["question"]})
            messages = msgs
        if not messages and item.get("prompt"):
            messages = [{"role": "user", "content": item["prompt"]}]
        r = chat(args.base, key, args.model, messages,
                 item.get("max_tokens", 1024), tools=item.get("tools"),
                 extra=extra, timeout=args.timeout)
        score, detail = SCORERS[item["scorer"]](item, r)
        rec.update({"score": score, "detail": {k: v for k, v in detail.items()
                                               if k != "content"},
                    "wall_s": r["wall_s"], "ttft_s": r["ttft_s"],
                    "prompt_tokens": r["prompt_tokens"],
                    "completion_tokens": r["completion_tokens"],
                    "prefill_tps": r["prefill_tps"], "decode_tps": r["decode_tps"]})
    except Exception as e:
        rec.update({"score": 0, "error": f"{type(e).__name__}: {e}"[:300]})
    return rec


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 2) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:4000/v1")
    ap.add_argument("--model", default="pennyroyal")
    ap.add_argument("--key-file", default="/run/user/1000/litellm.key")
    ap.add_argument("--bank", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="", help="space-separated category prefixes")
    ap.add_argument("--effort", default="", help="reasoning_effort (low/medium/xhigh); empty = engine default")
    ap.add_argument("--timeout", type=int, default=480)
    args = ap.parse_args()

    key = open(args.key_file, encoding="utf-8").read().strip()
    items = load_bank(args.bank)
    if args.only:
        prefixes = args.only.split()
        items = [i for i in items
                 if any(i["cat"].startswith(p.strip("-").strip()) or i["cat"].split("-")[0] == p.strip("-").strip() for p in prefixes)]
    import os
    os.makedirs(args.out, exist_ok=True)
    runs_path = args.out + "/runs.jsonl"
    results = []
    for item in items:
        n = MEDIAN_CATS.get(item["cat"], 1)
        for _ in range(n):
            rec = run_item(item, args, key)
            results.append(rec)
            with open(runs_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec) + "\n")
            print(f"{rec['id']:8s} score={rec.get('score',0):3d} "
                  f"wall={rec.get('wall_s','?')} ttft={rec.get('ttft_s','?')} "
                  f"ptok={rec.get('prompt_tokens','?')} ctok={rec.get('completion_tokens','?')} "
                  f"dtps={rec.get('decode_tps','?')} ptps={rec.get('prefill_tps','?')}"
                  + (" ERROR:" + rec["error"][:120] if rec.get("error") else ""),
                  flush=True)
    cats = sorted({i["cat"] for i in items})
    lines = ["cat\tscore_med\twall_med_s\tttft_med_s\tprefill_tps_med\tdecode_tps_med\tprompt_tok_med\tn"]
    md = ["| Kategorie | Score (Median) | Wall s | TTFT s | Prefill t/s | Decode t/s | Prompt-Tokens | Läufe |",
          "|---|---|---|---|---|---|---|---|"]
    for c in cats:
        rs = [r for r in results if r["cat"] == c]
        row = [c, med([r.get("score", 0) for r in rs]), med([r.get("wall_s") for r in rs]),
               med([r.get("ttft_s") for r in rs]), med([r.get("prefill_tps") for r in rs]),
               med([r.get("decode_tps") for r in rs]), med([r.get("prompt_tokens") for r in rs]),
               len(rs)]
        lines.append("\t".join(str(x) for x in row))
        md.append("| " + " | ".join(str(x) for x in row) + " |")
    with open(args.out + "/summary.tsv", "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    with open(args.out + "/summary.md", "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    meta = {"base": args.base, "model": args.model, "bank": args.bank,
            "effort": args.effort or "engine-default", "utc": time.strftime("%FT%TZ", time.gmtime()),
            "items": len(items), "runs": len(results)}
    with open(args.out + "/meta.json", "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
    print("\n".join(md))
    print("OUT=" + args.out)


if __name__ == "__main__":
    main()
