# VolumeChordRecorder SafeNoNC

이 버전은 부팅/리스프링 루프 방지를 위해 Notification Center transparency/live passthrough 관련 SpringBoard UI 훅을 전부 제거한 안전 빌드입니다.

유지 기능:
- SpringBoard/Home Screen에서 3손가락 아래 스와이프로 녹음 시작/종료
- 선택적으로 Volume Up + Down 트리거
- 녹음 시작/종료 진동
- 설정 앱 표시
- 녹음 파일 목록/삭제
- Respring 버튼

제거 기능:
- Notification Center Transparency
- Live Current Screen Passthrough
- CoverSheet/Poster/Wallpaper/UIView 전역 훅
- com.apple.UIKit 전역 앱 주입

빌드:
```bash
make clean
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
```

문제가 있던 빌드를 제거한 뒤 이 버전을 설치하세요.

---

# VolumeChordRecorder - RootHide/Rootless Source

세 손가락으로 아래로 스와이프하면 녹음을 시작/종료하는 Theos 트윅 예제입니다. 볼륨 업 + 볼륨 다운 조합은 설정에서 선택적으로 다시 켤 수 있습니다.


## 이번 버전 추가: 세 손가락 아래 스와이프 트리거

- 기본 트리거를 `Three-Finger Swipe Down`으로 변경했습니다.
- 기존 `Volume Up + Down Trigger`는 기본 OFF이며, 설정 앱에서 다시 켤 수 있습니다.
- 앱 안에서도 세 손가락 제스처를 감지할 수 있게 `com.apple.UIKit` 주입 필터를 추가했습니다.
- 실제 녹음은 SpringBoard에서만 실행되고, 앱 프로세스는 Darwin notification으로 SpringBoard에 토글 요청만 보냅니다.
- Dopamine2 RootHide/Bootstrap 환경에서 특정 앱 내부 제스처가 안 먹으면 Bootstrap App List에서 해당 앱의 tweak injection을 켜야 할 수 있습니다.
- iOS의 세 손가락 편집/접근성 제스처와 충돌하면 `Swipe Distance` 값을 180~220 정도로 올리거나, 필요한 앱에서만 주입을 조절하세요.

권장 초기 설정:

```text
Three-Finger Swipe Down: ON
Swipe Distance: 140
Volume Up + Down Trigger: OFF
Start/Stop Haptic Feedback: ON
```

## 중요한 제한

마이크 사용 표시(노란/주황 점)는 iOS의 개인정보 보호 표시입니다. 이 프로젝트는 해당 표시를 숨기거나 끄는 기능을 제공하지 않습니다.

## 설정 앱 기능

설정 앱에 `Volume Chord Recorder` 항목이 추가됩니다.

- Enable Tweak: 트윅 활성화/비활성화
- Three-Finger Swipe Down: 세 손가락 아래 스와이프로 녹음 시작/종료. 기본 ON
- Swipe Distance: 세 손가락 스와이프 인식 거리. 기본 140
- Volume Up + Down Trigger: 기존 볼륨 버튼 조합 트리거. 기본 OFF
- Hold Seconds: 볼륨 버튼 조합을 켰을 때 동시에 누르고 있어야 하는 시간. 기본 2초
- Max Record Seconds: 최대 녹음 시간. 기본 600초
- Haptic Feedback: 녹음 시작 시 강화 진동, 종료 시 강화 진동
- Debug Gesture Logs: 세 손가락 제스처 디버그 로그 출력
- Debug Button Logs: 볼륨 버튼 이벤트 로그 출력
- Show Recording Path: 녹음 저장 위치 표시
- Respring: SpringBoard 재시작

## 저장 위치

```text
/var/mobile/Media/VolumeChordRecorder/
```

## 로그 확인

```bash
log stream --predicate 'eventMessage contains "VolumeChordRecorder"' --info
```

## GitHub Actions 빌드

`scripts/build_github_actions.yml` 파일을 GitHub 저장소의 아래 위치로 복사하세요.

```text
.github/workflows/build.yml
```

그 후 GitHub Actions에서 `Build RootHide Theos Deb`를 실행하면 `packages/*.deb`가 artifact로 업로드됩니다.

## WSL 빌드

```bash
chmod +x scripts/*.sh
./scripts/build_deb_wsl.sh roothide
# 또는
./scripts/build_deb_wsl.sh rootless
```

## RootHide 주의

RootHide에서는 SpringBoard에 트윅이 실제로 주입되는지 확인해야 합니다.

```bash
log stream --predicate 'eventMessage contains "VolumeChordRecorder"' --info
```

아래 로그가 보여야 합니다.

