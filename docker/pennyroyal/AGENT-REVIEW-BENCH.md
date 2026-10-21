# Agent-Review-Benchmark

Das Merge-Gate dieses Projekts verlangt ein bis drei unabhaengige Reviewer pro
Merge. Dieser Benchmark misst, welcher Harness diese Rolle uebernimmt, und ist
damit der Verifizierungspunkt der Reviewer-Auswahl: Wer freigibt, muss
nachweislich finden, was im Baum steht, und das innerhalb eines Budgets.

## Messaufbau

- Aufgabe: Review des Commitsbereichs `6b501b800..HEAD` auf `flashnext/bf16`
  (12 Commits, 65 Dateien: PR-Ports #79/#86/#76, FR-Spec-Profil, OCI-Metadaten,
  Guard-Audit, Docs). Prompt: `prompt.md`, Ausgabeformat
  VERDICT / FINDINGS / TESTS / NOTES.
- Randbedingungen: nur lesen, keine Testlaeufe, kein Container-Eingriff,
  kein Build, kein Benchmark der Engine. Zeitlimit 1200 s (Runde 1).
- Modelle: LiteLLM-Router `auto` fuer codex, opencode, hermes, aider;
  copilot ueber sein GitHub-Backend.
- Ground Truth: `ground-truth.md`, 13 Defekte, alle von Hand, per Container-Suite
  im gebauten Bild oder per Diff verifiziert. Ein Finding zaehlt nur, wenn die
  Pruefung es traegt; erfundene Funde zaehlen als False Positive.
- Scoring: Fundabdeckung gegen Ground Truth, False Positives, Qualitaet der
  Testnachweise, Format- und Randbedingungstreue, dazu Laufzeit, Tokenverbrauch
  und Kosten aus den Logaden der Harnesses.

## Runde 1 — 2026-10-21

Head `1d3b74e78`, Limit 1200 s, ein Lauf je Harness, paralleler Start.

| Harness | rc | Laufzeit | Tokens | Kosten | Urteil des Reviews | Funde / verifiziert |
|---|---|---|---|---|---|---|
| copilot | 0 | 367 s | 968,4k Prompt (841,2k Cache) / 24,0k Output (19,6k Reasoning) | 3,63 AI-Credits | fix-and-adopt | 3 / 3 |
| hermes | 0 | 1016 s | nicht berichtet (`--usage-file` akzeptiert, Datei nie geschrieben) | n/a | fix-and-adopt | 6 / 6 |
| opencode | 0 | 1178 s | 2.153.136 Prompt / 5.897 Output + 19.343 Reasoning | 0 (lokaler Router) | fix-and-adopt | 7 / 7 |
| codex | 124 (Timeout) | 1200 s | keine Bilanz, kein Summary; 316 KB Log, eine Kontextkompaktierung | n/a | keine Lieferung | 0 / – |
| aider | 0 | 337 s | 47k gesendet / 1,0k erhalten | 0 (lokaler Router) | return | 0 / – |

### Fundabdeckung gegen Ground Truth

Legende: `+` gefunden und verifiziert, `n` nicht gefunden, `N` Bericht ohne
Lieferung, `-` Review ohne Codezugriff.

| # | Defekt | copilot | hermes | opencode | codex | aider |
|---|---|---|---|---|---|---|
| 1 | Guard-Manifest gestanden, Handover-Diagnose „unmodified QSA module“ falsch | Notiz | + | + | N | - |
| 2 | qsa/sm120-Heads im Handover transkribiert, `git cat-file` => not our ref | n | + | n | N | - |
| 3 | `FLASHNEXT-VARIANTS.md`: BF16-Zeile zeigt auf Docs-Commit `e6ffa5994` | n | + | + | N | - |
| 4 | Guard-Manifest ist selbstreferenzielle Allowlist (Plugin iteriert Manifest-Keys) | + | n | n | N | - |
| 5 | Transplant-Tool liefert Spender-Tokenizer aus | + | n | n | N | - |
| 6 | Dockerfile: Provenance-ARGs unvalidiert, `SOURCE_REPOSITORY`-Default = Upstream | + | + | + | N | - |
| 7 | 8er-Deckel im Shared-Helper gilt auch fuer Plain-Rezepte | n | n | + | N | - |
| 8 | `b9652e5e4`: literale `\n\n`, Co-Author-Trailer unparsable | n | n | + | N | - |
| 9 | Same-Path-Mounts exponieren Nachbar-Datasets | n | n | + | N | - |
| 10 | `refresh-source-guard.py`: kein Dirty-Tree-Guard, Provenance = Parent-Commit | n | n | + | N | - |
| 11 | `SGLANG_FLASHINFER_MOE_FUSED_FINALIZE` True->False, global auf dem Shared-Branch | n | + | n | N | - |
| 12 | `release-3.0.2.json` im Flug committet (`container: building`, `digest: null`) | n | + | n | N | - |
| 13 | `test_recipes_source_and_run_the_tp_guard` kann nicht bestehen (README ohne `device_ids`) | n | n | n | N | - |

