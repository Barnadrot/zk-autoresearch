#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
BENCH_DIR="$HOME/zk-autoresearch/leanMultisig-bench"
ZKALLOC_DIR="$HOME/zk-autoresearch/leanMultisig/zk-alloc"

# --- Configuration (override via env or edit) ---
ALLOCATORS="${ALLOCATORS:-glibc zkalloc mimalloc}"
MEMORY_LIMITS="${MEMORY_LIMITS:-64}"          # GB, space-separated
CORE_COUNTS="${CORE_COUNTS:-16}"              # space-separated
WORKLOAD="${WORKLOAD:-production_3x}"         # criterion_1400 or production_3x
PROOFS="${PROOFS:-3}"
SAMPLE_SIZE="${SAMPLE_SIZE:-20}"

# --- Pre-flight checks ---
preflight() {
    echo "=== Pre-flight checks ==="

    if swapon --show | grep -q .; then
        echo "FAIL: Swap is on. Run: sudo swapoff -a"
        exit 1
    fi
    echo "  swap: off"

    if ! command -v perf &>/dev/null; then
        echo "WARN: perf not found — perf_stat collection will be skipped"
    else
        echo "  perf: available"
    fi

    if ! command -v systemd-run &>/dev/null; then
        echo "FAIL: systemd-run not found — cannot enforce memory limits"
        exit 1
    fi
    echo "  systemd-run: available"

    for alloc in $ALLOCATORS; do
        case "$alloc" in
            glibc) ;;
            zkalloc)
                if [ ! -f "$ZKALLOC_DIR/libpreload_arena.so" ]; then
                    echo "Building zkalloc .so..."
                    (cd "$ZKALLOC_DIR" && gcc -O2 -shared -fPIC -o libpreload_arena.so preload_arena.c -ldl)
                fi
                echo "  zkalloc .so: ready"
                ;;
            mimalloc)
                if [ ! -f "$HOME/zk-autoresearch/mimalloc/out/release/libmimalloc.so" ]; then
                    echo "FAIL: mimalloc .so not built. Build it first."
                    exit 1
                fi
                echo "  mimalloc .so: ready"
                ;;
        esac
    done

    if [ ! -f "$BENCH_DIR/target/release/prove_loop" ]; then
        echo "Building prove_loop..."
        (cd "$BENCH_DIR" && cargo build --release --bin prove_loop)
    fi
    echo "  prove_loop: ready"

    echo "=== Pre-flight passed ==="
}

# --- Build LD_PRELOAD string for an allocator ---
preload_for() {
    local alloc="$1"
    case "$alloc" in
        glibc)    echo "" ;;
        zkalloc)  echo "$ZKALLOC_DIR/libpreload_arena.so" ;;
        mimalloc) echo "$HOME/zk-autoresearch/mimalloc/out/release/libmimalloc.so" ;;
        *)        echo "ERROR: unknown allocator $alloc" >&2; exit 1 ;;
    esac
}

# --- Run one configuration ---
run_one() {
    local alloc="$1"
    local mem_gb="$2"
    local cores="$3"
    local workload="$4"
    local commit_tag="${5:-current}"

    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local run_id="${timestamp}_${alloc}_${mem_gb}gb_${cores}c_${workload}_${commit_tag}"
    local run_dir="$RESULTS_DIR/$run_id"
    mkdir -p "$run_dir"

    echo ""
    echo "=== $run_id ==="

    # Write metadata
    cat > "$run_dir/meta.json" <<METAEOF
{
    "run_id": "$run_id",
    "timestamp": "$timestamp",
    "allocator": "$alloc",
    "memory_limit_gb": $mem_gb,
    "core_count": $cores,
    "workload": "$workload",
    "commit_tag": "$commit_tag",
    "machine": "$(hostname)",
    "cpu": "$(lscpu | grep 'Model name' | sed 's/.*: *//')",
    "total_ram_gb": $(free -g | awk '/Mem:/{print $2}'),
    "kernel": "$(uname -r)"
}
METAEOF

    local preload
    preload="$(preload_for "$alloc")"
    local preload_env=""
    [ -n "$preload" ] && preload_env="LD_PRELOAD=$preload"

    local taskset_cmd=""
    if [ "$cores" -lt "$(nproc)" ]; then
        local max_cpu=$((cores - 1))
        taskset_cmd="taskset -c 0-${max_cpu}"
    fi

    local mem_bytes=$((mem_gb * 1024 * 1024 * 1024))

    if [ "$workload" = "production_3x" ]; then
        # prove_loop with systemd-run memory limit
        echo "  Running prove_loop ${PROOFS} proofs..."
        sudo systemd-run --scope -p MemoryMax=${mem_bytes} --quiet \
            env $preload_env \
            $taskset_cmd \
            "$BENCH_DIR/target/release/prove_loop" "$PROOFS" \
            > "$run_dir/prove_loop.csv" \
            2> "$run_dir/prove_loop.log" || {
                echo "  FAILED (exit $?)" | tee "$run_dir/FAILED"
                return 0
            }

        # perf stat run (separate, 1 proof for perf data)
        if command -v perf &>/dev/null; then
            echo "  Running perf stat (1 proof)..."
            sudo systemd-run --scope -p MemoryMax=${mem_bytes} --quiet \
                perf stat -e task-clock,cycles,instructions,cache-references,cache-misses,page-faults,branch-misses,context-switches \
                env $preload_env \
                $taskset_cmd \
                "$BENCH_DIR/target/release/prove_loop" 1 \
                > /dev/null \
                2> "$run_dir/perf_stat.txt" || true
        fi

    elif [ "$workload" = "criterion_1400" ]; then
        echo "  Running Criterion (sample_size=$SAMPLE_SIZE)..."
        sudo systemd-run --scope -p MemoryMax=${mem_bytes} --quiet \
            env $preload_env \
            $taskset_cmd \
            cargo bench --manifest-path "$BENCH_DIR/Cargo.toml" \
                --bench xmss_leaf_glibc \
                -- --sample-size "$SAMPLE_SIZE" --output-format verbose \
            > "$run_dir/criterion.txt" \
            2> "$run_dir/criterion.log" || {
                echo "  FAILED (exit $?)" | tee "$run_dir/FAILED"
                return 0
            }
    fi

    echo "  Done -> $run_dir"
}

# --- Main ---
preflight

mkdir -p "$RESULTS_DIR"

echo ""
echo "Matrix: allocators=[$ALLOCATORS] mem=[$MEMORY_LIMITS] cores=[$CORE_COUNTS] workload=$WORKLOAD"
echo ""

for mem_gb in $MEMORY_LIMITS; do
    for cores in $CORE_COUNTS; do
        for alloc in $ALLOCATORS; do
            run_one "$alloc" "$mem_gb" "$cores" "$WORKLOAD"
        done
    done
done

echo ""
echo "=== All runs complete. Results in $RESULTS_DIR ==="
