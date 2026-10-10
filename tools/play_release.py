#!/usr/bin/env python3
"""TxD xDrip — Play Console automation (Android Publisher API v3).

Usage:
  /usr/bin/python3 tools/play_release.py release [aab]   # upload (optional) + roll out to internal
  /usr/bin/python3 tools/play_release.py listing         # store listing text + icon/feature/screenshots
  /usr/bin/python3 tools/play_release.py status          # show internal track + testers

Reuses the Food Health publisher service account and the IPv4 pin from
fh-txd-android/android/play_upload.py (the upload host is unreachable over
IPv6 from the sandboxed shell).
"""
import json
import os
import socket
import sys

import requests
import urllib3.util.connection as uc

uc.allowed_gai_family = lambda: socket.AF_INET

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
_FOODLOG = os.path.abspath(os.path.join(_ROOT, "..", "foodlog-android", "android"))
sys.path.insert(0, _FOODLOG)
from play_oauth_token import get_access_token  # noqa: E402

PKG = "com.foodhealth.txd.xdrip"
SA = os.path.join(_FOODLOG, "foodlog-play-service-account.json")
BASE = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PKG}"
UPLOAD = f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PKG}"
LISTING_DIR = os.path.join(_ROOT, ".local", "listing")
DEFAULT_AAB = os.path.join(_ROOT, "app/build/outputs/bundle/prodRelease/app-prod-release.aab")

TITLE = "TxD xDrip"
SHORT = "Real-time Dexcom Stelo/G7 glucose into Health Connect for Food Health TxD."
FULL = (
    "TxD xDrip is a free companion to Food Health TxD. It gets readings from a Dexcom Stelo, G7 or "
    "ONE+ into Health Connect within minutes, instead of the hours the vendor app takes, so Food "
    "Health TxD can label meals, voice notes and face check-ins with your current glucose.\n\n"
    "A four-step setup does everything: allow Health Connect, connect to your sensor, and leave the "
    "app installed. The recommended mode keeps the Stelo app in charge and reads its readings; an "
    "advanced mode connects to the sensor directly over Bluetooth.\n\n"
    "Built on the open-source xDrip+ engine (GPL-3.0). The full xDrip+ interface is available "
    "behind the Advanced button.\n\n"
    "Experimental community software, not a medical device. Not for treatment decisions. Readings "
    "stay on your phone; nothing is uploaded."
)


def _check(r, what):
    if not r.ok:
        print(f"ERROR {what}: {r.status_code}\n{r.text}", file=sys.stderr)
        r.raise_for_status()
    return r


def _headers():
    return {"Authorization": f"Bearer {get_access_token(SA)}"}


def _edit(h):
    return _check(requests.post(f"{BASE}/edits", headers={**h, "Content-Type": "application/json"}, json={}, timeout=60), "create edit").json()["id"]


def _commit(h, eid):
    _check(requests.post(f"{BASE}/edits/{eid}:commit", headers=h, timeout=120), "commit")


def cmd_status():
    h = _headers()
    eid = _edit(h)
    bundles = _check(requests.get(f"{BASE}/edits/{eid}/bundles", headers=h, timeout=60), "bundles").json()
    print("bundles:", [b.get("versionCode") for b in bundles.get("bundles", [])])
    track = requests.get(f"{BASE}/edits/{eid}/tracks/internal", headers=h, timeout=60)
    print("internal track:", json.dumps(track.json(), indent=1)[:1200])
    testers = requests.get(f"{BASE}/edits/{eid}/testers/internal", headers=h, timeout=60)
    print("testers:", testers.status_code, testers.text[:400])
    requests.delete(f"{BASE}/edits/{eid}", headers=h, timeout=60)


def cmd_release(aab=None):
    h = _headers()
    eid = _edit(h)
    if aab:
        print(f"uploading {os.path.basename(aab)} …")
        with open(aab, "rb") as f:
            r = _check(requests.post(f"{UPLOAD}/edits/{eid}/bundles?uploadType=media",
                                     headers={**h, "Content-Type": "application/octet-stream"},
                                     data=f, timeout=1800), "upload bundle")
        vc = r.json()["versionCode"]
        print("uploaded versionCode:", vc)
        mapping = os.path.join(_ROOT, "app/build/outputs/mapping/prodRelease/mapping.txt")
        if os.path.exists(mapping):
            with open(mapping, "rb") as f:
                requests.post(f"{UPLOAD}/edits/{eid}/bundles/{vc}/deobfuscationFiles/proguard?uploadType=media",
                              headers={**h, "Content-Type": "application/octet-stream"}, data=f, timeout=600)
    else:
        bundles = _check(requests.get(f"{BASE}/edits/{eid}/bundles", headers=h, timeout=60), "bundles").json()
        vcs = [b["versionCode"] for b in bundles.get("bundles", [])]
        if not vcs:
            raise SystemExit("no bundles on the app yet")
        vc = max(vcs)
        print("using existing versionCode:", vc)
    body = {"track": "internal", "releases": [{
        "name": "1.0.0" if vc == 1 else str(vc),
        "versionCodes": [str(vc)],
        "status": "completed",
        "releaseNotes": [{"language": "en-US", "text": "Stelo / G7 → Health Connect bridge with setup wizard."}],
    }]}
    _check(requests.put(f"{BASE}/edits/{eid}/tracks/internal", headers={**h, "Content-Type": "application/json"}, json=body, timeout=60), "track update")
    _commit(h, eid)
    print(f"DONE: versionCode {vc} live on 'internal'.")


def cmd_listing():
    h = _headers()
    eid = _edit(h)
    _check(requests.put(f"{BASE}/edits/{eid}/listings/en-US", headers={**h, "Content-Type": "application/json"},
                        json={"language": "en-US", "title": TITLE, "shortDescription": SHORT, "fullDescription": FULL}, timeout=60), "listing")
    print("listing text set")
    images = [("icon", "icon-512.png"), ("featureGraphic", "feature-graphic-1024x500.png"),
              ("phoneScreenshots", "shot-2-health.png"), ("phoneScreenshots", "shot-3-connect.png"), ("phoneScreenshots", "shot-4-status.png")]
    cleared = set()
    for kind, name in images:
        path = os.path.join(LISTING_DIR, name)
        if not os.path.exists(path):
            print("skip missing", name); continue
        if kind not in cleared:
            requests.delete(f"{BASE}/edits/{eid}/listings/en-US/{kind}", headers=h, timeout=60)
            cleared.add(kind)
        with open(path, "rb") as f:
            _check(requests.post(f"{UPLOAD}/edits/{eid}/listings/en-US/{kind}?uploadType=media",
                                 headers={**h, "Content-Type": "image/png"}, data=f, timeout=300), f"upload {kind} {name}")
        print("uploaded", kind, name)
    _commit(h, eid)
    print("DONE: listing committed.")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        cmd_status()
    elif cmd == "release":
        cmd_release(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "listing":
        cmd_listing()
    else:
        raise SystemExit(__doc__)
