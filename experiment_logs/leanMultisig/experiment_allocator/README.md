# Allocator Experiment — Placeholder

## Context
- mimalloc showed -24% on AWS (16GB KVM) but +3.6% on Hetzner (64GB bare metal)
- Root cause: memory pressure (16GB at 95% utilization) vs headroom (64GB at 25%)
- Binius removed bumpalo, replaced with custom BumpAllocator — too complex to thread through prove pipeline
- bumpalo is !Sync, unusable with Rayon

## Goal
Find hardware-agnostic allocation optimization that helps under both memory pressure and headroom.

## Key constraint
Must validate on BOTH AWS and bare metal. Dual-machine gate.

## Directions to explore
1. Source-code allocation count reduction (fewer allocs, not faster allocator)
2. Scoped arenas for specific phases (logup data prep, sumcheck rounds)
3. Pre-sized allocations from profiled sizes
4. Eliminating allocations entirely where possible
5. Custom thread-local allocation for Rayon workers

## Estimated scope
10-15 iterations

## Status
Parked. Run after experiment 5.
