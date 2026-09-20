# Customer flow parity — September 19, 2026

This pass continues the feature completion work in `Estimoto-plus-main`.
Parity here means completing the existing customer flows and matching demo
behavior to the API where it affects those flows. It does not claim every
original Estimoto feature or external integration is present.

## Changes

- **Estimates:** combine vehicle, status and text filters within the selected
  PDR/Collision discipline. Search vehicle, damage description, provider and claim
  number. Failed delivery or processing appears under Needs attention. Order by
  latest update with creation-date fallback and unknown dates last. All vehicles
  remains the default; filtered empty states and Clear filters keep hidden records
  discoverable. Selecting one vehicle also updates the default for new estimates.
- **Repairs and requests:** combine vehicle, activity and text filters; show
  latest updates first within each section. Follow up using the request's exact
  provider ID. Missing providers have explicit unavailable contact details.
  Scheduled requests can be cancelled, matching the existing API. Confirmations
  distinguish saved cancellation from provider acknowledgment; demo cancellation
  never implies a provider was contacted. Duplicate taps and expired sessions
  cannot trigger stale follow-up actions.
- **Guided capture:** review private saved images inside the capture flow and
  retake a selected view. The host binds reads to the current estimate, account,
  active photo ID and hash, with bounded raster bytes and response hash checks.
  Reads have an overall deadline and cancel their response stream. Retaking
  preserves the previous saved photo until its replacement succeeds. Legacy
  photos without hashes offer a return to the existing estimate viewer or a
  retake; older native hosts preserve evidence and show a preview fallback.
- **Demo:** preserve vehicles referenced by service history; admit nearby
  fictional shop visits consistently with discovery; require exact service ZIP
  for mobile visits and reject unsupported modes. Ready/approved sample estimates
  show completed review progress while explicitly reporting no shop contact.

## Validation

- `cd app && flutter test --no-pub --reporter expanded`: 321 tests passed,
  including the final capture timeout and body-cleanup regressions.
- `cd app && flutter analyze --no-pub`: no issues.
- `cd app && flutter build web --no-pub --dart-define=PLUS_DEMO=true`:
  successful JavaScript build. Existing secure-storage dependencies remain
  incompatible with Wasm; no Wasm build is claimed.
- `bash scripts/build_capture.sh`: 29 tests passed, TypeScript/Vite production
  build passed, and the vendored source digest matched unchanged source commit
  `22f6e42d00ec34af9ad1dcaa98f465b310993454`. The existing Three.js chunk-size
  warning remains.
- `cd backend && .venv/bin/python -m pytest -q tests/test_customer_capture.py tests/test_api.py tests/test_request_rejection.py`:
  52 passed. No backend source changed in this pass.
- Browser smoke in the local demo verified combined estimate text/status
  filtering, Clear filters, explicit vehicle scope across PDR/Collision, and
  repair activity filtering with no-results recovery.
- A disposable same-origin RPC mock harness verified the built capture page's
  saved-image selector, one selected preview at a time, a one-view VIN retake,
  and preservation of all nine photos after closing that retake. Controls were
  visually checked at 320px. This uses fictional fixtures with camera/network
  access blocked; it is not authenticated host or physical-camera proof.
- Widget regressions cover 320px enlarged text, disappearing vehicles, deleting
  the final estimate while filtered, ended sessions, duplicate cancellation,
  scheduled cancellation through the real API client with a mock transport,
  missing provider records, and combined search/scope/status filters.
- Independent review findings about inaccessible empty-list filters, unbounded
  slow preview downloads and legacy hashless photos were addressed before push.

## Release boundary

These are source, local test and demo-preview changes. No production deployment,
native mobile release, physical-device camera check or real provider contact is
claimed. Calendar/Gmail settings remain unconfigured. CARFAX, push reminder
delivery and automated phone/SMS booking remain separate integration work.
