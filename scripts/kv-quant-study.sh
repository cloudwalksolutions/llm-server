#!/usr/bin/env bash
# Measure what KV cache quantization actually costs this model.
#
# WHY THIS EXISTS
# config/llama.example.yaml has asserted for a while that q8_0 KV is "<0.1%
# quality loss" and q4_0 is "~50x the perplexity damage of q8_0", and
# the consuming app asserted that q4_0 "degrades tool calling specifically".
# None of those numbers came from this hardware, this model, or any published
# measurement. This script replaces them with numbers.
#
# THE DESIGN
# qwen3-14b and qwen3-14b-1m run the SAME GGUF and differ only in KV type, so
# KV quantization is a clean single variable here.
#
# Two things make the result trustworthy rather than merely numeric:
#
#   1. TWO CORPORA, ONE INSTRUMENT. Prose (wikitext-2) and real tool-calling
#      turns rendered through the server's own chat template. The claim under
#      test is DIFFERENTIAL — "tool calling suffers more than text" — so the
#      answer is the ratio between corpora, not either number alone.
#
#   2. TAILS, NOT MEANS. A broken tool call is a handful of tokens choosing
#      wrong. Mean KLD averages that to nothing; arXiv:2606.09864 measured
#      behavioural collapse at 1.03x perplexity. So we report 99%/99.9%/max KLD
#      and Same-top-p, and treat mean KLD as context only.
#
# The k4v8 arm is the diagnostic: llama.cpp discussion #23470 measured q4_0 on
# the K cache destroying Qwen2.5-7B (PPL ratio 196x, top-token agreement
# 98% -> 11.8%) while q4_0 on V cost almost nothing. If that reproduces on
# Qwen3-14B the question is settled at the K cache and nothing else matters.
#
# COST (measured on this target, not estimated)
#   ~148 KiB of disk per token of KLD base -> ~19 GiB per corpus at the default
#   size, ~38 GiB for both. The base arm of each corpus writes that file and takes
#   ~11 min; each comparison arm re-reads it and takes ~5.5 min. So the default
#   symmetric study is roughly 45 min of wall clock, most of it disk rather than
#   GPU. `--plan` prints the current numbers.
#
# It does NOT need a maintenance window. The study needs ~11 GiB and the target
# has ~56 GiB of VRAM free with all three instances running. Quality numbers are
# deterministic and unaffected by concurrent traffic. Only --bench needs a quiet
# machine, because it measures time.
#
# Usage:
#   ./scripts/kv-quant-study.sh --plan       budget + free space, changes nothing
#   ./scripts/kv-quant-study.sh --corpora    build/refresh the corpora only
#   ./scripts/kv-quant-study.sh              run the study, write the report
#   ./scripts/kv-quant-study.sh --bench      timing guard (needs a quiet target)
#   ./scripts/kv-quant-study.sh --report     rebuild the report from existing logs
#   ./scripts/kv-quant-study.sh --clean      delete the study dir (frees ~39 GiB)
#
#   STUDY_ASYMMETRIC=1 ...  also run the q8_0/q4_0 and q4_0/q8_0 arms. Slow (see
#                           the ARMS comment) and not deployable, but k4v8 is the
#                           arm that isolates K-cache sensitivity.
#   STUDY_FORCE=1 ...       re-run arms that already have a completed log.
#
# Completed arms are skipped on re-run, so an interrupted study resumes instead of
# rewriting its ~19 GiB reference logits.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1

# The instance whose model and API key we borrow. Any instance serving the model
# under test will do; we only read from it.
STUDY_INSTANCE="${STUDY_INSTANCE:-qwen3-14b}"
STUDY_DIR="${STUDY_DIR:-/opt/llm/kv-study}"
STUDY_CTX="${STUDY_CTX:-8192}"
STUDY_CHUNKS="${STUDY_CHUNKS:-16}"
REPORT="${REPORT:-specs/kv-quant-study.md}"

