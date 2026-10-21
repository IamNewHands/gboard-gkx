#!/usr/bin/env python3
"""检查自签后的 IPA：签名、描述文件、entitlements、注入是否保留。"""

import io
import os
import plistlib
import struct
import sys
import zipfile

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_EMBEDDED_ENTITLEMENTS = 0xFADE7171
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
LC_CODE_SIGNATURE = 0x1D


def read_varint(data, i):
    shift = val = 0
    while True:
        c = data[i]
        i += 1
        val |= (c & 0x7F) << shift
        if not c & 0x80:
            return val, i
        shift += 7


def find_code_signature(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    p = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == LC_CODE_SIGNATURE:
            off, size = struct.unpack_from("<II", data, p + 8)
            return off, size
        p += cmdsize
    return None


def parse_superblob(blob):
    magic, length, count = struct.unpack_from(">III", blob, 0)
    out = {}
    for i in range(count):
        btype, boff = struct.unpack_from(">II", blob, 12 + i * 8)
        out.setdefault(btype, []).append(boff)
    return out


def dump_signature(binary_path, label):
    data = open(binary_path, "rb").read()
    found = find_code_signature(data)
    print(f"--- {label}")
    if not found:
        print("    没有 LC_CODE_SIGNATURE（未签名）")
        return None
    off, size = found
    blob = data[off:off + size]
    magic = struct.unpack_from(">I", blob, 0)[0]
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        print(f"    签名 magic=0x{magic:08x}（非常规 superblob）")
        return None
    idx = parse_superblob(blob)
    print(f"    签名块 {size} 字节, blob 类型: {sorted(idx)}")
    ent = None
    # 类型索引 5 = CSMAGIC_EMBEDDED_ENTITLEMENTS
    for boff in idx.get(5, []):
        m, ln = struct.unpack_from(">II", blob, boff)
        if m != CSMAGIC_EMBEDDED_ENTITLEMENTS:
            print(f"    类型5 magic=0x{m:08x}（非 entitlements）")
            continue
        payload = blob[boff + 8: boff + ln]
        try:
            ent = plistlib.loads(payload)
        except Exception as exc:  # noqa: BLE001
            print(f"    entitlements 解析失败: {exc}")
            continue
    if ent:
        print("    entitlements:")
        for k in sorted(ent):
            v = ent[k]
            if isinstance(v, (list, tuple)):
                v = list(v)
            print(f"      {k} = {v}")
    return ent


def parse_provision(path):
    raw = open(path, "rb").read()
    start = raw.find(b"<?xml")
    end = raw.find(b"</plist>")
    if start < 0 or end < 0:
        start = raw.find(b"bplist00")
        if start < 0:
            return None
        return plistlib.loads(raw[start:])
    return plistlib.loads(raw[start:end + 8])


def main(ipa):
    z = zipfile.ZipFile(ipa)
    names = z.namelist()
    print(f"=== {ipa}")
    print(f"条目 {len(names)}, 完整性 {z.testzip() is None}\n")

    app = "Payload/Gboard.app"
    print("=== 关键文件是否存在")
    for rel in [f"{app}/embedded.mobileprovision",
                f"{app}/_CodeSignature/CodeResources",
                f"{app}/PlugIns/Gboard.appex/embedded.mobileprovision",
                f"{app}/PlugIns/Gboard.appex/_CodeSignature/CodeResources",
                f"{app}/PlugIns/Gboard.appex/Frameworks/libgkx.dylib"]:
        print(f"  {'OK ' if rel in names else 'MISS'}  {rel}")
    print()

    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dist", "_inspect")
    os.makedirs(tmp, exist_ok=True)

    for rel, label in [(f"{app}/Gboard", "主 App 二进制"),
                       (f"{app}/PlugIns/Gboard.appex/Gboard", "扩展二进制")]:
        if rel not in names:
            continue
        p = os.path.join(tmp, os.path.basename(label).replace(" ", "_") + ".bin")
        with open(p, "wb") as f:
            f.write(z.read(rel))
        dump_signature(p, label)
        print()

    for rel, label in [(f"{app}/embedded.mobileprovision", "主 App 描述文件"),
                       (f"{app}/PlugIns/Gboard.appex/embedded.mobileprovision", "扩展描述文件")]:
        if rel not in names:
            continue
        p = os.path.join(tmp, "prov_" + str(abs(hash(label))) + ".plist")
        with open(p, "wb") as f:
            f.write(z.read(rel))
        try:
            d = parse_provision(p)
        except Exception as exc:  # noqa: BLE001
            print(f"--- {label}: 解析失败 {exc}\n")
            continue
        print(f"--- {label}")
        print(f"    Name: {d.get('Name')}")
        print(f"    TeamIdentifier: {d.get('TeamIdentifier')}")
        print(f"    AppIDName: {d.get('AppIDName')}")
        ents = d.get("Entitlements", {})
        for k in sorted(ents):
            print(f"      {k} = {ents[k]}")
        print(f"    ProvisionedDevices: {'有 %d 台' % len(d['ProvisionedDevices']) if d.get('ProvisionedDevices') else '无（企业/AppStore 型）'}")
        exp = d.get("ExpirationDate")
        print(f"    过期时间: {exp}")
        print()

    # 扩展的加载命令是否还在
    if f"{app}/PlugIns/Gboard.appex/Gboard" in names:
        data = z.read(f"{app}/PlugIns/Gboard.appex/Gboard")
        ncmds = struct.unpack_from("<I", data, 16)[0]
        p = 32
        libs = []
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, p)
            if cmd in (0xC, 0x18, 0x8000001F):
                no = struct.unpack_from("<I", data, p + 8)[0]
                libs.append(data[p + no:p + cmdsize].split(b"\0")[0].decode())
            p += cmdsize
        print("=== 扩展链接库")
        for l in libs:
            print("   " + l)


if __name__ == "__main__":
    main(sys.argv[1])
