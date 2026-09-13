# ADR-0035: Make resource retirement and validation agree

**Status:** Accepted (constraint only; implementation is M11)
**Date:** 2026-09-13

## Context

M11 explicitly takes on the RHI's recorded lifetime, usage and frame-error debts.
`rhi.md` §3 promises that destruction invalidates a handle immediately and releases its
backing resource after GPU completion. Its §11 rule 9 instead rejects the destruction call
while a referencing frame is in flight. The null backend implements the latter, and Metal
removes objects immediately, relying on Metal's own retention. Renderer uploads assume that
being outside a frame means the GPU is idle; Metal `CommandBuffer.submit` is asynchronous,
and the frame ring alone does not account for a submission made after the last frame marker.

These are conflicting contracts around an existing operation, not a reason to replace the
RHI. Separately, resource usage flags are declared but not validated. ADR-0033 left their
enforcement open for M13, while the subsequently specified M11 scope calls it due now.

## Decision

Keep `rhi.md` §3's deferred-destruction contract. Every backend invalidates a destroyed handle
immediately and retains its backing allocation until all already-recorded uses have finished.
Clarify rule 9 accordingly: premature **physical release**, or a new use of a destroyed
handle, is invalid; requesting retirement while submitted work is in flight is valid.
Memory needed to retire an object must be reserved before its creation succeeds, so a void
destroy operation cannot fail, leak on allocation failure or release early. Completion tracks
all submissions on the existing single queue, including uploads outside a frame.

Renderer handles retain their own identity boundary. M11 integrates their teardown with the
completed RHI contract without exposing RHI handles to games, changing the public C tables,
or making the renderer responsible for backend completion. CPU-side dependencies still have
to remain valid while recording a command; deferred GPU release does not authorize recording
new commands through stale handles.

Add usage conformance as validation rule 11. Check the operations expressible by the current
RHI against their declared flags, separately from resource-state checks. Descriptor failures
use `InvalidDescriptor`; command violations use the existing validation-reporting path. The
matrix and negative/positive evidence are specified in `docs/design/hardening.md` §6. This
settles only ADR-0033's usage-enforcement question early; Vulkan's implementation, loader,
shader toolchain, descriptor allocation and device recovery remain M13 work.

Distinguish a temporarily unavailable presentation image from a lost surface and a lost
device. Add the internal `FrameError.SurfaceUnavailable` outcome; only that outcome permits
a normal render skip. `SurfaceLost` and `DeviceLost` retain fatal propagation in the current
host. Recovery and swapchain policy for Vulkan remain undesigned. A failed frame acquisition
must not open a frame, advance its successful-frame identity or leak a drawable.

## Consequences

The two backends can exercise the same legal command stream and the same retirement contract.
Texture reload no longer depends on Metal forgiving an early free. The null backend can
prove completion and stale-handle behavior without a GPU, while Metal supplies distinct
device evidence. Explicit retirement costs retained storage until completion and requires
failure-safe bookkeeping, which is bounded by the resources successfully created.

Some rule-9 tests must change their expected result because they currently reject behavior
§3 promises. Replacement tests must observe retained storage and eventual reclamation, and
must still fail when reclamation occurs early. Merely removing the old violation is not proof.
Usage tests may expose missing flags in fixtures and real consumers; those consumers must be
corrected rather than exempted. No C ABI table or serialized content layout changes here.

## Alternatives considered

* Rewrite the RHI promise as caller-owned immediate destruction: less backend work, but
  withdraws the established §3 guarantee and repeats completion policy in every consumer.
* Wait for the entire device at every destruction: safe after submission, but serializes
  ordinary texture replacement and does not by itself cover commands not yet submitted.
* Depend on Metal retention: cannot establish the same contract for the validation backend
  or the planned Vulkan backend.
* Leave usage validation to M13: preserves a known hole that M11 explicitly exists to close.
* Retry every surface error forever: conceals a failed surface and prevents useful diagnostics.

## Revisit if

Multiple queues arrive, measured retirement pressure needs finer reclamation, or Vulkan
bring-up exposes completion or surface outcomes the current single-queue contract cannot
express. Revisit the internal contract through an ADR before changing the public boundary.