```text
[VolumeChordRecorder] Loaded into com.apple.springboard
```


## 진동 알림 동작

- 녹음 시작: 짧은 진동 1회
- 녹음 종료: 짧은 진동 2회
- 설정 앱 > Volume Chord Recorder > Haptic Feedback에서 켜기/끄기 가능

## GitHub Actions에서 Telegram으로 .deb 자동 전송

이 ZIP에는 `.github/workflows/build.yml`이 포함되어 있습니다. 빌드가 성공하면 `packages/*.deb`를 GitHub artifact로 업로드하고, 아래 Secrets가 설정되어 있으면 Telegram으로도 전송합니다.

GitHub 저장소에서 설정:

```text
Settings → Secrets and variables → Actions → New repository secret
```

필요한 Secrets:

```text
TELEGRAM_BOT_TOKEN = BotFather에서 받은 봇 토큰
TELEGRAM_CHAT_ID   = .deb를 받을 개인/그룹/채널 chat_id
```

주의: 봇 토큰은 코드에 직접 넣지 마세요. 이미 공개된 토큰은 BotFather에서 revoke 후 새 토큰으로 교체하는 것을 권장합니다.

### CHAT_ID 확인 예시

1. Telegram에서 본인 봇에게 아무 메시지나 보냅니다.
2. 아래 URL을 브라우저에서 열거나 curl로 호출합니다.

```text
https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getUpdates
```

3. 응답의 `message.chat.id` 값을 `TELEGRAM_CHAT_ID` Secret에 넣습니다.

그룹에 보낼 경우 봇을 그룹에 초대한 뒤 그룹에서 메시지를 하나 보내고 `getUpdates`의 `chat.id`를 확인하세요. 그룹 chat_id는 보통 음수입니다.


## 2026-05-08 Fix: UIPressTypeVolumeUp/Down compile error

일부 iPhoneOS SDK 16.x 헤더에는 `UIPressTypeVolumeUp`, `UIPressTypeVolumeDown` 공개 상수가 없어서 컴파일이 실패합니다.
이번 버전은 `VCR_PRESS_TYPE_VOLUME_UP=102`, `VCR_PRESS_TYPE_VOLUME_DOWN=103` 숫자 fallback을 사용합니다.

빌드 후 실제 기기에서 버튼 감지가 안 되면 로그를 켜고 아래 명령으로 press type 값을 확인하세요.

```bash
log stream --predicate 'eventMessage contains "VolumeChordRecorder"' --info
```

로그 예시:

```text
[VolumeChordRecorder] press began type=102
[VolumeChordRecorder] press began type=103
```

만약 다른 숫자가 나오면 `Tweak.xm` 상단의 값을 수정하고 다시 빌드하세요.

```objc
#define VCR_PRESS_TYPE_VOLUME_UP 102
#define VCR_PRESS_TYPE_VOLUME_DOWN 103
```


## 2026-05-08 Fix: Preferences ARC compile error

`Preferences/VCRRootListController.mm` was updated for ARC builds:

- Removed manual `retain` from `_specifiers` assignment.
- Removed manual `autorelease` after `CFBridgingRelease`.
- Added `@import Darwin.POSIX.spawn;` so `posix_spawn` is visible under the iPhoneOS16.5 SDK module build.


## 2026-05-08 Fix
- Preferences bundle에 Info.plist가 누락되어 설정 앱에서 보이지 않던 문제를 수정했습니다.
- `layout/Library/PreferenceBundles/VolumeChordRecorderPrefs.bundle/Info.plist`에도 fallback으로 포함했습니다.

## 2026-05-08 설정 앱 표시 수정

Dopamine2 RootHide + PreferenceLoader 2.2.6 환경에서 설정 항목이 보이지 않던 문제를 반영했습니다.

변경 사항:

```text
기존 등록 파일: /Library/PreferenceLoader/Preferences/VolumeChordRecorder.plist
수정 등록 파일: /Library/PreferenceLoader/Preferences/VolumeChordRecorderPrefs.plist
```

`VolumeChordRecorderPrefs.plist`는 `icon` 항목을 제거하고 `isController`를 추가한 보수적인 PreferenceLoader 형식입니다.

설치 후 기존 등록 파일이 남아 있어도 동작에는 큰 문제 없지만, 중복이나 캐시 문제가 있으면 NewTerm/SSH에서 아래 파일을 삭제해도 됩니다.

```bash
rm /Library/PreferenceLoader/Preferences/VolumeChordRecorder.plist
killall Preferences
sbreload
```

확인:

```bash
ls -al /Library/PreferenceLoader/Preferences/VolumeChordRecorderPrefs.plist
ls -al /Library/PreferenceBundles/VolumeChordRecorderPrefs.bundle/
```

