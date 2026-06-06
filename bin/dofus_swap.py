#!/usr/bin/env python3
"""Dofus auto turn-swap (Hyprland), template-matching variant.

Watches the on-screen "current actor" popup, hashes the name region with phash,
matches against per-character reference hashes captured via `learn`, then
focuses the matching window using the iterate_windows.sh / do.sh pattern:
    animations off -> batched (focuswindow title:... ; alterzorder top) -> animations on
Floating stacked windows need alterzorder; focuswindow alone won't raise.

Workflow:
    ./dofus_swap.py calibrate                    # slurp tight box around name pill
    ./dofus_swap.py learn Reminiscer             # while Reminiscer popup visible
    ./dofus_swap.py learn Sayer                  # repeat per char...
    ./dofus_swap.py run                          # detector
"""

import argparse, io, json, re, subprocess, sys, time
from pathlib import Path
import imagehash
from PIL import Image

CFG = Path.home() / ".config/dofus-swap.json"
POLL = 0.5
IDLE_POLL = 1.5  # slower tick when no Dofus window is focused
DOFUS_CLASS = "Dofus.x64"
TITLE_RE = re.compile(r"^Dofus\s+(.+)$")
RESCAN_S = 5.0
DEBOUNCE_S = 0.4
HASH_MAX = 10  # max phash hamming distance to accept match
MIN_BRIGHTNESS = 5.0  # below this avg, treat as popup-not-visible


def shot(region):
    geom = f"{region['left']},{region['top']} {region['width']}x{region['height']}"
    p = subprocess.run(["grim", "-g", geom, "-"], capture_output=True, check=True)
    return Image.open(io.BytesIO(p.stdout))


def avg_brightness(img):
    g = img.convert("L")
    px = g.tobytes()
    return sum(px) / len(px)


def phash(img):
    return imagehash.phash(img.convert("RGB"), hash_size=16)


def hyprctl_json(*args):
    out = subprocess.run(
        ["hyprctl", "-j", *args], capture_output=True, text=True
    ).stdout
    return json.loads(out)


def hyprctl_quiet(*args):
    subprocess.run(["hyprctl", "-q", *args], check=False)


def active_is_dofus():
    try:
        return hyprctl_json("activewindow").get("class") == DOFUS_CLASS
    except Exception:
        return False


def focus_title(title):
    hyprctl_quiet("eval", "hl.config({ animations = { enabled = false } })")
    subprocess.run(
        [
            "hyprctl",
            "-q",
            "eval",
            f"""
            hl.dispatch(hl.dsp.focus({{ window = [[title:^({title})$]] }}))
            hl.dispatch(hl.dsp.window.bring_to_top())
            """,
        ],
        check=False,
    )
    hyprctl_quiet("eval", "hl.config({ animations = { enabled = true } })")


def discover(filter_names=None):
    out = {}
    for c in hyprctl_json("clients"):
        if c.get("class") != DOFUS_CLASS:
            continue
        m = TITLE_RE.match(c.get("title", ""))
        if not m:
            continue
        short = m.group(1).strip().lower()
        if filter_names and short not in filter_names:
            continue
        out[short] = c["title"]
    return out


def pick_region():
    raw = subprocess.run(["slurp"], capture_output=True, text=True).stdout.strip()
    pos, dim = raw.split()
    x, y = map(int, pos.split(","))
    w, h = map(int, dim.split("x"))
    return {"left": x, "top": y, "width": w, "height": h}


def load_cfg():
    if not CFG.exists():
        return {}
    return json.loads(CFG.read_text())


def save_cfg(data):
    CFG.parent.mkdir(parents=True, exist_ok=True)
    CFG.write_text(json.dumps(data, indent=2))


def require_region(cfg):
    if "region" not in cfg:
        sys.exit(f"No region. Run: {sys.argv[0]} calibrate")
    return cfg["region"]


def cmd_calibrate(args):
    print("Drag rectangle TIGHTLY around just the name pill (e.g. just 'Reminiscer').")
    cfg = load_cfg()
    old = cfg.get("region")
    cfg["region"] = pick_region()
    save_cfg(cfg)
    print(f"Saved region={cfg['region']}")
    if old and old != cfg["region"] and cfg.get("hashes"):
        print(
            f"WARNING: region changed (was {old}). Existing hashes "
            f"({list(cfg['hashes'])}) are now stale — re-run "
            f"`{sys.argv[0]} learn <Name>` for every character."
        )


def cmd_learn(args):
    cfg = load_cfg()
    region = require_region(cfg)
    img = shot(region)
    bright = avg_brightness(img)
    if bright < MIN_BRIGHTNESS:
        sys.exit(f"Region looks dark (avg={bright:.1f}). Popup visible? Aborting.")
    h = str(phash(img))
    cfg.setdefault("hashes", {})[args.name.lower()] = h
    save_cfg(cfg)
    out = Path("/tmp/dofus-swap")
    out.mkdir(exist_ok=True)
    img.save(out / f"learn_{args.name.lower()}.png")
    print(f"Learned {args.name!r} -> hash={h} (avg={bright:.1f})")
    print(f"Sample saved: {out}/learn_{args.name.lower()}.png")


def cmd_learned(args):
    cfg = load_cfg()
    print(json.dumps(cfg.get("hashes", {}), indent=2))


def cmd_list(args):
    print(json.dumps(discover(), indent=2))