# name  cache_type_k  cache_type_v   — 'base' must be first; it writes the
# reference logits every other arm is compared against.
#
# Only the symmetric arms run by default, for two reasons. `load_instance` rejects
# asymmetric cache types, so those arms measure a configuration this tooling
# refuses to deploy — interesting, not actionable. And they are MEASURED here to
# be far slower: at identical settings a symmetric arm took ~5.3 min while
# q8_0/q4_0 was still running after ~45, i.e. roughly an order of magnitude, on
# the GPU. That is worth recording as a finding but not worth paying on every run.
#
# STUDY_ASYMMETRIC=1 adds them. k4v8 is the interesting one: it isolates K
# sensitivity, which is what llama.cpp #23470 measured destroying Qwen2.5-7B.
ARMS=(
    "base f16  f16"
    "kv8  q8_0 q8_0"
    "kv4  q4_0 q4_0"
)
if [[ "${STUDY_ASYMMETRIC:-0}" == "1" ]]; then
    ARMS+=("k8v4 q8_0 q4_0" "k4v8 q4_0 q8_0")
fi
CORPORA=(prose tools)

MODE="run"
case "${1:-}" in
    --plan)    MODE="plan" ;;
    --corpora) MODE="corpora" ;;
    --bench)   MODE="bench" ;;
    --clean)   MODE="clean" ;;
    --report)  MODE="report" ;;
    "")        MODE="run" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

load_instance "$STUDY_INSTANCE" >/dev/null || {
    echo -e "${RED}no such instance: $STUDY_INSTANCE${NC}" >&2; exit 1; }
MODEL_FILE="$INST_MODEL_FILE"
PORT="$INST_PORT"

TOKENS=$((STUDY_CTX * STUDY_CHUNKS))
# 151870 bytes/token measured on this build (vocab 151936, ~1 byte per entry).
KLD_BYTES_PER_TOKEN=151870
KLD_GIB=$((TOKENS * KLD_BYTES_PER_TOKEN / 1073741824))
# A corpus shorter than this cannot fill --chunks, and llama-perplexity silently
# processes fewer chunks rather than complaining — which would make two arms
# incomparable for a reason nothing reports. ~3 bytes/token is conservative for
# both English prose and the token-dense JSON in the tools corpus.
CORPUS_MIN_BYTES=$((TOKENS * 3))
CORPUS_BUILD_BYTES=$((TOKENS * 5))

# ── Remote helpers ────────────────────────────────────────────────────────────
# :z on the writable mount — the target is Fedora with SELinux enforcing, and
# without it llama-perplexity fails with "failed to open ... for writing".
_ppl() {
    remote_exec "podman run --rm \
        --device /dev/kfd --device /dev/dri --group-add video \
        --security-opt seccomp=unconfined \
        -v /opt/llm/models:/models:ro -v $STUDY_DIR:/study:z \
        --entrypoint llama-perplexity $INST_CONTAINER_IMAGE \
        -m /models/$MODEL_FILE -ngl 999 --flash-attn on $*"
}

_bench() {
    remote_exec "podman run --rm \
        --device /dev/kfd --device /dev/dri --group-add video \
        --security-opt seccomp=unconfined \
        -v /opt/llm/models:/models:ro \
        --entrypoint llama-bench $INST_CONTAINER_IMAGE \
        -m /models/$MODEL_FILE -ngl 999 -fa 1 $*"
}

# ── Corpora ───────────────────────────────────────────────────────────────────
# Prose: wikitext-2 test split, the standard reference corpus.
build_prose() {
    echo -e "${CYAN}prose${NC}: wikitext-2 test split ($CORPUS_BUILD_BYTES bytes)"
    remote_exec "set -e
        mkdir -p $STUDY_DIR && cd $STUDY_DIR
        if [ ! -f wikitext-2-raw/wiki.test.raw ]; then
            curl -sL -o wt.zip https://huggingface.co/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip
            unzip -o -q wt.zip && rm -f wt.zip
        fi
        head -c $CORPUS_BUILD_BYTES wikitext-2-raw/wiki.test.raw > prose.txt
        wc -c prose.txt"
}