정상 번들 구성:

```text
Info.plist
Root.plist
VolumeChordRecorderPrefs
```


## 2026-05-08 수정

- Preferences의 Respring 버튼을 Dopamine2 RootHide/rootless 환경에 맞게 보강했습니다.
  - `/usr/bin/sbreload`, `/var/jb/usr/bin/sbreload`, `/private/preboot/jb/usr/bin/sbreload` 순서로 시도합니다.
  - 실패하면 `killall -9 SpringBoard` fallback을 시도합니다.
  - 모두 실패하면 설정 앱에서 실패 알림을 표시합니다.
- 녹음 시작 시 짧은 진동 1회, 녹음 종료 시 짧은 진동 2회가 동작합니다.
- 설정 앱의 `Start/Stop Haptic Feedback` 스위치로 진동을 켜고 끌 수 있습니다.

주의: iOS 마이크/카메라 개인정보 표시 점을 숨기거나 비활성화하는 기능은 포함하지 않았습니다.

## 2026-05-08 추가 수정

이번 버전에는 아래 기능이 추가되었습니다.

1. 녹음 시작/종료 진동 강화
   - 녹음 시작: 2회 패턴
   - 녹음 종료: 3회 패턴
   - 설정 앱의 `Start/Stop Haptic Feedback`으로 전체 ON/OFF 가능
   - `Test Strong Haptic` 버튼으로 테스트 가능

2. Respring 버튼 안정화
   - `posix_spawnp("sbreload")`로 PATH 기반 실행 먼저 시도
   - `/usr/bin/sbreload`, `/var/jb/usr/bin/sbreload`, `/private/preboot/jb/usr/bin/sbreload`, `/private/preboot/procursus/usr/bin/sbreload` 순서로 시도
   - SpringBoard restart notification fallback 추가
   - `killall -9 SpringBoard` fallback 추가
   - 실패 시 시도한 경로와 상태값을 알림창으로 표시

3. 녹음 파일 관리 버튼 추가
   - `Show Recordings List`: 최근 녹음 파일 목록, 용량, 생성시간 표시
   - `Delete Latest Recording`: 최신 녹음 파일 1개 삭제
   - `Delete All Recordings`: `/var/mobile/Media/VolumeChordRecorder` 안의 `.m4a` 파일 전체 삭제

녹음 저장 위치:

```text
/var/mobile/Media/VolumeChordRecorder/
```

설정 등록 파일명은 Dopamine2 RootHide + PreferenceLoader에서 표시 확인된 형식인 아래 이름을 사용합니다.

```text
/Library/PreferenceLoader/Preferences/VolumeChordRecorderPrefs.plist
```


## 이번 버전 추가: Notification Center 투명도

설정 앱 → Volume Chord Recorder → Notification Center Transparency 에서 조절할 수 있습니다.

- Enable NC Transparency: 알림센터/커버시트 배경 투명화 켜기
- Wallpaper Alpha: 커버시트 배경/잠금화면 월페이퍼 계층 투명도. 0.0이면 현재 화면이 더 잘 보이고, 1.0이면 원래대로에 가깝습니다.
- Blur / Material Alpha: 블러·머티리얼 계층 투명도
- Dim / Scrim Alpha: 어둡게 덮는 dim/scrim 계층 투명도
- Apply NC Transparency Now: SpringBoard에 즉시 적용 알림 전송

기본값은 기능 OFF입니다. 켠 뒤 `Wallpaper Alpha = 0.0`, `Blur / Material Alpha = 0.08`, `Dim / Scrim Alpha = 0.0` 조합부터 테스트하세요.

주의: 이 기능은 알림센터/커버시트 배경만 조절하며, 마이크/카메라 개인정보 표시 점은 숨기지 않습니다.


## Notification Center 투명도가 다 내린 후 풀리는 경우

이 버전은 iOS가 알림센터 전환 완료 시점에 CoverSheet/Notification Center 배경 Material/Blur 레이어를 다시 생성하거나 alpha를 재설정하는 경우를 보강했습니다.

추가된 안정화 로직:

```text
- CoverSheet/Notification Center subtree를 window class가 아닌 view hierarchy에서도 재검색
- viewDidAppear/viewDidLayoutSubviews/layoutSubviews 이후 반복 재적용
- 전환 완료 후 0.05 / 0.15 / 0.35 / 0.70 / 1.10초 지연 재적용
- UIVisualEffectView / MTMaterialView가 NC context 안에 있을 때 alpha 재강제
```

권장 테스트값:

