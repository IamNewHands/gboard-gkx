#!/usr/bin/env python3
"""把已打包 IPA 里的 libgkx.dylib 换成新的，其余内容原样保留。

用法:
    python tools/swap_dylib.py --ipa dist/gboard-ntr-1.0-unsigned.ipa \
        --dylib new/libgkx.dylib --out /tmp/out.ipa

为什么需要它：
    CI 拿不到原始 Gboard IPA（仓库不含 Google 二进制，也不该含），所以 CI 里
    无法从头 inject。但 Release 上那份 IPA 已经是注入完成的成品——app group
    已改写、词库已内嵌、加载命令已写入。换 dylib 只需替换 Frameworks 下那一个
    文件并清掉旧签名，其余字节保持原样。

    inject.py 负责「从原始包生成成品」，本脚本负责「在成品上换 dylib」，
    两者共用同一套解包/重打包/权限保留代码，避免两份实现漂移。
"""

import argparse
import hashlib
import os
import shutil
import stat
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inject import DYLIB_NAME, repack, sha256, strip_signatures, unpack  # noqa: E402


def find_dylibs(root):
    """返回 IPA 里所有 libgkx.dylib 的相对路径（正常只有 1 个）。"""
    hits = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name == DYLIB_NAME:
                hits.append(os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/"))
    return sorted(hits)


def main():
    ap = argparse.ArgumentParser(description="在已打包 IPA 里替换 libgkx.dylib")
    ap.add_argument("--ipa", required=True, help="已注入的成品 IPA")
    ap.add_argument("--dylib", required=True, help="新的 libgkx.dylib")
    ap.add_argument("--out", required=True, help="输出 IPA（不得已存在）")
    args = ap.parse_args()

    for path, label in ((args.ipa, "IPA"), (args.dylib, "dylib")):
        if not os.path.isfile(path):
            raise SystemExit("%s 不存在: %s" % (label, path))
    if os.path.lexists(args.out):
        raise SystemExit("输出已存在，请指定新的 --out 文件名")

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="gkx-swap-", dir=out_dir)

    print("[1/4] 解包 %s" % args.ipa)
    metadata = unpack(args.ipa, workdir)

    targets = find_dylibs(workdir)
    if not targets:
        raise SystemExit("包内没有 %s，这不是注入过的成品包" % DYLIB_NAME)
    print("[2/4] 替换 %d 处 %s" % (len(targets), DYLIB_NAME))
    new_hash = sha256(args.dylib)
    for rel in targets:
        dst = os.path.join(workdir, rel.replace("/", os.sep))
        shutil.copy2(args.dylib, dst)
        os.chmod(dst, 0o755)
        metadata[rel] = (stat.S_IFREG | 0o755, (1980, 1, 1, 0, 0, 0))
        print("      %s" % rel)

    # dylib 换了，旧签名必然对不上；inject.py 打包时也会做同样的事。
    print("[3/4] 清理旧签名")
    removed = strip_signatures(workdir)
    print("      删除 %d 个签名目录" % len(removed))

    print("[4/4] 重新打包")
    repack(workdir, args.out, metadata)
    shutil.rmtree(workdir, ignore_errors=True)

    # 读回校验：包内 dylib 必须就是新传进去的那份字节。
    with zipfile.ZipFile(args.out) as z:
        inside = [n for n in z.namelist() if n == DYLIB_NAME or n.endswith("/" + DYLIB_NAME)]
        if not inside:
            raise SystemExit("输出包里找不到 %s" % DYLIB_NAME)
        for name in inside:
            got = hashlib.sha256(z.read(name)).hexdigest()
            if got != new_hash:
                raise SystemExit("包内 dylib 哈希不符: %s" % name)
        print("      包内 %s 校验通过 (%d 处)" % (DYLIB_NAME, len(inside)))
        print("      dylib sha256 = %s" % new_hash)
        print("      输出 %s (%.2f MB)" % (args.out, os.path.getsize(args.out) / 1048576))


if __name__ == "__main__":
    main()
