# Ground Truth für den Review-Benchmark

Punkte, die ein Review im Bereich finden kann. Jeder Punkt ist von Hand, durch
den Suite-Lauf im gebauten Bild oder durch Diff verifiziert; ein Review-Fund
zählt nur, wenn die Prüfung in der letzten Spalte ihn trägt.

| # | Punkt | Prüfung |
|---|---|---|
| 1 | Handover-Diagnose „legacy source-guard test has a stored hash mismatch for an unrelated, unmodified QSA module“ ist falsch: PR #79 (`b9652e5e4`) ändert drei der elf geschützten Module, das Manifest war gestanden | `python3 -c` SHA-256 der elf Module gegen `pennyroyal-source.json`; Suite-Lauf im Bild am alten Kopf: Guard-Test FAILED |
| 2 | qsa/sm120-Heads im Handover existieren nicht: `63fd73ef04fa…` und `fdfc29987c9a…` sind transkribiert; die echten Köpfe teilen nur die Präfixe | `git cat-file -t 63fd73ef04fa51d956c50509979d7bd900944df0` => `upload-pack: not our ref` |
| 3 | `docker/pennyroyal/FLASHNEXT-VARIANTS.md`: BF16-Zeile nennt `e6ffa59942fc…` als „Variant implementation commit“, das ist `docs: update Flash-Next handover`; Implementation ist `889268c66` | `git log -1 --format=%s e6ffa59942fc…` |
| 4 | Guard-Manifest ist eine selbstreferenzielle Allowlist: der Plugin iteriert die Manifest-Keys (`plugin.py:116,182`), das Audit-Tool konserviert Auslassungen (`refresh-source-guard.py:49`), der Test prüft nur ein Modul (`test_ple_nvme_integration.py:241`) | Code-Leseprüfung; kanonische Modulmenge aus `plugin.REQUIRED_SGLANG_MODULES` |
| 5 | Transplant-Tool kopiert Tokenizer-Dateien des FP8-Spenders und schließt die der Basis aus (`transplant_ple_fp8.py:495,504-505`), die Doku erklärt den Swift-Tokenizer zur Basis | Code-Leseprüfung gegen `SWIFT1.5-FLASH-NEXT.md:22` |
| 6 | Provenance-ARGs im Dockerfile ohne Default und ohne Prüfung; `SOURCE_REPOSITORY` defaultet auf Upstream, ein argumentfreier Build labelt ein Fork-Bild als Upstream mit leeren `io.flashnext.*` | `docker/pennyroyal/Dockerfile` ARG/LABEL-Block; der Guard im Runtime-Stage seit `c6b712a100` bricht im Negativtest mit „build arg SOURCE_REVISION is required and must not be empty“ (rc=1) und lässt den vollen Arg-Satz durch (rc=0) |
| 7 | Der Acht-Request-Deckel sitzt im geteilten `configs/pennyroyal/request-capacity.sh`, den auch die Plain-Rezepte source'n: `MAX_RUNNING_REQUESTS=16` war in v3.0.2 legal und beendet jetzt jeden Flash-Next-Start | `MAX_RUNNING_REQUESTS=16 bash -c 'source configs/pennyroyal/request-capacity.sh'` => Exit 1 |
| 8 | `b9652e5e4`-Commit-Body enthält literale `\n\n` vor `Co-authored-by:`, das Trailer wird nicht geparst | `git log -1 --format=%B b9652e5e4 \| cat -A` |
| 9 | Same-Path-Mounts in `docker/pennyroyal/launch/run.sh` (`--checkpoint-root /srv/ai/models`, `--ple-root /srv/ai/ple`) exponieren read-only alle Nachbar-Datasets, nicht nur die zwei des Profils | `ls /srv/ai/models /srv/ai/ple/data` |
| 10 | `refresh-source-guard.py` hasht den Arbeitsbaum ohne Dirty-Prüfung und datiert den Parent-Commit ein: ein Manifest kann aus ungecommitteten Bytes entstehen und durch die Laufzeitprüfung kommen | Code-Leseprüfung; seit Runde-2-Tool mit `--require-clean` und `--check` ohne `--source` geschlossen |
| 11 | `SGLANG_FLASHINFER_MOE_FUSED_FINALIZE` kippt von `True` auf `False` und ändert damit den MoE-Finalize-Pfad aller Nutzer des geteilten Zweigs, nicht nur Flash-Next | `git diff 6b501b800..HEAD -- python/sglang/srt/environ.py` |
| 12 | `release-3.0.2.json` im Flug committet: `source_publication: published`, `container: building` mit Build-URL und `digest: null` | Datei im Wurzelverzeichnis, committet in `b9652e5e4` |
| 13 | `test_recipes_source_and_run_the_tp_guard` kann in diesem Baum nicht bestehen: Assertion erwartet `device_ids: ["0", "1"]` in `docker/pennyroyal/README.md`, dort steht kein solcher Text | Suite-Lauf im Bild: FAILED, einzige Fehlstelle dieser Art |

Runde 1 (2026-10-21, Head `1d3b74e78`, Limit 1200 s, ein Lauf je Harness):

| Punkt | copilot | hermes | opencode | codex | aider |
|---|---|---|---|---|---|
| 1 | Notiz | + | + | keine Lieferung | kein Codezugriff |
| 2 | – | + | – (Präfixvergleich als „exactly“ gemeldet) | keine Lieferung | kein Codezugriff |
| 3 | – | + | + | keine Lieferung | kein Codezugriff |
| 4 | + | – | – | keine Lieferung | kein Codezugriff |
| 5 | + | – | – | keine Lieferung | kein Codezugriff |
| 6 | + | + | + | keine Lieferung | kein Codezugriff |
| 7 | – | – | + | keine Lieferung | kein Codezugriff |
| 8 | – | – | + | keine Lieferung | kein Codezugriff |
| 9 | – | – | + | keine Lieferung | kein Codezugriff |
| 10 | – | – | + | keine Lieferung | kein Codezugriff |
| 11 | – | + | – | keine Lieferung | kein Codezugriff |
| 12 | – | + | – | keine Lieferung | kein Codezugriff |
| 13 | – | – | – | keine Lieferung | kein Codezugriff |
