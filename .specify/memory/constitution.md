<!--
SYNC IMPACT REPORT
==================
Version change: (template / unversioned) → 1.0.0
Bump rationale: Initial ratification of a concrete constitution from the
  unfilled template. MAJOR (0→1) because this establishes the foundational
  governance set; no prior versioned principles existed.

Modified principles:
  - [PRINCIPLE_1_NAME] → I. Code Quality (NON-NEGOTIABLE)
  - [PRINCIPLE_2_NAME] → II. Testing Standards (NON-NEGOTIABLE)
  - [PRINCIPLE_3_NAME] → III. User Experience Consistency
  - [PRINCIPLE_4_NAME] → IV. Performance Requirements
  - [PRINCIPLE_5_NAME] → (removed; project requested four principles)

Added sections:
  - Technology & Quality Constraints (Go, Python, React)
  - Development Workflow & Quality Gates

Removed sections:
  - Placeholder fifth principle slot (intentional; only four principles requested)

Templates requiring updates:
  - ✅ .specify/templates/plan-template.md (Constitution Check gate is generic; no change needed)
  - ✅ .specify/templates/spec-template.md (no constitution-specific tokens; no change needed)
  - ✅ .specify/templates/tasks-template.md (task categories align with principles; no change needed)
  - ✅ .specify/templates/checklist-template.md (generic; no change needed)

Follow-up TODOs: None.
-->

# AISAT Studio Constitution

## Core Principles

### I. Code Quality (NON-NEGOTIABLE)

All code MUST meet a consistent, enforceable quality bar before it is merged.

- Every change MUST pass the project's automated linters and formatters with zero
  errors: `gofmt`/`golangci-lint` for Go, `ruff`/`black` for Python, and
  `eslint`/`prettier` for React/TypeScript.
- Public functions, exported types, and module entry points MUST be documented;
  code MUST be self-explanatory through clear naming over inline commentary.
- Functions MUST have a single responsibility; cyclomatic complexity and file
  length that exceed agreed lint thresholds MUST be refactored, not suppressed.
- No commented-out code, dead code, or `TODO` without an associated tracked issue
  may be merged.
- Every change MUST be reviewed and approved by at least one other engineer.

**Rationale**: A uniform quality bar across three language ecosystems prevents
divergence, lowers onboarding cost, and keeps the codebase maintainable as it
scales.

### II. Testing Standards (NON-NEGOTIABLE)

Tests are the contract for behavior and MUST be written and maintained rigorously.

- Test-Driven Development is mandatory: write a failing test, get it approved,
  see it fail, then implement. Red-Green-Refactor is strictly enforced.
- Every new feature and every bug fix MUST include automated tests; a bug fix
  MUST include a regression test that fails without the fix.
- Test coverage MUST NOT decrease on any change; new code targets a minimum of
  80% line coverage measured by the language's standard tool (`go test -cover`,
  `pytest --cov`, `vitest`/`jest --coverage`).
- Contract and integration tests are REQUIRED for new service boundaries, API
  changes, inter-service communication, and shared schemas.
- The full test suite MUST pass in CI before merge; flaky tests MUST be fixed or
  quarantined with a tracked issue, never ignored.

**Rationale**: Tests written first define intended behavior, catch regressions
early, and make refactoring safe across the Go, Python, and React layers.

### III. User Experience Consistency

The product MUST present a coherent, predictable experience across all surfaces.

- UI components MUST come from the shared React design system; ad-hoc, one-off
  components that duplicate existing patterns are prohibited.
- Visual language (spacing, typography, color, iconography) and interaction
  patterns MUST follow the documented design tokens and guidelines.
- All interfaces MUST meet WCAG 2.1 AA accessibility requirements, including
  keyboard navigation, focus management, and screen-reader labels.
- API responses, error formats, and naming conventions MUST be consistent across
  Go and Python services so clients see one predictable contract.
- User-facing error states MUST be actionable, human-readable, and consistent in
  tone and structure.

**Rationale**: Consistency reduces cognitive load for users, builds trust, and
ensures the product feels like one cohesive whole rather than disconnected parts.

### IV. Performance Requirements

Performance is a feature and MUST be specified, measured, and defended.

- Every feature with user-facing latency MUST define measurable performance
  budgets before implementation. Default targets unless a feature documents an
  exception: API p95 latency < 200ms, initial web page interactive < 2.5s.
- Performance-sensitive paths MUST have benchmarks or load tests; regressions
  beyond the agreed budget MUST block the merge.
- Resource usage (CPU, memory, payload size, bundle size) MUST be bounded and
  monitored; React production bundles MUST track size budgets and fail CI on
  unexplained growth.
- Database and external calls on hot paths MUST avoid N+1 patterns and MUST use
  pagination, indexing, and caching where appropriate.
- Observability (structured logs, metrics, traces) MUST be in place to measure
  the budgets above in production.

**Rationale**: Defining and continuously measuring performance budgets prevents
slow degradation, protects user experience, and keeps infrastructure costs
predictable as usage grows.

## Technology & Quality Constraints

- **Languages & stacks**: Backend services in Go and Python; frontend in React
  (TypeScript). New components MUST justify any deviation from these stacks.
- **Tooling baseline**: Go (`gofmt`, `golangci-lint`, `go test`), Python
  (`ruff`, `black`, `pytest`), React (`eslint`, `prettier`, `vitest`/`jest`).
- **Dependencies**: New third-party dependencies MUST be justified, actively
  maintained, license-compatible, and security-scanned before adoption.
- **Security**: Code MUST be free of the OWASP Top 10 vulnerability classes;
  secrets MUST never be committed and MUST be loaded from the environment.

## Development Workflow & Quality Gates

- **Branching & review**: Work happens on feature branches; merges to `main`
  require at least one approving review and a green CI run.
- **CI gates (all MUST pass before merge)**: lint/format, full test suite,
  coverage threshold, performance/bundle-size checks, and security scan.
- **Constitution Check**: Plans and specs MUST verify alignment with these
  principles. Any violation MUST be documented with explicit justification or
  the work MUST be revised to comply.
- **Definition of Done**: Code reviewed, tests passing, coverage maintained,
  performance budgets met, UX guidelines followed, and documentation updated.

## Governance

This constitution supersedes all other development practices. Where another
document conflicts with it, this constitution prevails.

- **Amendments**: Proposed changes MUST be submitted as a pull request that
  describes the change, its rationale, and migration impact. Amendments require
  approval from project maintainers before they take effect.
- **Versioning policy**: This constitution follows semantic versioning.
  MAJOR for backward-incompatible governance or principle removals/redefinitions,
  MINOR for newly added or materially expanded principles/sections, and PATCH for
  clarifications and non-semantic refinements.
- **Compliance review**: All pull requests and design reviews MUST verify
  compliance with these principles. Reviewers MUST reject changes that violate a
  NON-NEGOTIABLE principle without a documented, approved exception.
- **Runtime guidance**: Use `.github/copilot-instructions.md` and the active
  plan for day-to-day development guidance consistent with this constitution.

**Version**: 1.0.0 | **Ratified**: 2026-06-05 | **Last Amended**: 2026-06-05
