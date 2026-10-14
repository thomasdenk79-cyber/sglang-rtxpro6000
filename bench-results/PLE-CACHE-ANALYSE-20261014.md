# PLE-NVMe im Betrieb: Cache-Bedarf, Hit-Rate, Spar-Potenzial (2026-10-14 03:00)

## Messwerte (xlong-c1, 8×32k Prompts, v3.0.1, Overlay 47,68 GiB FP8)

| Messung | Wert |
|---|---|
| Warm-Lauf (Boot-Checksum + Cache warm) | 56 KB echte Plattenreads / 848 MB logischer Bedarf → Hit-Rate ≈ 99,99 % |
| 2.独立 Warm-Lauf identischer Punkt | 220 KB (Systemrauschen), identisch |
| Idle 120 s nach Traffic | 454 KB reads / 453 KB writes — PLE-Seiten bleiben unverändert resident |
| fincore layer-0.bin nach Boot, Traffic, Idle | konstant 47,7G / 47,7G (100 %) |
| MemAvailable im NVMe-Betrieb | 107-111 GB; Cached ~155 GB |

## Warum "kalt" hier nicht messbar ist: das Design

1. Der Reader (ssd_stream) hat **keinen Zeilen-Cache** — jeder Forward-Pass
   holt die gebrauchten Zeilen durch den **Linux Page-Cache**; die einzigen
   begrenzten Strukturen sind 2×32 MiB gepinntes Staging. Es gibt keine
   Treffer-Zähler, weil es keinen Treffer-Begriff gibt: Cache = Kernel.
2. Der Start prüft die Prüfsumme des Präparats und liest dabei die **gesamte
   47,68-GiB-Datei sequentiell** durch. Damit ist der Zustand "Cache kalt,
   Traffic läuft" im Regelbetrieb unerreichbar: jeder Boot wärmt vollständig
   vor (≈ DB: Recovery-Scan beim Start statt Cold Buffer Pool).
3. drop_caches allein entlässt die gemmapte Tabelle nicht (Unevictable ~1,5G
   Konten + aktive Mappings); erst Restart + Boot-Checksum = wieder 100 % hot.

## Kernantwort auf "können wir RAM sparen, weil ~30 % der PLE kalt sind?"

Heute im aktuellen Setup: **der Page-Cache belegt im Betrieb konstant die
kompletten 47,7 GiB**, weil (a) die Boot-Prüfsumme alles durchliest und (b)
gleichförmiger Token-Zugriff auf 320 Mio Zeilen keinen stabilen warmen Kern
erzeugt. Der Unterschied zu PENNY_PLE_BACKEND=ram ist der Mechanismus, nicht
die Bilanz: RAM-Modus = 47,7 GiB **gepinnt** (unkompressibel, nicht eviktierbar,
bei Druck OOM-Risiko), NVMe-Modus = 47,7 GiB **reclaimbar** (unter Druck gibt
der Kernel sie frei, Traffic wird dann aber von der Platte bedient).
"Einsparung" existiert also nur unterm Druckfenster, nicht im ruhenden Betrieb.

Ein 30-%-Kern wäre nur ohne Boot-Checksummen-Zwang und mit ungleichförmigem
Tokenzugriff denkbar. Beides ist hier nicht gegeben; deshalb: kein realistisches
Sparpotenzial bei gleichem Traffic.

## ZFS ARC

Bei 188 GB RAM und voll-amen Cache bringt ARC gegenüber dem Page-Cache nichts —
höchstens Prefetch-Heuristiken. Relevant wäre es erst im künstlich
speicherarmen Szenario, das wir hier gar nicht haben. Setup-Aufwand (neuer
Pool, /srv ist btrfs) stünde in keinem Verhältnis; Überspringen empfohlen.

## Geplanter Knecht-Test (heute Nacht, in Runde C eingebaut)

Simulierter Speicherarmut-Betrieb, um die Technik von der Cache-Bequemlichkeit
zu trennen:
1. Restart mit `IOReadBandwidthMax=nvme-Gerät auf ~300 MB/s` (systemd-Override
   für pennyroyal.service) **und** MemoryHigh=20G (drückt den nutzbaren
   Page-Cache auf ~10-20 GB).
2. identische Matrix c1-c8 × 4 Tiers gegen NVMe; erwartet: short/medium
   kaum anders (Zeilen klein, Latenz-tolerant), xlong TTFT deutlich schlechter
   — Quantifizierung, wieviel vom "NVMe-Vorteil" in Wahrheit Linux-Cache ist.
3. Parallel dazu BF16-Runde C (104 GB Overlay) mit demselben Runner; der
   Runner zeichnet je Punkt den Blockstat-Delta auf (Hit-Rate-Beweis pro Punkt).
