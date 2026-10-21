# Shared Flash-Next request/state capacity; source before deriving the namespace.
# More admitted requests also need recurrent-state slots and graph headroom.
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"
MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-}"
MAMBA_CACHE_ARGS=()
MAMBA_CACHE_SIZE_ID=auto
if [[ -n "$MAX_MAMBA_CACHE_SIZE" ]]; then
  MAMBA_CACHE_ARGS=(--max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE")
  MAMBA_CACHE_SIZE_ID="$MAX_MAMBA_CACHE_SIZE"
fi
for capacity_name in MAX_RUNNING_REQUESTS; do
  if [[ ! ${!capacity_name} =~ ^[1-9][0-9]*$ ]]; then
    echo "$capacity_name must be a positive integer" >&2
    exit 1
  fi
done
if (( ${#MAX_RUNNING_REQUESTS} > 1 )) || [[ "$MAX_RUNNING_REQUESTS" > 8 ]]; then
  echo "MAX_RUNNING_REQUESTS must be between 1 and 8" >&2
  exit 1
fi
if [[ -n "$MAX_MAMBA_CACHE_SIZE" && ! "$MAX_MAMBA_CACHE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "MAX_MAMBA_CACHE_SIZE must be a positive integer" >&2
  exit 1
fi
