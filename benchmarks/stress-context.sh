#!/usr/bin/env bash
# stress-context.sh — Replicate the CUDA kernel timeout failure scenario
#
# The crash happened during multi-turn conversation at ~58K context tokens,
# with each turn generating ~4K tokens (reasoning+answer) at ~90 t/s.
# The CUDA kernel timed out during cudaStreamSynchronize after sustained
# generation at high context depth.
#
# This test replicates that by:
#   1. Building up context through successive conversation turns
#   2. Each turn requests a long generation (~4K tokens)
#   3. Context grows by ~5-6K tokens per turn (prompt + generation)
#   4. Monitors for failures: connection drops, HTTP errors, throughput collapse
#
# Usage:
#   ./benchmarks/stress-context.sh                    # Default: 12 turns, target 60K tokens
#   ./benchmarks/stress-context.sh --turns 20         # More turns, push to ~100K
#   ./benchmarks/stress-context.sh --port 10500       # Custom port
#   ./benchmarks/stress-context.sh --max-tokens 8192  # Longer generations per turn

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
HOST="${HOST:-localhost}"
PORT="${PORT:-10500}"
TURNS="${TURNS:-12}"
MAX_TOKENS="${MAX_TOKENS:-4096}"
MODEL="${MODEL:-}"
VERBOSE="${VERBOSE:-0}"

# ── Parse args ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)      HOST="$2"; shift 2 ;;
        --port)      PORT="$2"; shift 2 ;;
        --turns)     TURNS="$2"; shift 2 ;;
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --model)     MODEL="$2"; shift 2 ;;
        --verbose)   VERBOSE=1; shift ;;
        --help|-h)
            echo "Usage: $0 [--host HOST] [--port PORT] [--turns N] [--max-tokens N] [--verbose]"
            echo ""
            echo "Stress test to replicate CUDA kernel timeout at high context depth."
            echo "Builds a multi-turn conversation, generating ~4K tokens per turn,"
            echo "pushing context to 55K+ tokens where the original crash occurred."
            exit 0
            ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

BASE_URL="http://${HOST}:${PORT}"

# ── Colors ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# ── Check server is up ────────────────────────────────────────────────
info "Checking server at ${BASE_URL}..."
if ! curl -sf "${BASE_URL}/health" > /dev/null 2>&1; then
    fail "Server not responding at ${BASE_URL}/health"
    exit 1
fi
ok "Server is healthy"