Defekt 13 hat der Auftrag selbst gefunden, durch den Suite-Lauf im gebauten Bild.
Kein Reviewer durfte Tests ausfuehren; diese Zeile ist die messbare Grenze des
Setups und der Grund, warum das Merge-Gate zusaendlich zur Suite-lauffaehigkeit
geprueft wird.

### Bewertung

| Harness | Review-Note | Brauchbarkeit | Begruendung |
|---|---|---|---|
| opencode | 5 | 8,5 | Sieben Funde, alle echt, vier einzigartige; Byte-Vergleich gegen PR-Heads. Ein Test-Claim zu breit formuliert („match exactly“ nach Präfixvergleich). 2,15M Prompt-Tokens, null Cache-Treffer. |
| hermes | 4,5 | 8 | Sechs Funde, alle echt, vier einzigartige, saubere Trennung verifiziert / nicht verifizierbar. `--usage-file` schreibt keine Datei, damit keine Tokenbuchfuehrung. |
| copilot | 3,5 | 9 | Drei Funde, 100 % Präzision, zwei davon die schwerwiegendsten. Schnellster Lauf, sauberste Kostenangabe. |
| codex | 1 | 5 | Beste Isolation (`--sandbox read-only`), beste Review-Subcommand. 1200 s Read-Loop, Kompaktierung, keine Lieferung. |
| aider | 1 | 3 | Oneshot ohne Shell/Zugriff auf den Baum: kein Code-Review moeglich. `--read-only` existiert nicht, schreibt Cache und History in den Projektbaum. |

### Randbedingungs- und Artefaktpruefung

Alle fuenf haben im Bereich nichts geaendert; die `git status`-Prüfung pro Lauf
war global kontaminiert, well aider im ersten Lauf `.aider*` im Worktree
hinterlassen hatte und die Pruefung aller Laeufe dasselbe Verzeichnis sahen.
Einzige Schreibgriffe: aider `.aider.tags.cache.v4/` (untracked) und ein
Eintrag in `.git/info/exclude`; hermes meldete eigene `__pycache__`-Aktivitaet,
keine Aenderung an getrackten Dateien. Der Produktionscontainer
`luni-llm-orcarouter` war waehrend der gesamten Messung aktiv und unveraendert.

### Erststartreibung

| Harness | Aufwaendigung beim ersten Start |
|---|---|
| copilot | keine |
| codex | keine |
| opencode | `--dir` existiert nicht, Arbeitsverzeichnis ist das cwd |
| hermes | `--usage-file` muss vor dem Subcommand stehen |
| aider | unbekanntes Flag `--read-only`, fehlender `OPENAI_API_KEY`; spaeter `model-metadata-file` gegen die Warnseite noetig |

## Runde 2 — vorbereitet, Start im ruhigen Fenster

Ein Benchmark-Set laeuft allein. Diese Messung laeuft nicht parallel zu Builds,
Bild-Baustellen, anderen Benchmark-Sets oder Engine-Starts; sie haelt den
Router, die Platte und die CPU frei, damit Zeit und Tokenzahl vergleichbar
bleiben. Nach den Reviewer-Benchmarks kommen im ruhigen Fenster die
Performance-Benchmarks der Engine.

Runde 1 hatte vier Messluecken, die der Runner in diesem Verzeichnis schliesst:

1. Isolierte Worktrees je Harness, damit die Aenderungspruefung einem Harness
   zurechenbar ist.
2. Tokenbilanz je Harness aus dessen eigenem Format, inklusive
   “nicht verfuegbar” als explizitem Wert (hermes schreibt keine usage-Datei).
3. Drei Wiederholungen je Harness fuer Laufzeit und Tokenverbrauch, reporte Median.
4. Abbruchgrund als Feld (Timeout, Abbruch, Fehler), nicht als rc-Ziffer alone.

Start: `tools/agent-bench/bench.sh --repo <pfad> --head <sha> --limit 900
--repeats 3` (sequenziell, isolierte Worktrees je Harness, `--parallel` nur
ausdruecklich); Matrix: `tools/agent-bench/score.py <runs/verzeichnis>`
schreibt die Markdown-Tabelle, die dann unter Runde 2 in diesem Dokument
steht.

## Konsequenz fuer das Merge-Gate

- Primere Reviewer: copilot (Praezision, Kosten, Zeit) und hermes (Tiefe pro
  Sekunde). Fuer Security-, Lifecycle- und Infrastruktur-Aenderungen dritter
  Reviewer opencode.
- codex nur mit engerem Scope (ein Verzeichnis, `codex exec review`, eigenes
  Budget); mit dem vollen Bereich dieser Aufgabe liefert er nichts ab.
- aider aus der Review-Rotation; als Editier-Werkzeug im interaktiven Modus
  weiterhin nutzbar.
- Kein Reviewer ersetzt die Suite: Defekt 13 war nur im Container-Lauf sichtbar.