# Tools: the real thing, rendered by the server's own chat template via
# POST /apply-template, so the corpus is byte-for-byte what the model sees for a
# tool-using turn — the tool schema, the <tool_call> block, the tool response.
# Hand-writing this format would be guessing at it.
#
# Sessions vary deterministically (fixed seed) so the corpus is stable across
# runs but not trivially predictable, which would deflate every arm equally and
# hide the effect.
build_tools() {
    echo -e "${CYAN}tools${NC}: agent turns via /apply-template on :$PORT"
    local key body prompt out i=0 have=0
    key=$(remote_conf_value "$INSTANCES_DIR/$STUDY_INSTANCE.conf" LLAMA_API_KEY)
    [[ -n "$key" ]] || { echo -e "${RED}could not read the API key${NC}" >&2; return 1; }

    # Tool-result bodies are sliced from the prose corpus, so it has to exist
    # first. CORPORA is ordered to make that true, but say so rather than rely on it.
    remote_exec "test -s $STUDY_DIR/prose.txt" || build_prose

    out=$(mktemp)
    # Append sessions until the byte target is met rather than guessing a count:
    # session size depends on the template, which is the model's business, not
    # ours.
    while ((have < CORPUS_BUILD_BYTES)); do
        body=$(_tool_session_json "$i")
        prompt=$(remote_exec "curl -s --max-time 60 -H 'Authorization: Bearer $key' \
            -H 'Content-Type: application/json' -d $(_shq "$body") \
            http://127.0.0.1:$PORT/apply-template" | jq -r '.prompt // empty')
        if [[ -z "$prompt" ]]; then
            echo -e "\n${RED}/apply-template returned nothing for session $i${NC}" >&2
            rm -f "$out"; return 1
        fi
        printf '%s\n\n' "$prompt" >> "$out"
        have=$(wc -c < "$out")
        i=$((i + 1))
        printf '\r  %d sessions, %d/%d bytes' "$i" "$have" "$CORPUS_BUILD_BYTES"
    done
    echo ""
    remote_exec "mkdir -p $STUDY_DIR && cat > $STUDY_DIR/tools.txt" < "$out"
    rm -f "$out"
    remote_exec "wc -c $STUDY_DIR/tools.txt"
}

# One tool-using session: system prompt, user turn, assistant tool_call, tool
# response, follow-up. Sized to the ~2000-2500 token search payload that
# the consuming app measured from real traffic.
# The search-result BODIES are real prose, sliced from wikitext, not generated
# filler.
#
# This matters more than it looks. A first version generated result text by
# cycling a fixed 18-word vocabulary, which produced a corpus with a measured
# perplexity of 1.04 — the model predicted it almost perfectly. A corpus with no
# entropy has no headroom to show quantization damage, so every arm would look
# clean and the prose-vs-tools comparison would be meaningless. Real prose inside
# the real tool-call structure is also the honest shape of the thing: a Tavily
# result is natural language wrapped in JSON wrapped in the chat template.
_tool_session_json() {
    local i="$1" r0 r1 r2 r3 r4
    # Five distinct ~1200-char slices per session, advancing through the corpus so
    # no two sessions share bodies. Deterministic: same index, same slice.
    r0=$(_prose_slice $((i * 5 + 0)))
    r1=$(_prose_slice $((i * 5 + 1)))
    r2=$(_prose_slice $((i * 5 + 2)))
    r3=$(_prose_slice $((i * 5 + 3)))
    r4=$(_prose_slice $((i * 5 + 4)))

    jq -nc --argjson i "$i" \
        --arg r0 "$r0" --arg r1 "$r1" --arg r2 "$r2" --arg r3 "$r3" --arg r4 "$r4" '
        def topics: ["fintech regulation","payment rails","embedded finance",
                     "open banking","card networks","stablecoin settlement",
                     "KYC automation","merchant acquiring"];
        (topics[$i % 8]) as $topic |
        ([$r0,$r1,$r2,$r3,$r4]) as $bodies |
        {
          messages: [
            {role: "system",
             content: "You are a marketing research agent. Use web_search for anything time-sensitive, then answer with a JSON object matching the requested schema. Be concise and cite sources."},
            {role: "user",
             content: ("What is the latest on " + $topic + "? Summarize for a product brief.")},
            {role: "assistant",
             content: "",
             tool_calls: [{id: ("call_" + ($i | tostring)), type: "function",
                           function: {name: "web_search",
                                      arguments: ({query: $topic} | tojson)}}]},
            # 5 results x ~1800 chars lands each tool response near the 2000-2500
            # tokens the consuming app measured from real Tavily traffic.
            # Undersizing this would understate exactly the KV pressure the study
            # is about.
            {role: "tool", tool_call_id: ("call_" + ($i | tostring)),
             content: ([range(0; 5) | {
                 title: ($topic + " update " + (. | tostring)),
                 url: ("https://example.invalid/" + ($topic | gsub(" "; "-")) + "/" + (. | tostring)),
                 content: $bodies[.]
               }] | tojson)},
            {role: "user", content: "Now give me the three most important points."}
          ],
          tools: [{type: "function", function: {
            name: "web_search",
            description: "Search the web for current information and return ranked results.",
            parameters: {type: "object",
                         properties: {query: {type: "string",
                                              description: "The search query"}},
                         required: ["query"]}}}]
        }'
}

