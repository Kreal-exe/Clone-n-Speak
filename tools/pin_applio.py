#!/usr/bin/env python3
"""Writes Sources/cns_pins.py: the hashes cns_engines.py checks every pro-engine download against.

Needs the network (this developer command only): it downloads the pinned Applio and Seed-VC tarballs, hashes the
files the app extracts, and asks Hugging Face for the sha256 (LFS oid) and size of every pinned weight. The Applio
hashes are compared with the desktop Applio's backend/revision.json; a difference stops the run.

    python3 tools/pin_applio.py [--revision-json PATH] [--applio-tar PATH] [--seedvc-tar PATH] [--out PATH]
"""
import argparse
import hashlib
import json
import os
import pathlib
import pprint
import re
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPIKES = ROOT / "tools" / "spikes"

APPLIO_COMMIT = "59c113106c0dfff647324ab1a80c286f17b51929"
SEEDVC_COMMIT = "51383efd921027683c89e5348211d93ff12ac2a8"
HF_REPO = "IAHispano/Applio"
HF_REV = "3ff370b7023086f57e200ef86a9a251ddf4da472"
DEFAULT_REVISION_JSON = "/Applications/Applio.app/Contents/Resources/app/backend/revision.json"

# What the app extracts from the Applio tarball. rvc/models is the weights folder (a symlink at install time), the
# desktop-only parts (tabs/, app.py, Gradio) are not needed. logs/mute holds the silent clips training mixes in.
APPLIO_TOP_FILES = ("core.py", "LICENSE", "assets/config_template.json", "requirements-engine.txt")
APPLIO_PREFIXES = ("rvc/", "logs/mute/")
APPLIO_SKIP_PREFIXES = ("rvc/models/",)
SEEDVC_SKIP_PREFIXES = ("examples/", "assets/", ".github/")

# component id -> list of (path inside <root>/weights, path in the HF repo)
WEIGHT_SPECS = {
    "rvc-core": [
        ("predictors/rmvpe.pt", "Resources/predictors/rmvpe.pt"),
        ("embedders/contentvec/pytorch_model.bin", "Resources/embedders/contentvec/pytorch_model.bin"),
        ("embedders/contentvec/config.json", "Resources/embedders/contentvec/config.json"),
    ],
    "rvc-fcpe": [("predictors/fcpe.pt", "Resources/predictors/fcpe.pt")],
}
for _sr in ("32", "40", "48"):
    WEIGHT_SPECS["rvc-train-%sk" % _sr] = [
        ("pretraineds/hifi-gan/f0G%sk.pth" % _sr, "Resources/pretrained_v2/f0G%sk.pth" % _sr),
        ("pretraineds/hifi-gan/f0D%sk.pth" % _sr, "Resources/pretrained_v2/f0D%sk.pth" % _sr),
    ]

# What Seed-VC's inference.py fetches on its first conversion (DiT without f0, the default path): repo, exact revision,
# where it caches ("checkpoints": load_custom_model_from_hf uses ./checkpoints; "hub": from_pretrained uses HF_HUB_CACHE).
SEEDVC_MODEL_SPECS = [
    ("Plachta/Seed-VC", "257283f9f41585055e8f858fba4fd044e5caed6e", "checkpoints",
     ["DiT_seed_v2_uvit_whisper_small_wavenet_bigvgan_pruned.pth", "config_dit_mel_seed_uvit_whisper_small_wavenet.yml"]),
    ("funasr/campplus", "e4b6ede7ce16997aff4ae69fbca1f0175e2afede", "checkpoints", ["campplus_cn_common.bin"]),
    ("nvidia/bigvgan_v2_22khz_80band_256x", "633ff708ed5b74903e86ff1298cf4a98e921c513", "hub",
     ["config.json", "bigvgan_generator.pt"]),
    ("openai/whisper-small", "973afd24965f72e36ca33b3055d56a652f456b4d", "hub",
     ["config.json", "model.safetensors", "preprocessor_config.json"]),
]
EDGE_REQUIREMENT = "edge-tts==7.3.1"

