# Multi-photo problem sessions

A separate authenticated `POST /ai/problem` endpoint analyzes 1–5 photos of one problem together. It returns one fully validated JSON plan; it never streams partial actions. Existing `/ai/parts`, `/ai/steps` and `/ai/ask` contracts are unchanged.

## Request

`Content-Type: application/json`, existing session bearer token. Fields:

- `problem`: nonempty description, at most 1,000 characters.
- `photos`: 1–5 `{id, image, note, role}` objects. `image` is base64 JPEG or a JPEG data URL, longest side ≤768 pixels, ≤2 MiB each. `note` ≤300 characters. `role` is `overview`, `detail`, `label`, or `after`.
- `history`: at most 30 `{stepId, title, photoId, outcome, note}` objects. `outcome` is `done`, `unable`, or `unchanged`; title ≤100 characters, note ≤300.
- `answers`: at most 12 `{question, answer}` objects, each text ≤500 characters.
- `previousComponents`: at most 15 `{id, name, views:[{photoId, box}]}` objects. Name ≤80 characters, 1–5 views per component. Boxes are integer XYXY values from 0 through 1,000, with positive width and height, relative to that specific photo.
- `resolutionConfirmed`: boolean; means the person confirmed the result, not merely that a step was performed.
- Optional `provider`: `astra` or `gemini`, permitted only when the environment allows provider selection. Default follows `AI_PROVIDER`.
- Optional `sessionId`: UUID for usage correlation. It is not trusted to exempt a request from quota.

IDs contain only ASCII letters, numbers, `_` and `-`, with a 64-character maximum. Photos, history step IDs, components and per-component views must have unique IDs. History and previous component views must reference photos retained in the bundle. Old evidence is never silently discarded. The request stream is bounded to 15 MiB even without a truthful Content-Length; decoded images total at most 10 MiB.

## Response and safety rules

The response contains `summary`, one `observations` entry per input photo, `components`, `links`, at most five `steps`, and `next`. Optional usage fields returned by the backend are `model`, `usage`, `costUsd`, and `latencyMs`.

Observations classify relevance as `relevant`, `uncertain`, or `unrelated`. A component can have multiple views to represent the same physical object; different components can be related by `same_system`, `connected`, or `uncertain` links with photo evidence and a reason. The schema cannot prove visual identity: the prompt directs the model to ask when identity is uncertain, and both server and client validate its declared references before exposing actions.

Each step contains `id`, `title`, `text`, `photoId`, `componentIds`, nullable `arrow`, nullable `warning`, and nullable `tool`. Every targeted component must have a view on the selected relevant photo. IDs already in history cannot be replayed. Arrow pairs are `rotate:cw/ccw`, `move:up/down/left/right/toward/away/up_left/up_right/down_left/down_right`, and `press/hold/align:none`.

The model orders actions by their prerequisites and the problem's needs, independently of upload order. Each step selects the clearest available view of its target; a plan can revisit a photo, for example photo 2 → photo 1 → photo 2. The input photos, their IDs, and their evidence associations stay intact. Both provider transport tests exercise that sequence and verify the selected components' photo-specific boxes after response validation and coordinate conversion. These mocked tests establish ordering and reference preservation, not the model's ability to choose a correct real-world sequence.

`next` contains `kind`, `prompt`, and `reason`:

- `needs_answer` / `needs_photo`: request missing evidence with zero actionable steps.
- `verify`: give safe next steps and then check the outcome, or ask for result verification.
- `resolved`: no steps, explicit user result confirmation required, with at least one `done` history entry.
- `unresolved`: no steps; explain what could not be established and why.

Uncertain links block all actions pending clarification. Confirmed links must reference relevant photos containing evidence for both endpoints. Unrelated or uncertain photos cannot be action targets. Exhausted photo/answer/history limits never become success; they also cannot produce another unavailable request or action. Invalid schemas, references, arrow pairs, coordinates, truncated provider output and timeouts return an error instead of a partial plan. Semantic accuracy still requires real scenario evaluation; structural validation alone cannot establish a diagnosis.

Both providers receive a prompt followed by alternating photo-label text and actual image data for **every** photo in input order. Gemini uses its native YXYX `box_2d` schema and the existing transport converts back to XYXY before validation. The endpoint makes one paid call per turn and does not automatically retry a full bundle. Client cancellation and provider deadlines cancel the upstream signal.

## Quota, usage and deployment

Migration `backend/worker/migrations/0004_usage_problem.sql` adds the `problem` stage to the usage-table constraint. It rebuilds the table while preserving every historical row and the user/date index. Apply migrations in order, including `0003_usage_explain.sql` on environments that have not received that earlier migration, before deploying code that records the new stage. Historical `explain` rows remain valid even though that UI was removed.

Each paid problem turn counts toward the existing daily limit, together with legacy `parts` requests. Failed paid turns count too. This deliberately avoids trusting a client-supplied session ID to bypass quota; follow-up turns consume quota as well. Usage summaries consequently count problem turns rather than unique multi-photo sessions. The existing settings UI label should be reconsidered if it promises unique session counts.

