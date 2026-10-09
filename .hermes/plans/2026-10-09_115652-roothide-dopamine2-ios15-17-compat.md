# VolumeChordRecorder — Dopamine2(rootless) / rootHide(roothide) / iOS 15~17 호환성·안정화·배포 플랜

작성: 2026-10-09 11:56 KST · 대상 저장소: `C:/Users/server/Desktop/VolumeChordRecorder_roothide_src/Tweaks` (branch `main`, HEAD `4218433`, 워킹트리 clean)

플랜 파일 자신: `.hermes/plans/2026-10-09_115652-roothide-dopamine2-ios15-17-compat.md`

---

## Goal

같은 소스 하나로 **roothide + rootless 두 스킴 패키지**를 빌드해 Dopamine2(rootless)와 rootHide Bootstrap(roothide)에서 iOS 15~17까지 설치·동작하게 만들고, README가 이미 "제거했다"고 선언한 Notification Center/UI 전역 훅 표면을 실제로 제거해 크래시 경로를 없앤 뒤, 정적 검사 하네스와 기기 실측으로 검증해 배포한다.

---

## Current context / assumptions

### 저장소 실측 (이 플랜 작성 시점에 직접 확인한 값)

| 항목 | 확인된 사실 |
|---|---|
| 파일 | `Tweak.xm`(2201줄), `VCRTelegramUploader.{h,m}`, `Preferences/{Makefile,Info.plist,VCRRootListController.mm,Resources/Root.plist}`, `layout/`, `control`, `Makefile`, `scripts/vcr_check.py`, `scripts/build_deb_wsl.sh`, `scripts/build_github_actions*.yml`(stale 사본), `.github/workflows/build.yml`(실제 CI) |
| Makefile | `ARCHS = arm64 arm64e`, `TARGET = iphone:clang:latest:14.0`(= minos 14.0), `INSTALL_TARGET_PROCESSES = SpringBoard Preferences`, 빌드 지침 주석에 `THEOS_PACKAGE_SCHEME=roothide|rootless` |
| control | `Package: com.yourname.volumechordrecorder`, `Version: 0.0.10`, `Architecture: iphoneos-arm`, `Depends: mobilesubstrate, preferenceloader` |
| Filter | `layout/Library/MobileSubstrate/DynamicLibraries/VolumeChordRecorder.plist` → `Bundles = (com.apple.springboard)` **단독** (UIKit 주입 없음, 부팅 사슬 비관여) |
| postinst | `layout/DEBIAN/postinst`: `rm -f /Library/PreferenceLoader/Preferences/VolumeChordRecorder.plist` + `killall -9 SpringBoard` |
| CI | `.github/workflows/build.yml` — roothide/theos 설치 → `make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1` **한 스킴만** → artifact + Telegram. **정적 검사를 돌리지 않는다.** |
| 정적 하네스 | `scripts/vcr_check.py` — 현재 `OK: 93 checks, 0 failed` (`check("...")` 호출 85개 + 루프). 게이트 명령: `python scripts/vcr_check.py` |
| 훅 표면 | 훅 블록 14개 / `%orig` 40회 / 원본 삼킴 0개(직전 커밋에서 수정) |
| NC 훅 | **살아 있음**: 그룹 10개(`VCRCSCoverSheetViewControllerHooks` 1781, `VCRSBDashBoardViewControllerHooks` 1807, `VCRSBNotificationCenterViewControllerHooks` 1833, `VCRNCNotificationListViewControllerHooks` 1859, `VCRCSCoverSheetViewHooks` 1870, `VCRSBDashBoardViewHooks` 1881, `VCRSBCoverSheetWindowHooks` 1892, `VCRSBNotificationCenterWindowHooks` 1903, `VCRUIVisualEffectViewHooks` 1914, `VCRMTMaterialViewHooks` 1940) + 헬퍼 17개(`VCRNC*`, 1371~1688) + `%init` 블록(2181~2187) |
| 경로 하드코딩 | `Tweak.xm:493` `@"/var/jb/var/mobile/Documents/VolumeChordRecorder"` · `Preferences/VCRRootListController.mm:543` PATH에 `/var/jb/usr/bin:/private/preboot/jb/...` · 같은 파일 571~573, 600~601 sbreload/killall 절대경로 목록 |
| `jbroot()` | **사용 안 함** (0회). `roothide.h` include 0회 |
| 버전 가드 | `@available` 0회, `__IPHONE_OS_VERSION` 0회, `respondsToSelector` 0회, `objc_getClass` 12회 |
| 기기 | iPhone 14 Pro Max(16.4.1, `100.90.218.125`) roothide — 정상, 최신 빌드 설치·로드 확인됨 / iphone-12(16.1.x, `100.121.201.19`) — **애플 로고 루프, Tailscale offline**. SpringBoard 전용 트윅은 이 증상을 만들 수 없다(계층이 다름) → **이 플랜의 범위 밖** |

### 이 플랜을 정당화하는 결정적 발견 3개

1. **문서와 소스가 다르다.** `README_KR.md`는 "부팅/리스프링 루프 방지를 위해 NC transparency / live passthrough / CoverSheet·Poster·Wallpaper·`UIView` 전역 훅을 전부 제거한 안전 빌드"라고 선언하는데, 소스에는 그 훅 10그룹 + 헬퍼 17개가 그대로 있고 `%init`까지 된다. 즉 **지금 빌드되는 deb은 README가 "문제가 있던 빌드"라고 부른 구성 그대로**다. (프리퍼런스 기본값이 꺼짐이라 평상시 비용은 없지만, 설정에서 켜면 그 경로가 되살아난다.)
2. **rootHide 경로 규칙을 안 지킨다.** 공식 문서(`roothide/Developer`)에 따르면 rootHide의 부트스트랩은 매 탈옥마다 **랜덤 이름 jbroot**를 쓰고, 부트스트랩 도구는 **jbroot 기준 경로만** 받는다. 그런데 이 트윅의 "Respring" 기능은 `/var/jb/...`와 `/private/preboot/jb/...`를 하드코딩해 찾는다 → rootHide에서 **전부 missing** → 기능이 안 먹는다. 공식 해법은 `jbroot()` API(roothide/rootless/rootful 모두 컴파일 호환, rootful·rootless에선 빈 스텁).
3. **한 스킴만 배포한다.** Dopamine2는 rootless, rootHide Bootstrap은 roothide다. CI는 roothide만 만든다 → rootless 사용자는 설치 불가.

### 전제 / 가정

- 툴체인은 **roothide/theos** 공식 설치 스크립트 사용(CI가 이미 그렇게 한다). 로컬은 WSL에서 `scripts/build_deb_wsl.sh`(SCHEME 환경변수 지원) 사용.
- Windows 쪽 Python: `C:/Users/server/AppData/Local/Programs/Python/Python314/python.exe`. 셸은 git-bash(POSIX 문법).
- 기기 SSH: 사용자 `mobile`, 비밀번호는 **오직 환경변수 `SSHPASS`에서만** 읽는다(literal 금지). iOS 특이점: root 명령은 `sudo -S -p '' sh -c ...` + stdin으로 비밀번호, `/private/var/...`가 실제 경로.
- 기기는 화면이 꺼지면 Tailscale/SSH가 끊긴다(설치 직후 respring 뒤 잠들면 수 분 뒤 복귀). **기기 검증은 "기기가 깨어 있을 때"만 가능**하다는 전제로 태스크를 쪼갰다.
- Telegram 봇 토큰/챗 ID는 CI 시크릿에만 있다(값 비노출).
- iOS 15.x / 17.x 실기기는 아직 확보되지 않았다 → 태스크 T4.2/T7.3에서 기기 목록을 확정한다(추측 금지).