# Slice n of the local prose cache, ~1200 chars, wrapping around if exhausted.
PROSE_CACHE=""
PROSE_TOTAL=0
# 5 slices x 1800 chars ~= 9000 chars ~= 2250 tokens per tool response, which is
# the range the consuming app measured from real Tavily traffic.
PROSE_SLICE_LEN=1800
_prose_slice() {
    local n="$1" off
    if [[ -z "$PROSE_CACHE" ]]; then
        PROSE_CACHE=$(mktemp)
        remote_exec "cat $STUDY_DIR/prose.txt" > "$PROSE_CACHE" 2>/dev/null
        [[ -s "$PROSE_CACHE" ]] || { echo "could not read prose.txt for tool bodies" >&2; return 1; }
        PROSE_TOTAL=$(wc -c < "$PROSE_CACHE")
    fi
    off=$(( (n * PROSE_SLICE_LEN) % (PROSE_TOTAL - PROSE_SLICE_LEN) + 1 ))
    # tail -c +N | head -c is two processes; dd with bs=1 would be one syscall per
    # byte, and this runs 5x per session across dozens of sessions.
    # tr squeezes newlines so each body reads as one scraped paragraph.
    tail -c +"$off" "$PROSE_CACHE" | head -c "$PROSE_SLICE_LEN" | tr '\n' ' ' | tr -s ' '
}

corpus_stats() {
    echo -e "\n${YELLOW}corpora${NC}"
    remote_exec "cd $STUDY_DIR && for f in prose.txt tools.txt; do
        [ -f \$f ] && printf '  %-10s %8d bytes  md5 %s\n' \$f \$(wc -c < \$f) \$(md5sum \$f | cut -c1-12)
    done" || true
}

# ── Arms ──────────────────────────────────────────────────────────────────────
run_arm() {
    local corpus="$1" arm="$2" ctk="$3" ctv="$4" log extra
    log="$STUDY_DIR/$corpus.$arm.log"

    # Resume rather than restart. Arms are deterministic and the base arm alone
    # writes ~19 GiB, so re-running completed work costs a lot and proves nothing.
    # A log counts as complete only if it contains a finished report.
    if [[ "${STUDY_FORCE:-0}" != "1" ]] \
       && remote_exec "grep -qE 'Final estimate|Mean    KLD' $log 2>/dev/null"; then
        printf '  %-6s %-5s/%-5s %s\n' "$corpus" "$ctk" "$ctv" "$(echo -e "${GREEN}cached${NC}")"
        return 0
    fi

    if [[ "$arm" == "base" ]]; then
        extra="--kl-divergence-base /study/$corpus.kld"
    else
        extra="--kl-divergence-base /study/$corpus.kld --kl-divergence"
    fi

    printf '  %-6s %-5s/%-5s ' "$corpus" "$ctk" "$ctv"
    if _ppl "-f /study/$corpus.txt -c $STUDY_CTX --chunks $STUDY_CHUNKS \
             -ctk $ctk -ctv $ctv $extra" > /tmp/.kvarm.$$ 2>&1; then
        remote_exec "cat > $log" < /tmp/.kvarm.$$
        if grep -q 'failed to open' /tmp/.kvarm.$$; then
            echo -e "${RED}could not write the KLD base (SELinux? disk?)${NC}"
            rm -f /tmp/.kvarm.$$; return 1
        fi
        echo -e "${GREEN}ok${NC}"
    else
        echo -e "${RED}failed${NC}"
        tail -5 /tmp/.kvarm.$$ >&2
        rm -f /tmp/.kvarm.$$; return 1
    fi
    rm -f /tmp/.kvarm.$$
}

