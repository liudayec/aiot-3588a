#!/usr/bin/env python3
"""Generate a lightweight index of upstream GitHub Releases.

The firmware assets are intentionally not copied into this fork. The upstream
release is currently far beyond practical GitHub repository storage limits, so
the index links directly to each upstream asset.
"""

from __future__ import annotations

import json
import os
import urllib.request
from pathlib import Path
from typing import Any

UPSTREAM_OWNER = "yifengyou"
UPSTREAM_REPO = "aiot-3588a"
OUTPUT = Path("UPSTREAM_RELEASES.md")


def get_json(url: str, token: str) -> tuple[Any, str | None]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "aiot-3588a-fork-sync",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)
        link = response.headers.get("Link", "")
    next_url = None
    for part in link.split(","):
        if 'rel="next"' in part:
            next_url = part.split(";", 1)[0].strip().strip("<>")
            break
    return data, next_url


def human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.1f} {unit}"
        value /= 1024
    raise AssertionError("unreachable")


def main() -> None:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("GH_TOKEN or GITHUB_TOKEN is required")

    releases: list[dict[str, Any]] = []
    url: str | None = (
        f"https://api.github.com/repos/{UPSTREAM_OWNER}/{UPSTREAM_REPO}"
        "/releases?per_page=100"
    )
    while url:
        page, url = get_json(url, token)
        releases.extend(page)

    releases.sort(
        key=lambda item: item.get("published_at") or item.get("created_at") or "",
        reverse=True,
    )

    total_assets = sum(len(item.get("assets", [])) for item in releases)
    total_bytes = sum(
        int(asset.get("size", 0))
        for item in releases
        for asset in item.get("assets", [])
    )

    lines = [
        "# AIoT-3588A 上游固件发布索引",
        "",
        "本文件由 GitHub Actions 自动生成。源码、分支和标签会同步到本 fork；"
        "固件二进制仍托管在原作者的上游 Release 中，下载链接直指上游。",
        "",
        f"- 发布数：{len(releases)}",
        f"- 固件文件数：{total_assets}",
        f"- 文件总大小：{human_size(total_bytes)}",
        f"- 上游仓库：https://github.com/{UPSTREAM_OWNER}/{UPSTREAM_REPO}",
        "",
    ]

    for release in releases:
        title = release.get("name") or release.get("tag_name") or "Untitled"
        tag = release.get("tag_name") or ""
        html_url = release.get("html_url") or ""
        published = release.get("published_at") or release.get("created_at") or ""
        assets = sorted(
            release.get("assets", []),
            key=lambda item: item.get("name", ""),
        )

        lines.extend(
            [
                f"## {title}",
                "",
                f"- Tag: [`{tag}`]({html_url})",
                f"- Published: {published}",
                f"- Assets: {len(assets)}",
                "",
            ]
        )

        if not assets:
            lines.extend(["_该发布没有附件。_", ""])
            continue

        lines.extend(
            [
                "| 文件 | 大小 | 下载 |",
                "|---|---:|---|",
            ]
        )
        for asset in assets:
            name = str(asset.get("name", "")).replace("|", "\\|")
            size = human_size(int(asset.get("size", 0)))
            download_url = asset.get("browser_download_url", "")
            lines.append(f"| `{name}` | {size} | [下载]({download_url}) |")
        lines.append("")

    OUTPUT.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
