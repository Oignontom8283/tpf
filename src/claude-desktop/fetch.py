#!/usr/bin/env python3
"""Downloads the official Claude Desktop arm64 .deb and every Debian library
package it depends on. Usage: fetch.py WORKDIR DEBIAN_RELEASE"""
import hashlib, lzma, os, re, subprocess, sys, time, urllib.request

ANTHROPIC = "https://downloads.claude.ai/claude-desktop/apt/stable/"
DEBIAN = "https://deb.debian.org/debian/"

# Packages that must NOT be fetched: already provided by Termux's glibc, or
# daemons / hardware stacks that make no sense here (and drag in huge trees).
SKIP_EXACT = {
    "libc6", "libc-bin", "libc-dev-bin", "dpkg", "debconf", "perl-base", "adduser",
    "passwd", "lsb-base", "init-system-helpers", "gnupg", "curl", "dbus", "dbus-bin",
    "dbus-daemon", "dbus-session-bus-common", "dbus-system-bus-common", "xdg-utils",
    "libgl1-mesa-dri", "mesa-vulkan-drivers", "libgbm1-lts", "kmod", "udev",
}
SKIP_PREFIX = (
    "systemd", "libllvm", "mesa-", "libgallium", "qemu", "ovmf", "virtiofsd",
    "gnome-keyring", "kde", "plasma", "gcc-", "linux-", "nvidia", "libnvidia",
)
# Libraries that Chromium loads with dlopen() at run time: they are not in the
# .deb's "Depends" line. Without libx11-xcb1 the app dies at start-up (SIGTRAP).
EXTRA_SEEDS = ["fonts-dejavu-core", "libgdk-pixbuf-2.0-0", "libxkbcommon0",
               "libx11-xcb1", "libx11-6", "libxcb1"]


def log(msg):
    print(msg, flush=True)


def fetch(url, tries=4):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "claude-desktop-termux-installer"})
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(2 * (i + 1))
    raise RuntimeError(f"download failed: {url}: {last}")


def parse_packages(text):
    pkgs = []
    for stanza in text.split("\n\n"):
        if not stanza.strip():
            continue
        fields, key = {}, None
        for line in stanza.split("\n"):
            if line[:1] in (" ", "\t") and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, _, val = line.partition(":")
                fields[key] = val.strip()
        if "Package" in fields:
            pkgs.append(fields)
    return pkgs


def vkey(v):
    return [int(p) if p.isdigit() else p for p in re.findall(r"\d+|[A-Za-z]+", v)]


def pkgname(token):
    token = re.sub(r"\(.*?\)", "", token)      # version constraint
    token = re.sub(r"\[.*?\]|<.*?>", "", token)  # arch / profile restrictions
    return token.strip().split(":")[0]


def skipped(name):
    return name in SKIP_EXACT or name.startswith(SKIP_PREFIX)


def resolve(seed_depends, index, provides):
    """seed_depends: a Depends-style string. Returns an ordered list of package names."""
    result, queue, seen = [], [], set()

    def groups(dep):
        for g in dep.split(","):
            g = g.strip()
            if g:
                yield [pkgname(a) for a in g.split("|") if pkgname(a)]

    def pick(alts):
        for a in alts:
            if skipped(a):
                return None
        for a in alts:
            if a in index:
                return a
        for a in alts:
            if a in provides:
                return provides[a]
        return ""   # unresolved

    def enqueue(dep):
        for alts in groups(dep):
            p = pick(alts)
            if p is None:
                continue
            if p == "":
                log(f"[WARN] no Debian package found for: {' | '.join(alts)}")
                continue
            if p not in seen:
                seen.add(p)
                queue.append(p)

    enqueue(seed_depends)
    for extra in EXTRA_SEEDS:
        if extra in index and extra not in seen:
            seen.add(extra)
            queue.append(extra)
    while queue:
        name = queue.pop(0)
        result.append(name)
        d = index[name]
        enqueue(d.get("Pre-Depends", ""))
        enqueue(d.get("Depends", ""))
    return result


def download(url, dest, sha256):
    if os.path.exists(dest):
        h = hashlib.sha256(open(dest, "rb").read()).hexdigest()
        if not sha256 or h == sha256:
            return
        os.remove(dest)
    data = fetch(url)
    if sha256 and hashlib.sha256(data).hexdigest() != sha256:
        raise RuntimeError(f"SHA256 mismatch: {url}")
    with open(dest + ".part", "wb") as f:
        f.write(data)
    os.replace(dest + ".part", dest)


def main():
    work, release = sys.argv[1], sys.argv[2]
    debs = os.path.join(work, "debs")
    os.makedirs(debs, exist_ok=True)

    # --- Official Claude Desktop .deb (newest arm64) ------------------------
    log("[INFO] Reading Anthropic's package index (arm64)...")
    idx = fetch(ANTHROPIC + "dists/stable/main/binary-arm64/Packages").decode("utf-8", "replace")
    cands = [p for p in parse_packages(idx) if p.get("Package") == "claude-desktop"]
    if not cands:
        raise RuntimeError("claude-desktop not found in Anthropic's arm64 index")
    cands.sort(key=lambda p: vkey(p.get("Version", "0")))
    cd = cands[-1]
    log(f"[INFO] Claude Desktop {cd.get('Version')}: downloading {cd['Filename']}")
    cd_path = os.path.join(work, "claude-desktop.deb")
    download(ANTHROPIC + cd["Filename"], cd_path, cd.get("SHA256"))
    log("[ OK ] Claude Desktop .deb downloaded and verified.")

    # The .deb's own dependency list is the source of truth for libraries.
    depends = ""
    for field in ("Pre-Depends", "Depends"):
        out = subprocess.run(["dpkg-deb", "-f", cd_path, field], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            depends += ("," if depends else "") + out.stdout.strip()
    if not depends:   # fall back on the repository index
        depends = cd.get("Pre-Depends", "") + "," + cd.get("Depends", "")
    log(f"[INFO] Dependencies of the app: {depends}")

    # --- Debian libraries ----------------------------------------------------
    log(f"[INFO] Reading Debian '{release}' package index (arm64, ~8 MB)...")
    raw = fetch(DEBIAN + f"dists/{release}/main/binary-arm64/Packages.xz")
    text = lzma.decompress(raw).decode("utf-8", "replace")
    pkgs = parse_packages(text)
    index = {p["Package"]: p for p in pkgs}
    provides = {}
    for p in pkgs:
        for prov in p.get("Provides", "").split(","):
            n = pkgname(prov)
            if n and n not in provides:
                provides[n] = p["Package"]
    names = resolve(depends, index, provides)
    log(f"[INFO] {len(names)} library packages to download.")

    listing = []
    for i, n in enumerate(names, 1):
        p = index[n]
        dest = os.path.join(debs, os.path.basename(p["Filename"]))
        log(f"    ({i}/{len(names)}) {n}")
        download(DEBIAN + p["Filename"], dest, p.get("SHA256"))
        listing.append(dest)
    with open(os.path.join(work, "libs.list"), "w") as f:
        f.write("\n".join(listing) + "\n")
    with open(os.path.join(work, "version.txt"), "w") as f:
        f.write(cd.get("Version", "unknown") + "\n")
    log("[ OK ] All packages downloaded.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)