# Pull one labelled number out of a llama-perplexity report.
#
# The `sed` is load-bearing: percentile labels contain their own decimal number
# ("99.0%   KLD:   0.657441"), so matching a float across the whole line returns
# 99.0 rather than the value. Everything up to the first colon is the label.
_num() {
    grep -m1 "^$2" "$1" 2>/dev/null \
        | sed 's/^[^:]*://' \
        | grep -oE '[-0-9]+\.[0-9]+' | head -1
}

parse_arm() {
    local corpus="$1" arm="$2" log
    log=$(mktemp)
    remote_exec "cat $STUDY_DIR/$corpus.$arm.log 2>/dev/null" > "$log" || true

    if [[ "$arm" == "base" ]]; then
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$corpus" "$arm" \
            "$(_num "$log" 'Final estimate: PPL')" "-" "-" "-" "100.000"
    else
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$corpus" "$arm" \
            "$(_num "$log" 'Mean PPL(Q) ')" \
            "$(_num "$log" 'Mean    KLD')" \
            "$(_num "$log" '99.0%   KLD')" \
            "$(_num "$log" '99.9%   KLD')" \
            "$(_num "$log" 'Same top p')"
    fi
    rm -f "$log"
}

# ── Timing guard ──────────────────────────────────────────────────────────────
# An unsupported (K,V,head-size) combination can silently fall back to CPU
# attention, which llama.cpp #24485 measured at ~25x slower. That would make
# every quality number above a measurement of the wrong code path, so check that
# prefill throughput stays in the same league across arms.
run_bench() {
    echo -e "${BLUE}Timing guard${NC} — prefill throughput per arm"
    echo -e "${YELLOW}note:${NC} this one needs a quiet target; concurrent traffic invalidates it\n"
    local arm ctk ctv
    for spec in "${ARMS[@]}"; do
        read -r arm ctk ctv <<<"$spec"
        printf '  %-5s %-5s/%-5s ' "$arm" "$ctk" "$ctv"
        _bench "-ctk $ctk -ctv $ctv -p 512 -n 0 -r 3 -o csv" 2>/dev/null \
            | awk -F, '/pp512/ {printf "%8.1f t/s\n", $(NF-1)}' | tail -1 \
            || echo "failed"
    done
    echo -e "\nAny arm far below the others is on CPU attention, not a quality result."
}