---

## Architecture / proposed approach

소스는 하나로 유지하고 **스킴은 빌드 파라미터**(roothide/rootless)로만 분기한다. 코드에서 탈옥 경로를 만드는 모든 지점은 공식 `jbroot()` API로 통과시켜(컴파일 시 rootless/rootful에선 스텁) 두 스킴이 같은 소스로 성립하게 한다. 안정성은 기능 추가가 아니라 **훅 표면 축소**(README가 선언한 SafeNoNC로 소스를 되돌림)로 얻고, 모든 변경은 `scripts/vcr_check.py`에 불변식 검사로 먼저 실패시킨 뒤 구현한다(하네스가 실행 가능한 스펙). 배포는 CI가 두 스킴 deb을 만들어 artifact+Telegram으로 내보내고, 기기에는 `scripts/vcr_device.py`(이 플랜에서 저장소로 vendor)로 `dpkg -i` 후 prefs 스탬프/스티키 카운터를 읽어 판정한다.

---

## Ground rules (위반 금지)

1. **추측 금지 — 훅 대상은 기기에서 확인한다.** 없는 클래스를 `%hook` 하면 로드 시 크래시한다. 모든 훅 클래스는 실측(`VCRDumpVolumeAPI` 덤프 또는 `objc_getClass` 가드)으로만 추가하고, `scripts/hook_allowlist.txt`에 등재한다.
2. **비밀번호 literal 금지.** `SSHPASS` env에서만 읽고, 미설정이면 명확히 실패한다. 커밋되는 파일에 어떤 자격증명도 넣지 않는다.
3. **`dpkg --purge` 금지.** 비활성화/제거는 파일 이동으로 한다.
4. **모든 변경은 검사와 함께.** 각 태스크는 `scripts/vcr_check.py`에 **먼저 실패하는 검사**를 추가하고, 구현 후 `OK: N checks, 0 failed`를 확인한다.
5. **1 태스크 = 1 커밋.** 커밋 메시지는 영어 명령형. push 전 `python scripts/vcr_check.py` 통과가 조건.
6. **문서-소스 드리프트 금지.** `docs/COMPAT.md`와 하네스가 소스의 실제 훅 목록을 강제한다(발견 #1의 재발 방지).

---

## Step-by-step tasks

### Phase 0 — 베이스라인과 도구 (선행 필수)

#### T0.1 베이스라인 기록
- 파일: 없음(읽기만). 커밋: 없음.
- 명령과 기대 출력:
```bash
cd "C:/Users/server/Desktop/VolumeChordRecorder_roothide_src/Tweaks"
git log --oneline -1                 # 4218433 Never swallow the original implementation in a hook
python scripts/vcr_check.py | tail -3 # OK: 93 checks, 0 failed
git status --porcelain                # (빈 출력)
```
- 이 값을 `docs/BASELINE.md`에 표로 적고 커밋한다(T6.1에서 확장).

#### T0.2 기기 헬퍼를 저장소로 vendor
- 파일(신규): `scripts/vcr_device.py`
- 이유: 지금은 스크래치 디렉터리에만 있는 헬퍼(24시간 뒤 pruning)에 의존한다. 배포/검증은 저장소 안 도구로 해야 재현된다.
- 전체 내용(그대로 저장; **비밀번호 fallback literal 절대 넣지 말 것**):
```python
#!/usr/bin/env python3
"""Device access for the jailbroken iPhones (rootHide / Dopamine rootless).

Rules encoded here (see the roothide-tweak-surgery skill):
 - the password only ever comes from the SSHPASS environment variable, never a literal
 - root commands go through `sudo -S -p '' sh -c ...` with the password on stdin (iOS sudo quirk)
 - SFTP is the authoritative view: shell path resolution differs per mount namespace

Usage:
  SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 sh "dpkg -l | grep volumechord"
  SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 --root sh "dpkg -i /var/mobile/Documents/x.deb"
  SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 put ./packages/x.deb /var/mobile/Documents/x.deb
  SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 get /private/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist ./prefs.plist
"""
import argparse, os, shlex, sys

try:
    import paramiko
except ImportError:
    sys.exit("paramiko is required: python -m pip install paramiko")

PASSWORD = os.environ.get("SSHPASS")
if not PASSWORD:
    sys.exit("SSHPASS is not set. Export it first (the value is never written to disk or to this file).")


def connect(host, user="mobile", timeout=25):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=PASSWORD, timeout=timeout,
              look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd, timeout=300, root=False):
    if root:
        cmd = "sudo -S -p '' sh -c " + shlex.quote(cmd)
    _in, out, err = c.exec_command(cmd, timeout=timeout)
    if root:
        _in.write(PASSWORD + "\n")
        _in.flush()
    return (out.read() + err.read()).decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", default="mobile")
    ap.add_argument("--root", action="store_true")
    ap.add_argument("--timeout", type=int, default=300)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_sh = sub.add_parser("sh"); p_sh.add_argument("command")
    p_put = sub.add_parser("put"); p_put.add_argument("local"); p_put.add_argument("remote")
    p_get = sub.add_parser("get"); p_get.add_argument("remote"); p_get.add_argument("local")
    a = ap.parse_args()

    c = connect(a.host, a.user)
    try:
        if a.cmd == "sh":
            print(run(c, a.command, timeout=a.timeout, root=a.root))
        else:
            s = c.open_sftp()
            try:
                if a.cmd == "put":
                    s.put(a.local, a.remote); print("uploaded %d bytes -> %s" % (os.path.getsize(a.local), a.remote))
                else:
                    s.get(a.remote, a.local); print("downloaded %s -> %d bytes" % (a.remote, os.path.getsize(a.local)))
            finally:
                s.close()
    finally:
        c.close()


if __name__ == "__main__":
    main()
```
- 검사 추가(`scripts/vcr_check.py`, `# --- 6. packaging ---` 앵커 **앞**):
```python
# --- 5e. the device helper must not carry credentials ---
_dev = open(os.path.join(ROOT, "scripts/vcr_device.py"), encoding="utf-8").read()
check("the device helper reads the password from the environment only",
      'os.environ.get("SSHPASS")' in _dev and "python -m pip install paramiko" in _dev)
check("the device helper contains no password literal",
      not re.search(r'PASSWORD\s*=\s*[^o]', _dev) and "or \"1\"" not in _dev)
```
- 검증:
```bash
python scripts/vcr_check.py | tail -2      # OK: 95 checks, 0 failed
SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 sh "uname -a"
# 기대: Darwin iPhone-14-Pro-Max ... arm64  (기기가 잠들어 있으면 TimeoutError → 화면을 깨우고 재시도)
```
- 커밋: `Vendor the device helper with env-only credentials`

#### T0.3 정적 게이트를 CI에 연결
- 파일: `.github/workflows/build.yml` (T3.3에서 전체 교체하지만, 이 단계에서는 스텝만 먼저 추가)
- 삽입 위치: `Checkout` 스텝 **다음**, apt 설치 **앞**:
```yaml
      - name: Static gate (vcr_check)
        run: python3 scripts/vcr_check.py
```
- 검증: push 후 `gh run view <id> --json conclusion -q .conclusion` → `success`. 로컬에서 CI 로그에 `OK: 95 checks, 0 failed`가 찍히는지 `gh run view <id> --log | grep -m1 "checks,"`.
- 커밋: `Run the static gate before building in CI`

---

### Phase 1 — SafeNoNC: 소스를 README가 선언한 상태로 되돌린다 (최대 안정성 레버)

#### T1.1 실패 검사를 먼저 쓴다
- 파일: `scripts/vcr_check.py` (`# --- 6. packaging ---` 앞)
```python
# --- 5f. SafeNoNC: no Notification Center / UI-wide hook may ship ---
# README_KR.md declares this build "SafeNoNC": the NC transparency / live passthrough hook surface was
# removed because it caused boot and respring loops. The source drifted back into shipping it.
_nc_lines = [n for n, ln in enumerate(T.split("\n"), 1)
             if re.search(r"VCRNC|CSCoverSheet|MTMaterialView|UIVisualEffectView|SBDashBoard|SBNotificationCenter", ln)]
check("the SafeNoNC build ships no Notification Center / UI-wide hooks",
      not _nc_lines, "still present on lines: %s" % _nc_lines[:12])
```
- 검증(실패 확인):
```bash
python scripts/vcr_check.py 2>&1 | grep -E "SafeNoNC|checks,"
# 기대: FAIL the SafeNoNC build ships no Notification Center / UI-wide hooks
#       FAILED: 96 checks, 1 failed
#       (detail: still present on lines: [1371, 1375, ...])
```
- 커밋: `Add the SafeNoNC invariant check (fails)`

#### T1.2 Tweak.xm에서 NC 훅 그룹 10개와 헬퍼 17개를 제거
- 파일: `Tweak.xm`
- 삭제 대상(정확히 이 심볼들만; 다른 기능은 손대지 않는다):
  - `%group` 블록 10개: `VCRCSCoverSheetViewControllerHooks`, `VCRSBDashBoardViewControllerHooks`, `VCRSBNotificationCenterViewControllerHooks`, `VCRNCNotificationListViewControllerHooks`, `VCRCSCoverSheetViewHooks`, `VCRSBDashBoardViewHooks`, `VCRSBCoverSheetWindowHooks`, `VCRSBNotificationCenterWindowHooks`, `VCRUIVisualEffectViewHooks`, `VCRMTMaterialViewHooks`
  - static 헬퍼 17개: `VCRNCNameContains`, `VCRNCNameContainsAny`, `VCRNCSetBackgroundAlpha`, `VCRNCLooksLikeLargeBackgroundImage`, `VCRNCClassLooksLikeContext`, `VCRNCWindowLooksLikeContext`, `VCRNCViewIsProtectedContent`, `VCRNCViewIsInsideContext`, `VCRNCShouldSkipSubview`, `VCRNCApplyRecursive`, `VCRNCApplyToContainer`, `VCRNCFindAndApplyInView`, `VCRNCApplyToAllKnownWindows`, `VCRNCSchedulePass`, `VCRNCScheduleBurst`, `VCRNCApplyToContainerAndBurst`, `VCRNCApplyToMaterialView`
  - `%init` 라인: `%init(VCRUIVisualEffectViewHooks);` + 9개 가드 `%init` 라인(`objc_getClass("CSCoverSheetViewController")` 등)
  - 호출 지점 2곳: `prefschanged` 핸들러 안의 `VCRNCApplyToAllKnownWindows();` 와 `applyNCTransparency` notify 등록 블록(`notify_register_dispatch("com.yourname.volumechordrecorder.applyNCTransparency", ...)`) 전체
- 사용 금지: 일괄 정규식 삭제(주변 코드 훼손 위험). 블록 단위로 지운다.
- 검증:
```bash
grep -c "VCRNC\|CSCoverSheet\|MTMaterialView\|UIVisualEffectView\|SBDashBoard\|SBNotificationCenter" Tweak.xm
# 기대: 0
python scripts/vcr_check.py | tail -2      # OK: 96 checks, 0 failed
python scripts/vcr_check.py 2>&1 | grep -c "^FAIL"   # 기대: 0
```
- 커밋: `Remove the Notification Center hook surface (SafeNoNC, as README already claimed)`

#### T1.3 설정 UI에서 NC 항목 제거
- 파일: `Preferences/Resources/Root.plist`, `Preferences/VCRRootListController.mm`
- Root.plist에서 NC 관련 셀(키 이름이 `nc`/`NC`/`Transparency`/`Passthrough` 계열) 전부 제거. VCRRootListController.mm에서 그 키를 읽거나 핸들러를 다는 코드 제거.
- 검사 추가(`scripts/vcr_check.py`):
```python
check("the preferences UI no longer exposes the removed NC options",
      not any(re.search(r"ncEnabled|NCTransparency|nclog|Passthrough", str(c)) for c in CELLS))
```
- 검증:
```bash
python scripts/vcr_check.py | tail -2      # OK: 97 checks, 0 failed
grep -rn "Passthrough\|NCTransparency" Preferences/ | wc -l   # 기대: 0
```
- 커밋: `Drop the removed NC options from the preferences UI`
- **결정 기록**: NC 기능을 되살리려면 git history에서 복원해 **기본 OFF + 실험 플래그 + 별도 브랜치**로만 다룬다(이 플랜 범위 밖, YAGNI).

---

### Phase 2 — 스킴 호환 경로 (공식 `jbroot()` API)

#### T2.1 `jbroot()` 도입 — Tweak.xm
- 파일: `Tweak.xm`
- (a) 상단 `#import`/`#include` 블록(파일 첫 20줄 안)에 추가:
```objc
#include <roothide.h>   // jbroot(): resolves the random jbroot on rootHide, empty stub on rootless/rootful
```
- (b) 493행 후보 경로 교체:
```objc
// 이전: @"/var/jb/var/mobile/Documents/VolumeChordRecorder",
[jbroot(@"/var/mobile/Documents/VolumeChordRecorder") copy],   // rootHide 실제 경로, rootless에선 스텁
```
- (c) 스킴 호환 검사 추가:
```python
# --- 5g. jailbreak paths must go through the official roothide API ---
_prefix_hits = [(p, n) for p in ("Tweak.xm", "Preferences/VCRRootListController.mm")
                for n, ln in enumerate(open(os.path.join(ROOT, p), encoding="utf-8").read().split("\n"), 1)
                if re.search(r"/var/jb|/private/preboot", ln) and "jbroot(" not in ln]
check("no hardcoded jailbreak prefix (rootHide randomises the jbroot)",
      not _prefix_hits, repr(_prefix_hits[:8]))
check("jailbreak paths are resolved through the official jbroot() API",
      has('#include <roothide.h>') and 'jbroot(@"/var/mobile/Documents/VolumeChordRecorder")' in T)
```
- 검증:
```bash
python scripts/vcr_check.py 2>&1 | grep -E "hardcoded|jbroot|checks,"
# 기대(중간): FAIL no hardcoded jailbreak prefix (detail: [('Preferences/VCRRootListController.mm', 543), ...]) → T2.2 후 PASS
```
- 커밋: `Resolve jailbreak paths through the official jbroot() API (source half)`

#### T2.2 `jbroot()` 도입 — 설정 앱의 Respring (실제로 안 먹던 기능)
- 파일: `Preferences/VCRRootListController.mm`
- `VCRSpawnProgram`(539~551행)과 `vcrDoRespring`(557~624행)의 PATH/절대경로 목록을 아래로 교체(roothide `interface.md`의 `posix_spawn(jbroot(...))` 예제 패턴):
```objc
static int VCRRunTool(const char *jbrootPath, char * const argv[]) {
    // rootHide keeps the bootstrap in a randomly named jbroot, so /var/jb/... paths never exist
    // there. jbroot() resolves the live prefix (and compiles to a stub for rootless/rootful).
    const char *path = jbroot(jbrootPath);
    if (!VCRFileExists(path)) return ENOENT;
    pid_t pid = 0;
    int status = 0;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, NULL);
    if (rc != 0 || pid <= 0) return rc ?: -1;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : status;
}

- (void)vcrDoRespring {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *attempts = [NSMutableString string];
        char * const sbreloadArgs[] = {(char *)"sbreload", NULL};
        char * const killallArgs[] = {(char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL};

        int rc = VCRRunTool("/usr/bin/sbreload", sbreloadArgs);
        [attempts appendFormat:@"jbroot(/usr/bin/sbreload): %d\n", rc];
        if (rc == 0) return;

        rc = VCRRunTool("/usr/bin/killall", killallArgs);
        [attempts appendFormat:@"jbroot(/usr/bin/killall): %d\n", rc];
        if (rc == 0) return;

        notify_post("com.apple.springboard.restart");
        [attempts appendString:@"posted com.apple.springboard.restart\n"];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = [NSString stringWithFormat:@"Respring command failed. Last status: %d\n\nAttempts:\n%@\nTry running sbreload manually from NewTerm/SSH.", rc, attempts];
            UIAlertController *failed = [UIAlertController alertControllerWithTitle:@"Respring Failed"
                                                                            message:message
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [failed addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:failed animated:YES completion:nil];
        });
    });
}
```
- `VCRSpawnProgram`/`VCRSpawnCommand` 중 더 이상 안 쓰는 것은 삭제(Dead code 금지), 남는 참조가 있으면 그 호출부도 `VCRRunTool`로 바꾼다.
- 검증:
```bash
grep -n "VCRSpawnProgram\|/private/preboot\|/var/jb" Preferences/VCRRootListController.mm | wc -l   # 기대: 0
python scripts/vcr_check.py | tail -2      # OK: 99 checks, 0 failed
```
- 커밋: `Fix the settings Respring button on rootHide with jbroot()`

#### T2.3 패키지에 그대로 실렸는지 확인(로컬 빌드)
- 명령(WSL):
```bash
cd /mnt/c/Users/server/Desktop/VolumeChordRecorder_roothide_src/Tweaks
SCHEME=roothide bash scripts/build_deb_wsl.sh
cd packages && dpkg-deb -f *.deb Package Version Architecture Depends
dpkg-deb -e *.deb /tmp/ctl && cat /tmp/ctl/postinst
dpkg-deb -x *.deb /tmp/payload && strings /tmp/payload/usr/lib/TweakInject/VolumeChordRecorder.dylib 2>/dev/null | grep -m2 "jbroot"
ls -la /tmp/payload/usr/lib/TweakInject/ /tmp/payload/Library/PreferenceBundles/ 2>/dev/null
```
- 기대: `dpkg-deb -f`가 실제 값을 출력한다(이 플랜은 값을 단정하지 않는다 — **출력값을 `docs/COMPAT.md` 매트릭스에 그대로 기록**한다). Preferences 바이너리에도 `jbroot` 심볼이 있어야 한다(`nm -u /tmp/payload/Library/PreferenceBundles/VolumeChordRecorderPrefs.bundle/VolumeChordRecorderPrefs | grep -i jbroot` → 있으면 rootHide 해석이 동작).
- 커밋: 없음(검증만). 결과는 T6.1 문서에 반영.

---

### Phase 3 — 패키징: 두 스킴을 CI가 만들고, postinst/의존성을 정리

#### T3.1 control 정리
- 파일: `control`
```
Depends: mobilesubstrate
```
(제거: `preferenceloader` — PreferenceLoader plist을 직접 동봉하므로 하드 의존이 불필요하고, 일부 환경에서 설치를 막는다. 남기려면 `Recommends:`로.)
- 검사 추가:
```python
check("preferenceloader is not a hard dependency (it blocks installs where it is absent)",
      "preferenceloader" not in open(os.path.join(ROOT, "control"), encoding="utf-8").read().split("Depends:")[1].split("\n")[0])
```
- 검증: `python scripts/vcr_check.py | tail -2` → `OK: 100 checks, 0 failed`
- 커밋: `Do not hard-depend on preferenceloader`

#### T3.2 postinst를 스킴 안전하게
- 파일: `layout/DEBIAN/postinst`
- 문제: `rm -f /Library/PreferenceLoader/Preferences/VolumeChordRecorder.plist`는 rootfs 경로다(rootHide에선 jbroot 상대, rootless에선 `/var/jb/Library/...`). 스킴마다 다른 경로를 스크립트가 알 수 없으므로 **정리 대상 자체를 없앤다**.
- 새 내용(전체):
```sh
#!/bin/sh
# The legacy PreferenceLoader entry this used to delete is not shipped any more, and the script runs
# with a different root per packaging scheme (rootfs / /var/jb / random jbroot), so path guessing is
# removed. Respringing is handled by theos via INSTALL_TARGET_PROCESSES (see Makefile).
exit 0
```
- 검증(패키징 후): `dpkg-deb -e packages/*.deb /tmp/ctl && cat /tmp/ctl/postinst` → 위 내용. 그리고 `dpkg-deb -e`의 다른 파일(`postrm` 등)도 그대로인지 확인.
- 커밋: `Make the postinst scheme-neutral and rely on INSTALL_TARGET_PROCESSES`

#### T3.3 CI를 2스킴 매트릭스로 교체
- 파일: `.github/workflows/build.yml` (전체 교체), 그리고 `scripts/build_github_actions_with_telegram.yml`을 **동일 내용으로 동기화**
```yaml
name: Build VolumeChordRecorder debs (roothide + rootless)

on:
  workflow_dispatch:
  push:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        scheme: [ roothide, rootless ]
    steps:
      - uses: actions/checkout@v4

      - name: Static gate (vcr_check)
        run: python3 scripts/vcr_check.py

      - name: Install apt dependencies
        run: |
          sudo apt update
          sudo apt install -y build-essential clang git perl python3 fakeroot dpkg-dev \
            xz-utils libplist-utils curl ca-certificates make

      - name: Install RootHide Theos
        run: |
          bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
          echo "THEOS=$HOME/theos" >> "$GITHUB_ENV"
          echo "$HOME/theos/bin" >> "$GITHUB_PATH"

      - name: Verify RootHide Theos
        run: |
          echo "THEOS=$THEOS"
          test -e "$THEOS/vendor/mod/roothide"

      - name: Ensure iPhoneOS SDK
        run: |
          if ls "$THEOS/sdks"/iPhoneOS*.sdk >/dev/null 2>&1; then ls -la "$THEOS/sdks"; else "$THEOS/bin/install-sdk" latest || true; ls -la "$THEOS/sdks"; fi

      - name: Build ${{ matrix.scheme }} package
        run: |
          make clean
          make package THEOS_PACKAGE_SCHEME=${{ matrix.scheme }} FINALPACKAGE=1
          ls -la packages

      - name: Report control + postinst (evidence for docs/COMPAT.md)
        run: |
          DEB="$(ls -1 packages/*.deb | head -n 1)"
          dpkg-deb -f "$DEB" Package Version Architecture Depends
          rm -rf /tmp/ctl && dpkg-deb -e "$DEB" /tmp/ctl && ls -la /tmp/ctl && cat /tmp/ctl/postinst 2>/dev/null || true

      - name: Upload ${{ matrix.scheme }} deb
        uses: actions/upload-artifact@v4
        with:
          name: VolumeChordRecorder-${{ matrix.scheme }}-deb
          path: packages/*.deb

  telegram:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: debs
      - name: Send debs to Telegram
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          set -euo pipefail
          if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
            echo "Telegram secrets are not set. Skipping."; exit 0
          fi
          for f in $(find debs -name '*.deb' | sort); do
            curl -fS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
              -F "chat_id=${TELEGRAM_CHAT_ID}" \
              -F "caption=VolumeChordRecorder $(basename "$f") - ${GITHUB_REPOSITORY}@${GITHUB_SHA::7}" \
              -F "document=@${f}"
          done
```
- 드리프트 검사 추가:
```python
check("the workflow copy in scripts/ matches the live workflow",
      open(os.path.join(ROOT, "scripts/build_github_actions_with_telegram.yml"), encoding="utf-8").read()
      == open(os.path.join(ROOT, ".github/workflows/build.yml"), encoding="utf-8").read())
```
- 검증:
```bash
cp .github/workflows/build.yml scripts/build_github_actions_with_telegram.yml
python scripts/vcr_check.py | tail -2        # OK: 101 checks, 0 failed
git add -A && git commit -m "Build and publish both packaging schemes from CI" && git push
RID=$(gh run list --limit 1 --json databaseId -q '.[0].databaseId'); gh run watch $RID
gh run view $RID --json conclusion -q .conclusion         # success
gh run download $RID -D /tmp/art && find /tmp/art -name '*.deb'
# 기대: roothide 1개 + rootless 1개, 파일명 접미사가 스킴별로 다름(예: ..._iphoneos-arm64e.deb / ..._iphoneos-arm64.deb)
```
- 커밋: 위 push에 포함.

#### T3.4 두 deb의 메타데이터를 실측해 매트릭스에 기록
- 명령(로컬, 다운로드 후):
```bash
for d in /tmp/art/*/*.deb; do echo "== $d"; dpkg-deb -f "$d" Package Version Architecture Depends; done
```
- 기대: 두 스킴의 `Architecture`/파일명을 **그대로** `docs/COMPAT.md`에 적는다(추측 금지). 만약 rootless 빌드가 `iphoneos-arm64e`로 나오고 A11(arm64) 기기 설치를 막으면, 그때만 `ARCHS=arm64` 단독 빌드를 추가한다(그 판단의 근거: 실제 기기에서 `dpkg -i` 실패 메시지).

---

### Phase 4 — iOS 15~17 런타임 호환

#### T4.1 훅 allowlist와 가드 강제
- 파일(신규): `scripts/hook_allowlist.txt`
```
# One class per line. A class may only be hooked if it was observed on a real device build
# (VCRDumpVolumeAPI dump or objc_getClass) - hooking an invented name crashes at load.
SBSensorActivityDataProvider
SpringBoard
SBVolumeHardwareButtonActions
SBVolumeControl
```
- 검사(T1.2의 `_hook_blocks` 재사용, 그 블록 **뒤**에 배치):
```python
_allow = set(l.split("#")[0].strip() for l in
             open(os.path.join(ROOT, "scripts/hook_allowlist.txt"), encoding="utf-8").read().split("\n"))
_hooked = set(c for c, s, e, b in _hook_blocks)
check("every hooked class is listed in scripts/hook_allowlist.txt", _hooked <= _allow,
      "missing: %s" % sorted(_hooked - _allow))
```
- 검증: `python scripts/vcr_check.py | tail -2` → `OK: 102 checks, 0 failed`
- 커밋: `Pin the hooked class set to a device-verified allowlist`

#### T4.2 기기별 훅 대상 실측(iOS 15/16/17)
- 목적: `SBVolumeHardwareButtonActions`, `SBVolumeControl`, `SBSensorActivityDataProvider`가 iOS 15/17에 존재하는지 **덤프로** 확인(없으면 폴백 경로만 남는다).
- 명령(각 기기에서):
```bash
SSHPASS=... python scripts/vcr_device.py --host <HOST> --root sh \
  "ls /usr/lib/TweakInject/VolumeChordRecorder.dylib && dpkg -l | grep volumechord"
SSHPASS=... python scripts/vcr_device.py --host <HOST> get \
  /private/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist ./prefs_<HOST>.plist
python -c "import plistlib;d=plistlib.load(open('prefs_<HOST>.plist','rb'));print({k:d.get(k) for k in ('debugLastLoadTime','debugLastLoadBundle','debugVolumeSelectors','debugPressTypes')})"
```
- 또한 기기에서 직접 클래스 존재 확인이 필요하면 **덤프를 다시 돌린다**(트윅이 `%ctor`에서 백그라운드로 실행하고 링에 `volume API dump: %d classes`를 남긴다). 트윅을 재설치(respring)하면 새 덤프가 남는다:
```bash
SSHPASS=... python scripts/vcr_device.py --host <HOST> --root sh "killall -9 SpringBoard"
sleep 45
SSHPASS=... python scripts/vcr_device.py --host <HOST> get /private/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist ./p.plist
python -c "import plistlib;d=plistlib.load(open('p.plist','rb'));print([l for l in d.get('debugEvents','').split(chr(10)) if 'volume API dump' in l])"
# 기대: ["... volume API dump: 87 classes"] (값은 OS마다 다르다 - 그 값을 그대로 기록)
```
  판정 기준은 두 가지다: (a) 위 덤프 라인이 그 OS에서 몇 개 클래스를 봤는지, (b) `debugVolumeSelectors`에 `increaseVolumeIntent`/`decreaseVolumeIntent` 키가 실제로 생기는지 — 볼륨을 한 번 누른 뒤
- 결과를 `docs/COMPAT.md`의 매트릭스에 기기별로 기록. **T4.1의 allowlist를 결과에 맞게 갱신**(없는 클래스는 제거 + `%init` 가드 유지).
- 커밋: `Record the device-verified hook target set per OS`

#### T4.3 버전 게이트 헬퍼 + minos 정렬
- 파일: `Tweak.xm`, `Preferences/VCRRootListController.mm`
- 추가(공용 위치: `Tweak.xm`의 `VCRLog` 정의 근처, MM에는 로컬 사본):
```objc
// Private SpringBoard internals drift between iOS builds. Never assume a selector exists: ask.
static BOOL VCROSAtLeast(double major, double minor) {
    static double v = 0.0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ v = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion + NSProcessInfo.processInfo.operatingSystemVersion.minorVersion / 10.0; });
    return v >= (major + minor / 10.0);
}
```
- 사용 규칙: iOS 버전에 따라 분기가 필요한 곳(예: 향후 `SBVolumeControl` 셀렉터 차이 대응)은 `VCROSAtLeast(...)` 또는 `[obj respondsToSelector:@selector(...)]`로 감싼다. **지금 당장 분기가 필요하지 않은 곳에 추측으로 넣지 않는다**(YAGNI) — T4.2에서 차이가 실측되면 그때 넣는다.
- minos: `Makefile`/`Preferences/Makefile`의 `TARGET = iphone:clang:latest:14.0`은 iOS 15~17을 이미 포함한다. **SDK 재현성**만 손본다:
```bash
# CI 로그에서 실제 SDK를 확인하고, 재현 가능하게 고정
gh run view <id> --log | grep -m3 "iPhoneOS.*sdk"
```
  그 후 `TARGET = iphone:clang:16.5:14.0`처럼 실재하는 SDK로 고정하고(없으면 `$THEOS/bin/install-sdk <ver>`), 빌드 후 minos를 실측 확인:
```bash
cd packages && dpkg-deb -x *.deb /tmp/p2 && otool -l /tmp/p2/usr/lib/TweakInject/VolumeChordRecorder.dylib | grep -A3 LC_BUILD_VERSION | head -8
# 기대: minos 14.0, sdk <고정값>
```
- 커밋: `Add an OS version helper and pin the SDK for reproducible builds`

---

### Phase 5 — 증상 기반 안정화 (실측 오라클 → 최소 수정)

#### T5.1 오라클 확립(문서화)
- 파일(신규): `docs/ORACLE.md`
- 내용: 진단 근거 3종과 읽는 방법 — (1) prefs 링 `debugEvents`(최근 14줄), (2) 스티키 카운터(`debugPressTypes`, `debugVolumeSelectors`, `debugChordCounts`, `debugOtherPresses`), (3) `tweak-crash.log`(신호 핸들러가 SIGSEGV/ABRT/BUS/ILL/TRAP 기록). 각각의 정확한 읽기 명령(위 T4.2 명령 재사용)과 "이 값이 나오면 무엇을 뜻하는가" 표.
- 검사:
```python
check("docs/ORACLE.md documents the three diagnostic oracles",
      os.path.exists(os.path.join(ROOT, "docs/ORACLE.md")))
```
- 검증: `python scripts/vcr_check.py | tail -2` → `OK: 103 checks, 0 failed`
- 커밋: `Document the on-device diagnostic oracles`

#### T5.2 옵션 변경 크래시 — `prefschanged` 핸들러 재진입/부하 축소
- 파일: `Tweak.xm` (`notify_register_dispatch("com.yourname.volumechordrecorder.prefschanged", ...)` 블록)
- 현재: 모든 옵션 변경마다 동기적으로 `VCRLoadPrefs()` + `VCRNCApplyToAllKnownWindows()` 실행(NC 호출은 T1.2에서 제거됨) → 남은 부하는 `VCRLoadPrefs()`뿐.
- 변경(디바운스 + 배경 큐 + 메인큐 반영):
```objc
// Settings posts this notification for every single switch flip. Coalesce bursts on a background
// queue so a fast series of toggles cannot block SpringBoard's main thread (a main thread that never
// comes back is what "changing an option crashes it" looks like on the device).
static int vcrPendingPrefsReload = 0;

static void VCRSchedulePrefsReload(void) {
    if (vcrPendingPrefsReload) return;
    vcrPendingPrefsReload = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        vcrPendingPrefsReload = 0;
        @try {
            VCRLoadPrefs();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!vcrEnabled && isRecording) VCRStopRecording();
                if (!vcrEnabled && vcrCameraRecording) VCRStopVideoRecording();
            });
        } @catch (NSException *exception) {
            VCRDebugEvent([NSString stringWithFormat:@"PREFS CHANGED CRASH %@: %@", exception.name, exception.reason]);
        }
    });
}
```
  그리고 notify 블록의 본문을 `@try { VCRDebugEvent(@"prefs changed -> reload"); VCRSchedulePrefsReload(); } @catch (...) {...}`로 교체.
- 검사:
```python
check("prefs reloads are coalesced and never run inline on the main thread",
      has("VCRSchedulePrefsReload") and order("static void VCRSchedulePrefsReload", "dispatch_get_global_queue"))
```
- 검증(기기): 설정에서 스위치를 연속 5회 빠르게 토글한 뒤
```bash
SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 sh \
  "launchctl list | awk '/com.apple.SpringBoard/{print \$1}'"      # 기대: PID 불변(크래시/리스프링 없음)
SSHPASS=... python scripts/vcr_device.py --host 100.90.218.125 get /private/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist ./p.plist
python -c "import plistlib;d=plistlib.load(open('p.plist','rb'));print(d.get('debugEvents','')[-300:]); print(d.get('debugLastLoadTime'))"
# 기대: 'prefs changed -> reload'가 여러 번, 'PREFS CHANGED CRASH' 0회
```
- 커밋: `Coalesce preference reloads off the main thread`

#### T5.3 기능 안 먹는 문제 인테이크(사용자 입력 필요 → 그 뒤 최소 수정)
- 남은 체크리스트: (a) 세 손가락 스와이프가 특정 앱에서 안 먹음, (b) 볼륨 코드가 안 먹음, (c) 촬영이 저장 안 됨, (d) Telegram 업로드 실패. 각 항목은 다음 템플릿으로 처리한다:
  1. 오라클 읽기(T5.1 명령) → 증상이 재현되는 정확한 링/카운터를 확보.
  2. 코드 불변식이면 검사로 먼저 고정(예: "the chosen recording directory is published before use").
  3. 최소 수정 + 검사 통과 + 기기 재검증.
  4. 커밋: `<symptom>: <one-line cause>`
- 이 태스크의 **선행 입력**: 사용자가 겪는 증상을 3개 이하로 특정해 알려줘야 한다(이 플랜 시점에 미확정).

---

### Phase 6 — 개발 가이드/프레임워크 리서치 → 저장소 문서

#### T6.1 공식 문서에서 규칙을 뽑아 `docs/COMPAT.md` 작성
- 소스(공식 우선; 블로그 의존 금지):
  - rootHide 공식: `https://github.com/roothide/Developer` — `README.md`(설치/스킴), `interface.md`(`jbroot`/`rootfs` API + posix_spawn 예제), `roothide.md`(random jbroot, `@loader_path/.jbroot/...` install_name, 부트스트랩 도구는 jbroot 경로만), `entitlements.md`(sandbox/파일 접근), `vroot.md`/`filemirror.md`
  - rootHide 부트스트랩 개발자 문서: `https://roothidebootstrap.com/develop/`
  - Theos 공식: `https://theos.dev/docs/packaging`, `https://theos.dev/docs/rootless` + **툴체인 실물**(문서보다 우선): `grep -rn "THEOS_PACKAGE_SCHEME\|INSTALL_TARGET_PROCESSES" $THEOS/makefiles | head -20`, `ls $THEOS/vendor/mod/roothide`
  - ElleKit(훅 엔진, `mobilesubstrate` 제공): `https://github.com/evelyneee/ElleKit`
  - Dopamine(버전/아키텍처 매트릭스 원본): `https://github.com/opa334/Dopamine` README
  - palera1n(iOS 17 rootless): `https://github.com/palera1n/palera1n`
- 파일(신규): `docs/COMPAT.md` — 아래 표를 **실측값으로** 채운다(이 플랜의 값을 복사하지 말고 T2.3/T3.4/T4.2에서 나온 출력을 넣는다):
```markdown
# Compatibility matrix (filled from real output, never from memory)

| Jailbreak | Scheme | iOS range | Arch in deb | Install path | Verified on |
|---|---|---|---|---|---|
| rootHide Bootstrap | roothide | 15.0-17? | (dpkg-deb -f 결과) | jbroot(random) | iPhone 14 Pro Max 16.4.1 |
| Dopamine 2 | rootless | 15.0-16.6.1 | (결과) | /var/jb | (실기기) |

## Hook inventory (must match the source; enforced by scripts/vcr_check.py)
| Class | Hooked selectors | Fallback if absent |
|---|---|---|
| SpringBoard | sendEvent:, pressesBegan:withEvent:, pressesEnded:withEvent: | none needed |
| SBVolumeHardwareButtonActions | volumeIncrease/DecreasePressDownWithModifiers:, ...PressUp | UIPress path |
| SBVolumeControl | increaseVolume, decreaseVolume | press path |
| SBSensorActivityDataProvider | _handleNewDomainData: (pass-through only) | n/a |

## Path rules used in this tweak
- Jailbreak paths: `jbroot()` (roothide.h) only. No `/var/jb` or `/private/preboot` literals.
- Captures: rootfs path chosen at runtime by VCRRecordingDirectory().
```
- 검사(문서-소스 드리프트 방지; `_hook_blocks` 재사용):
```python
_matrix = open(os.path.join(ROOT, "docs/COMPAT.md"), encoding="utf-8").read()
check("docs/COMPAT.md lists every hooked class", all(c in _matrix for c, s, e, b in _hook_blocks),
      "missing: %s" % [c for c, s, e, b in _hook_blocks if c not in _matrix])
```
- 검증: `python scripts/vcr_check.py | tail -2` → `OK: 105 checks, 0 failed`
- 커밋: `Add docs/COMPAT.md with the scheme/OS matrix and the hook inventory`

#### T6.2 README를 소스와 일치시킨다
- 파일: `README_KR.md`
- T1.2 이후 실제 기능 목록으로 갱신(제거된 NC 항목 삭제, 지원 스킴/기기 매트릭스는 `docs/COMPAT.md` 링크로 대체). **문서가 소스보다 앞서거나 뒤처지지 않게** 한다(발견 #1의 재발 방지).
- 검사:
```python
check("README does not advertise removed features",
      not re.search(r"Notification Center Transparency|Passthrough", open(os.path.join(ROOT, "README_KR.md"), encoding="utf-8").read().split("제거 기능")[-1]))
```
- 검증: `python scripts/vcr_check.py | tail -2` → `OK: 106 checks, 0 failed`
- 커밋: `Align README with the shipped feature set`

---

### Phase 7 — 검증과 배포

#### T7.1 전체 게이트(로컬)
```bash
cd "C:/Users/server/Desktop/VolumeChordRecorder_roothide_src/Tweaks"
python scripts/vcr_check.py            # 기대: OK: 106 checks, 0 failed
git status --porcelain                  # 기대: 빈 출력
```
#### T7.2 CI 배포
```bash
git push origin main
RID=$(gh run list --limit 1 --json databaseId -q '.[0].databaseId'); echo $RID
for i in $(seq 1 30); do S=$(gh run view $RID --json status,conclusion -q '.status+" "+.conclusion'); echo "$S"; case "$S" in completed*) break;; esac; sleep 20; done
gh run download $RID -D ./packages_ci && find ./packages_ci -name '*.deb'
```
- 기대: `completed success`, deb 2개(스킴별). 실패 시 `gh run view $RID --log-failed | tail -40`로 원인 확인 후 해당 태스크로 되돌아간다.

#### T7.3 기기 설치·기능 검증(기기가 깨어 있을 때만)
- 공통 절차(기기마다 반복):
```bash
HOST=100.90.218.125
DEB=$(ls ./packages_ci/*roothide*/*.deb | head -1)     # rootless 기기면 rootless deb
SSHPASS=... python scripts/vcr_device.py --host $HOST put "$DEB" /var/mobile/Documents/vcr.deb
SSHPASS=... python scripts/vcr_device.py --host $HOST --root sh "dpkg -i /var/mobile/Documents/vcr.deb" 2>&1 | tail -3
# 기대: 'Setting up com.yourname.volumechordrecorder (0.0.10)' (기기가 respring하며 SSH가 잠시 끊길 수 있음 → 화면 깨우고 5~10분 내 복귀 대기)
SSHPASS=... python scripts/vcr_device.py --host $HOST sh "dpkg -l | grep volumechord; ls -la /usr/lib/TweakInject/VolumeChordRecorder.dylib"
SSHPASS=... python scripts/vcr_device.py --host $HOST get /private/var/mobile/Library/Preferences/com.yourname.volumechordrecorder.plist ./p.plist
python -c "import plistlib;d=plistlib.load(open('p.plist','rb'));print(d.get('debugLastLoadTime'), d.get('debugLastLoadBundle'))"
# 기대: com.apple.springboard + 설치 직후 시각(= 트윅 로드 확인)
```
- 기능 체크리스트(각 항목 PASS/FAIL을 `docs/COMPAT.md`에 기기별로 기록):
  1. 설정 앱에 "Volume Chord Recorder" 진입점이 뜬다.
  2. 설정에서 **Respring** 버튼이 실제로 리스프링시킨다(rootHide에서 T2.2 수정 확인).
  3. 세 손가락 아래 스와이프로 녹음 시작/정지 + 햅틱.
  4. 볼륨 업→다운을 0.45초 안에 누르면 링에 `volbtn chord armed by paired presses (NNN ms apart)`, 유지 후 릴리스로 녹음 토글.
  5. 녹음 파일이 저장되고 설정의 목록에 뜨며 삭제 가능.
  6. 옵션 5연속 토글에도 SpringBoard PID 불변(T5.2).
  7. (해당 기기에서) `debugVolumeSelectors`에 `increaseVolumeIntent`가 생기면 `SBVolumeControl` 훅이 살아 있다는 증거.
- iOS 15.x / 17.x 기기: **먼저 기기 인벤토리 확정**(사용자에게 기기·OS 확인):
```bash
tailscale status | grep -i ios        # 후보: iphone-3, ipad-pro-105-inch 등
SSHPASS=... python scripts/vcr_device.py --host <HOST> sh "sw_vers 2>/dev/null; uname -a; df -h / | tail -1"
# 기대: ProductVersion 15.x / 17.x, 여유공간 확인
```
  확보되지 않으면 그 행은 `docs/COMPAT.md`에 `unverified`로 남긴다(추측 금지).

#### T7.4 롤백 준비
- 이전 동작 deb을 `packages_ci/prev/`에 보관. 문제 시 기기에서 파일 이동으로 비활성화:
```bash
SSHPASS=... python scripts/vcr_device.py --host $HOST --root sh \
  "mkdir -p /var/mobile/Documents/vcr-disabled && mv /usr/lib/TweakInject/VolumeChordRecorder.dylib /usr/lib/TweakInject/VolumeChordRecorder.plist /var/mobile/Documents/vcr-disabled/ && killall -9 SpringBoard"
```
(`dpkg --purge` 금지 — Ground rule 3.)

---

## Tests / validation

- **정적 하네스가 곧 테스트다.** 모든 태스크는 (1) `scripts/vcr_check.py`에 검사를 추가하고 (2) 실행해 실패를 확인한 뒤(정확한 `FAIL <검사명>` 라인) (3) 구현하고 (4) `OK: N checks, 0 failed`를 확인한다. TDD 사이클이 그대로 적용된다.
  ```bash
  python scripts/vcr_check.py            # 전체
  python scripts/vcr_check.py 2>&1 | grep "^FAIL"   # 실패 목록(성공 시 0줄)
  ```
- **회귀 방지용 신규 불변식(이 플랜이 추가하는 것)**: NC 훅 금지, 하드코딩된 탈옥 경로 금지, `jbroot()` 사용, 훅 클래스 allowlist, 워크플로 사본 동기화, README/COMPAT 문서가 소스와 일치, 자격증명 literal 금지, prefs 리로드가 메인스레드 인라인 금지, postinst 스킴 중립.
- **패키징 검증**: `dpkg-deb -f`(메타데이터) + `dpkg-deb -e`(postinst) + `dpkg-deb -x` + `otool -l`(minos) 를 실제 파일에 대해 실행하고 출력을 문서에 기록. **기대값을 단정하지 않고 실측값을 기록**한다.
- **기기 검증**: 로드 스탬프(`debugLastLoadTime`/`debugLastLoadBundle`) → 기능 체크리스트 → 스티키 카운터/링. 크래시는 `tweak-crash.log`와 SpringBoard PID 불변성으로 판정한다.
- 커밋 규율: 태스크당 1커밋, push 전 하네스 통과.

---

## Risks, tradeoffs, and open questions

1. **NC 기능 삭제는 기능 축소다(의도적).** 근거: 이 저장소의 `README_KR.md`가 이미 NC/전역 훅 제거를 "안전 빌드"로 선언했고, 실제 크래시/부팅 루프는 그 훅 표면이 있던 빌드에서 나왔다. **되살릴 경우** 기본 OFF + 실험 플래그 + 별도 브랜치로만. → 사용자 확인 필요(아래 Q1).
2. **Dopamine2/rootHide의 정확한 지원 범위를 이 플랜은 단정하지 않는다.** (Dopamine=rootless, rootHide Bootstrap=roothide, iOS 버전 경계는 저장소 문서 원본에서 확인 후 매트릭스에 기록.) iOS 17은 rootless 계열(palera1n)로 검증하는 것이 유일한 현실 경로이며, **실기기가 없으면 `unverified`로 남긴다.**
3. **아키텍처 태그 리스크.** roothide/rootless 스킴이 만들어내는 `Architecture` 값이 arm64 기기(A11/palera1n)에서 설치를 거부할 수 있다. 대응은 실측 실패 메시지를 근거로 `ARCHS=arm64` 단독 빌드 추가(추측으로 미리 만들지 않는다).
4. **기기 가용성.** iphone-12는 애플 로고 루프(이 트윅과 계층이 다른 문제)로 offline이고, iPhone 14 Pro Max는 화면이 꺼지면 Tailscale/SSH가 끊긴다. 기기 의존 태스크(T4.2, T5.2, T7.3)는 기기가 깨어 있을 때만 진행된다 → 나머지 태스크(T1~T3, T6)를 먼저 끝내는 순서가 강제된다.
5. **`jbroot()`가 정말 두 스킴에서 안전한가.** 공식 문서 근거(rootful/rootless 컴파일 시 빈 스텁)로 안전하다고 판단했지만, **실제 rootless 기기에서의 미검증**이다. T7.3에서 rootless 실기기 확인 전까지는 "문서 근거 있음"으로만 주장한다.
6. **postinst 정리가 기존 사용자에게 미치는 영향.** 이전 빌드가 남긴 `/Library/PreferenceLoader/Preferences/VolumeChordRecorder.plist`를 지우던 동작을 없앤다 → 중복 진입점이 남아 있는 기기가 있을 수 있다. 대응: T7.4 롤백 절차에 수동 삭제 한 줄을 문서로 남긴다.
7. **16.1.x 기기의 애플 로고 루프는 이 플랜의 범위 밖**이며, 이 트윅이 원인이라는 근거는 없다(SpringBoard 전용 Filter). 그 기기의 복구(탈옥 없이 부팅 → preboot 여유공간/부트스트랩 상태 확인)는 별도 작업으로 분리한다. 이 플랜은 트윅이 **부팅 사슬에 관여하지 않는다**는 성질(Filter=springboard 단독)을 유지하는 것만 보장한다.

### Open questions (구현 전에 답이 필요)

- **Q1**: NC transparency 기능을 정말 버릴 것인가? (권장: T1.2대로 제거. 되살리기는 별도 브랜치.)
- **Q2**: iOS 15.x / 17.x 실기기가 있는가? 있다면 host와 OS 버전을 알려주면 T4.2/T7.3에서 검증한다.
- **Q3**: 사용자가 겪는 "안 되는 기능/크래시"를 3개 이하로 특정해줄 수 있는가? (T5.3의 입력. 없으면 오라클 덤프를 함께 보고 결정한다.)
- **Q4**: 배포 채널은 CI artifact + Telegram으로 충분한가, 별도 repo/tap(Sileo repo)까지 원하는가? (YAGNI 기본값: artifact + Telegram.)