```text
Enable NC Transparency: ON
Wallpaper Alpha: 0.0
Blur / Material Alpha: 0.05 ~ 0.12
Dim / Scrim Alpha: 0.0
```

그래도 풀리면 `Debug NC View Logs`를 켠 뒤 아래로 로그를 확인하세요.

```bash
log stream --predicate 'eventMessage contains "VolumeChordRecorder"' --info
```


## Notification Center transparency readability fix

If Notification Center text mixes with the Settings screen or another app while dragging down,
turn on `Protect Notification Cards` or press `Set Readable NC Transparency`.
This preserves notification/platter/card backgrounds while still making the main Notification Center background transparent.
Recommended readable values:

```text
Wallpaper Alpha: 0.00
Blur / Material Alpha: 0.16
Dim / Scrim Alpha: 0.18
Protect Notification Cards: ON
```

If you want the most transparent look, lower Blur/Dim again, but notification text can visually overlap with the app underneath.


## 알림센터 현재 화면 스냅샷 언더레이

알림센터를 끝까지 내리면 iOS가 현재 앱 화면이 아니라 CoverSheet/잠금화면 배경 레이어를 사용합니다. 그래서 단순히 배경 투명도만 낮추면 현재 앱이 아니라 잠금화면 배경이 보일 수 있습니다.

이번 버전의 `Use Current Screen Snapshot`은 알림센터가 표시되기 시작할 때 화면을 메모리 안에서만 캡처해 알림센터 뒤에 깔아둡니다. 파일로 저장하지 않으며 알림센터가 사라질 때 제거됩니다. 완전히 실시간 화면은 아니고 정적 스냅샷입니다.

추천값:

```text
Enable NC Transparency: ON
Use Current Screen Snapshot: ON
Wallpaper Alpha: 0.0
Blur / Material Alpha: 0.03 ~ 0.08
Dim / Scrim Alpha: 0.0
```

## Notification Center Live Pass-through 모드

이번 버전은 스냅샷을 기본 사용하지 않고, 알림센터가 완전히 내려갔을 때 나타나는 Lock Screen/CoverSheet 배경화면·Poster 레이어를 숨기는 방식으로 현재 화면이 뒤에 남아 보이도록 시도합니다.

권장 설정:

```text
Enable NC Transparency: ON
Hide Lock Screen Wallpaper: ON
Use Snapshot Fallback: OFF
Wallpaper Alpha: 0.0
Blur / Material Alpha: 0.04 ~ 0.12
Dim / Scrim Alpha: 0.0
```

빠른 설정 버튼:

```text
Set Live NC Passthrough
```

주의: 이 방식은 스냅샷이 아니라 실제 아래 레이어를 보이게 하는 방식이라, 홈화면/스프링보드에서 재생되는 영상은 보일 가능성이 높습니다. 다만 일반 앱의 영상은 iOS가 알림센터가 완전히 덮였다고 판단하면 렌더링을 멈추거나 정지 화면으로 바꿀 수 있습니다. 이 경우 완전한 실시간 영상 유지까지는 앱/WindowServer 정책에 따라 달라질 수 있습니다.

## 이번 버전: 알림센터 Live Passthrough 모드

이전 `Keep Current Screen Snapshot` 방식은 현재 화면을 메모리 스냅샷으로 깔아주는 방식이라, 홈화면에서 영상이 재생 중이어도 알림센터를 완전히 내린 뒤에는 정지된 이미지처럼 보일 수 있습니다.

이번 버전은 스냅샷을 기본 OFF로 바꾸고, 아래 옵션을 추가했습니다.

```text
설정 앱 → Volume Chord Recorder → Notification Center Transparency

Live Current Screen Passthrough: ON
Hide Lock Screen Wallpaper / Poster: ON
Fallback Snapshot Underlay: OFF
```

권장 프리셋:

```text
Set Live Passthrough Preset
```

이 모드는 알림센터/CoverSheet가 완전히 열린 상태에서 iOS가 락스크린 배경화면/Poster 레이어를 다시 올리는 것을 최대한 숨기고, Notification Center 창과 배경 레이어를 투명하게 유지합니다. 그래서 아래쪽 앱 화면이나 홈화면 영상이 계속 움직이는 형태로 보이는 것을 목표로 합니다.

기기/iOS 조합에 따라 private view 이름이 다르면 일부 레이어가 남을 수 있습니다. 그때는 `Debug NC View Logs`를 켜고 아래 명령으로 클래스명을 확인해 주세요.

```bash
log stream --predicate 'eventMessage contains "VolumeChordRecorder"' --info
```

이 기능은 알림센터/커버시트 배경 레이어만 조절하며, 마이크/카메라 개인정보 표시 점은 숨기거나 변경하지 않습니다.
