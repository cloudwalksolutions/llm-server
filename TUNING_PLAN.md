# LLM Server Performance Tuning & Stress Testing Plan

## Context

The automated deployment framework successfully deployed optimization settings (8 parallel slots, 12 gen threads, 8 batch threads, 6 HTTP threads) and the server is running stably. However, during the k6 benchmark (1-8 concurrent users over 2m21s), CPU utilization remains very low - only Core 6 at 32%, with most other cores at 0-1%.

**The problem:** We're not pushing the hardware to its limits. The Beelink GTR9 Pro has 16 cores (32 threads), 128GB RAM, and a powerful AMD Radeon 8060S GPU, but current load testing doesn't stress the system enough to reveal maximum capacity.

**User goal:** Balance throughput and latency by finding the optimal configuration that maximizes requests/second while maintaining reasonable response times.

**Root cause analysis needed:** Low CPU usage during benchmarking could indicate:
1. Benchmark concurrency too low (only 8 users) - system capable of handling much more
2. GPU bottleneck - CPU waiting for GPU, but GPU utilization unknown
3. Thread affinity issues - work concentrated on few cores instead of distributed
4. Conservative thread counts - 12/8/6 threads may be too low for 32 available threads
5. Parallel slots too low - 8 slots may not saturate the system
6. Container CPU limits or resource constraints

## Recommended Approach

### Phase 1: Diagnostic Baseline (Read-Only Investigation)

**Objective:** Understand current system behavior under various loads before making changes.

**Steps:**

1. **Check GPU utilization during load**
   - SSH into server and monitor GPU usage with `radeontop` or similar
   - Run benchmark in one terminal, watch GPU metrics in another
   - Determine if GPU is the bottleneck (>90% utilization = GPU bound)

2. **Monitor system resources during benchmark**
   - CPU usage per core
   - Memory usage
   - GPU utilization
   - Disk I/O (should be minimal with models loaded in RAM)
   - Network I/O

3. **Test with higher concurrency**
   - Create a temporary k6 test with 16, 24, 32 concurrent users
   - Observe where system starts to struggle
   - Identify if CPU usage increases with more load or stays low

4. **Review metrics endpoint data**
   - Check slot utilization during load
   - Verify all 8 slots are being used
   - Look for queue depth and request queueing

5. **Examine container resource limits**
   - Check if podman has CPU/memory limits set
   - Verify `--cpus` or `--cpu-shares` not restricting cores
   - Ensure container has access to all CPU cores

### Phase 2: Incremental Tuning

**Objective:** Systematically increase parallelism to find optimal configuration.

**Tuning Parameters to Test (in order):**

#### Test 1: Increase Parallel Slots (8 → 12)
- **Rationale:** With 16 cores and aggressive GPU acceleration, 8 slots may be conservative
- **Config change:** `parallel_slots: 12`
- **Expected impact:** Higher concurrent request handling, more slot utilization
- **Monitor:** Slot queue depth, memory usage (KV cache grows with slots)
- **Rollback if:** OOM errors, or no throughput improvement

#### Test 2: Increase Generation Threads (12 → 16)
- **Rationale:** More threads for token sampling/logits processing
- **Config change:** `threads_gen: 16`
- **Expected impact:** Better CPU core distribution for generation phase
- **Monitor:** CPU usage per core, generation speed
- **Rollback if:** Thrashing, no improvement, or latency degrades

#### Test 3: Increase Batch Threads (8 → 12)
- **Rationale:** More parallel prompt encoding
- **Config change:** `threads_batch: 12`
- **Expected impact:** Faster prompt processing for new requests
- **Monitor:** Time to first token (TTFT)
- **Rollback if:** No latency improvement

#### Test 4: Increase HTTP Threads (6 → 8)
- **Rationale:** Better concurrent request handling
- **Config change:** `threads_http: 8`
- **Expected impact:** Lower request queueing at HTTP layer
- **Monitor:** Request latency, HTTP queue depth
- **Rollback if:** No improvement

#### Test 5: Add CPU Affinity Settings
- **Rationale:** Force thread distribution across all cores
- **Implementation:** Set `taskset` or CPU affinity in podman run
- **Config change:** Add `--cpuset-cpus=0-31` to podman run
- **Expected impact:** Better core utilization distribution
- **Monitor:** CPU usage across all cores
- **Rollback if:** Performance degrades

### Phase 3: Stress Testing

**Objective:** Find the breaking point to understand true system capacity.

**Progressive Load Tests:**

1. **Light Load Test** (current baseline)
   - Concurrency: 1-8 users
   - Duration: 2.5 minutes
   - Expected: ~1.3 req/s, 100% success

2. **Medium Load Test**
   - Concurrency: 8-16 users
   - Duration: 3 minutes
   - Target: 2-3 req/s, >95% success

3. **Heavy Load Test**
   - Concurrency: 16-32 users
   - Duration: 3 minutes
   - Target: 4-6 req/s, >90% success