# Task 7.5 adds the stem models here: id -> [(file name, url, sha256 or None to read it from the URL's LFS headers)].
STEM_SPECS = {}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(url, dest):
    if not url.startswith("https://"):
        raise SystemExit("refusing a non-HTTPS URL: %s" % url)
    req = urllib.request.Request(url, headers={"User-Agent": "Clone-n-Speak-pin"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as out:
        while True:
            block = resp.read(1 << 20)
            if not block:
                break
            out.write(block)


def tar_files(tar_path):
    """({path below the tarball's top folder: sha256}, {path: size}) of regular files; links stop the run."""
    out, sizes = {}, {}
    with tarfile.open(tar_path) as tar:
        for m in tar:
            if m.issym() or m.islnk():
                raise SystemExit("%s: link in the tarball: %s" % (tar_path, m.name))
            if not m.isfile():
                continue
            rel = m.name.split("/", 1)[1] if "/" in m.name else m.name
            h = hashlib.sha256()
            f = tar.extractfile(m)
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
            out[rel] = h.hexdigest()
            sizes[rel] = m.size
    return out, sizes


def select_applio(all_files):
    keep = {}
    for rel, digest in all_files.items():
        if rel in APPLIO_TOP_FILES or (rel.startswith(APPLIO_PREFIXES) and not rel.startswith(APPLIO_SKIP_PREFIXES)):
            keep[rel] = digest
    return dict(sorted(keep.items()))


def check_against_revision(selected, revision_json):
    rev = json.load(open(revision_json))
    if rev.get("commit") != APPLIO_COMMIT:
        raise SystemExit("revision.json is for commit %s, not %s" % (rev.get("commit"), APPLIO_COMMIT))
    bad = []
    for rel, digest in rev["files"].items():
        if selected.get(rel) != digest:
            bad.append(rel)
    if bad:
        raise SystemExit("hashes differ from the desktop Applio's revision.json (%d files), first: %s" % (len(bad), bad[:5]))
    return len(rev["files"])


def select_seedvc(all_files):
    return dict(sorted((k, v) for k, v in all_files.items() if not k.startswith(SEEDVC_SKIP_PREFIXES)))


def hf_head(url, rev=None):
    """(sha256, size) of a Hugging Face file: the LFS oid is the x-linked-etag of the redirect."""
    rev = rev or HF_REV
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "Clone-n-Speak-pin"})
    try:
        resp = opener.open(req, timeout=60)
        headers = resp.headers
    except urllib.error.HTTPError as e:
        headers = e.headers
    commit = headers.get("x-repo-commit")
    if commit != rev:
        raise SystemExit("%s: repo commit %s, expected %s" % (url, commit, rev))
    etag = (headers.get("x-linked-etag") or "").strip('"')
    size = headers.get("x-linked-size")
    if re.fullmatch(r"[0-9a-f]{64}", etag) and size:
        return etag, int(size)
    return None, None   # a small non-LFS file: hash it by downloading


def weight_entry(dest, url, tmpdir, rev=None):
    digest, size = hf_head(url, rev)
    if digest is None:
        # A small non-LFS file (config.json, a yml): HF publishes only its git sha1, so the sha256 is trust-on-first-pin:
        # computed from this download of the exact revision, then enforced on every install.
        part = os.path.join(tmpdir, "small.bin")
        fetch(url, part)
        digest, size = sha256_file(part), os.path.getsize(part)
    return {"path": dest, "url": url, "sha256": digest, "size": size}


def parse_requirements_header(text):
    """The three install stages are written in the file's header comment (see the spike)."""
    stage2 = stage3 = None
    for line in text.splitlines():
        m = re.match(r"#\s*2\)\s*uv pip install --no-deps (.+)$", line)
        if m:
            stage2 = m.group(1).split()
        m = re.match(r"#\s*3\)\s*uv pip install (.+)$", line)
        if m:
            stage3 = m.group(1).split()
    if not stage2 or not stage3:
        raise SystemExit("could not read stages 2 and 3 from the requirements header")
    body = "\n".join(l for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#")
                     and not l.startswith("edge-tts")) + "\n"   # edge-tts lives in its own environment
    return body, stage2, stage3


def freeze_text(path):
    return "\n".join(l.strip() for l in open(path).read().splitlines() if l.strip() and not l.startswith("#")) + "\n"


