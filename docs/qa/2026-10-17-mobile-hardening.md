# Mobile feature hardening — October 17, 2026

This pass audits the existing mobile workflows beyond Settings and fixes concrete
session, transport and interaction failures. It does not claim every external
integration is connected or that simulated tests prove physical-device behavior.

## Changes

- Account invalidation immediately shuts down the API repository. Requests waiting
  for an auth token cannot dispatch afterward; late responses cannot return data
  to the ended session. Closing the API client is idempotent.
- Authentication waits have a 20-second deadline. JSON request bodies are serialized
  before awaiting authentication, including nested values. Vehicle and estimate
  upload bytes are copied before that await; guided capture also snapshots its
  fields and bytes. Reviewed request contents cannot change while a token refresh
  is pending.
- JSON responses are bounded to 16 MiB. Existing image/receipt and capture response
  size limits remain. Response deadlines cover headers plus the whole body:
  ordinary API/estimate-photo reads 20 seconds, vehicle images 25 seconds,
  uploads/capture 45 seconds, assistant/receipt requests 60 seconds. Capture and
  receipts retain their shorter idle timeouts too. Authentication has its own
  deadline. A continuously trickling stream cannot extend these response deadlines.
- Incomplete response subscriptions are cancelled on timeout, oversize data or
  invalid session. Bodies arriving after the response deadline are discarded.
  Normal EOF does not redundantly cancel an already completed subscription.
- Vehicle and reminder forms use the existing account-bound workspace lifecycle.
  Duplicate save/delete callbacks are guarded; confirmations cannot execute after
  sign-out. Vehicle removal now asks for confirmation. Late vehicle saves cannot
  restore selection after private session state was cleared.
- Clearing Estibot's conversation invalidates outstanding replies, including late
  errors. An old reply cannot repopulate the cleared conversation.
- History privacy controls distinguish an unknown choice from false. Malformed
  saved responses retain the unconfirmed intent and retry control rather than
  claiming consent was disabled or successfully changed.

## Workflow audit and retained protections

| Surface | Checked paths and evidence |
| --- | --- |
| Garage and reminders | Create/edit/remove, duplicate callbacks, confirmation after sign-out, late save completion; garage, reminder and new workflow regressions |
| Estimates and photos | Draft create/edit/delete, review, submission replay, photo recovery and ownership; existing estimate/capture suites plus transport shutdown, immutable uploads and streaming deadlines |
| Repairs and requests | Explicit consent, exact-body idempotent replay, cancellation and account guards; repair/request regressions and real HTTP smoke |
| History and receipts | CRUD, pending receipt recovery, private reads, parsing/cost conflicts and consent; history/receipt suites plus malformed privacy and receipt deadline regressions |
| Find Help and saved shops | Search scope/generation guards, explicit outreach review and authorization, private CRUD; discovery, customer workspace and outreach suites plus common transport protections |
| Calendar and valuation | Account-bound async results, calendar reconciliation, selected vehicle and saved lookup scope; existing calendar/valuation suites plus common transport protections |
| Estibot | Context changes, account changes, duplicate submissions and conversation clearing; existing actions suite plus outstanding-reply regression |

No automatic mutation retry was introduced. Existing idempotent requests keep
original keys and bodies; photo/receipt workflows retain saved evidence after an
uncertain outcome. Already transmitted requests cannot be recalled by closing a
client.

## Validation

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub --timeout 45s --reporter expanded`: 428 tests passed,
  including 31 new transport and workflow regressions.
- `backend/.venv/bin/python scripts/smoke_api.py --flutter-client`: passed,
  including migration/schema checks and persistence after API restart.
- `flutter build apk --debug --no-pub --dart-define=PLUS_DEMO=true`: passed.
  The existing pdfx Kotlin Gradle plugin compatibility warning remains.
- iOS simulator debug build: blocked locally. Xcode 27.1 rejects older deployment
  targets. A temporary external xcconfig setting the simulator target to iOS 15
  got past that check, but Flutter's `debug_unpack_ios` then rejected the framework
  architecture list (`arm64 x86_64`) even though lipo reports both architectures.
  An arm64-only override did not resolve it. No tracked platform settings or
  supported OS versions were changed; iOS compilation is not verified.

The local socket smoke uses disposable services and fictional identities/providers;
it verifies the real Dart HTTP adapter, ownership, edits/deletes, request replay,
private photos and persistence across API restarts. No production calls are made.

## Release boundary

This is source hardening and local validation. No deployment, store upload,
physical-device camera run, real provider delivery or production calendar flow is
claimed. Calendar/Gmail configuration, CARFAX, push reminders and automated
phone/SMS booking remain separate integration work. This pass adds no backend
migration; the previously committed settings migration is still required for its
rollout.
