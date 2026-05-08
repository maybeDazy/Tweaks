# VolumeChordRecorder

볼륨 업 + 볼륨 다운을 동시에 2초간 누르면 음성녹음을 시작/종료하는 개인용 탈옥 트윅 예제입니다.

- 대상: 탈옥 iPhone
- 빌드: Windows 10/11 + WSL2 Ubuntu + Theos
- 아키텍처: `arm64 arm64e`
- 패키지 방식: `rootless` 기본, `roothide` 선택 가능
- 주입 대상: `com.apple.springboard`

> 주의: 이 프로젝트는 녹음 시작/종료 시 진동과 로그 피드백을 남깁니다. 녹음 권한/TCC, iOS 버전별 버튼 이벤트, 탈옥 환경의 SpringBoard 주입 가능 여부에 따라 동작이 달라질 수 있습니다.

---

## 1. Windows에서 빌드 준비

WSL2 Ubuntu 터미널에서 실행하세요.

```bash
cd VolumeChordRecorder
chmod +x scripts/*.sh
./scripts/install_theos_wsl_ubuntu.sh
source ~/.bashrc
```

---

## 2. Rootless 빌드

```bash
./scripts/build_deb_wsl.sh rootless
```

또는 직접:

```bash
make clean
make package THEOS_PACKAGE_SCHEME=rootless
```

---

## 3. RootHide 빌드

```bash
./scripts/build_deb_wsl.sh roothide
```

또는 직접:

```bash
make clean
make package THEOS_PACKAGE_SCHEME=roothide
```

결과물은 아래에 생성됩니다.

```text
packages/*.deb
```

---

## 4. 설치 예시

기기에 `.deb`를 복사한 뒤 SSH에서 설치합니다.

```bash
# 예시: 기기 내부에서
sudo dpkg -i com.example.volumechordrecorder_0.2.0_iphoneos-arm.deb
sbreload
```

환경에 따라 `sudo`가 없을 수 있고, `sbreload`, `uicache`, userspace reboot 방식이 다를 수 있습니다.

---

## 5. 로그 확인 위치

별도 `.log` 파일을 만들지 않습니다. `NSLog()`로 iOS Unified Log에 출력됩니다.

기기 SSH에서:

```bash
log stream --predicate 'eventMessage contains "VolumeChordRecorder"' --info
```

정상 주입되면 이런 로그가 보여야 합니다.

```text
[VolumeChordRecorder] Loaded into com.apple.springboard. Recording dir=/var/mobile/Media/VolumeChordRecorder
```

버튼 이벤트 디버그 로그 예시:

```text
[VolumeChordRecorder] pressesBegan candidate type=102 phase=...
[VolumeChordRecorder] pressesEnded candidate type=102 phase=...
```

---

## 6. 녹음 파일 저장 위치

```text
/var/mobile/Media/VolumeChordRecorder/
```

파일명 예시:

```text
VCR_20260508_153012.m4a
```

---

## 7. 버튼 감지가 안 될 때

`Tweak.xm` 안의 아래 함수가 볼륨 버튼 type을 판별합니다.

```objc
static BOOL VCRPressLooksLikeVolumeUp(UIPress *press) {
    NSInteger t = (NSInteger)press.type;
    return (t == 102 || t == 100);
}

static BOOL VCRPressLooksLikeVolumeDown(UIPress *press) {
    NSInteger t = (NSInteger)press.type;
    return (t == 103 || t == 101);
}
```

기기에서 `log stream`을 켜고 볼륨 버튼을 눌러 실제 `type=` 값을 확인한 뒤 위 값을 수정하세요.

수정 후 다시 빌드:

```bash
./scripts/build_deb_wsl.sh roothide
# 또는
./scripts/build_deb_wsl.sh rootless
```

---

## 8. RootHide 환경 메모

RootHide에서는 다음이 핵심입니다.

1. `THEOS_PACKAGE_SCHEME=roothide`로 빌드
2. RootHide Bootstrap에서 SpringBoard 또는 관련 주입 대상이 허용되는지 확인
3. 설치 후 `sbreload` 또는 userspace reboot
4. `log stream`에서 `Loaded into com.apple.springboard` 확인

이 로그가 안 나오면 트윅이 SpringBoard에 주입되지 않은 상태라 볼륨 버튼 감지가 안 됩니다.

---

## 9. TCC/마이크 권한 문제

SpringBoard 프로세스에서 바로 `AVAudioRecorder`를 쓰는 구조라 기기/iOS 버전에 따라 마이크 권한 문제가 발생할 수 있습니다.

증상:

```text
AVAudioSession setCategory failed
AVAudioRecorder init failed
record returned NO
```

이 경우 안정적인 구조는 다음처럼 분리하는 방식입니다.

```text
SpringBoard tweak: 버튼 조합 감지
        ↓ Darwin notification / IPC
Companion app 또는 daemon: 마이크 권한을 가진 녹음 담당
```

현재 ZIP은 단일 트윅 예제라서, 먼저 버튼 감지/빌드/주입 확인용으로 쓰는 것을 권장합니다.
