# CloudTunnelX · 云隧通

基于 Cloudflare Tunnel 的全协议内网穿透可视化管理工具（Windows / Android 双端）。零公网 IP、零 VPS，完全替代命令行操作，通过图形界面完成隧道搭建、状态监控、域名管理与报错修复。

## 功能特性

- **临时穿透**：一键启动临时隧道，HTTP 类自动生成 Cloudflare 临时公网域名，适合快速测试
- **固定穿透**：绑定自有域名创建命名隧道，支持 Token 远程模式；DNS 路由通过 Cloudflare API 自动创建，无需登录网页控制台
- **全协议支持**：HTTP / HTTPS / WebSocket / TCP（SSH、RDP、MySQL、Redis 等）
- **域名管理**：应用内直接管理 Cloudflare 托管的 Zone 与 DNS 记录（增删改查）
- **状态监控**：实时连接状态、在线时长、流量统计（metrics），断线自动重连（3s/8s/15s 阶梯）
- **智能校验**：URL/端口格式、端口占用、本地服务连通性、DNS 托管（DoH）全维度校验，附带修复建议
- **日志与报错解析**：按隧道分类的实时日志，常见报错自动识别并给出修复方案
- **系统集成**：Windows 开机自启 + 系统托盘；Android 前台服务保活，通知栏一键停止
- **内核管理**：cloudflared 内核自动检测 / 一键下载，Android 支持手动导入

## 运行环境

| 平台 | 要求 |
| --- | --- |
| Flutter | 3.44.2 stable（Dart ^3.12） |
| Windows | Windows 10/11 x64 + Visual Studio 2022（C++ 桌面开发组件，仅构建需要） |
| Android | Android 7.0+，需自行导入 arm64 版 cloudflared 内核 |

**前置条件**：拥有自有域名，且域名 DNS 已托管至 Cloudflare（固定隧道必需）。

## 快速开始

```bash
# 1. 安装依赖
flutter pub get

# 2. 运行 Windows 桌面端
flutter run -d windows

# 3. 构建 Android APK
flutter build apk --release
```

首次使用流程：设置页下载/检测 cloudflared 内核 → （固定隧道）填写 Cloudflare API Token → 创建隧道并绑定子域名 → 启动。

## 项目结构

```
lib/
├── main.dart              # 入口：服务注入与 Provider 装配
├── window_setup.dart      # Windows 窗口/托盘初始化
├── android_service.dart   # Android 前台服务
├── core/
│   ├── models/            # 数据模型（隧道配置、状态、协议、Cloudflare Zone/DNS）
│   └── services/          # 核心服务层
│       ├── app_controller.dart     # 统一控制器（页面唯一操作入口）
│       ├── tunnel_service.dart     # 隧道进程调度、断线重连、流量统计
│       ├── cloudflare_service.dart # Cloudflare API 封装（Zone/DNS 管理）
│       ├── binary_manager.dart     # cloudflared 内核查找/下载/导入
│       ├── validation_service.dart # 全维度参数校验
│       ├── config_repository.dart  # hive_ce 持久化
│       ├── log_service.dart        # 日志收集
│       ├── error_catalog.dart      # 报错识别与修复方案
│       ├── tray_service.dart       # 系统托盘菜单
│       └── autostart_service.dart  # 开机自启
└── ui/
    ├── app_shell.dart     # 导航框架
    ├── theme.dart         # 主题
    └── pages/             # 总览 / 临时穿透 / 固定穿透 / 域名管理 / 日志 / 设置
```

## CI / CD

- `.github/workflows/ci.yml`：push/PR 触发 — 静态分析 + 单元测试 → Windows 构建 → Android 构建（APK/AAB）
- `.github/workflows/release.yml`：打 `v*` tag 触发 — 双端构建并打包发布到 GitHub Release（Windows zip 已内置 VC++ 运行时 DLL）

## 文档

详细设计见 `docs/` 目录：

- 需求文档（全协议版）
- 技术文档（Windows/Android 双平台）
- 项目命名方案

## 协议边界

- **支持**：HTTP、HTTPS、WebSocket、TCP
- **不支持**（cloudflared 官方限制）：UDP、QUIC、ICMP、广播/组播
