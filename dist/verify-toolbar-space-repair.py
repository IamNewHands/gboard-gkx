"""Fixed Gboard 2.3.19 packaging check; final independently revalidates CI provenance.
Both phases use read-only GitHub GETs. preflight downloads/extracts the one CI dylib;
final writes an exclusive receipt only after all checks. Never run with Python -O.
"""
import hashlib, json, plistlib, re, stat, struct, subprocess, sys, zipfile
from pathlib import Path

ROOT = Path("D:/GitHub_Clone")
REPO = ROOT / "gboard-gkx"
BASE = ROOT / "Gboard_2.3.19.ipa"
BASE_SHA256 = "c011730153df537f226052e766bbbf71834b5afcfeb13cba12f365d049719731"
DICT_SHA256 = "12482d2893a8fe063b38b0a14db12f547b2fb3b90190cd65ab569a0bd7133839"
APP = "Payload/Gboard.app"
EXES = [APP + "/Gboard", APP + "/PlugIns/Gboard.appex/Gboard"]
FRAMEWORK = APP + "/Frameworks/gboard_framework.framework/gboard_framework"
DYLIB = APP + "/Frameworks/libgkx.dylib"
DICT = APP + "/Frameworks/user_dictionary.db"
TARGET = b"group.zunbengege.top"
GROUPS = [b"group.com.google." + s for s in (b"keyboard", b"common", b"gsuite", b"GoogleMobile", b"keyboard.enterprise", b"common.enterprise", b"gsuite.enterprise", b"GoogleMobile.enterprise")]
# Independently probed from BASE, not copied from a previous IPA receipt.
GROUP_SLOTS = [(9190675, GROUPS[1]), (9190699, GROUPS[5]),
               (9190734, GROUPS[2]), (9190758, GROUPS[6]),
               (9199423, GROUPS[0]), (9199449, GROUPS[4]),
               (9199486, GROUPS[3]), (9199516, GROUPS[7])]
SIGNATURE_FILES = {APP + "/_CodeSignature/CodeResources",
                   APP + "/PlugIns/Gboard.appex/_CodeSignature/CodeResources",
                   APP + "/Frameworks/gboard_framework.framework/_CodeSignature/CodeResources"}
EXPECTED_DIFFS = {FRAMEWORK:176, EXES[0]:28, EXES[1]:27}
LOAD_PATH = "@rpath/libgkx.dylib"
LIB_COMMANDS = {0xC, 0xD, 0x18, 0x80000018, 0x8000001F, 0x80000023, 0x20}
LINKEDIT_COMMANDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034, 0x36, 0x37, 0x38}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def configure(args):
    global SHA, RUN, ARTIFACT, DIGEST, TAG, ART, IPA
    require(len(args) == 4, "Expected full SHA, run ID, artifact ID, bare archive SHA256")
    SHA, run, artifact, DIGEST = args
    require(re.fullmatch(r"[0-9a-f]{40}", SHA) is not None, "Invalid full commit SHA")
    require(re.fullmatch(r"[1-9][0-9]*", run) is not None and re.fullmatch(r"[1-9][0-9]*", artifact) is not None, "Invalid run/artifact ID")
    require(re.fullmatch(r"[0-9a-f]{64}", DIGEST) is not None, "Invalid bare archive SHA256")
    RUN, ARTIFACT, TAG = int(run), int(artifact), SHA[:7]
    ART = REPO / f"dist/artifact-{TAG}"
    IPA = REPO / f"dist/gboard-gkx-{TAG}-toolbar-space-repair-unsigned.ipa"


