#!/usr/bin/env python3
"""把 libgkx.dylib 注入 Gboard IPA 的键盘扩展，输出未签名 IPA。

用法:
    python tools/inject.py --ipa <原始.ipa> --dylib <libgkx.dylib> \
        --app-group group.zunbengege.top --out <输出.ipa>

--app-group 是必填项，不是可选优化：不改写的话 Gboard 拿不到 app group
容器，真机上打开应用即闪退、键盘锁在 26 键无法切九键。

实现要点:
  纯 Python 写 Mach-O 加载命令，不依赖 LIEF。
  新增的 LC_LOAD_DYLIB 直接覆盖 load commands 之后的填充区（不移动任何字节，
  因此所有 section/file offset 保持有效），只更新 ncmds 与 sizeofcmds。
"""

import argparse
import hashlib
import os
import plistlib
import shutil
import stat
import struct
import sys
import tempfile
import zipfile

LOAD_PATH = "@rpath/libgkx.dylib"
DYLIB_NAME = "libgkx.dylib"

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
MH_MAGIC_64 = 0xFEEDFACF

# Gboard 里请求的 app group；自签描述文件不会授权它们，容器返回 nil 会让
# -[NSFileManager contentsOfDirectoryAtURL:] 抛异常，主 App 启动即崩。
GROUP_CANDIDATES = [
    b"group.zunbengege.top",
    b"group.com.google.keyboard",
    b"group.com.google.common",
    b"group.com.google.gsuite",
    b"group.com.google.GoogleMobile",
    b"group.com.google.keyboard.enterprise",
    b"group.com.google.common.enterprise",
    b"group.com.google.gsuite.enterprise",
    b"group.com.google.GoogleMobile.enterprise",
]