def cmd_inspect(args):
    cfg = load_cfg()
    region = require_region(cfg)
    out = Path("/tmp/dofus-swap")
    out.mkdir(exist_ok=True)
    img = shot(region)
    img.save(out / "inspect.png")
    bright = avg_brightness(img)
    h = phash(img)
    refs = cfg.get("hashes", {})
    distances = {n: h - imagehash.hex_to_hash(v) for n, v in refs.items()}
    print(f"region={region}  size={img.size}  avg_brightness={bright:.1f}/255")
    print(f"phash={h}")
    if distances:
        for n, d in sorted(distances.items(), key=lambda kv: kv[1]):
            print(f"  d={d:3d}  {n}")
    print(f"saved: {out}/inspect.png")


def cmd_run(args):
    cfg = load_cfg()
    region = require_region(cfg)
    refs_raw = cfg.get("hashes", {})
    if not refs_raw:
        sys.exit(f"No learned hashes. Run: {sys.argv[0]} learn <Name> per character.")
    refs = {n: imagehash.hex_to_hash(v) for n, v in refs_raw.items()}

    roster = set(n.lower() for n in args.characters) if args.characters else None
    windows = discover(roster)
    if not windows:
        print(
            f"No Dofus windows yet — waiting (rescan every {RESCAN_S:.0f}s).",
            flush=True,
        )
    else:
        active = [n for n in refs if n in windows]
        print(
            f"Refs={list(refs)}  Windows={list(windows)}  Active={active}", flush=True
        )

    last = None
    last_swap = 0.0
    next_rescan = 0.0
    debug_dir = Path("/tmp/dofus-swap")
    if args.debug:
        debug_dir.mkdir(exist_ok=True)

    while True:
        try:
            now = time.time()
            if now >= next_rescan:
                windows = discover(roster)
                next_rescan = now + RESCAN_S

            if not active_is_dofus():
                if args.debug:
                    print(f"[{time.strftime('%H:%M:%S')}] idle (no Dofus focused)")
                time.sleep(IDLE_POLL)
                continue

            img = shot(region)
            bright = avg_brightness(img)

            if args.debug:
                img.save(debug_dir / "last.png")

            if bright < MIN_BRIGHTNESS:
                if args.debug:
                    print(f"[{time.strftime('%H:%M:%S')}] dark avg={bright:.1f}")
                time.sleep(POLL)
                continue

            h = phash(img)
            scored = sorted(((n, h - r) for n, r in refs.items()), key=lambda kv: kv[1])
            best_name, best_d = scored[0]
            if args.debug:
                top = ", ".join(f"{n}={d}" for n, d in scored[:3])
                print(f"[{time.strftime('%H:%M:%S')}] avg={bright:5.1f} {top}")

            if (
                best_d <= HASH_MAX
                and best_name in windows
                and (now - last_swap) >= DEBOUNCE_S
            ):
                print(f"[{time.strftime('%H:%M:%S')}] -> {best_name} (d={best_d})")
                if not args.dry_run:
                    focus_title(windows[best_name])
                last_swap = now

            time.sleep(POLL)
        except KeyboardInterrupt:
            return
        except Exception as e:
            print(f"err: {e}", file=sys.stderr)
            time.sleep(1)


USAGE = """\
Dofus auto turn-swap detector (Hyprland, phash-based).

Watches the on-screen current-actor popup and focuses the matching Dofus window.

WORKFLOW (one-time per machine / resolution / popup design):
  1. ./dofus_swap.py calibrate
       Drag tight box around the name pill (just "Reminiscer"-style text).
  2. ./dofus_swap.py learn <Name>      # while that char's popup is visible
       Repeat for every character on the roster. Hashes accumulate.
  3. ./dofus_swap.py learned           # verify which chars are stored
  4. ./dofus_swap.py inspect           # while popup visible: should show d≈0
  5. ./dofus_swap.py run [--characters N1 N2 ...] [--debug] [--dry-run]
       Detector loop. Filter by roster. Survives Dofus restarts.

OTHER:
  ./dofus_swap.py list                 # show Dofus windows seen by hyprctl

NOTES:
  * Re-running calibrate with a different region INVALIDATES all learned
    hashes (different pixels = different phash). Re-learn every char.
  * Same applies if game resolution / scaling changes.
  * Config lives at ~/.config/dofus-swap.json
  * Debug grabs go to /tmp/dofus-swap/
"""


def main():
    ap = argparse.ArgumentParser(
        description="Dofus auto turn-swap (template match).",
        epilog=USAGE,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser(
        "calibrate",
        help="Pick popup name region with slurp (invalidates learned hashes).",
    )
    pl = sub.add_parser(
        "learn",
        help="Capture reference hash for one character (popup must be visible).",
    )
    pl.add_argument("name", help="Character name, e.g. Reminiscer.")
    sub.add_parser("learned", help="Print stored hashes.")
    sub.add_parser("list", help="Show detected Dofus windows.")
    sub.add_parser(
        "inspect", help="One-shot capture; print phash + distance to each learned char."
    )
    pr = sub.add_parser("run", help="Detector loop. Use Ctrl-C to stop.")
    pr.add_argument(
        "--characters",
        nargs="+",
        default=None,
        help="Roster filter, short names (e.g. Reminiscer Sayer).",
    )
    pr.add_argument(
        "--debug",
        action="store_true",
        help="Verbose ticks; dump last grab to /tmp/dofus-swap/.",
    )
    pr.add_argument(
        "--dry-run", action="store_true", help="Detect only, do not focus windows."
    )
    args = ap.parse_args()
    {
        "calibrate": cmd_calibrate,
        "learn": cmd_learn,
        "learned": cmd_learned,
        "list": cmd_list,
        "inspect": cmd_inspect,
        "run": cmd_run,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