4. **Saturation Test**
   - Concurrency: 32-64 users
   - Duration: 2 minutes
   - Goal: Find where system starts rejecting/queueing excessively
   - Accept some failures to identify limits

5. **Sustained Load Test**
   - Concurrency: Optimal from above tests
   - Duration: 10 minutes
   - Target: Verify stability under sustained load
   - Monitor: Memory leaks, GPU thermal throttling, error rates

**Metrics to Capture:**
- Throughput (req/s)
- Latency (p50, p95, p99)
- Error rate
- CPU utilization (all cores)
- GPU utilization
- Memory usage
- Slot utilization
- Queue depth

### Phase 4: Benchmark Script Enhancement

**Create `scripts/stress-test.sh`** with multiple test profiles:

```bash
#!/usr/bin/env bash
# Comprehensive stress testing with variable loads

# Profile 1: Light (current)
# Profile 2: Medium (16 users)
# Profile 3: Heavy (32 users)
# Profile 4: Saturation (64 users)
# Profile 5: Custom (user-specified)

# Each profile runs k6 with different VU counts
# Outputs comparative results table
# Saves detailed metrics to timestamped files
```

**Modify `scripts/benchmark.k6.js`** to accept environment variables:
- `BENCHMARK_MAX_VUS` - maximum concurrent users
- `BENCHMARK_DURATION` - test duration
- `BENCHMARK_MAX_TOKENS` - max tokens per request
- `BENCHMARK_RAMP_TIME` - ramp-up duration

### Phase 5: Configuration Optimization

**Create tuning workflow in `config/llama.yaml`:**

Add commented presets for different workload types:

```yaml
# Performance presets (uncomment one)

# CONSERVATIVE (current - 8 slots, safe)
parallel_slots: 8
threads_gen: 12
threads_batch: 8
threads_http: 6

# BALANCED (12 slots, moderate throughput)
# parallel_slots: 12
# threads_gen: 16
# threads_batch: 12
# threads_http: 8

# AGGRESSIVE (16 slots, maximum throughput)
# parallel_slots: 16
# threads_gen: 20
# threads_batch: 16
# threads_http: 10

# LATENCY_OPTIMIZED (fewer slots, more threads per slot)
# parallel_slots: 4
# threads_gen: 24
# threads_batch: 16
# threads_http: 8
```

## Implementation Steps

### Step 1: Diagnostic Investigation (Read-Only)

**File:** `scripts/diagnose-utilization.sh` (new)

**Purpose:** Gather comprehensive metrics during load testing

**Tasks:**
1. Start monitoring GPU utilization (radeontop or rocm-smi)
2. Start monitoring CPU per-core (htop, mpstat, or similar)
3. Run existing benchmark
4. Capture metrics at 5-second intervals
5. Generate report showing:
   - Peak CPU utilization per core
   - Average GPU utilization
   - Memory high-water mark
   - Slot utilization statistics
   - Request queue depth over time

**Deliverable:** Diagnostic report identifying the bottleneck

### Step 2: Create Enhanced Stress Test

**File:** `scripts/stress-test.sh` (new)

**Features:**
- Multiple test profiles (light, medium, heavy, saturation)
- Accepts command-line arguments for custom profiles
- Outputs comparative table of results
- Saves detailed metrics for each test
- Automatically identifies optimal concurrency level

**Usage:**
```bash
make stress-test              # Run all profiles
make stress-test PROFILE=medium   # Run specific profile
make stress-test VUS=24       # Custom concurrency
```

### Step 3: Tune Thread Configuration

**File:** `config/llama.yaml` (modify)

**Process:**
1. Start with diagnostic results from Step 1
2. If GPU is <80% utilized → increase slots and threads
3. If GPU is >90% utilized → GPU bound, focus on GPU batch sizes
4. If CPU shows poor distribution → add CPU affinity settings
5. Test each change with stress test
6. Deploy with `make deploy` (idempotent)
7. Benchmark and compare results
8. Iterate until optimal

### Step 4: Add CPU Affinity (if needed)

**File:** `scripts/deploy-llama.sh` (modify)

**Change:** Add CPU pinning to podman run command

```bash
ExecStart=/usr/bin/podman run \
    --name llama-server-container \
    --cpuset-cpus=0-31 \           # NEW: Explicit CPU access
    --device /dev/kfd \
    --device /dev/dri \
    ...
```

**Alternative:** Use `taskset` to set CPU affinity for llama-server process inside container

### Step 5: Document Optimal Configuration

**File:** `docs/tuning-results.md` (new)

**Contents:**
- Test results table showing throughput at various configurations
- Resource utilization graphs
- Recommended configuration for different workload types
- Bottleneck analysis and findings
- Future optimization opportunities

## Critical Files

### New Files to Create
- `scripts/diagnose-utilization.sh` - Resource monitoring during load tests (~150 lines)
- `scripts/stress-test.sh` - Multi-profile load testing (~200 lines)
- `scripts/benchmark-profiles/` - Directory with k6 test profiles
  - `light.k6.js` - 1-8 users (current)
  - `medium.k6.js` - 8-16 users
  - `heavy.k6.js` - 16-32 users
  - `saturation.k6.js` - 32-64 users
