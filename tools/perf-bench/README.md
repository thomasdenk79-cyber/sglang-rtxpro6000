# perf-bench c1-c8

Kategorie-Bank (`bank.jsonl`, ryangu00-Namen: c1-kbqa, c2-longctx, c3-tool,
c4-code, c5-extract, c6-math, c7-agentic-if, c8-judgment) mit deterministischen
Gold-Antworten und Auto-Scoring; Messgroessen je Lauf: Score, Wall, TTFT,
Prefill-/Decode-tok/s, Prompt-Tokens (SSE-usage der Engine).

Ausfuehren (sequentiell, genau ein Set zur Zeit):

    OUT_DIR=/srv/work/flashnext/logs/perf-bench-<ts> ./run-c1-c8.sh [--only c1 c3] [--effort low]

Vor jedem Lauf schreibt der Runner Power-Limit, Engine-State und Git-Head nach
`meta.txt` — Bedingungen sind damit mit dem Ergebnis verankert (A/B ueber
Power-Limit oder `--effort`). Aggregat: `summary.tsv`/`summary.md`
(Mediane pro Kategorie, Kilo-/Tool-Kategorien median aus 2-3 Laeufen);
Rohevents: `runs.jsonl`. c2 erzeugt einen ~150k-Token-Heuhaufen deterministisch
im Client, die Bank-Datei bleibt klein.
