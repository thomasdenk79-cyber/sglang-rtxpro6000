#!/usr/bin/env bash

# The Swift tokenizer is byte-different from the reference but has the same
# token-ID vocabulary and added-token records, with matching sampled encodings.
verify_frspec_tokenizer_sha() {
  case "$1" in
    0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3|\
    06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523)
      ;;
    *)
      echo "Target tokenizer is not one of the verified FR-Spec-compatible revisions" >&2
      return 1
      ;;
  esac
}
