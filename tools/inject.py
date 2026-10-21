#!/usr/bin/env python3
"""把 libgkx.dylib 注入 Gboard IPA 的键盘扩展，输出未签名 IPA。

用法:
    python tools/inject.py --ipa <原始.ipa> --dylib <libgkx.dylib> --out <输出.ipa>

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
                    continue  # 目标更长，无法原地替换
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
    with zipfile.ZipFile(ipa) as z:
        z.extractall(dst)


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
                out.append(os.path.join(plugins, name))
    return out


def appex_executable(appex):
    with open(os.path.join(appex, "Info.plist"), "rb") as f:
        data = plistlib.load(f)
    return os.path.join(appex, data["CFBundleExecutable"])


# ---------------------------------------------------------------- Mach-O

def _parse_header(data):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("不是 64 位 Mach-O（magic 0x%08x）" % magic)
    cputype, cpusub, filetype, ncmds, sizeofcmds = struct.unpack_from("<iIIII", data, 4)
    return ncmds, sizeofcmds


def _existing_libraries(data, ncmds):
    names = []
    p = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd in (LC_LOAD_DYLIB, 0x8000001F, 0x18):
            name_off = struct.unpack_from("<I", data, p + 8)[0]
            raw = data[p + name_off:p + cmdsize].split(b"\0")[0]
            names.append(raw.decode("utf-8", "replace"))
        p += cmdsize
    return names


def _min_section_offset(data, ncmds):
    """load commands 之后、第一个真实 section 数据的文件偏移。"""
    lowest = None
    p = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, p + 64)[0]
            q = p + 72
            for _s in range(nsects):
                off = struct.unpack_from("<I", data, q + 48)[0]
                if off > 0 and (lowest is None or off < lowest):
                    lowest = off
                q += 80
        p += cmdsize
    return lowest


def add_load_command(binary_path, load_path=LOAD_PATH):
    with open(binary_path, "rb") as f:
        data = bytearray(f.read())

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
    ncmds, _ = _parse_header(data)
    out = []
    p = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == 0x8000001C:  # LC_RPATH
            off = struct.unpack_from("<I", data, p + 8)[0]
            out.append(data[p + off:p + cmdsize].split(b"\0")[0].decode("utf-8", "replace"))
        p += cmdsize
    return out


def resolve_frameworks_dir(appex, binary_path):
    """按 LC_RPATH 决定 dylib 应该放在哪个 Frameworks 目录。

    Gboard.appex 的 rpath 是 @executable_path/../../Frameworks，
    即主 App 的 Frameworks；放错到 appex 自己的 Frameworks 会 dyld 找不到。
    """
    app_root = os.path.dirname(os.path.dirname(appex))  # Payload/Gboard.app
    for rp in _rpaths(binary_path):
        if "../../Frameworks" in rp:
            return os.path.join(app_root, "Frameworks"), rp
        if rp.rstrip("/").endswith("@executable_path/Frameworks") or rp == "@executable_path/Frameworks":
            return os.path.join(appex, "Frameworks"), rp
    # 兜底：主 App 的 Frameworks
    return os.path.join(app_root, "Frameworks"), "<no rpath>"


def strip_signatures(root):
    removed = []
    for dirpath, dirnames, _files in os.walk(root):
        for d in list(dirnames):
            if d in ("_CodeSignature", "SC_Info"):
                shutil.rmtree(os.path.join(dirpath, d))
                removed.append(os.path.join(dirpath, d))
                dirnames.remove(d)
    return removed


def repack(src_root, out_ipa):
    out_ipa = os.path.abspath(out_ipa)
    os.makedirs(os.path.dirname(out_ipa), exist_ok=True)
    if os.path.exists(out_ipa):
        os.remove(out_ipa)

    entries = []
    for dirpath, _dirnames, filenames in os.walk(src_root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            entries.append((os.path.relpath(full, src_root).replace(os.sep, "/"), full))
    entries.sort()

    with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel, full in entries:
            info = zipfile.ZipInfo(rel)
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = os.stat(full).st_mode
            info.external_attr = ((mode & 0xFFFF) if stat.S_ISREG(mode) else 0o644) << 16
            with open(full, "rb") as f:
                z.writestr(info, f.read())
    return out_ipa


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--dylib", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--app-group", help="把 Gboard 的 app group 改写成这个（描述文件授权的那个）")
    ap.add_argument("--keep", help="保留解包目录（调试用）")
    args = ap.parse_args()

    if not os.path.isfile(args.dylib):
        raise SystemExit("dylib 不存在: %s" % args.dylib)

    workdir = args.keep or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist", "_work")
    workdir = os.path.abspath(workdir)
    if os.path.isdir(workdir):
        shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir, exist_ok=True)

    print("[1/5] 解包 %s" % args.ipa)
    unpack(args.ipa, workdir)
    payload = os.path.join(workdir, "Payload")
    if not os.path.isdir(payload):
        raise SystemExit("IPA 里没有 Payload/")

    appexes = find_appex(payload)
    if not appexes:
        raise SystemExit("没找到 .appex，无法注入")
    print("[2/5] 发现 %d 个扩展: %s" % (len(appexes), [os.path.basename(a) for a in appexes]))

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
        print("        rpath=%s -> 落点 %s" % (used_rpath, os.path.relpath(dst, workdir)))

    print("[3/5] 清理旧签名")
    removed = strip_signatures(workdir)
    print("      删除 %d 个签名目录" % len(removed))

    if args.app_group:
        print("[3.5/5] 改写 app group -> %s" % args.app_group)
        changed = patch_app_groups(payload, args.app_group)
        if not changed:
            print("      警告：没有命中任何 app group 字符串")
        for rel, hits in changed:
            print("      %s (%d 处)" % (rel, hits))

    print("[4/5] 重新打包")
    out = repack(workdir, args.out)
    print("      输出 %s (%.2f MB)" % (out, os.path.getsize(out) / 1048576))

    print("[5/5] 完成")
    print("      sha256 = %s" % sha256(out))

    if args.keep is None:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
