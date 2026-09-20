# Local feature completion — September 19, 2026

Implemented in the downloaded `Estimoto-plus-main` workspace, which initially had
no Git metadata. The workspace is now connected to the existing GitHub repository
with its original history preserved. These are local source/build results, not a
production deployment or mobile release.

## Completed flows

- **Reminders:** overdue, due-now and upcoming status follows either the saved
  calendar date or the vehicle's current mileage. Lists sort by urgency, then
  date and mileage. A collapsed completed list allows reopening, editing and
  deleting after Undo expires. Changes are scoped to the selected vehicle;
  duplicate taps and session changes cannot trigger stale follow-up actions.
- **Reminder editing:** clear an existing date to use mileage only, retain
  date-or-mileage validation, and open very old overdue dates without a date
  picker assertion. Mileage input respects the API's five-million-mile limit.
- **Service history:** search service names, shops, parts and notes; combine
  search with category filters; clear filters; show matching counts and distinct
  no-results feedback. Newest service records appear first. Switching vehicles
  resets filters. Documented costs explicitly include all records for the vehicle.
- **History editing and receipts:** camera/gallery/PDF actions save the edit and
  continue to attachment on the same record. Cancelling selection preserves the
  saved edit. The original vehicle is shown as read-only because the API does
  not support moving records. Amounts of $1,000 or more remain valid when editing
  or recovering a draft; existing receipts and exact cents are retained.
- **Estimate follow-up:** submitted estimates expose their selected provider's
  contact profile using the saved provider ID. Missing providers get an explicit
  unavailable message rather than matching by name. This profile shows contact
  options without unrelated save or request prompts. Draft sharing remains intact.
- **Google shop saving:** live listing verification runs outside the customer
  write transaction so the separate atomic request-budget transaction cannot
  deadlock SQLite. Ownership is checked before lookup and again under the write
  lock afterward. Failed verification preserves the previous shop choice.

## Validation

- `cd app && flutter test --no-pub --reporter expanded`: 282 tests passed.
- Cost-format and contact-profile regressions were reproduced before their fixes
  and are included in the final app suite.
- `cd app && flutter analyze --no-pub`: no issues.
- `cd app && flutter build web --no-pub --dart-define=PLUS_DEMO=true`: successful
  JavaScript web build. Existing secure-storage dependencies do not support Wasm;
  no Wasm build is claimed.
- `cd backend && .venv/bin/python -m pytest -q`: 449 passed, 37 skipped. Skipped
  tests require a disposable PostgreSQL instance or the original Estimoto bridge
  checkout. No PostgreSQL/integrated bridge proof is claimed for this local run.
- Browser checks in the local demo verified completion and reopening after Undo,
  category filtering, matching text search, and the selected estimate shop profile.
- Widget coverage includes 320px screens with enlarged text, cross-vehicle scope,
  stale sessions, duplicate taps, same-record attachments, missing providers, and
  vehicle deletion/reassignment during shop verification.

## Remaining scope

No production deployment, native distribution or physical-device verification
was performed. No shop was contacted. Calendar/Gmail configuration, push reminder
delivery, CARFAX and store publication remain separate integration work. Reminder
completion does not create a service-history entry or automatically repeat a
maintenance interval. The capture page's existing “Review required photos” button
still opens its camera; a gallery-first review flow remains a follow-up improvement.
