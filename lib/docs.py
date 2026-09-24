#!/usr/bin/env python3
"""Data for the documentation site (docs/), for build-docs.sh.

  docs.py reference <repo> <out.json>
      config variables (config/mvx.conf), the entry scripts' usage, the guest
      scripts' purpose, the workaround and status tables (README.md) -- taken
      from the repo itself, so the site cannot drift from it.

  docs.py capture <base-url> <site-topology-dir> <frames> <interval> [checks.json]
      a recording of local-noc's topology (frames of /api/topology) and every
      node's raw tables (/api/node/<id>), for the topology viewer on the site.
      Secrets (PSKs, keys, passwords) are redacted from the raw tables.
      checks.json (optional, read from stdin as "name<TAB>status text" lines)
      is written next to the reference data.
"""

import json
import os
import re
import sys
import time
import urllib.request

# ---------------------------------------------------------------- reference


def config_vars(path):
    out, comment = [], []
    section = ""
    for line in open(path):
        line = line.rstrip("\n")
        m = re.match(r'^: "\$\{(\w+):=(.*)\}"\s*(#\s*(.*))?$', line)
        if line.startswith("# ---"):
            section = line.strip("# -").strip()
            comment = []
        elif m:
            doc = " ".join(c for c in comment if c)
            if m.group(4):
                doc = (doc + " " + m.group(4)).strip()
            out.append({"name": m.group(1), "default": m.group(2), "section": section, "doc": doc})
            comment = []
        elif line.startswith("#"):
            comment.append(line.lstrip("#").strip())
        else:
            comment = []
    return out


def script_usage(path):
    """The usage block at the top of an entry script (the lines usage() prints)."""
    lines, started = [], False
    for line in open(path).read().splitlines()[1:]:
        if not line.startswith("#"):
            break
        text = line[2:] if line.startswith("# ") else line[1:]
        if not started and not text.strip():
            continue
        started = True
        lines.append(text)
    return "\n".join(lines).strip()


def guest_purpose(path):
    """The first comment block of a guest script."""
    lines = []
    for line in open(path).read().splitlines()[1:]:
        if not line.startswith("#"):
            break
        lines.append(line.lstrip("#").strip())
    return " ".join(l for l in lines if l).strip()


def md_table(text, heading):
    """Rows of the first markdown table after a heading."""
    i = text.find(heading)
    if i < 0:
        return []
    rows = []
    for line in text[i:].splitlines()[1:]:
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split(" | ")]
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        elif rows:
            break
    return rows[1:] if rows else []        # without the header row


def reference(repo, out):
    readme = open(os.path.join(repo, "README.md")).read()
    scripts = {}
    for name in ("build-mvx.sh", "setup-vm.sh", "deploy-mvx.sh", "build-pod.sh", "build-docs.sh"):
        p = os.path.join(repo, name)
        if os.path.exists(p):
            scripts[name] = script_usage(p)
    guests = []
    gdir = os.path.join(repo, "guest")
    for name in sorted(os.listdir(gdir)):
        if re.match(r"\d\d-.*\.sh$", name):
            guests.append({"name": name, "purpose": guest_purpose(os.path.join(gdir, name))})
    data = {
        "generated": int(time.time()),
        "config": config_vars(os.path.join(repo, "config", "mvx.conf")),
        "scripts": scripts,
        "guests": guests,
        "workarounds": [{"problem": r[0], "workaround": r[1], "fix": r[2]}
                        for r in md_table(readme, "### Workarounds") if len(r) >= 3],
        "status": [{"goal": r[0], "result": r[1]} for r in md_table(readme, "## Status") if len(r) >= 2],
    }
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(data, f, indent=1)
    print(f"reference: {len(data['config'])} settings, {len(scripts)} scripts, "
          f"{len(guests)} guest scripts, {len(data['workarounds'])} workarounds -> {out}")


# ---------------------------------------------------------------- capture

SECRET = re.compile(r"(psks?|secret|password|passwd|passphrase|private_key|^key|_key)$", re.I)
KEEP = re.compile(r"(key_mgmt|key_id|keys)$", re.I)


def redact(v, name=""):
    if name and SECRET.search(name) and not KEEP.search(name):
        if isinstance(v, list) and len(v) == 2 and v[0] == "map":
            return ["map", [[k, "(redacted)"] for k, _ in v[1]]]
        return "(redacted)" if v not in ("", None, ["set", []]) else v
    if isinstance(v, list) and len(v) == 2 and v[0] == "map":
        return ["map", [[k, redact(x, str(k))] for k, x in v[1]]]
    if isinstance(v, dict):
        return {k: redact(x, k) for k, x in v.items()}
    return v


def get(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)


def capture(base, site, frames, interval, checks=None):
    base = base.rstrip("/")
    api = os.path.join(site, "api")
    os.makedirs(os.path.join(api, "node"), exist_ok=True)
    recs = []
    for i in range(frames):
        recs.append(get(base + "/api/topology"))
        print(f"capture: frame {i + 1}/{frames}", flush=True)
        if i + 1 < frames:
            time.sleep(interval)
    last = recs[-1]
    with open(os.path.join(api, "topology"), "w") as f:
        json.dump({"recorded": int(last["t"]), "source": "local-noc", "frames": recs}, f)
    for old in os.listdir(os.path.join(api, "node")):
        os.remove(os.path.join(api, "node", old))
    for n in last["nodes"]:
        if n["kind"] in ("gateway", "extender"):
            raw = get(base + "/api/node/" + urllib.request.quote(n["id"]))
            raw["tables"] = {t: {u: redact(row) for u, row in rows.items()} for t, rows in raw["tables"].items()}
            raw["note"] = "recorded from local-noc for the documentation; secrets redacted"
            with open(os.path.join(api, "node", n["id"] + ".json"), "w") as f:
                json.dump(raw, f, indent=1)
    print(f"capture: {frames} frames, {len(last['nodes'])} nodes, {len(last['links'])} links -> {api}")
    if checks:
        results = {}
        for line in sys.stdin:
            name, _, text = line.rstrip("\n").partition("\t")
            if name:
                results.setdefault(name, []).append(text)
        with open(checks, "w") as f:
            json.dump({"recorded": int(last["t"]), "checks": results}, f, indent=1)
        print(f"capture: {len(results)} check results -> {checks}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "reference":
        reference(sys.argv[2], sys.argv[3])
    elif cmd == "capture":
        capture(sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5]),
                sys.argv[6] if len(sys.argv) > 6 else None)
    else:
        sys.exit(__doc__)
