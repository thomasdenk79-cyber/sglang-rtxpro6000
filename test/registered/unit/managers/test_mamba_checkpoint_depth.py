"""The donated mamba checkpoint depth must land on the tree page.

DCP widens the tree page past the mamba chunk grid. A checkpoint picked on the
finer grid names a depth no radix node can carry, so it gets attached to the
preceding node and a later request resumes from a state that already covers
tokens past that node.
"""

import unittest
from array import array
from types import SimpleNamespace
from unittest.mock import MagicMock

import torch

from sglang.srt.managers.schedule_batch import Req, ScheduleBatch
from sglang.srt.managers.schedule_policy import (
    _floor_chunk_cut,
    combine_truncation_align,
)
from sglang.srt.runtime_context import get_context, mamba_track_grid
from sglang.srt.sampling.sampling_params import SamplingParams
from sglang.srt.server_args import (
    ServerArgs,
    set_global_server_args_for_scheduler,
)
from sglang.test.ci.ci_register import register_cpu_ci

register_cpu_ci(est_time=2, suite="base-a-test-cpu")

CHUNK = 64


def _track_seqlen(*, tree_page: int, prefix_len: int, extend_len: int) -> int:
    """Run one extend through the tracker and report the donated depth."""
    server_args = ServerArgs(model_path="dummy", page_size=CHUNK)
    # The property would otherwise load the HF config for the dummy model.
    server_args._mamba_cache_chunk_size = CHUNK
    set_global_server_args_for_scheduler(server_args)

    sampling_params = SamplingParams(max_new_tokens=1)
    sampling_params.normalize(None)
    req = Req(
        rid="req",
        origin_input_text="",
        origin_input_ids=array("q", [1] * (prefix_len + extend_len)),
        sampling_params=sampling_params,
        vocab_size=128,
    )
    req.prefix_indices = torch.arange(prefix_len, dtype=torch.int64)
    req.set_extend_range(prefix_len, prefix_len + extend_len)
    req.mamba_ping_pong_track_buffer = torch.tensor([0, 1], dtype=torch.int64)
    req.mamba_next_track_idx = 0
    req.mamba_branching_seqlen = None

    batch = ScheduleBatch(reqs=[req])
    batch.tree_cache = SimpleNamespace(page_size=tree_page)
    batch.req_to_token_pool = MagicMock()
    batch.req_to_token_pool.get_mamba_ping_pong_other_idx.return_value = 1

    batch._mamba_radix_cache_v2_req_prepare_for_extend(req)
    return req.mamba_last_track_seqlen


class TestMambaCheckpointDepth(unittest.TestCase):
    def test_widened_tree_page_moves_the_donated_depth_onto_it(self):
        # 4066 tokens past a 16384 prefix: the chunk grid would stop at 20416,
        # which a 256-token page cannot name.
        depth = _track_seqlen(tree_page=256, prefix_len=16384, extend_len=4066)
        self.assertEqual(depth % 256, 0)
        self.assertEqual(depth, 20224)

    def test_unwidened_tree_page_keeps_the_chunk_grid(self):
        depth = _track_seqlen(tree_page=CHUNK, prefix_len=16384, extend_len=4066)
        self.assertEqual(depth, 20416)


class TestChunkedPrefillMambaAlignment(unittest.TestCase):
    def test_combines_existing_alignment_with_mamba_grid(self):
        self.assertEqual(combine_truncation_align(None, grid=CHUNK), CHUNK)
        self.assertEqual(combine_truncation_align(4096, grid=CHUNK), 4096)
        self.assertEqual(combine_truncation_align(96, grid=CHUNK), 192)
        self.assertEqual(combine_truncation_align(4096, grid=1), 4096)

    def test_continuing_cuts_stay_on_grid_without_zero_progress(self):
        total = 100_000
        prefix = 0
        cuts = []
        for budget in (8192, 5000, 8192, 3333, 8192, 777):
            remaining = total - prefix
            cut = _floor_chunk_cut(
                min(budget, remaining),
                extend_input_len=remaining,
                truncation_align_size=CHUNK,
            )
            self.assertGreater(cut, 0)
            self.assertEqual(cut % CHUNK, 0)
            depth = _track_seqlen(
                tree_page=CHUNK, prefix_len=prefix, extend_len=cut
            )
            self.assertEqual(depth % CHUNK, 0)
            cuts.append(cut)
            prefix += cut
        self.assertEqual(cuts, [8192, 4992, 8192, 3328, 8192, 768])

    def test_final_and_sub_grid_cuts_keep_their_length(self):
        self.assertEqual(
            _floor_chunk_cut(
                37, extend_input_len=37, truncation_align_size=CHUNK
            ),
            37,
        )
        self.assertEqual(
            _floor_chunk_cut(
                40, extend_input_len=8192, truncation_align_size=CHUNK
            ),
            40,
        )


class TestMambaTrackGrid(unittest.TestCase):
    def _grid(self, *, interval: int, tree_page: int, chunk: int = CHUNK) -> int:
        with get_context().override_server_args(
            mamba_track_interval=interval, _mamba_cache_chunk_size=chunk
        ):
            return mamba_track_grid(tree_page)

    def test_widened_tree_page_rounds_the_interval_up(self):
        self.assertEqual(self._grid(interval=256, tree_page=512), 512)

    def test_interval_already_on_the_tree_page_is_untouched(self):
        self.assertEqual(self._grid(interval=256, tree_page=256), 256)
        self.assertEqual(self._grid(interval=256, tree_page=128), 256)
        self.assertEqual(self._grid(interval=256, tree_page=64), 256)

    def test_grid_stays_on_the_chunk_size(self):
        self.assertEqual(self._grid(interval=192, tree_page=64, chunk=128) % 128, 0)


if __name__ == "__main__":
    unittest.main()