Successful requests record provider/model, tokens, estimated cost and latency; failures record an error/timeout row. As in older routes, unknown tokens/cost on failed requests are recorded as zero and are not proof that the provider charged nothing. No images or prompt contents are saved in usage rows. Database writes are kept alive through the Worker execution context.

**Deployed to staging on 2026-10-18:** Worker version `1a075bb0-6eb7-44b9-945b-6640386fa4b7`, after migration `0004_usage_problem.sql`. The 439 existing usage rows were preserved. Free health/auth checks passed, including `/ai/problem` returning 401 without credentials. Development tests used mocked provider responses; no paid multi-photo evaluation has been run. Routing and simulator checks do not establish model accuracy.

## Backend verification

From `backend/worker`, using Node 22 or newer:

```sh
npm run typecheck
npm test
```

Current result: all 399 Worker tests passed, including 70 new multi-photo tests. Tests cover both providers' actual request payload shape/order, Gemini coordinate conversion, auth, provider-selection gating, quota accounting, input/body limits, references, component associations, all 15 arrow pairs, unsafe/ambiguous actions, replay prevention, confirmation requirements, cancellation, deadlines and refusal to expose invalid partial plans.

## iOS workflow and simulator review

The start screen uses its existing **გადაიღე ფოტო** and gallery entries. After the first capture, the original description screen shows a photo strip and **ფოტოს დამატება** for another camera shot or multiple gallery photos (up to five total). Adding/removing photos preserves the description and stable photo IDs. There is no separate multi-photo start button. Submitting one photo keeps the existing single-photo pipeline; submitting several transfers all full-frame evidence, description and selected AI provider into `ProblemSessionModel` and opens `PhotoProblemFlowView` directly in analysis. Users do not have to describe the problem again. Closing that result view returns to the original draft. Import normalizes all eight orientations, preserves the entire frame, downsamples to ≤768 pixels without upscaling, and caps source/output bytes. Each photo has an editable role and note until a successful analysis submits that evidence.

The current step selects its own photo. Component IDs can occur in multiple photos, each with its own box; `ProblemEvidenceView` refuses to draw a step's arrow on a different selected photo. Users can report done/unable/unchanged, answer clarification, or add another evidence photo and request a revised plan. Pending new photos disable old action controls until reconsidered. The original description, submitted evidence, answers and history remain in the in-memory session. Closing the session does not persist it to disk.

The app retains evidence and history on errors and retries, cancels the HTTP request when its operation is cancelled, and does not label exhausted limits as completion. It never infers success merely from pressing “შევასრულე”. Explicit result confirmation follows completed actions. Up to five photos are retained, so the interface suggests keeping a slot for outcome evidence.

`--problem-demo` opens a clearly labelled offline demo. It uses a bundled overall photo and an explicitly labelled crop of the same scene, then exercises clarification, two photo-specific steps and explicit confirmation. It makes no AI request and is not an accuracy evaluation. Additional gallery photos can be imported, but this mock does not analyze their contents.

To inspect on the dedicated iPhone 17 Pro simulator after building:

```sh
xcrun simctl install A7DED3A5-97EC-4804-B894-61C60D463C3D /tmp/kadri-arrows-build/Build/Products/Debug-iphonesimulator/Kadri.app
open -a Simulator --args -CurrentDeviceUDID A7DED3A5-97EC-4804-B894-61C60D463C3D
xcrun simctl launch A7DED3A5-97EC-4804-B894-61C60D463C3D ge.kadri.app --problem-demo
```

Tap **შეადგინე ნაბიჯები**, answer where the drops appear, then follow both steps. Check that the selected photo changes with the second instruction. Report an unsuccessful action to see the unresolved branch, or complete both actions and confirm the result. Tap **თავიდან** to reset its in-memory scenario. No video is recorded.

Core validation: 151 tests executed, one skipped, zero failures; 14 specifically cover multi-photo state/transport, including Unicode-safe request bounds and network cancellation. New simulator tests cover full-frame imports and the complete mocked multi-photo flow, including wrong-photo arrow exclusion and unsuccessful-action handling.

Simulator regression result: **39/39 passed**, covering the new flow/import tests plus existing annotation selection, autopilot, camera, check-photo, completion and multi-round tests. The final UI-only rerun after presentation refinements also passed **2/2**. Logs: `/tmp/kadri-problem-regression.log`, `/tmp/kadri-problem-ui-final.log`; screenshots of seven flow states are in `/tmp/kadri-problem-shots/`. Simulator tests and screenshots do not establish live model accuracy. No videos were created.


### Unified capture validation (2026-10-18)

The unified draft preserves the original description panel and AI-provider picker. Camera captures retain the full frame; additional photos may come from camera or library. Tests verify first/last-photo removal, five-photo limit, preserved description/provider/IDs, automatic analysis on submission, and photo 2 → photo 1 → photo 2 step order. The initial simulator regression passed 18/18 tests; the final draft/flow suite passed 11/11. Backend problem tests passed 72/72 and typecheck passed. Screenshots were inspected at iPhone 12 dimensions and a compact keyboard-sized viewport. No video was recorded.

iPhone 12 build `2026101802` was installed over the previous NETA app and launched normally, using staging rather than mock launch arguments. A real user-photo AI run is still to be evaluated.