# ── Report ────────────────────────────────────────────────────────────────────
write_report() {
    local rows=() spec arm ctk ctv corpus
    for corpus in "${CORPORA[@]}"; do
        for spec in "${ARMS[@]}"; do
            read -r arm ctk ctv <<<"$spec"
            rows+=("$(parse_arm "$corpus" "$arm")|$ctk|$ctv")
        done
    done

    {
        echo "# What KV cache quantization costs Qwen3-14B on this target"
        echo ""
        echo "Generated by \`scripts/kv-quant-study.sh\` on $(date -u +%Y-%m-%dT%H:%MZ)."
        echo "This file replaces asserted numbers with measured ones. Do not edit by hand;"
        echo "re-run the script."
        echo ""
        echo "## Setup"
        echo ""
        echo "| | |"
        echo "|---|---|"
        echo "| model | \`$MODEL_FILE\` (identical across arms — only KV type varies) |"
        echo "| context | \`-c $STUDY_CTX\`, \`--chunks $STUDY_CHUNKS\` = $TOKENS tokens per arm |"
        echo "| flash attention | \`--flash-attn on\` explicitly, never \`auto\` |"
        echo "| backend | Vulkan/RADV, gfx1151 |"
        echo "| build | $(remote_exec "curl -sf http://127.0.0.1:$PORT/props -H 'Authorization: Bearer $(remote_conf_value "$INSTANCES_DIR/$STUDY_INSTANCE.conf" LLAMA_API_KEY)'" 2>/dev/null | jq -r '.build_info // "unknown"') |"
        echo ""
        echo "## Results"
        echo ""
        echo "\`base\` is f16/f16 and is the reference every other arm is compared against,"
        echo "so its KLD columns are empty by construction."
        echo ""
        echo "| corpus | arm | K | V | PPL | mean KLD | 99% KLD | 99.9% KLD | same top-1 |"
        echo "|---|---|---|---|---|---|---|---|---|"
        local r
        for r in "${rows[@]}"; do
            IFS='|' read -r c a ppl mk k99 k999 stp ck cv <<<"$r"
            printf '| %s | `%s` | %s | %s | %s | %s | %s | %s | %s%% |\n' \
                "$c" "$a" "$ck" "$cv" "${ppl:--}" "${mk:--}" "${k99:--}" "${k999:--}" "${stp:--}"
        done
        echo ""
        echo "## The differential — the actual question"
        echo ""
        echo "\"Does KV quantization hurt tool calling more than it hurts text?\" is a ratio,"
        echo "not an absolute. Below is each metric on \`tools\` divided by the same metric on"
        echo "\`prose\`, per arm. **1.0 means no tool-calling-specific effect.**"
        echo ""
        echo "| arm | mean KLD | 99% KLD | 99.9% KLD | same top-1 (pp difference) |"
        echo "|---|---|---|---|---|"
        local spec arm ctk ctv pr to
        for spec in "${ARMS[@]}"; do
            read -r arm ctk ctv <<<"$spec"
            [[ "$arm" == "base" ]] && continue
            pr=$(parse_arm prose "$arm"); to=$(parse_arm tools "$arm")
            IFS='|' read -r _ _ _ pmk pk99 pk999 pstp <<<"$pr"
            IFS='|' read -r _ _ _ tmk tk99 tk999 tstp <<<"$to"
            awk -v a="$arm" -v pmk="$pmk" -v tmk="$tmk" -v p99="$pk99" -v t99="$tk99" \
                -v p999="$pk999" -v t999="$tk999" -v ps="$pstp" -v ts="$tstp" 'BEGIN{
                printf "| `%s` | %.2fx | %.2fx | %.2fx | %+.2f pp |\n",
                       a, tmk/pmk, t99/p99, t999/p999, ts-ps }'
        done
        echo ""
        echo "Read \`same top-1\` as the behavioural metric — it is the share of tokens where"
        echo "the quantized cache still ranks the same token first. A **positive** pp difference"
        echo "means the tool-calling corpus held up BETTER than prose."
        echo ""
        echo "## How to read this"
        echo ""
        echo "- **same top-1** is the share of tokens where the quantized cache still ranks"
        echo "  the same token first. This is the number that tracks behaviour."
        echo "- **99% / 99.9% KLD** are the tail. A mean KLD near zero with a fat tail means"
        echo "  most tokens are fine and a few are badly wrong — which is exactly how a"
        echo "  malformed tool call happens."
        echo "- **The differential is the finding.** Compare each arm's numbers on \`tools\`"
        echo "  against the same arm on \`prose\`. Similar degradation means KV quantization"
        echo "  is not specifically a tool-calling problem, whatever the folklore says."
        echo "- **\`k4v8\` is the diagnostic.** llama.cpp #23470 measured q4_0-on-K destroying"
        echo "  Qwen2.5-7B (PPL ratio 196x, same top-1 98% -> 11.8%) while q4_0-on-V cost"
        echo "  almost nothing. If \`k4v8\` collapses here and \`k8v4\` does not, K sensitivity"
        echo "  is the whole story and \`cache_type_k\` is the only knob that matters."
        echo ""
        echo "## Raw logs"
        echo ""
        echo "Kept on the target at \`$STUDY_DIR/<corpus>.<arm>.log\`."
        echo "The KLD reference files are ~$KLD_GIB GiB each; \`--clean\` removes them."
    } > "$REPORT"

    echo -e "\n${GREEN}wrote $REPORT${NC}"
    sed -n '/^| corpus/,/^$/p' "$REPORT"
}

