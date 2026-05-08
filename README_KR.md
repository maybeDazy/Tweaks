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