# ── Prompts designed to elicit long reasoning responses ───────────────
# Each prompt asks for deep analysis to trigger ~4K token generations,
# matching the workload pattern that caused the crash.
PROMPTS=(
    "Explain the complete history and evolution of the x86 instruction set architecture, from the Intel 8086 through modern x86-64 extensions. Cover each major generation, the key instructions added, backward compatibility considerations, and how the architecture adapted to 64-bit computing. Be extremely thorough and detailed."
    "Write a comprehensive technical analysis of how modern GPU architectures handle memory coalescing, warp scheduling, and occupancy optimization. Cover NVIDIA's Ampere, Ada Lovelace, and Blackwell architectures specifically. Include concrete examples of how kernel launch configurations affect performance."
    "Provide an exhaustive comparison of B-trees, B+ trees, LSM trees, and fractal trees as database index structures. Cover their theoretical complexity, practical performance characteristics, write amplification, read amplification, space amplification, and which workloads each is best suited for. Include detailed examples."
    "Explain the complete TCP/IP stack from the physical layer through the application layer. For each layer, describe the protocols, header formats, state machines, flow control mechanisms, and congestion avoidance algorithms. Pay special attention to TCP's congestion control evolution from Tahoe through BBR."
    "Write a detailed technical essay on the evolution of filesystem design from FAT through ext4, XFS, Btrfs, and ZFS. Cover journaling strategies, copy-on-write semantics, checksumming, compression, deduplication, snapshot mechanisms, and RAID implementations. Compare their approaches to data integrity."
    "Analyze the complete lifecycle of a Linux process from fork() through exit(). Cover virtual memory layout, page table management, context switching, scheduler classes (CFS, SCHED_FIFO, SCHED_DEADLINE), signal handling, ptrace, namespaces, cgroups, and seccomp. Be extremely detailed."
    "Provide a comprehensive analysis of modern CPU branch prediction techniques, including two-level adaptive predictors, tournament predictors, TAGE, perceptron predictors, and the interaction between branch prediction and speculative execution. Cover Spectre-class vulnerabilities and their mitigations."
    "Write an exhaustive guide to the Rust ownership system, covering ownership rules, borrowing, lifetimes, the borrow checker, interior mutability, Pin, Unpin, variance, subtyping, higher-ranked trait bounds, and how these features interact with async/await. Include concrete code examples for each concept."
    "Explain distributed consensus algorithms in extreme detail: Paxos, Multi-Paxos, Raft, Viewstamped Replication, PBFT, and HotStuff. For each, cover the message flows, leader election, log replication, safety proofs, liveness guarantees, and real-world implementations."
    "Provide a deep technical analysis of how modern compilers optimize code, covering SSA form, dominator trees, loop optimizations, vectorization, register allocation (graph coloring vs linear scan), instruction selection, instruction scheduling, link-time optimization, and profile-guided optimization."
    "Write a comprehensive analysis of cryptographic hash functions from MD5 through SHA-3, covering the Merkle-Damgård construction, the sponge construction, length extension attacks, collision resistance proofs, and practical applications in digital signatures, HMACs, key derivation, and proof-of-work systems."
    "Explain the complete NVIDIA CUDA programming model in extreme detail: thread hierarchy, memory hierarchy (registers, shared, L1, L2, global, constant, texture), warp execution, bank conflicts, memory coalescing, streams, events, unified memory, cooperative groups, and dynamic parallelism."
    "Analyze the design and implementation of the Linux kernel's memory management subsystem. Cover the buddy allocator, slab/slub/slob, vmalloc, page cache, swap, memory compaction, transparent huge pages, NUMA balancing, OOM killer, memory cgroups, and reclaim watermarks."
    "Write a detailed comparison of garbage collection algorithms: mark-sweep, mark-compact, copying, generational, concurrent mark-sweep, G1, ZGC, Shenandoah, and the Azul C4 collector. Cover pause times, throughput, memory overhead, and the engineering tradeoffs in each design."
    "Provide an exhaustive analysis of database transaction isolation levels from Read Uncommitted through Serializable. Cover the anomalies each prevents, implementation techniques (2PL, MVCC, SSI), and how PostgreSQL, MySQL/InnoDB, and Oracle implement each level differently."
    "Explain the complete LLVM compilation pipeline in extreme detail, from Clang frontend through LLVM IR, optimization passes, instruction selection via SelectionDAG and GlobalISel, register allocation, and machine code emission. Cover the pass manager, analysis passes, and how to write custom passes."
    "Write a comprehensive technical analysis of container runtimes. Cover Linux namespaces (all 8 types), cgroups v1 vs v2, overlay filesystems, seccomp-BPF, capabilities, AppArmor/SELinux integration, and how Docker, containerd, CRI-O, and Kata Containers differ in their approaches."
    "Analyze the complete HTTP/2 and HTTP/3 protocol specifications. Cover binary framing, multiplexing, stream prioritization, header compression (HPACK/QPACK), flow control, server push, connection coalescing, and the QUIC transport layer including its loss detection and congestion control."
    "Provide an extremely detailed analysis of modern SSD architecture: NAND flash physics, FTL design, wear leveling, garbage collection, write amplification, over-provisioning, NVMe command sets, multi-queue I/O, and how ZNS (Zoned Namespaces) and FDP (Flexible Data Placement) change the landscape."
    "Write a comprehensive essay on the theory and practice of distributed systems debugging. Cover vector clocks, Lamport timestamps, happened-before relations, consistent snapshots, distributed tracing (Jaeger, Zipkin), chaos engineering principles, and formal verification techniques like TLA+."
)

# ── Build conversation and stress test ────────────────────────────────
MESSAGES='[]'
TOTAL_FAILURES=0
RESULTS=()

bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "  Context Stress Test — Replicating CUDA Kernel Timeout"
bold "  Target: ${TURNS} turns × ~${MAX_TOKENS} tokens/turn → ~$((TURNS * 5000)) context tokens"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for ((i = 0; i < TURNS; i++)); do
    PROMPT_IDX=$((i % ${#PROMPTS[@]}))
    PROMPT="${PROMPTS[$PROMPT_IDX]}"

    # Add user message to conversation
    MESSAGES=$(echo "$MESSAGES" | jq --arg content "$PROMPT" '. + [{"role": "user", "content": $content}]')

    # Build request payload
    PAYLOAD=$(jq -n \
        --argjson messages "$MESSAGES" \
        --argjson max_tokens "$MAX_TOKENS" \
        '{
            messages: $messages,
            max_tokens: $max_tokens,
            stream: false
        }')

    # Add model field if specified
    if [[ -n "$MODEL" ]]; then
        PAYLOAD=$(echo "$PAYLOAD" | jq --arg model "$MODEL" '. + {model: $model}')
    fi

    MSG_COUNT=$(echo "$MESSAGES" | jq 'length')
    info "Turn $((i + 1))/${TURNS} | messages: ${MSG_COUNT} | requesting ${MAX_TOKENS} max tokens..."

    # Time the request
    START_TIME=$(date +%s%N)

    HTTP_RESPONSE=$(curl -sf -w "\n%{http_code}" \
        --max-time 600 \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${BASE_URL}/v1/chat/completions" 2>&1) || {
        EXIT_CODE=$?
        fail "Turn $((i + 1)): curl failed (exit $EXIT_CODE) — likely CUDA timeout or server crash!"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        RESULTS+=("FAIL:turn=$((i+1)):curl_error=$EXIT_CODE")

        # Check if server is still alive
        sleep 2
        if curl -sf "${BASE_URL}/health" > /dev/null 2>&1; then
            warn "Server still responding — may have recovered"
        else
            fail "Server is DOWN — crash confirmed!"
            fail "Check logs: journalctl --user -u rtx-qwen3-8-27b-nvfp4-mtp-196k -n 50 --no-pager"
            RESULTS+=("CRASH:turn=$((i+1)):server_down")
            break
        fi
        continue
    }

    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))

    # Parse response
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
    BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

    if [[ "$HTTP_CODE" != "200" ]]; then
        fail "Turn $((i + 1)): HTTP $HTTP_CODE"
        TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
        RESULTS+=("FAIL:turn=$((i+1)):http=$HTTP_CODE")
        [[ "$VERBOSE" == "1" ]] && echo "$BODY" | head -5
        continue
    fi

    # Extract stats
    REPLY=$(echo "$BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")
    PROMPT_TOKENS=$(echo "$BODY" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null || echo 0)
    COMPLETION_TOKENS=$(echo "$BODY" | jq -r '.usage.completion_tokens // 0' 2>/dev/null || echo 0)
    TOTAL_TOKENS=$(echo "$BODY" | jq -r '.usage.total_tokens // 0' 2>/dev/null || echo 0)

    # Calculate throughput
    if [[ "$ELAPSED_MS" -gt 0 && "$COMPLETION_TOKENS" -gt 0 ]]; then
        TPS=$(echo "scale=1; $COMPLETION_TOKENS * 1000 / $ELAPSED_MS" | bc 2>/dev/null || echo "?")
    else
        TPS="?"
    fi

    ok "Turn $((i + 1)): ${COMPLETION_TOKENS} gen tokens | ctx: ${TOTAL_TOKENS} total | ${TPS} t/s | ${ELAPSED_MS}ms"
    RESULTS+=("OK:turn=$((i+1)):ctx=${TOTAL_TOKENS}:gen=${COMPLETION_TOKENS}:tps=${TPS}:ms=${ELAPSED_MS}")

    # Add assistant reply to conversation for next turn
    if [[ -n "$REPLY" ]]; then
        MESSAGES=$(echo "$MESSAGES" | jq --arg content "$REPLY" '. + [{"role": "assistant", "content": $content}]')
    fi

    # Warn if throughput is degrading (crash happened around ~88 t/s after decline from ~100)
    if [[ "$TPS" != "?" ]] && (( $(echo "$TPS < 50" | bc -l 2>/dev/null || echo 0) )); then
        warn "Throughput dropped below 50 t/s — approaching danger zone"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────
echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "  Results"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for r in "${RESULTS[@]}"; do
    if [[ "$r" == OK:* ]]; then
        echo -e "  ${GREEN}✓${NC} $r"
    elif [[ "$r" == CRASH:* ]]; then
        echo -e "  ${RED}💥${NC} $r"
    else
        echo -e "  ${RED}✗${NC} $r"
    fi
done

echo ""
if [[ "$TOTAL_FAILURES" -eq 0 ]]; then
    ok "All ${TURNS} turns completed successfully — no CUDA timeout reproduced."
    ok "The config change appears stable at this context depth."
else
    fail "${TOTAL_FAILURES} failure(s) in ${TURNS} turns."
    fail "CUDA kernel timeout likely reproduced. Check journalctl for CUDA errors."
fi

exit "$TOTAL_FAILURES"
