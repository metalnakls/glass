# List performance audit — 2026-10-06

## Evidence

A 25-second CPU Profiler recording of the installed debug app collected 15,236 samples. Its largest identified leaf costs were SwiftUI AttributeGraph updates, propagation, and runtime allocation/dispatch. The recording included list interactions, but automation was interrupted by concurrent user input, so it is not a controlled scrolling benchmark. It does not measure GPU frame time or establish a before/after speedup.

## Changes

- Match the folder flight to the native row animation (260 ms). Previously every flight also waited through an unconditional 320 ms settling animation, even at its correct destination. Now only displaced destinations receive a 120 ms correction; later changes receive bounded 80 ms corrections. The same live glass view still flies.
- Avoid repeating unchanged frame, transform, rotation, opacity, and visibility writes during native icon layout. Ignore scroll cancellation when no flight is active.
- Preserve header-specific section insets instead of overriding them with zero at the enclosing row collection.
- Apply header scroll coordinates without inherited AppKit animation timing; retain the existing opacity and blur transitions.

## Remaining costs and validation

Each glass icon still contains a live system glass effect. Frost adds a material and blur, and nonzero HDR adds a separate highlight pass. These settings remain shared and user-controlled; this audit does not silently reduce quality. Native List recycling, SwiftUI layout, and artwork realization remain measurable costs.

The flight tests cover late destination movement, view identity, ownership recovery, and all visible members. The complete test suite and canonical debug build/install validate the source. Perceived smoothness, header spacing, and GPU hitches still need a visual check on the installed app. A controlled repeatable scroll recording with frame-time instrumentation is needed before claiming a measured improvement.