def _is_macho(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return False
    return len(head) == 4 and struct.unpack("<I", head)[0] in (MH_MAGIC_64, 0xFEEDFACE)


def patch_app_groups(root, target):
    """把 Gboard 请求的 app group 字符串原地改写成描述文件授权的那个。

    目标字符串更短，所以直接在原位置写入并以 NUL 补齐剩余字节，
    不移动任何数据，section 偏移保持有效。
    """
    if not target.startswith("group.") or "\0" in target:
        raise ValueError("Invalid App Group identifier")
    tb = target.encode("utf-8")
    changed = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if not _is_macho(path):
                continue
            with open(path, "rb") as f:
                data = bytearray(f.read())
            hits = 0
            for cand in GROUP_CANDIDATES:
                if len(tb) > len(cand):
                    if cand + b"\0" in data:
                        raise ValueError("App Group target exceeds an existing string slot")
                    continue
                start = 0
                while True:
                    idx = data.find(cand, start)
                    if idx < 0:
                        break
                    if idx + len(cand) < len(data) and data[idx + len(cand)] == 0:
                        span = len(cand) + 1  # 含原 NUL
                        data[idx:idx + span] = (tb + b"\0" * (span - len(tb)))
                        hits += 1
                    start = idx + 1
            if hits:
                with open(path, "wb") as f:
                    f.write(data)
                changed.append((os.path.relpath(path, root), hits))
    return changed


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def unpack(ipa, dst):
    root = os.path.realpath(dst)
    metadata = {}
    seen = set()
    with zipfile.ZipFile(ipa) as z:
        for item in z.infolist():
            rel = item.filename.replace("\\", "/")
            target = os.path.realpath(os.path.join(root, rel))
            mode = item.external_attr >> 16
            if rel.startswith("/") or ":" in rel or ".." in rel.split("/") or os.path.commonpath([root, target]) != root or stat.S_ISLNK(mode):
                raise ValueError("Unsafe IPA archive entry")
            normalized = os.path.relpath(target, root).replace(os.sep, "/")
            if normalized in seen:
                raise ValueError("Duplicate IPA archive entry")
            seen.add(normalized)
            if not item.is_dir():
                metadata[normalized] = (stat.S_IFREG | (stat.S_IMODE(mode) or 0o644), item.date_time)
        z.extractall(dst)
    return metadata


def find_appex(payload):
    out = []
    for app in sorted(os.listdir(payload)):
        if not app.endswith(".app"):
            continue
        plugins = os.path.join(payload, app, "PlugIns")
        if not os.path.isdir(plugins):
            continue
        for name in sorted(os.listdir(plugins)):
            if name.endswith(".appex"):
                path = os.path.join(plugins, name)
                with open(os.path.join(path, "Info.plist"), "rb") as f:
                    info = plistlib.load(f)
                if info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.keyboard-service":
                    out.append(path)
    return out


def appex_executable(appex):
    with open(os.path.join(appex, "Info.plist"), "rb") as f:
        data = plistlib.load(f)
    name = data["CFBundleExecutable"]
    if not isinstance(name, str) or not name or name in (".", "..") or "/" in name or "\\" in name or ":" in name:
        raise ValueError("Invalid CFBundleExecutable")
    return os.path.join(appex, name)


def bundle_executable(bundle):
    """读任意 bundle（.app/.appex）的 CFBundleExecutable 并返回绝对路径。"""
    with open(os.path.join(bundle, "Info.plist"), "rb") as f:
        data = plistlib.load(f)
    name = data["CFBundleExecutable"]
    if not isinstance(name, str) or not name or name in (".", "..") or "/" in name or ":" in name:
        raise ValueError("Invalid CFBundleExecutable")
    return os.path.join(bundle, name)


# ---------------------------------------------------------------- Mach-O

def _parse_header(data):
    if len(data) < 32:
        raise ValueError("Mach-O header truncated")
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise ValueError("不是 64 位 Mach-O（magic 0x%08x）" % magic)
    cputype, cpusub, filetype, ncmds, sizeofcmds = struct.unpack_from("<iIIII", data, 4)
    if ncmds > sizeofcmds // 8 or 32 + sizeofcmds > len(data):
        raise ValueError("Mach-O load command table out of bounds")
    p = 32
    for _ in range(ncmds):
        if p + 8 > 32 + sizeofcmds:
            raise ValueError("Mach-O load command header truncated")
        cmd, size = struct.unpack_from("<II", data, p)
        if size < 8 or size % 8 or p + size > 32 + sizeofcmds:
            raise ValueError("Mach-O invalid load command size")
        if cmd == LC_SEGMENT_64:
            if size < 72:
                raise ValueError("Mach-O segment command truncated")
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            if 72 + nsects * 80 != size:
                raise ValueError("Mach-O section table size mismatch")
            for q in range(p + 72, p + size, 80):
                length = struct.unpack_from("<Q", data, q + 40)[0]
                offset, flags = struct.unpack_from("<I", data, q + 48)[0], struct.unpack_from("<I", data, q + 64)[0]
                if flags & 0xff not in (1, 0xc, 0x12) and length and (offset < 32 + sizeofcmds or offset + length > len(data)):
                    raise ValueError("Mach-O section data out of bounds")
        p += size
    if p != 32 + sizeofcmds:
        raise ValueError("Mach-O sizeofcmds does not match command table")
    return ncmds, sizeofcmds


def _commands(data):
    ncmds, _ = _parse_header(data)
    p = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, p)
        yield p, cmd, size
        p += size


def _command_string(data, p, size, minimum):
    if size < minimum:
        raise ValueError("Mach-O string command truncated")
    offset = struct.unpack_from("<I", data, p + 8)[0]
    if offset < minimum or offset >= size:
        raise ValueError("Mach-O string offset out of bounds")
    raw = bytes(data[p + offset:p + size])
    if b"\0" not in raw:
        raise ValueError("Mach-O command string is not terminated")
    return raw.split(b"\0", 1)[0].decode("utf-8")


def _existing_libraries(data, ncmds):
    names = []
    for p, cmd, cmdsize in _commands(data):
        if cmd in (LC_LOAD_DYLIB, 0x8000001F, 0x18, 0x80000018):
            names.append(_command_string(data, p, cmdsize, 24))
    return names


