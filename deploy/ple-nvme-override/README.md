# NVMe-PLE reader override (local, documented deviation)

Problem: image v3.0.1 (`6ade93c`) ships the BF16 element-size hotfix, but the
FP8 PLE table keeps the stock 16 MiB staging budget -> capacity 104857 rows.
Our FR-Spec adaptive width (steps 7 / draft 8, chunk 8192) asks exactly
131072 rows per prefill forward -> `PLE lookup needs 131072 staging rows`
RuntimeError kills the first big request (observed 2026-10-14 00:41).

Fix: `backend.py` identical to `e6319ae46` except `_STAGING_MIB = 32`
(row budget 32 MiB for FP8, 64 MiB BF16 => capacity 209715/104857*209715...
per dtype). Cost: 2 staging slots x 32 MiB pinned per PLE layer. Pattern
follows the upstream BF16 hotfix (mount a patched backend.py over the image
plugin, see tools/ple_nvme/BF16-STAGING-HOTFIX.md).

Applied via Quadlet:
`Volume=/srv/ai/ple/overrides/backend.py:/opt/pennyroyal/.ple-nvme/sglang_ssd_stream/backend.py:ro`
Host copy: /srv/ai/ple/overrides/backend.py (0644, owner uid 100999).
Verified: SSD Stream enabled capacity=209715 rows (00:50:37 boot).

Remove by switching PENNY_PLE_BACKEND=ram (default) or dropping the volume
line. If upstream releases a reader with a configurable budget, retire this.
