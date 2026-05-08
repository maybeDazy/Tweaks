# VolumeChordRecorder - RootHide/Rootless Source

볼륨 업 + 볼륨 다운을 동시에 일정 시간 누르면 녹음을 시작/종료하는 Theos 트윅 예제입니다.

## 중요한 제한

마이크 사용 표시(노란/주황 점)는 iOS의 개인정보 보호 표시입니다. 이 프로젝트는 해당 표시를 숨기거나 끄는 기능을 제공하지 않습니다.

## 설정 앱 기능

설정 앱에 `Volume Chord Recorder` 항목이 추가됩니다.

- Enable Tweak: 트윅 활성화/비활성화
- Hold Seconds: 동시에 누르고 있어야 하는 시간. 기본 2초
- Max Record Seconds: 최대 녹음 시간. 기본 600초
- Haptic Feedback: 녹음 시작 시 1회 진동, 종료 시 2회 진동
- Debug Button Logs: 버튼 이벤트 로그 출력
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
