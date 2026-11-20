#!/usr/bin/env python3
"""把打包好的未签名 IPA 发布到 GitHub Release，并刷新 Release 页面的发布时间。

用法:
    python tools/publish_release.py --asset dist/gboard-ntr-1.0-unsigned.ipa
    python tools/publish_release.py --asset dist/x.ipa --tag v1.0 --notes-file notes.md

为什么单独一个脚本：
    这个项目的发布惯例是「只保留一条 release、资产名固定、下载地址固定」，
    所以每次出包都是就地覆盖同一个资产，而不是新建 tag/release。
    但 gh release upload --clobber 只换文件，published_at 会一直停在 tag
    首次发布那天，Release 页面看起来像几周没更新。因此这里补一步
    「置草稿 -> 立刻发布」把 published_at 重置成本次时间（约 1 秒的
    下载链接 404 窗口，用户已接受）。

前置：gh 已登录且具备 repo 写权限；release 与 tag 必须已存在。
"""

import argparse
import json
import subprocess
import sys

DEFAULT_TAG = "v1.0"
DEFAULT_ASSET_NAME = "gboard-ntr-1.0-unsigned.ipa"


def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        sys.stderr.write(r.stdout or "")
        sys.stderr.write(r.stderr or "")
        raise SystemExit("gh %s failed (exit %d)" % (" ".join(args), r.returncode))
    return r.stdout


def main():
    ap = argparse.ArgumentParser(description="上传 IPA 到既有 Release 并刷新发布时间")
    ap.add_argument("--asset", required=True, help="本地 IPA 路径")
    ap.add_argument("--tag", default=DEFAULT_TAG, help="目标 release tag，默认 %s" % DEFAULT_TAG)
    ap.add_argument("--name", default=None, help="资产名，默认沿用本地文件名")
    ap.add_argument("--repo", default=None, help="owner/repo，默认取当前仓库")
    ap.add_argument("--notes-file", default=None, help="可选：用该文件覆盖 release 正文")
    args = ap.parse_args()

    import os
    if not os.path.isfile(args.asset):
        raise SystemExit("找不到资产文件: %s" % args.asset)
    name = args.name or os.path.basename(args.asset)
    repo_args = ["--repo", args.repo] if args.repo else []

    # 1. 覆盖上传（资产名固定，下载地址因此固定）
    gh("release", "upload", args.tag, args.asset, "--clobber", *repo_args)
    print("[1/4] 已上传 %s -> release %s" % (name, args.tag))

    # 2. 置草稿再发布，让 published_at 跟随本次出包时间
    if args.notes_file:
        gh("release", "edit", args.tag, "--notes-file", args.notes_file, *repo_args)
    gh("release", "edit", args.tag, "--draft", *repo_args)
    gh("release", "edit", args.tag, "--draft=false", *repo_args)
    print("[2/4] 已重置发布时间")

    # 3. 读回校验：资产存在、大小与本地一致
    info = json.loads(gh("release", "view", args.tag, "--json", "publishedAt,assets", *repo_args))
    size = os.path.getsize(args.asset)
    hit = [a for a in info.get("assets", []) if a.get("name") == name]
    if not hit:
        raise SystemExit("上传后 release 里找不到资产 %s" % name)
    got = hit[0].get("size")
    if got != size:
        raise SystemExit("资产大小不一致: 远端 %s / 本地 %s" % (got, size))
    print("[3/4] 资产校验通过: %s %d bytes" % (name, size))

    # 4. 打印固定下载地址与摘要
    digest = hit[0].get("digest") or "(该 gh 版本未返回 digest)"
    print("[4/4] published_at=%s" % info.get("publishedAt"))
    print("      sha256=%s" % digest)
    print("      下载: https://github.com/%s/releases/latest/download/%s"
          % (args.repo or "<owner/repo>", name))


if __name__ == "__main__":
    main()