def seedvc_models(tmpdir):
    out = []
    for repo, rev, cache, files in SEEDVC_MODEL_SPECS:
        entries = []
        for name in files:
            url = "https://huggingface.co/%s/resolve/%s/%s" % (repo, rev, name)
            e = weight_entry(name, url, tmpdir, rev)
            entries.append(e)
        out.append({"repo": repo, "rev": rev, "cache": cache, "files": entries})
        print("%s: %d MB" % (repo, sum(e["size"] for e in entries) // 1000000))
    return out


def edge_constraints():
    """Exact versions of edge-tts and everything it pulls in, as uv resolves them now (wheels only)."""
    import subprocess
    run = subprocess.run(["uv", "pip", "compile", "-", "--python-version", "3.11", "--no-header", "--no-annotate",
                          "--only-binary", ":all:", "-q"], input=EDGE_REQUIREMENT + "\n", capture_output=True, text=True)
    if run.returncode:
        raise SystemExit("uv pip compile failed: " + run.stderr[-500:])
    return "\n".join(l.strip() for l in run.stdout.splitlines() if l.strip() and not l.startswith("#")) + "\n"


def build(args, tmpdir):
    applio_tar = args.applio_tar or os.path.join(tmpdir, "applio.tar.gz")
    if not args.applio_tar:
        fetch("https://github.com/IAHispano/Applio/archive/%s.tar.gz" % APPLIO_COMMIT, applio_tar)
    seed_tar = args.seedvc_tar or os.path.join(tmpdir, "seedvc.tar.gz")
    if not args.seedvc_tar:
        fetch("https://github.com/Plachtaa/seed-vc/archive/%s.tar.gz" % SEEDVC_COMMIT, seed_tar)

    applio_all, applio_sizes = tar_files(applio_tar)
    applio = select_applio(applio_all)
    n = check_against_revision(applio, args.revision_json)
    print("Applio: %d files selected, %d matched revision.json" % (len(applio), n))
    seed_all, seed_sizes = tar_files(seed_tar)
    seedvc = select_seedvc(seed_all)
    print("Seed-VC: %d files" % len(seedvc))

    weights = {}
    for comp, specs in WEIGHT_SPECS.items():
        weights[comp] = [weight_entry(dest, "https://huggingface.co/%s/resolve/%s/%s" % (HF_REPO, HF_REV, src), tmpdir)
                         for dest, src in specs]
        print("%s: %d MB" % (comp, sum(e["size"] for e in weights[comp]) // 1000000))
    stems = {}
    for comp, specs in STEM_SPECS.items():
        stems[comp] = [dict(path=name, url=url, sha256=sha, size=size) for name, url, sha, size in specs]

    req_body, stage2, stage3 = parse_requirements_header((SPIKES / "pro-env-py311-requirements.txt").read_text())
    return {
        "APPLIO_COMMIT": APPLIO_COMMIT,
        "APPLIO_URL": "https://github.com/IAHispano/Applio/archive/%s.tar.gz" % APPLIO_COMMIT,
        "SEEDVC_COMMIT": SEEDVC_COMMIT,
        "SEEDVC_URL": "https://github.com/Plachtaa/seed-vc/archive/%s.tar.gz" % SEEDVC_COMMIT,
        "HF_REV": HF_REV,
        "APPLIO_FILES": applio,
        "APPLIO_SIZES": {k: applio_sizes[k] for k in applio},
        "SEEDVC_FILES": seedvc,
        "SEEDVC_SIZES": {k: seed_sizes[k] for k in seedvc},
        "SEEDVC_MODELS": seedvc_models(tmpdir),
        "EDGE_REQUIREMENT": EDGE_REQUIREMENT,
        "EDGE_CONSTRAINTS": edge_constraints(),
        "WEIGHTS": weights,
        "STEMS": stems,
        "PRO_REQUIREMENTS": req_body,
        "PRO_STAGE2": stage2,
        "PRO_STAGE3": stage3,
        "PRO_CONSTRAINTS": freeze_text(SPIKES / "pro-env-py311-freeze.txt"),
        "APPLIO_STRICT_CONSTRAINTS": freeze_text(SPIKES / "applio-strict-py312-freeze.txt"),
    }


def render(values):
    lines = ['"""Pinned hashes and versions for the pro engines. GENERATED by tools/pin_applio.py: do not edit by hand."""', ""]
    for name, value in values.items():
        lines.append("%s = %s" % (name, pprint.pformat(value, width=110, sort_dicts=True)))
        lines.append("")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--revision-json", default=DEFAULT_REVISION_JSON)
    ap.add_argument("--applio-tar", help="use this tarball instead of downloading")
    ap.add_argument("--seedvc-tar", help="use this tarball instead of downloading")
    ap.add_argument("--out", default=str(ROOT / "Sources" / "cns_pins.py"))
    args = ap.parse_args(argv)
    with tempfile.TemporaryDirectory() as tmp:
        values = build(args, tmp)
    pathlib.Path(args.out).write_text(render(values))
    print("wrote %s" % args.out)


if __name__ == "__main__":
    main()
