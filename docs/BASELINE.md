# Baseline (recorded before the compatibility work)

Measured on 2026-10-09 at commit `4218433` on Windows (git-bash), Python `Python314`.

| Item | Value |
|---|---|
| `python scripts/vcr_check.py` | `OK: 93 checks, 0 failed` |
| HEAD | `4218433 Never swallow the original implementation in a hook` |
| Hook blocks / `%orig` calls | 14 / 40 (0 blocks swallow the original) |
| NC hook groups shipped | 10 groups (lines 1781-1940) + 17 `VCRNC*` helpers (1371-1688) |
| `jbroot()` usage | 0 |
| `@available` / `__IPHONE_OS_VERSION` guards | 0 / 0 |
| `objc_getClass` guards | 12 |
| Hardcoded jailbreak paths | `Tweak.xm:493`, `Preferences/VCRRootListController.mm:543,571-573,600-601` |
| Package archs / minos | `ARCHS = arm64 arm64e` / `TARGET = iphone:clang:latest:14.0` |
| CI schemes built | roothide only (`.github/workflows/build.yml`) |
| Devices | iPhone 14 Pro Max iOS 16.4.1 (`100.90.218.125`, roothide) reachable; iphone-12 iOS 16.1.x (`100.121.201.19`) offline (Apple-logo loop, out of scope) |

Baseline is only a starting point: every value above is expected to change, and the plan's checks
enforce the changes. Never copy a value out of this file into a spec - re-measure it.
