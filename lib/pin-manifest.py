#!/usr/bin/env python3
"""Write a revision-locked copy of a repo checkout's manifest.

Equivalent of `repo manifest -r`, which is unusable in the reference trees
(their bundled .repo/repo imports the `formatter` module that Python 3.10
removed). Every <project> gets revision=<HEAD sha of its checkout> and keeps
the branch it tracked as upstream=, so `repo sync --current-branch` still
knows what to fetch.

Refuses to pin a project with local modifications. Also writes
<out.xml>.projects: one "name path sha upstream" line per project, which
build-mvx.sh uses to populate the pin store.

usage: pin-manifest.py <checkout-root> <out.xml>
"""

import os
import subprocess
import sys
import xml.etree.ElementTree as ET


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def load_manifest(repo_dir):
    """Resolve .repo/manifest.xml (symlink or <include> wrapper) to the real file."""
    path = os.path.realpath(os.path.join(repo_dir, "manifest.xml"))
    root = ET.parse(path).getroot()
    includes = root.findall("include")
    if includes and not root.findall("project"):
        if len(includes) != 1:
            sys.exit("manifest wrapper with several <include>s is not supported")
        path = os.path.join(repo_dir, "manifests", includes[0].get("name"))
        root = ET.parse(path).getroot()
    return path, root


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    checkout, out = sys.argv[1:]
    repo_dir = os.path.join(checkout, ".repo")
    src, root = load_manifest(repo_dir)

    remotes = {r.get("name"): r for r in root.findall("remote")}
    default = root.find("default")
    default_rev = default.get("revision") if default is not None else None
    default_remote = default.get("remote") if default is not None else None

    errors = []
    lines = []
    for proj in root.findall("project"):
        name = proj.get("name")
        path = proj.get("path", name)
        wt = os.path.join(checkout, path)
        head = git("rev-parse", "HEAD", cwd=wt)
        if head.returncode:
            errors.append(f"{path}: not a git checkout")
            continue
        sha = head.stdout.strip()
        if git("status", "--porcelain", "--untracked-files=no", cwd=wt).stdout.strip():
            errors.append(f"{path}: has local modifications")
        remote = remotes.get(proj.get("remote") or default_remote)
        branch = proj.get("revision") or (remote.get("revision") if remote is not None else None) or default_rev
        if not branch:
            errors.append(f"{path}: cannot determine the branch it tracks")
            continue
        if not proj.get("upstream"):
            proj.set("upstream", branch)
        proj.set("revision", sha)
        lines.append(f"{name} {path} {sha} {proj.get('upstream')}")

    if errors:
        sys.exit("cannot pin:\n  " + "\n  ".join(errors))

    comment = ET.Comment(
        f" revision-locked from {checkout} ({os.path.basename(src)}) by mvx-opensync lib/pin-manifest.py "
    )
    root.insert(0, comment)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(out, encoding="UTF-8", xml_declaration=True)
    with open(out + ".projects", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"pinned {len(root.findall('project'))} projects -> {out}")


if __name__ == "__main__":
    main()
