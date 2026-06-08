# Working agreement for this repo

These are the coding standards and working conventions for `iac-gke`. They apply to
everyone working in this repo — humans and Claude Code sessions alike — so that
parallel work stays consistent. They were extracted from a maintainer's personal
Claude profile to make the conventions shared and explicit.

## Communication

- Keep responses very brief by default. Elaborate only when explicitly asked.
- Always expand an acronym the first time it appears in any write-up or response —
  e.g. "HashiCorp Configuration Language (HCL)". After the first expansion the
  acronym alone is fine.
- When a request is ambiguous about scope or placement (e.g. where a feature should
  live, or how broadly to apply a change), ask a brief clarifying question before
  implementing — don't guess or add extra "just in case."

# Engineering standards

Apply these to everything: application code, tests, configuration, infrastructure
(YAML/HCL), and user interfaces (UI). Nothing is exempt from clarity. When verifying
a change requires a setup that isn't available (e.g. a local cluster), ask how to
proceed rather than guessing.

## Prototype & POC mode

When work is flagged as a proof-of-concept (POC), spike, or prototype, optimize for
speed of learning over durability: skip tests, observability, and heavy documentation
unless asked. Briefly state what rigor was skipped, so the trade-off is visible rather
than silent.

Non-negotiable even in a POC, because skipping them costs as much as in production:
never hardcode or commit secrets; don't point at production data or systems without
flagging it; add a top-of-file comment marking the code as a throwaway POC and noting
the main shortcut taken; keep names readable. Treat the relaxation as scoped to that
one effort — when a POC graduates to real use, switch back to full standards and
harden it deliberately.

## Implementation workflow (production builds)

For production-grade work, begin by turning the request into a detailed implementation
plan broken into independently testable **chunks** (the smallest build-test-commit
unit) and **milestones** (demoable slices made of several chunks). Run
`/implementation-plan` to draft it, finalize it, and create the GitHub issues — one
issue per chunk and one tracking issue per milestone, grouped under a native GitHub
Milestone. Every issue carries an `Acceptance criteria` checklist. Create issues only
after the plan is approved; approval is the gate. The plan also captures the
significant decisions and rejected alternatives — mined from any POC work and from the
conversation — as Architecture Decision Records (ADRs) in `docs/adr/` (Markdown Any
Decision Records, MADR, format) plus a Technical Design Record (TDR) for the overall
design in `docs/design/`; both are committed and linked from the issues they govern, so
the *why* survives the session.

Then execute with this discipline:

- Per chunk: build it, write tests covering its acceptance criteria, run them and
  verify, commit referencing the issue, check off only the criteria a test actually
  confirmed, and close the issue. Each chunk is green before the next begins.
- Per milestone: run integration tests across all chunks up to it, record results in
  the milestone issue, fix any regressions, check off the milestone's criteria, and
  close it before going further.
- A box is checked only when a test you ran confirms it; anything unverified stays
  unchecked and you say why. Issues are reopenable — to cover a scenario found later,
  reopen it, add the criterion, fix, re-test, and re-close.

This keeps a traceable record of exactly what code went into each chunk and which
acceptance criteria were proven.

## Design & simplicity

- Favor the simplest design that fully solves the problem. Resist premature abstraction
  ("You Aren't Gonna Need It", YAGNI) as hard as you resist duplication; simplicity
  breaks ties.
- Keep clear module boundaries with explicit contracts. Depend on abstractions, not
  concretions.
- Push side effects (I/O, network, time, randomness) to the edges; keep a pure, easily
  tested core.
- Match the surrounding code's style and idioms — consistency over personal preference.
  Name things for the reader, since code is read far more than written. Delete dead
  code rather than commenting it out.

## Documentation — the *why*, not just the *what*

- File level: a header stating the file's purpose and role. Function level: contract,
  parameters, return value, errors raised, and any non-obvious behavior. Inline: only
  where intent isn't self-evident.
- Comments explain *why* and what was *rejected* — never narrate what the code plainly
  shows. Aim between cryptic and verbose: enough for a human to understand and debug.
- Capture significant decisions as ADRs in `docs/adr/` (MADR format: context → options
  → decision → consequences). Capture the *how* of a non-trivial feature — chosen
  design, data flow, key interfaces — as a TDR in `docs/design/`. Follow the repo's
  existing convention. This is what an engineer reading the code years from now needs
  most.
- Config, infrastructure manifests, and UI get the same documentation care as code —
  no exceptions.

## Error handling & resilience

- Distinguish recoverable from fatal, and expected from exceptional. Never swallow
  errors silently.
- Errors must carry context (what failed, with which inputs) without leaking secrets.
  Fail fast on programmer mistakes; degrade gracefully on operational faults.
- For anything networked: timeouts, retries with backoff, and idempotency. Always
  release resources; support graceful shutdown.

## Concurrency & performance

- State thread-safety assumptions explicitly; prefer immutability and message-passing
  over shared mutable state.
- Measure before optimizing — profile and benchmark, don't guess. Mind algorithmic
  complexity, but never trade clarity for unmeasured gains.

## Observability

- Three pillars: structured logs + metrics + traces. Propagate a correlation/trace ID
  so one request can be followed across components.
- Log levels with intent: DEBUG traces the execution path; INFO marks key state
  transitions; WARN flags recoverable anomalies; ERROR captures actionable failures.
  Never log secrets or Personally Identifiable Information (PII).
- Provide health/readiness checks for long-running services.

## Security

- Validate and sanitize all input at trust boundaries; assume input is hostile. Encode
  output for its destination.
- Apply least privilege everywhere. Never hardcode secrets — load them from a secrets
  manager or environment; never log them.
- Pin and scan dependencies; treat the supply chain as attack surface.

## Testing

- Follow the pyramid: many fast unit tests, a solid integration tier, a few
  end-to-end (E2E) tests. Cover happy paths, edge cases, and failure modes at the
  function level.
- Test the *flow*, not just units: when a user action triggers behavior, exercise the
  whole path — backend and front end (Playwright or equivalent).
- Coverage percentage is a floor, not a goal — assert behavior, not lines. Tests must
  be deterministic (control time, randomness, ordering); no flaky tests.
- Treat tests as documentation: name each by the behavior it proves.

## Reproducibility & change safety

- Commit lockfiles; pin dependency and toolchain versions so the same input produces
  the same build on any machine, years later.
- Use semantic versioning and a clear deprecation policy for anything others depend on.
  Schema and data migrations must be reversible and forward/backward-safe.

## Workflow

- Changes must pass the full test suite, linters, and formatters before being
  committed. If a change can't be verified, say so plainly — don't claim it's done.
- When a local environment is available, deploy there and run end-to-end tests before
  declaring success; when it isn't, ask how to proceed.
- Prefer small, atomic, reversible commits whose messages explain *why*.
