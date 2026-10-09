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
import argparse
import os
import shlex
import sys

try:
    import paramiko
except ImportError:
    sys.exit("paramiko is required: python -m pip install paramiko")

_PASSWORD = os.environ.get("SSHPASS")
if not _PASSWORD:
    sys.exit("SSHPASS is not set. Export it first (the value is never written to disk or to this file).")
PASSWORD = _PASSWORD  # str from here on (the guard above exits otherwise)


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
    p_sh = sub.add_parser("sh")
    p_sh.add_argument("command")
    p_put = sub.add_parser("put")
    p_put.add_argument("local")
    p_put.add_argument("remote")
    p_get = sub.add_parser("get")
    p_get.add_argument("remote")
    p_get.add_argument("local")
    a = ap.parse_args()

    c = connect(a.host, a.user)
    try:
        if a.cmd == "sh":
            print(run(c, a.command, timeout=a.timeout, root=a.root))
        else:
            s = c.open_sftp()
            try:
                if a.cmd == "put":
                    s.put(a.local, a.remote)
                    print("uploaded %d bytes -> %s" % (os.path.getsize(a.local), a.remote))
                else:
                    s.get(a.remote, a.local)
                    print("downloaded %s -> %d bytes" % (a.remote, os.path.getsize(a.local)))
            finally:
                s.close()
    finally:
        c.close()


if __name__ == "__main__":
    main()