def _min_section_offset(data, ncmds):
    """load commands 之后、第一个真实 section 数据的文件偏移。"""
    lowest = None
    for p, cmd, cmdsize in _commands(data):
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            q = p + 72
            for _s in range(nsects):
                off = struct.unpack_from("<I", data, q + 48)[0]
                length = struct.unpack_from("<Q", data, q + 40)[0]
                flags = struct.unpack_from("<I", data, q + 64)[0] & 0xff
                if length and flags not in (1, 0xc, 0x12) and off > 0 and (lowest is None or off < lowest):
                    lowest = off
                q += 80
    return lowest


def add_load_command(binary_path, load_path=LOAD_PATH):
    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

    original = bytes(data)
    if not load_path or "\0" in load_path:
        raise ValueError("Invalid dylib load path")
    ncmds, sizeofcmds = _parse_header(data)
    if load_path in _existing_libraries(data, ncmds):
        return "already-present", ncmds, sizeofcmds

    name = load_path.encode("utf-8") + b"\0"
    cmdsize = 24 + len(name)
    cmdsize = (cmdsize + 7) & ~7  # 8 字节对齐

    insert_at = 32 + sizeofcmds
    limit = _min_section_offset(data, ncmds)
    if limit is None or insert_at + cmdsize > limit:
        raise SystemExit(
            "头部空隙不足：需要 %d 字节，可用 %s" % (cmdsize, "未知" if limit is None else limit - insert_at)
        )

    if any(data[insert_at:insert_at + cmdsize]):
        raise ValueError("Mach-O load command padding is not zero-filled")

    cmd = struct.pack(
        "<IIIIII",
        LC_LOAD_DYLIB,
        cmdsize,
        24,            # name offset（相对 load command 起点）
        2,             # timestamp
        0x00010000,    # current_version 1.0.0
        0x00010000,    # compatibility_version 1.0.0
    ) + name
    cmd = cmd.ljust(cmdsize, b"\0")

    data[insert_at:insert_at + cmdsize] = cmd
    struct.pack_into("<I", data, 16, ncmds + 1)
    struct.pack_into("<I", data, 20, sizeofcmds + cmdsize)

    _parse_header(data)
    if len(data) != len(original) or data[:16] != original[:16] or data[24:insert_at] != original[24:insert_at] or data[insert_at + cmdsize:] != original[insert_at + cmdsize:]:
        raise ValueError("Mach-O injection changed bytes outside header/padding")
    with open(binary_path, "wb") as f:
        f.write(data)
    return "added", ncmds + 1, sizeofcmds + cmdsize


def verify(binary_path):
    with open(binary_path, "rb") as f:
        data = f.read()
    ncmds, sizeofcmds = _parse_header(data)
    return _existing_libraries(data, ncmds), ncmds, sizeofcmds


# ---------------------------------------------------------------- package

def _rpaths(binary_path):
    """读 LC_RPATH。"""
    with open(binary_path, "rb") as f:
        data = f.read()
    out = []
    for p, cmd, cmdsize in _commands(data):
        if cmd == 0x8000001C:  # LC_RPATH
            out.append(_command_string(data, p, cmdsize, 12))
    return out


def resolve_frameworks_dir(appex, binary_path):
    """按 LC_RPATH 决定 dylib 应该放在哪个 Frameworks 目录。

    Gboard.appex 的 rpath 是 @executable_path/../../Frameworks，
    即主 App 的 Frameworks；放错到 appex 自己的 Frameworks 会 dyld 找不到。
    """
    app_root = os.path.dirname(os.path.dirname(appex))  # Payload/Gboard.app
    for rp in _rpaths(binary_path):
        if rp.rstrip("/") == "@executable_path/../../Frameworks":
            return os.path.join(app_root, "Frameworks"), rp
        if rp.rstrip("/") == "@executable_path/Frameworks":
            return os.path.join(appex, "Frameworks"), rp
    raise ValueError("Unsupported LC_RPATH: cannot resolve @rpath/libgkx.dylib")