# ── Modes ─────────────────────────────────────────────────────────────────────
show_plan() {
    echo -e "${BLUE}KV quantization study — plan${NC}\n"
    echo -e "${YELLOW}what runs${NC}"
    echo "  ${#CORPORA[@]} corpora x ${#ARMS[@]} arms = $(( ${#CORPORA[@]} * ${#ARMS[@]} )) perplexity runs"
    echo "  $TOKENS tokens each (-c $STUDY_CTX x $STUDY_CHUNKS chunks)"
    echo "  model: $MODEL_FILE (same GGUF in every arm)"
    echo ""
    echo -e "${YELLOW}cost${NC}"
    echo "  disk:  ~$KLD_GIB GiB per corpus of KLD reference logits, ~$((KLD_GIB * ${#CORPORA[@]})) GiB total"
    echo "  time:  ~$(( TOKENS * ${#CORPORA[@]} * ${#ARMS[@]} / 790 / 60 )) min of GPU at the ~790 tok/s measured here"
    echo "  VRAM:  ~11 GiB (9 GiB model + f16 KV at this context)"
    echo ""
    echo -e "${YELLOW}target headroom${NC}"
    remote_exec "df -h --output=avail $STUDY_DIR 2>/dev/null | tail -1 | xargs echo '  disk free:'" || \
        remote_exec "df -h --output=avail /opt 2>/dev/null | tail -1 | xargs echo '  disk free (/opt):'"
    remote_exec "awk '{printf \"  VRAM free: %d MiB of %d MiB\n\", (98304*1048576-\$1)/1048576, 98304}' /sys/class/drm/card0/device/mem_info_vram_used" 2>/dev/null || true
    echo ""
    echo "No instance is stopped and nothing is deployed. Quality numbers are"
    echo "deterministic, so concurrent traffic does not affect them — only --bench"
    echo "needs a quiet machine."
    corpus_stats
}

case "$MODE" in
    plan)
        show_plan
        ;;
    clean)
        echo -e "${YELLOW}removing $STUDY_DIR on $REMOTE_HOST${NC}"
        remote_exec "du -sh $STUDY_DIR 2>/dev/null || true"
        remote_exec_sudo "rm -rf $STUDY_DIR"
        echo -e "${GREEN}done${NC}"
        ;;
    corpora)
        test_ssh || { echo -e "${RED}cannot reach target${NC}" >&2; exit 1; }
        build_prose
        build_tools
        corpus_stats
        ;;
    bench)
        test_ssh || { echo -e "${RED}cannot reach target${NC}" >&2; exit 1; }
        run_bench
        ;;
    report)
        # Rebuild the report from logs already on the target. Useful when the
        # arms are fine but the parsing or presentation changed — re-running arms
        # to fix a table would cost ~45 minutes and change none of the data.
        test_ssh || { echo -e "${RED}cannot reach target${NC}" >&2; exit 1; }
        write_report
        ;;
    run)
        test_ssh || { echo -e "${RED}cannot reach target${NC}" >&2; exit 1; }
        echo -e "${BLUE}KV quantization study${NC} — $MODEL_FILE on $REMOTE_HOST\n"

        # Reuse a corpus only if it is big enough to fill --chunks. Testing mere
        # existence would silently reuse a short file, and llama-perplexity
        # processes fewer chunks rather than erroring — so two arms would be
        # measured over different amounts of text with nothing saying so.
        for c in "${CORPORA[@]}"; do
            if remote_exec "test -f $STUDY_DIR/$c.txt && [ \$(wc -c < $STUDY_DIR/$c.txt) -ge $CORPUS_MIN_BYTES ]"; then
                echo -e "  ${GREEN}reusing${NC} $c.txt"
            else
                case "$c" in
                    prose) build_prose ;;
                    tools) build_tools ;;
                esac
            fi
        done
        corpus_stats

        echo -e "\n${YELLOW}arms${NC} (base first — it writes the reference logits)"
        for corpus in "${CORPORA[@]}"; do
            for spec in "${ARMS[@]}"; do
                read -r arm ctk ctv <<<"$spec"
                run_arm "$corpus" "$arm" "$ctk" "$ctv" || exit 1
            done
        done

        write_report
        echo ""
        echo -e "Timing guard (needs a quiet target): ${BLUE}./scripts/kv-quant-study.sh --bench${NC}"
        echo -e "Reclaim ~$((KLD_GIB * ${#CORPORA[@]})) GiB when done:   ${BLUE}./scripts/kv-quant-study.sh --clean${NC}"
        ;;
esac