- `docs/tuning-results.md` - Documentation of findings

### Files to Modify
- `config/llama.yaml` - Add performance presets as comments
- `scripts/deploy-llama.sh` - Potentially add CPU affinity settings
- `scripts/benchmark.sh` - Make k6 parameters configurable via env vars
- `Makefile` - Add `stress-test` and `diagnose` targets

### Reference Files
- `scripts/benchmark.sh` - Existing k6 integration pattern
- `scripts/benchmark.k6.js` - Current load test profile
- `scripts/server-utils.sh` - Existing metrics gathering functions

## Verification Plan

### Diagnostic Phase Success Criteria
- ✅ Identified whether GPU or CPU is the bottleneck
- ✅ Baseline metrics captured for all 4 load profiles
- ✅ Confirmed all 8 parallel slots are being utilized
- ✅ Verified no container CPU limits are in place
- ✅ Documented current system capacity (max req/s before degradation)

### Tuning Phase Success Criteria
- ✅ Increased throughput by 50-100% (from 1.3 req/s baseline)
- ✅ Maintained p95 latency under 5 seconds
- ✅ CPU utilization distributed across multiple cores (not just Core 6)
- ✅ Error rate remains <1% under optimal load
- ✅ Memory usage stable (no leaks during sustained load)
- ✅ Configuration is idempotent and reproducible via `make deploy`

### Stress Testing Success Criteria
- ✅ Documented maximum sustainable throughput
- ✅ Identified breaking point (req/s where errors >10%)
- ✅ Verified system recovers gracefully from overload
- ✅ No thermal throttling or resource exhaustion
- ✅ Benchmarks saved and comparable over time

## Expected Outcomes

### Conservative Estimate (if GPU-bound)
- Current: 1.3 req/s with 8 concurrent users
- Optimized: 2.5-4 req/s with 16-24 concurrent users
- Limitation: GPU saturation, CPU still underutilized (expected with -ngl 999)

### Optimistic Estimate (if underutilized)
- Current: 1.3 req/s with 8 concurrent users
- Optimized: 6-10 req/s with 24-32 concurrent users
- Improvement: Better thread distribution, higher parallelism, optimal slot count

### Most Likely Scenario
- GPU becomes bottleneck at 12-16 parallel slots
- CPU utilization increases to 40-60% across multiple cores
- Throughput reaches 4-6 req/s sustained
- System can burst to 8-10 req/s for short periods
- Configuration: 12-14 parallel slots, 16 gen threads, 12 batch threads

## Technical Details

### Thread Count Rationale

**Current (Conservative):**
- threads_gen: 12 (37.5% of 32 threads)
- threads_batch: 8 (25% of 32 threads)
- threads_http: 6 (18.75% of 32 threads)
- **Total: 26/32 threads = 81% allocation**

**Proposed (Balanced):**
- threads_gen: 16 (50% of 32 threads)
- threads_batch: 12 (37.5% of 32 threads)
- threads_http: 8 (25% of 32 threads)
- **Total: 36/32 threads = 113% allocation** (acceptable with overlap)

**Aggressive (Maximum):**
- threads_gen: 20 (62.5% of 32 threads)
- threads_batch: 16 (50% of 32 threads)
- threads_http: 10 (31% of 32 threads)
- **Total: 46/32 threads = 144% allocation** (intentional oversubscription)

### Parallel Slots vs. Memory

Each slot requires KV cache memory:
- Context size: 32,768 tokens
- KV cache per slot (f16): ~2GB for 32B model
- 8 slots: ~16GB KV cache
- 12 slots: ~24GB KV cache
- 16 slots: ~32GB KV cache
- **Available: 128GB total, ~100GB usable for inference**

Conclusion: Memory headroom allows increasing to 16+ slots safely.

### GPU Batch Size Tuning

Current:
- batch_size: 2048 (logical)
- ubatch_size: 512 (physical)
- Ratio: 4:1

If GPU-bound, try:
- batch_size: 4096 (logical)
- ubatch_size: 1024 (physical)
- Ratio: 4:1 (maintain, but larger batches)

This may improve GPU utilization by giving it larger chunks of work.

## Quick Start Commands

```bash
# 1. Run diagnostic (manual for now)
make ssh
# In SSH session:
htop  # Monitor CPU per-core
# In another terminal: make benchmark

# 2. Test higher concurrency (edit benchmark.k6.js manually)
# Change max VUs from 8 to 16, then run:
make benchmark

# 3. Tune configuration
vim config/llama.yaml
# Change parallel_slots to 12, threads_gen to 16
make deploy
make benchmark

# 4. Compare results
cat benchmarks/*.txt
```

## Next Steps

1. Create diagnostic script to monitor GPU + CPU during load
2. Run stress tests with 16, 24, 32 concurrent users
3. Identify bottleneck (GPU vs CPU vs memory vs network)
4. Tune configuration based on findings
5. Document optimal settings for production use