def resolve_app_frameworks_dir(app, binary_path):
    """主 App 自己的 @executable_path 是 Gboard.app，@executable_path/Frameworks 落点即主 App Frameworks。

    与 appex 的 @executable_path/Frameworks（appex 内部目录）语义不同，必须独立解析。
    """
    for rp in _rpaths(binary_path):
        if rp.rstrip("/") in ("@executable_path/Frameworks", "@executable_path/../Frameworks"):
            return os.path.join(app, "Frameworks"), rp
    raise ValueError("Unsupported LC_RPATH for main app: cannot resolve @rpath/libgkx.dylib")


def strip_signatures(root):
    removed = []
    for dirpath, dirnames, _files in os.walk(root):
        for d in list(dirnames):
            if d in ("_CodeSignature", "SC_Info"):
                shutil.rmtree(os.path.join(dirpath, d))
                removed.append(os.path.join(dirpath, d))
                dirnames.remove(d)
    return removed


def repack(src_root, out_ipa, archive_metadata=None):
    out_ipa = os.path.abspath(out_ipa)
    os.makedirs(os.path.dirname(out_ipa), exist_ok=True)
    if os.path.lexists(out_ipa):
        raise FileExistsError("Output already exists; choose a new IPA filename")

    entries = []
    for dirpath, _dirnames, filenames in os.walk(src_root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            entries.append((os.path.relpath(full, src_root).replace(os.sep, "/"), full))
    entries.sort()

    with zipfile.ZipFile(out_ipa, "x", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel, full in entries:
            saved = (archive_metadata or {}).get(rel)
            mode, timestamp = saved if saved is not None else (os.stat(full).st_mode, (1980, 1, 1, 0, 0, 0))
            info = zipfile.ZipInfo(rel, date_time=timestamp)
            info.create_system = 3  # Unix: mode belongs to the IPA, not Windows extraction.
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | stat.S_IMODE(mode)) << 16
            with open(full, "rb") as f:
                z.writestr(info, f.read())
    return out_ipa


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--dylib", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument(
        "--app-group",
        required=True,
        help="把 Gboard 的 app group 改写成这个（描述文件授权的那个，例如 group.zunbengege.top）。"
             "必填：漏掉会导致真机启动闪退且键盘锁在 26 键。",
    )
    ap.add_argument("--dict", help="预置 Mozc user_dictionary.db 词库文件")
    ap.add_argument("--keep", help="保留解包目录（调试用）")
    args = ap.parse_args()

    if not os.path.isfile(args.dylib):
        raise SystemExit("dylib 不存在: %s" % args.dylib)

    if not os.path.isfile(args.ipa):
        raise SystemExit("IPA 不存在: %s" % args.ipa)
    if args.dict and not os.path.isfile(args.dict):
        raise SystemExit("词库不存在: %s" % args.dict)
    if not args.app_group.startswith("group.") or "\0" in args.app_group:
        raise SystemExit("--app-group 必须是 group. 开头的合法标识符: %r" % args.app_group)
    if os.path.lexists(args.out):
        raise SystemExit("输出已存在，请指定新的 --out 文件名")
    if args.keep:
        workdir = os.path.abspath(args.keep)
        os.makedirs(workdir, exist_ok=False)
    else:
        output_dir = os.path.dirname(os.path.abspath(args.out))
        os.makedirs(output_dir, exist_ok=True)
        workdir = tempfile.mkdtemp(prefix="gkx-inject-", dir=output_dir)

    print("[1/5] 解包 %s" % args.ipa)
    archive_metadata = unpack(args.ipa, workdir)
    payload = os.path.join(workdir, "Payload")
    if not os.path.isdir(payload):
        raise SystemExit("IPA 里没有 Payload/")

    appexes = find_appex(payload)
    if not appexes:
        raise SystemExit("没找到 .appex，无法注入")
    print("[2/5] 发现 %d 个扩展: %s" % (len(appexes), [os.path.basename(a) for a in appexes]))

    # 主 App 进程也有自己的 clearcut/Breakpad 上报链路，必须一并注入。
    # 它的 LC_RPATH 是 @executable_path/Frameworks，落点同样是主 App 的 Frameworks。
    main_app = os.path.dirname(appexes[0])
    main_app = os.path.dirname(main_app)  # PlugIns -> Gboard.app
    app_exe = bundle_executable(main_app)
    print("      注入 %s" % os.path.relpath(app_exe, workdir))
    app_result, _, app_sizeof = add_load_command(app_exe)
    app_libs, app_ncmds, _ = verify(app_exe)
    if LOAD_PATH not in app_libs:
        raise SystemExit("主 App 加载命令未写入，注入失败")
    print("        add=%s ncmds=%d sizeofcmds=0x%x 验证=OK" % (app_result, app_ncmds, app_sizeof))
    app_fw, app_rpath = resolve_app_frameworks_dir(main_app, app_exe)
    print("        rpath=%s -> 落点 %s" % (app_rpath, os.path.relpath(app_fw, workdir)))
    os.makedirs(app_fw, exist_ok=True)
    app_dst = os.path.join(app_fw, DYLIB_NAME)
    shutil.copy2(args.dylib, app_dst)
    os.chmod(app_dst, 0o755)
    archive_metadata[os.path.relpath(app_dst, workdir).replace(os.sep, "/")] = (
        stat.S_IFREG | 0o755, (1980, 1, 1, 0, 0, 0))

    for appex in appexes:
        exe = appex_executable(appex)
        rel = os.path.relpath(exe, workdir)
        print("      注入 %s" % rel)
        result, ncmds, sizeofcmds = add_load_command(exe)
        libs, ncmds2, _ = verify(exe)
        ok = LOAD_PATH in libs
        print("        add=%s ncmds=%d sizeofcmds=0x%x 验证=%s" % (result, ncmds2, sizeofcmds, "OK" if ok else "失败"))
        if not ok:
            raise SystemExit("加载命令未写入，注入失败")

        fw, used_rpath = resolve_frameworks_dir(appex, exe)
        os.makedirs(fw, exist_ok=True)
        dst = os.path.join(fw, DYLIB_NAME)
        shutil.copy2(args.dylib, dst)
        os.chmod(dst, 0o755)
        archive_metadata[os.path.relpath(dst, workdir).replace(os.sep, "/")] = (stat.S_IFREG | 0o755, (1980, 1, 1, 0, 0, 0))
        print("        rpath=%s -> 落点 %s" % (used_rpath, os.path.relpath(dst, workdir)))

        if args.dict and os.path.isfile(args.dict):
            dict_dst_fw = os.path.join(fw, "user_dictionary.db")
            dict_dst_appex = os.path.join(appex, "user_dictionary.db")
            shutil.copy2(args.dict, dict_dst_fw)
            shutil.copy2(args.dict, dict_dst_appex)
            for dict_dst in (dict_dst_fw, dict_dst_appex):
                archive_metadata[os.path.relpath(dict_dst, workdir).replace(os.sep, "/")] = (stat.S_IFREG | 0o644, (1980, 1, 1, 0, 0, 0))
            print("        词库注入: %s -> %s" % (args.dict, os.path.relpath(dict_dst_fw, workdir)))

    print("[3/5] 清理旧签名")
    removed = strip_signatures(workdir)
    print("      删除 %d 个签名目录" % len(removed))

    # 必做步骤：不改写的话 Gboard 拿不到 app group 容器，
    # 真机表现为打开应用即闪退、键盘锁在 26 键无法切九键。
    print("[3.5/5] 改写 app group -> %s" % args.app_group)
    changed = patch_app_groups(payload, args.app_group)
    if not changed:
        raise SystemExit("没有匹配到任何 app group 字符串，拒绝产出误导性安装包")
    for rel, hits in changed:
        print("      %s (%d 处)" % (rel, hits))

    print("[4/5] 重新打包")
    out = repack(workdir, args.out, archive_metadata)
    print("      输出 %s (%.2f MB)" % (out, os.path.getsize(out) / 1048576))

    print("[5/5] 完成")
    print("      sha256 = %s" % sha256(out))

    if args.keep is None:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
