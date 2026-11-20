#!/usr/bin/env python3
"""把打包好的未签名 IPA 发布到 GitHub Release，并刷新 Release 页面的发布时间。

用法:
    python tools/publish_release.py --asset dist/gboard-ntr-1.0-unsigned.ipa
    python tools/publish_release.py --asset x.ipa --tag v1.0 --notes-file notes.md
    python tools/publish_release.py --asset x.ipa --refresh-sha   # 正文里的 SHA/体积跟着换

为什么单独一个脚本：
    这个项目的发布惯例是「只保留一条 release、资产名固定、下载地址固定」，
    所以每次出包都是就地覆盖同一个资产，而不是新建 tag/release。
    但 gh release upload --clobber 只换文件，published_at 会一直停在 tag
    首次发布那天，Release 页面看起来像几周没更新。因此这里补一步
    「置草稿 -> 立刻发布」把 published_at 重置成本次时间（约 1 秒的
    下载链接 404 窗口，用户已接受）。

    另一个坑：--clobber 会先删旧资产再传新的，网络抖一下就留下空资产列表。
    所以上传带重试，且最后一定读回校验大小与摘要。

前置：gh 已登录且具备 repo 写权限；release 与 tag 必须已存在。
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

DEFAULT_TAG = "v1.0"


def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        sys.stderr.write(r.stdout or "")
        sys.stderr.write(r.stderr or "")
        raise SystemExit("gh %s failed (exit %d)" % (" ".join(args), r.returncode))
    return r.stdout


def upload_with_retry(tag, asset, repo_args, attempts=3):
    """--clobber 会先删后传；中断会留下空资产列表，重跑即可恢复。"""
    last = ""
    for i in range(1, attempts + 1):
        r = subprocess.run(["gh", "release", "upload", tag, asset, "--clobber", *repo_args],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode == 0:
            return
        last = (r.stderr or r.stdout or "").strip()
        sys.stderr.write("[upload %d/%d 失败] %s\n" % (i, attempts, last.splitlines()[-1] if last else "?"))
        if i < attempts:
            time.sleep(3 * i)
    raise SystemExit("上传失败（已重试 %d 次）: %s" % (attempts, last))


def refresh_body(tag, repo_args, asset_name, size, digest):
    """把正文里的「文件/SHA-256」两行改成本次产物，避免用户下到校验不过的包。"""
    body = json.loads(gh("release", "view", tag, "--json", "body", *repo_args)).get("body") or ""
    if not body:
        return None
    mb = "%.2f MB" % (size / 1048576.0)
    new = re.sub(r"(文件：[^\n]*?)（[\d.]+ MB）", lambda m: "%s（%s）" % (m.group(1), mb), body)
    new = re.sub(r"(SHA-256：)[0-9a-fA-F]{64}", lambda m: m.group(1) + digest, new)
    new = re.sub(r"(- 文件：[^\n]*?)\n", lambda m: m.group(1) + "\n", new)
    if new == body:
        return None
    return new


def main():
    ap = argparse.ArgumentParser(description="上传 IPA 到既有 Release 并刷新发布时间")
    ap.add_argument("--asset", required=True, help="本地 IPA 路径")
    ap.add_argument("--tag", default=DEFAULT_TAG, help="目标 release tag，默认 %s" % DEFAULT_TAG)
    ap.add_argument("--name", default=None, help="资产名，默认沿用本地文件名")
    ap.add_argument("--repo", default=None, help="owner/repo，默认取当前仓库")
    ap.add_argument("--notes-file", default=None, help="可选：用该文件覆盖 release 正文")
    ap.add_argument("--refresh-sha", action="store_true",
                    help="把正文里的体积与 SHA-256 改成本次产物")
    ap.add_argument("--skip-upload", action="store_true",
                    help="跳过上传，只刷新时间与正文（用于已手工传过的情况）")
    args = ap.parse_args()

    if not os.path.isfile(args.asset):
        raise SystemExit("找不到资产文件: %s" % args.asset)
    name = args.name or os.path.basename(args.asset)
    size = os.path.getsize(args.asset)
    repo_args = ["--repo", args.repo] if args.repo else []

    # 1. 覆盖上传（资产名固定，下载地址因此固定）
    if args.skip_upload:
        print("[1/4] 跳过上传（--skip-upload）")
    else:
        upload_with_retry(args.tag, args.asset, repo_args)
        print("[1/4] 已上传 %s -> release %s" % (name, args.tag))

    # 2. 读回远端摘要，供正文刷新与最终校验使用
    info = json.loads(gh("release", "view", args.tag,
                         "--json", "publishedAt,assets,body", *repo_args))
    hit = [a for a in info.get("assets", []) if a.get("name") == name]
    if not hit:
        raise SystemExit("release 里找不到资产 %s（上传可能中断，重跑本脚本即可）" % name)
    got_size = hit[0].get("size")
    if got_size != size:
        raise SystemExit("资产大小不一致: 远端 %s / 本地 %s" % (got_size, size))
    digest_full = hit[0].get("digest") or ""
    digest = digest_full.split(":", 1)[1] if digest_full.startswith("sha256:") else ""

    # 3. 改正文（可选）+ 置草稿再发布，让 published_at 跟随本次出包时间
    if args.notes_file:
        gh("release", "edit", args.tag, "--notes-file", args.notes_file, *repo_args)
        print("[2/4] 正文已用 %s 覆盖" % args.notes_file)
    elif args.refresh_sha and digest:
        new_body = refresh_body(args.tag, repo_args, name, size, digest)
        if new_body:
            import tempfile
            with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
                f.write(new_body)
                tmp = f.name
            gh("release", "edit", args.tag, "--notes-file", tmp, *repo_args)
            os.unlink(tmp)
            print("[2/4] 正文体积/SHA-256 已刷新")
        else:
            print("[2/4] 正文无需刷新")
    else:
        print("[2/4] 正文未改动")

    gh("release", "edit", args.tag, "--draft", *repo_args)
    gh("release", "edit", args.tag, "--draft=false", *repo_args)

    # 4. 最终读回
    info = json.loads(gh("release", "view", args.tag,
                         "--json", "publishedAt,isDraft,assets", *repo_args))
    hit = [a for a in info.get("assets", []) if a.get("name") == name][0]
    print("[3/4] published_at=%s draft=%s" % (info.get("publishedAt"), info.get("isDraft")))
    print("      资产 %s %d bytes" % (name, hit.get("size")))
    print("      sha256=%s" % (hit.get("digest") or "(该 gh 版本未返回 digest)"))
    print("[4/4] 下载: https://github.com/%s/releases/latest/download/%s"
          % (args.repo or "<owner/repo>", name))


if __name__ == "__main__":
    main()
