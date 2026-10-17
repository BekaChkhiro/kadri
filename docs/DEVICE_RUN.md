# კადრი — ფიზიკურ iPhone-ზე build, გაშვება და ტესტები

ბოლოს შემოწმდა 2026-10-17: Xcode 26.6, iPhone 12 (iPhone13,2, iOS 18.7.8, LiDAR-ის გარეშე).
ყველა ბრძანება რეპოზიტორიის ძირიდან ეშვება.

## მოწყობილობა და signing

| რა | მნიშვნელობა |
| --- | --- |
| UDID (`xcodebuild -destination`) | `00008101-000E7C500A08801E` |
| devicectl identifier | `21CC38E7-AA4C-5DAB-925B-D881EDA84284` |
| Team ID | `M49DJ3634D` (FormaCore LLC) |
| Bundle ID | `ge.kadri.app` |

`ios/project.yml`-ში `DEVELOPMENT_TEAM` ცარიელია, ამიტომ Team ID ბრძანების ხაზიდან გადაეცემა.
Automatic signing + `-allowProvisioningUpdates` თავად ქმნის App ID-სა და development profile-ს; Xcode-ში ხელით არაფერი დაგვჭირდა.
ტელეფონების სია: `xcrun devicectl list devices` (საჭიროა `available (paired)`).

## 1. Build

```sh
xcodebuild -project ios/Kadri.xcodeproj -scheme Kadri -configuration Debug \
  -destination 'id=00008101-000E7C500A08801E' \
  -derivedDataPath /tmp/kadri-device \
  DEVELOPMENT_TEAM=M49DJ3634D CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
```

შედეგი: `** BUILD SUCCEEDED **`. აპი: `/tmp/kadri-device/Build/Products/Debug-iphoneos/Kadri.app`.

## 2. დაყენება და გაშვება

```sh
D=21CC38E7-AA4C-5DAB-925B-D881EDA84284
xcrun devicectl device install app --device $D /tmp/kadri-device/Build/Products/Debug-iphoneos/Kadri.app
xcrun devicectl device process launch --device $D --terminate-existing ge.kadri.app
# პირდაპირ AR დებაგის ეკრანზე (მხოლოდ Debug build; ContentView კითხულობს არგუმენტს):
xcrun devicectl device process launch --device $D --terminate-existing ge.kadri.app --ar-debug
```

ბოლო სტრიქონი: `Launched application with ge.kadri.app bundle identifier.`
UI-დან: მთავარ ეკრანზე ზედა ღილაკი „AR დებაგი“.

პროცესი ცოცხალია? (გაშვებიდან 20 წმ-ის შემდეგ შემოწმდა, crash არ ყოფილა):

```sh
xcrun devicectl device info processes --device $D | grep Kadri
xcrun devicectl device info apps --device $D --bundle-id ge.kadri.app   # დაყენებული ვერსია
```

## 3. ლოგები

```sh
# stdout/stderr ტერმინალში; devicectl ელოდება აპის დახურვას (Ctrl-C წყვეტს)
xcrun devicectl device process launch --device $D --terminate-existing --console ge.kadri.app --ar-debug
```

სისტემური ლოგები (`os_log`/`Logger`): Console.app → მარცხნივ iPhone → ფილტრი `process:Kadri`.
Crash report-ები: Xcode → Window → Devices and Simulators → View Device Logs.

## 4. Unit ტესტები ტელეფონზე

```sh
xcodebuild -project ios/Kadri.xcodeproj -scheme Kadri -configuration Debug \
  -destination 'id=00008101-000E7C500A08801E' \
  -derivedDataPath /tmp/kadri-device \
  DEVELOPMENT_TEAM=M49DJ3634D CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates test
```

შედეგი: `Executed 5 tests, with 0 failures` → `** TEST SUCCEEDED **`.
ამავე გზით გაეშვება Segmenter-ის parity/ლატენციის ტესტები რეალურ Neural Engine-ზე.

## ტიპური შეცდომები

| სიმპტომი | გამოსავალი |
| --- | --- |
| `No Accounts` / `No profiles for 'ge.kadri.app' were found` | Xcode → Settings → Accounts → Apple ID, რომელიც Team M49DJ3634D-შია; ან ერთხელ Signing & Capabilities-ში აირჩიე Team. მერე build თავიდან. |
| `Signing for "Kadri" requires a development team` | ბრძანებას აკლია `DEVELOPMENT_TEAM=M49DJ3634D`. |
| `Unable to find a destination matching …` | ტელეფონი გახსენი, „Trust This Computer“, შეამოწმე `xcrun devicectl list devices`. |
| launch: `device is locked` / `Locked` | ტელეფონი გახსენი და გაიმეორე. |
| launch: `untrusted developer` | iPhone → Settings → General → VPN & Device Management → developer app → Trust. |
| `Developer Mode disabled` | Settings → Privacy & Security → Developer Mode → On (გადატვირთვა). |
| `--ar-debug` არაფერს აკეთებს | მხოლოდ Debug build-შია (`#if DEBUG`); გამოიყენე „AR დებაგი“ ღილაკი. |
| კამერა შავია | Settings → კადრი → Camera ჩართე (ნებართვის ტექსტი `project.yml`-შია, `NSCameraUsageDescription`). |

## ადამიანისთვის: ტელეფონით შემოწმება

აპი („კადრი“) iPhone 12-ზე უკვე დაყენებულია.

1. გახსენი „კადრი“ → ზემოთ „AR დებაგი“ → კამერის ნებართვა „Allow“.
2. მიჰყევი [AR_DEVICE_CHECKLIST.md](AR_DEVICE_CHECKLIST.md)-ს: დაელოდე „ტრეკინგი ნორმალურია“, გააჩერე ≥300 მწ, „კადრი“.
3. „სატესტო box-ები“ → ჩაიწერე თითო ნაწილის `Δ N px` საწყის ხედზე; მოაბრუნე +30° და −30°, დაბრუნდი, ჩაიწერე Δ. 5-ჯერ (მიზანი iPhone 12-ზე ≤30 px).

დამიბრუნე:
- „სიმკვეთრე: N“ ციფრი და გაჩნდა თუ არა „ტრეკინგი ნორმალურია“;
- რამდენი ნაწილი მიება (მწვანე) და რამდენი `2D` (ნარინჯისფერი);
- 5 დაბრუნების Δ მაქსიმუმები (px) თითო ნაწილზე, სცენა, განათება და მანძილი;
- 1–2 სქრინშოტი (საწყისი ხედი და ±30°-დან დაბრუნების შემდეგ) ან მოკლე ვიდეო.
