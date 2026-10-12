# Shared Flash-Next request/state capacity; source before deriving the namespace.
# More admitted requests also need recurrent-state slots and graph headroom.
# Turbo/capacity profiles (measured unit costs on the RTX PRO 6000, see
# docs/local-deployment.md "Capacity planning"): slots = requests * 4 + 3,
# mamba pool ~58 MB/slot, decode graph buckets cap at MAX_RUNNING_REQUESTS,
# and --mem-fraction-static must give back ~1 GB per doubling of capacity.
# c8:   8 / 35 / fraction <= 0.970   c16:  16 / 67 / fraction <= 0.947
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-4}"
MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-24}"
# Waiting-request admission cap; overflow receives a fast 429 instead of being
# held in the scheduler where chunked-prefill admission would still touch GPU state.
MAX_QUEUED_REQUESTS="${MAX_QUEUED_REQUESTS:-32}"
for capacity_name in MAX_RUNNING_REQUESTS MAX_MAMBA_CACHE_SIZE MAX_QUEUED_REQUESTS; do
  if [[ ! ${!capacity_name} =~ ^[1-9][0-9]*$ ]]; then
    echo "$capacity_name must be a positive integer" >&2
    exit 1
  fi
done
