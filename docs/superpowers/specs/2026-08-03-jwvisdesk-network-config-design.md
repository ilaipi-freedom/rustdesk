# JwVisDesk Windows 定制配置设计

## 目标

在现有 Windows x64 Flutter 打包流程中生成与官方 RustDesk 可并存的 JwVisDesk 客户端。构建时从 Gitea secret `NETWORK_CONFIG` 注入 ID Server、Relay Server、API Server 和 Key；客户端默认使用 `access-mode=full`，锁定该设置并隐藏网络相关页面。

## 方案

工作流不解析服务器配置的编码格式，而是把 secret 原样写入发布目录旁的 `jwvisdesk-config.json`。Rust 启动时先执行官方 `custom.txt` 加载，再读取该 sidecar；sidecar 中的 `network-config` 交给现有 `custom_server::get_custom_server_from_string` 解析，随后转换为官方 `override-settings`。这样复用官方的反转 Base64URL、无签名 JSON 和签名 JSON 解析逻辑，避免 PowerShell 与 Rust 的编码实现分叉。

sidecar 强制设置 `app-name=JwVisDesk`，并覆盖：

- `custom-rendezvous-server`
- `relay-server`
- `api-server`
- `key`
- `access-mode=full`
- `enable-remote-printer=N`
- `hide-network-settings=Y`
- `hide-server-settings=Y`
- `hide-proxy-settings=Y`
- `hide-websocket-settings=Y`
- `hide-remote-printer-settings=Y`

构建脚本将 Flutter 产出的 `rustdesk.exe` 改名为 `JwVisDesk.exe`，portable packer 和 MSI 均使用该名称；`JwVisDesk.exe` 与 `jwvisdesk-config.json` 同目录部署。USB 虚拟显示和远程打印驱动文件仍保留在包内，但默认不启用远程打印，虚拟显示仅在显式使用功能时调用。

## 错误处理与兼容性

`NETWORK_CONFIG` 缺失、空值、JSON 无法解析或服务器配置无法解码时，工作流立即失败，避免产出会连接错误服务器的安装包。没有 sidecar 时程序保持官方行为，便于本地开发和已有发行流程继续工作。配置应用沿用官方设置分类和 `HARD_SETTINGS` 机制，`override-settings` 中的 `access-mode` 会被 `is_option_fixed` 锁定。

## 验证

增加真实的反转 Base64URL `NETWORK_CONFIG` 解码测试和配置应用测试；运行 `cargo test --lib custom_server`、`cargo test --lib`、`cargo fmt --check`，并对 PowerShell/YAML 进行语法和关键路径检查。推送后等待约 30 秒，再读取 Gitea Actions 最新日志，按首个决定性错误继续修复。
