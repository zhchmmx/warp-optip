# 第三方二进制目录

这个目录用于放安装器需要的第三方二进制：

```text
vendor/warp                         # CloudflareWarpSpeedTest Linux 二进制
vendor/wgcf_<version>_linux_<arch>  # wgcf Linux 二进制
```

默认不提交到 git。`install.sh` 会：

- `warp`：优先复用这里的本地文件，缺失才下载；
- `wgcf`：默认每次查询并下载 GitHub 最新版，下载失败才回退到这里的本地文件。

因此：

- 普通联网安装不需要把二进制放进仓库；
- 离线安装可以手动把文件放到这里，它们会被 `.gitignore` 忽略；
- 如果要发布完全自包含的离线包，建议把 `vendor/` 一起打进 Release 压缩包，
  而不是提交进 git 历史。

如果这些文件已经被 git 跟踪，需要先停止跟踪：

```bash
git rm --cached vendor/warp vendor/wgcf_2.2.32_linux_amd64
git commit -m "stop tracking vendor binaries"
```

历史中的大文件不会因为 `.gitignore` 自动消失；如果确实要清理历史，需要使用
`git filter-repo` 或 BFG 并强制推送。