def commands(data):
    """Validate arm64 command table and file-backed segment/section/linkedit ranges."""
    require(len(data) >= 32, "Mach-O header truncated")
    magic, cpu, _, _, count, total, _, _ = struct.unpack_from("<8I", data)
    require(magic == 0xFEEDFACF and cpu == 0x100000C, "Not arm64 Mach-O")
    end = 32 + total
    require(count <= total // 8 and end <= len(data), "Mach-O load command table out of bounds")
    out, pos, linkedit_ranges, linkedit_data = [], 32, [], []

    def span(offset, length, message, in_linkedit=False):
        require(offset <= len(data) and length <= len(data) - offset, message)
        if length:
            require(offset >= end, "Mach-O data overlaps load commands")
            if in_linkedit:
                linkedit_data.append((offset, length))

    for _ in range(count):
        require(pos + 8 <= end, "Mach-O load command header truncated")
        cmd, size = struct.unpack_from("<II", data, pos)
        require(size >= 8 and size % 8 == 0 and pos + size <= end, "Mach-O invalid load command size")
        out.append((pos, cmd, size))
        if cmd == 0x19:
            require(size >= 72, "Mach-O segment command truncated")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", data, pos + 24)
            require(vmaddr + vmsize <= 1 << 64 and filesize <= vmsize and fileoff <= len(data) and filesize <= len(data) - fileoff, "Mach-O segment range out of bounds")
            if data[pos + 8:pos + 24].split(b"\0", 1)[0] == b"__LINKEDIT":
                linkedit_ranges.append((fileoff, fileoff + filesize))
            sections = struct.unpack_from("<I", data, pos + 64)[0]
            require(size == 72 + sections * 80, "Mach-O section table size mismatch")
            for q in range(pos + 72, pos + size, 80):
                addr, length = struct.unpack_from("<QQ", data, q + 32)
                offset, _, reloff, nreloc, flags = struct.unpack_from("<5I", data, q + 48)
                require(vmaddr <= addr <= vmaddr + vmsize and length <= vmaddr + vmsize - addr, "Mach-O section VM range out of bounds")
                if flags & 0xFF not in (1, 0xC, 0x12) and length:
                    span(offset, length, "Mach-O section data out of bounds")
                    require(fileoff <= offset and offset + length <= fileoff + filesize, "Mach-O section outside segment")
                span(reloff, nreloc * 8, "Mach-O relocation table out of bounds", in_linkedit=True)
        elif cmd == 0x2:
            require(size == 24, "Mach-O symtab command truncated")
            symoff, nsyms, stroff, strsize = struct.unpack_from("<4I", data, pos + 8)
            span(symoff, nsyms * 16, "Mach-O symbol table out of bounds", in_linkedit=True)
            span(stroff, strsize, "Mach-O string table out of bounds", in_linkedit=True)
        elif cmd == 0xB:
            require(size == 80, "Mach-O dysymtab command truncated")
            fields = struct.unpack_from("<18I", data, pos + 8)
            for j, width in ((6, 8), (8, 56), (10, 4), (12, 4), (14, 8), (16, 8)):
                span(fields[j], fields[j + 1] * width, "Mach-O dysymtab range out of bounds", in_linkedit=True)
        elif cmd in (0x22, 0x80000022):
            require(size == 48, "Mach-O dyld info command truncated")
            fields = struct.unpack_from("<10I", data, pos + 8)
            for j in range(0, 10, 2):
                span(fields[j], fields[j + 1], "Mach-O dyld info range out of bounds", in_linkedit=True)
        elif cmd in LINKEDIT_COMMANDS:
            require(size == 16, "Mach-O linkedit command truncated")
            span(*struct.unpack_from("<II", data, pos + 8), "Mach-O linkedit data out of bounds", in_linkedit=True)
        elif cmd in (0x21, 0x2C):
            require(size == 24, "Mach-O encryption command truncated")
            cryptoff, cryptsize, cryptid = struct.unpack_from("<3I", data, pos + 8)
            span(cryptoff, cryptsize, "Mach-O encryption range out of bounds")
            require(cryptid == 0, "Mach-O remains encrypted")
        elif cmd == 0x80000028:
            require(size == 24, "Mach-O entry command truncated")
            require(struct.unpack_from("<Q", data, pos + 8)[0] < len(data), "Mach-O entry offset out of bounds")
        if cmd in LIB_COMMANDS or cmd == 0x8000001C:
            string_at(data, pos, size, 12 if cmd == 0x8000001C else 24)
        pos += size
    require(pos == end, "Mach-O sizeofcmds does not match command table")
    for offset, length in linkedit_data:
        require(any(lo <= offset and offset + length <= hi for lo, hi in linkedit_ranges), "Mach-O linkedit data outside __LINKEDIT")
    return out


def string_at(data, pos, size, minimum):
    require(size >= minimum, "Mach-O string command truncated")
    offset = struct.unpack_from("<I", data, pos + 8)[0]
    require(minimum <= offset < size, "Mach-O string offset out of bounds")
    raw = data[pos + offset:pos + size]
    require(b"\0" in raw, "Mach-O command string is not terminated")
    return raw.split(b"\0", 1)[0].decode("utf-8")


def command_strings(data, command):
    return [string_at(data, pos, size, 12 if command == 0x8000001C else 24)
            for pos, cmd, size in commands(data) if cmd == command]


def safe_zip(z, artifact=False):
    entries, seen = z.infolist(), set()
    for entry in entries:
        name = entry.orig_filename
        require(name == entry.filename, "ZIP filename normalized/truncated")
        parts = name.rstrip("/").split("/")
        require(name and not name.startswith("/") and ":" not in name and chr(92) not in name and all(p not in ("", ".", "..") for p in parts), "Unsafe ZIP archive entry")
        key = name.rstrip("/").casefold()
        require(key not in seen, "Duplicate ZIP archive entry")
        seen.add(key)
        mode = entry.external_attr >> 16
        kind = stat.S_IFMT(mode)
        require(kind in (0, stat.S_IFDIR if entry.is_dir() else stat.S_IFREG), "ZIP nonregular entry")
    require(z.testzip() is None, "ZIP CRC failure")
    if artifact:
        require([i.filename for i in entries] == ["libgkx.dylib"], "Unexpected CI artifact members")
    return entries


def ci_identity(meta=None, run=None):
    """Single provenance owner used by BOTH phases; API operations are GET only."""
    def api(path):
        return json.loads(subprocess.check_output(["gh", "api", "--method", "GET", f"repos/IamNewHands/gboard-gkx/{path}"]))
    if meta is None:
        meta = api(f"actions/artifacts/{ARTIFACT}")
    if run is None:
        run = api(f"actions/runs/{RUN}")
    require(meta["id"] == ARTIFACT and meta["name"] == "libgkx" and meta["workflow_run"]["head_sha"] == SHA and meta["workflow_run"]["id"] == RUN, "CI artifact identity mismatch")
    require(meta["digest"] == "sha256:" + DIGEST and not meta["expired"], "CI artifact digest/expiry mismatch")
    require(run["id"] == RUN and run["head_sha"] == SHA and run["path"] == ".github/workflows/build-dylib.yml", "CI workflow identity mismatch")
    require(run["status"] == "completed" and run["conclusion"] == "success", "CI run did not complete successfully")
    require(run["repository"]["full_name"] == "IamNewHands/gboard-gkx", "CI repository identity mismatch")
    return meta, run


def artifact_bytes(archive=None):
    archive = archive or ART / "ci-artifact.zip"
    require(sha(archive.read_bytes()) == DIGEST, "CI archive digest mismatch")
    with zipfile.ZipFile(archive) as z:
        safe_zip(z, artifact=True)
        data = z.read("libgkx.dylib")
    commands(data)
    require(struct.unpack_from("<I", data, 12)[0] == 6, "CI artifact is not MH_DYLIB")
    require(command_strings(data, 0xD) == [LOAD_PATH], "CI dylib install name mismatch")
    # Selectors only the repaired toolbar carries; diagnostic-only markers are gone by design.
    for marker in (b"contentRectForBounds:", b"onDismissKeyboard:", b"onSelectAll:", TARGET + b"\0"):
        require(marker in data, "Repair dylib marker missing: " + marker.decode().rstrip("\0"))
    return data


def original_inputs():
    require(sha(BASE.read_bytes()) == BASE_SHA256, "Original IPA digest mismatch")
    dictionary = (REPO / "dist/user_dictionary.db").read_bytes()
    require(sha(dictionary) == DICT_SHA256, "Dictionary digest mismatch")
    with zipfile.ZipFile(BASE) as z:
        entries = safe_zip(z)
        names = {i.filename for i in entries if not i.is_dir()}
        removed = {n for n in names if "_CodeSignature" in n.split("/") or "SC_Info" in n.split("/")}
        require(len(names) == 2051 and removed == SIGNATURE_FILES, "Original file/signature inventory mismatch")
        slots = []
        for name in sorted(names):
            data = z.read(name)
            if data[:4] != b"\xcf\xfa\xed\xfe":
                continue
            commands(data)
            for candidate in GROUPS:
                start = 0
                while True:
                    p = data.find(candidate + b"\0", start)
                    if p < 0:
                        break
                    slots.append((name, p, candidate))
                    start = p + 1
        require(sorted(slots) == sorted((FRAMEWORK, p, candidate) for p, candidate in GROUP_SLOTS), "Original group slot inventory mismatch")
    return dictionary


def patch_groups(data):
    result = bytearray(data)
    for offset, candidate in GROUP_SLOTS:
        span = len(candidate) + 1
        require(data[offset:offset + span] == candidate + b"\0", "Original group slot bytes mismatch")
        result[offset:offset + span] = TARGET + b"\0" * (span - len(TARGET))
    return bytes(result)


def expected_injection(data):
    table = commands(data)
    require(not any(LOAD_PATH in command_strings(data, c) for c in LIB_COMMANDS), "Original already loads libgkx")
    count, total = struct.unpack_from("<II", data, 16)
    name = LOAD_PATH.encode() + b"\0"
    size, pos = (24 + len(name) + 7) & ~7, 32 + total
    offsets = [struct.unpack_from("<I", data, q + 48)[0] for p, c, s in table if c == 0x19 for q in range(p + 72, p + s, 80) if struct.unpack_from("<Q", data, q + 40)[0] and struct.unpack_from("<I", data, q + 64)[0] & 0xFF not in (1, 0xC, 0x12)]
    require(offsets and pos + size <= min(offsets) and not any(data[pos:pos + size]), "Unsafe Mach-O insertion padding")
    cmd = (struct.pack("<6I", 0xC, size, 24, 2, 0x10000, 0x10000) + name).ljust(size, b"\0")
    result = bytearray(data)
    result[pos:pos + size] = cmd
    struct.pack_into("<II", result, 16, count + 1, total + size)
    require(len(result) == len(data), "Mach-O injection changed size")
    commands(result)
    return bytes(result)


def verify_package(ipa, artifact, dictionary):
    """Offline byte/structure half; production final MUST also revalidate CI identity."""
    with zipfile.ZipFile(BASE) as old, zipfile.ZipFile(ipa) as new:
        entries = safe_zip(new)
        names = [i.filename for i in entries]
        old_names = {i.filename for i in old.infolist() if not i.is_dir()}
        require(len(names) == 2050 and set(names) == (old_names - SIGNATURE_FILES) | {DYLIB, DICT}, "Unexpected added/removed files")
        require(new.read(DYLIB) == artifact and new.read(DICT) == dictionary, "Injected artifact/dictionary byte mismatch")
        require(plistlib.loads(new.read(APP + "/Info.plist"))["CFBundleShortVersionString"] == "2.3.19", "Version mismatch")
        extinfo = plistlib.loads(new.read(APP + "/PlugIns/Gboard.appex/Info.plist"))
        require(extinfo["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.keyboard-service", "Extension type mismatch")
        for exe, rp in zip(EXES, ("@executable_path/Frameworks", "@executable_path/../../Frameworks")):
            data = new.read(exe)
            require(command_strings(data, 0xC).count(LOAD_PATH) == 1 and sum(command_strings(data, c).count(LOAD_PATH) for c in LIB_COMMANDS) == 1, "Nonunique dylib load command")
            require(struct.unpack_from("<I", data, 12)[0] == 2, "Executable type mismatch")
            require(command_strings(data, 0x8000001C) == [rp], "Executable RPATH mismatch")
        changes, unchanged = [], 0
        for entry in entries:
            require(entry.create_system == 3 and stat.S_ISREG(entry.external_attr >> 16), "IPA member is not Unix regular file")
            mode = stat.S_IMODE(entry.external_attr >> 16)
            if entry.filename in (DYLIB, *EXES):
                require(mode == 0o755, "Executable/dylib mode mismatch")
            if entry.filename == DICT:
                require(mode == 0o644, "Dictionary mode mismatch")
            if entry.filename not in old_names:
                continue
            before, after = old.read(entry.filename), new.read(entry.filename)
            expected = expected_injection(before) if entry.filename in EXES else patch_groups(before) if entry.filename == FRAMEWORK else before
            require(after == expected, "Unexpected binary/resource change: " + entry.filename)
            require(mode == (stat.S_IMODE(old.getinfo(entry.filename).external_attr >> 16) or 0o644), "Unexpected permission change: " + entry.filename)
            if before != after:
                require(len(before) == len(after), "Binary size changed")
                different = sum(a != b for a, b in zip(before, after))
                require(EXPECTED_DIFFS.get(entry.filename) == different, "Binary changed-byte count mismatch")
                changes.append({"path":entry.filename, "different_bytes":different})
            else:
                unchanged += 1
        require({item["path"]:item["different_bytes"] for item in changes} == EXPECTED_DIFFS and unchanged == 2045, "Exact changed/unchanged inventory mismatch")
        data = new.read(FRAMEWORK)
        require(data.count(TARGET + b"\0") == 8 and not any(c + b"\0" in data for c in GROUPS), "Final group count mismatch")
        commands(data)
    return {"entries":len(names), "removed_signature_files":3, "removed_signature_paths":sorted(SIGNATURE_FILES), "group_slots":[{"offset":p,"original":c.decode()} for p,c in GROUP_SLOTS], "unchanged_resources":unchanged, "changes":changes}


def preflight():
    ci_identity()
    original_inputs()
    ART.mkdir(parents=True, exist_ok=True)
    archive = ART / "ci-artifact.zip"
    # Exclusive download preserves evidence of failures; reruns never overwrite it.
    with archive.open("xb") as target:
        subprocess.run(["gh", "api", "--method", "GET", f"repos/IamNewHands/gboard-gkx/actions/artifacts/{ARTIFACT}/zip"], stdout=target, check=True)
    data = artifact_bytes(archive)
    local = ART / "libgkx.dylib"
    if local.exists():
        require(local.read_bytes() == data, "Existing local CI dylib mismatch")
    else:
        with local.open("xb") as f:
            f.write(data)
    print(json.dumps({"phase":"preflight", "artifact_id":ARTIFACT, "run_id":RUN, "commit":SHA, "archive_sha256":DIGEST, "dylib_sha256":sha(data), "original_sha256":BASE_SHA256, "dictionary_sha256":DICT_SHA256}))


def final():
    ci_identity()
    artifact = artifact_bytes()
    require((ART / "libgkx.dylib").read_bytes() == artifact, "Local dylib differs from verified CI archive")
    dictionary = original_inputs()
    result = verify_package(IPA, artifact, dictionary)
    receipt = {"status":"PASS", "scope":"archive/arm64/file offsets/load paths/live CI identity/exact fixed-original byte diff; signing/device behavior not verified", "commit":SHA, "run_url":f"https://github.com/IamNewHands/gboard-gkx/actions/runs/{RUN}", "artifact_id":ARTIFACT, "artifact_archive_sha256":DIGEST, "original_sha256":BASE_SHA256, "ipa":str(IPA), "bytes":IPA.stat().st_size, "ipa_sha256":sha(IPA.read_bytes()), "dylib_sha256":sha(artifact), "dictionary_sha256":sha(dictionary), "version":"2.3.19", **result}
    receipt_path = REPO / f"dist/gboard-gkx-{TAG}-toolbar-space-repair-verification.json"
    with receipt_path.open("x", encoding="utf-8") as f:
        json.dump(receipt, f, ensure_ascii=False, indent=2)
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == "__main__":
    require(not sys.flags.optimize, "Verification refuses Python -O")
    require(len(sys.argv) == 6 and sys.argv[1] in ("preflight", "final"), "Usage: verifier preflight|final SHA RUN ARTIFACT DIGEST")
    configure(sys.argv[2:])
    {"preflight":preflight, "final":final}[sys.argv[1]]()
