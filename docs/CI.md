# CI (GitHub Actions)

Workflow: `.github/workflows/ci.yml`. ეშვება ყოველ `pull_request`-ზე და `push`-ზე `main`/`master`-ში. ერთ ref-ზე ახალი გაშვება ძველს აჩერებს (`concurrency` + `cancel-in-progress`). secrets არ გამოიყენება.

## Job-ები

| Job | Runner | Timeout | რას აკეთებს |
|---|---|---|---|
| `ios` | `macos-26` (arm64) | 40 წთ | უახლესი `Xcode_26*.app`-ის არჩევა → `brew install xcodegen` → `xcodegen generate` → `swift test` (KadriCore) → `xcodebuild test` სიმულატორზე |
| `worker` | `ubuntu-latest` | 10 წთ | Node 22, npm cache → `npm ci` → `npm run typecheck` → `npm test` (`backend/worker`) |

- სიმულატორი დინამიურად ირჩევა: `xcrun simctl list devices available --json`-დან პირველი iPhone უახლეს iOS runtime-ზე, `id=<udid>`-ით. image-ში მოწყობილობების სახელების ცვლილება ასე CI-ს არ გატეხს.
- `xcodebuild` ეშვება `CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation`-ით.
- DerivedData `actions/cache`-ით ინახება (`ios/project.yml` + `Package.swift`-ის hash-ზე).
- `ios/Tools`-ის Python-კონვერტაცია (SAM → Core ML) CI-ში **არ** ეშვება. `ios/Models/*.mlpackage` commit-იდან უნდა მოვიდეს.

## ლოკალური შემოწმება

```sh
actionlint .github/workflows/ci.yml
cd backend/worker && npm ci && npm run typecheck && npm test   # Node 22
cd ios && xcodegen generate && (cd Packages/KadriCore && swift test)
```

## remote-ის შემდეგ შესამოწმებელი

1. პირველი push-ის/PR-ის შემდეგ Actions ჩანართში ორივე job (`ios`, `worker`) მწვანეა.
2. `ios` job-ის "Select newest Xcode 26.x" ლოგში `xcodebuild -version` 26.x-ს აჩვენებს, ხოლო "Pick iPhone simulator" — runtime-ს და მოწყობილობას.
3. `.mlpackage`-ების commit-ის შემდეგ `ios` ისევ მწვანეა (Git LFS-ის გამოყენებისას `actions/checkout`-ს `lfs: true` დაემატება).
4. იმავე PR-ზე ახალი push წინა გაშვებას აუქმებს.
5. სურვილისამებრ: Settings → Branches-ში `ios` და `worker` required status check-ად.
6. თუ `macos-26` image-დან Xcode 26 გაქრება, `runs-on` და Xcode-ის არჩევის ნაბიჯი განახლდეს ([runner-images](https://github.com/actions/runner-images)).
