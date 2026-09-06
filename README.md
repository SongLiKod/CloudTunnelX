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
- **内核管理**：cloudflared 内核自动检测 / 一键下载更新，Android 内核随 APK 内置
- **应用自升级**：Windows 应用内下载 zip 覆盖升级并自动重启；Android 应用内下载 APK 直接调起系统安装器

## 运行环境

| 平台 | 要求 |
| --- | --- |
| Flutter | 3.44.2 stable（Dart ^3.12） |
| Windows | Windows 10/11 x64 + Visual Studio 2022（C++ 桌面开发组件，仅构建需要） |
| Android | Android 7.0+，内核已随 APK 内置（arm64） |

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

### 登录授权（cert.pem）

固定隧道默认需要一次浏览器授权生成 `cert.pem`（设置页 → 登录授权（浏览器）），Windows 与 Android 均已支持一键完成：

- Windows：凭证存放在 `C:\Users\<用户名>\.cloudflared\cert.pem`
- Android：凭证存放在应用私有数据目录（`Android/data/com.cloudtunnelx/files/.cloudflared/`，应用自动创建，已注入可写 HOME 环境变量）

如果手机自动授权仍然失败（如网络限制），推荐改用 **Token 远程模式**（固定隧道创建时选择「Token 管理」），它**无需 cert.pem、无需登录授权**，两种获取方式：

1. **App 内一键生成**（推荐，免登录）：固定隧道创建弹窗选择「Token 管理」→ 点击 **「一键生成 Token（无需登录）」**，App 会用「域名管理」里已配置的 Cloudflare API Token 自动创建远程隧道并回填运行 Token
   - 前提：该 API Token 需含 **「Account › Cloudflare Tunnel › Edit」** 权限（创建步骤见下），创建后直接「保存并启动」
2. **控制台手动创建**：Cloudflare 控制台 → Zero Trust → Networks → Tunnels → Create a tunnel → 选「Cloudflare」保存 → 在隧道详情复制 Token → 粘贴到 App 的 Token 输入框

> **App 内一键生成前提（给 API Token 加 Tunnel 权限）**
> Cloudflare 控制台 → 右上角头像 → **My Profile → API Tokens → Create Token** → 用「Edit zone DNS」模板 → 在 **Account 权限**中增加 **Cloudflare Tunnel → Edit**（Zone 权限保留 DNS → Edit）→ 创建后到「域名管理」替换/添加该 Token。若未加 Tunnel 权限，生成时会提示权限不足。

## 内核管理（cloudflared）

cloudflared 官方下载地址：<https://github.com/cloudflare/cloudflared/releases>

### Windows

- 首次使用：设置页「内核管理」点击 **一键下载 / 更新内核** 即可自动下载最新版 `cloudflared-windows-amd64.exe` 到软件目录 `bin/`，全程无命令行窗口
- 更新内核：同样点击 **一键下载 / 更新内核**，自动以最新版覆盖旧内核，无需手动替换文件
- 也支持「自定义内核目录」：手动放入 `cloudflared.exe` 后点「重新检测」即可识别

### Android（更新内置内核）

> Android 10+ 出于安全（W^X 策略）禁止执行应用可写目录中的文件，导入模式不可用。内核必须以 `libcloudflared.so` 内置在 APK 的 jniLibs 中，运行时从系统安装目录（nativeLibraryDir，只读可执行）启动。

更新步骤：

1. **下载内核**：打开 <https://github.com/cloudflare/cloudflared/releases>，在最新 Release 的 Assets 中下载 **`cloudflared-linux-arm64`**（无后缀的二进制文件）
   - 也可以从 Termux 获取 Android 构建版（`pkg install cloudflared`），临时穿透更稳，可规避 `lookup … on [::1]:53` 类 DNS 报错
2. **重命名**：将下载文件改名为 **`libcloudflared.so`**（注意扩展名，不是 `.exe`，也不要加其他后缀）
3. **放入工程目录**：替换 `android/app/src/main/jniLibs/arm64-v8a/libcloudflared.so`
4. **重新构建安装**：
   - 开发调试：`flutter run`
   - 发布测试：`flutter build apk --release` 后安装新 APK
5. **验证**：安装后回到设置页「内核管理」点击 **重新检测**，应能识别出新版本号；若失败，请确认放入的是 arm64-v8a（aarch64）架构的文件

应用内也会在「设置 → 内核管理」中提供上述指引与一键下载按钮。

## 应用升级

设置页「检查更新」会通过 GitHub Releases API 检测新版本，检测到后可一键升级：

| 平台 | 升级方式 |
| --- | --- |
| Windows | 下载 zip → 自动解压覆盖 → 重启应用，无需手动替换 |
| Android | 应用内下载 APK（含进度）→ 直接调起系统安装器 |

> Android 应用内升级要求各版本签名一致：发布构建需在仓库 Secrets 配置 `ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS` 固定签名密钥，否则覆盖安装会提示"签名不一致"（需卸载旧版重新安装，会清除本地配置）。

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
│       ├── app_updater.dart        # 应用自升级（版本检测/下载/安装）
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
- `.github/workflows/release.yml`：发布构建，两种触发方式：
  - **推送 `v*` tag**（推荐）：`git tag v2.0.2 && git push origin v2.0.2` 自动构建并打包发布到 GitHub Release
  - **手动触发**（Actions 页面 Run workflow）：填写发布标签（如 `v2.0.2`），自动创建同名 tag 并发布 Release，无需预先建 tag
  - Windows zip 已内置 VC++ 运行时 DLL，可直接解压运行

## 文档

详细设计见 `docs/` 目录：

- 需求文档（全协议版）
- 技术文档（Windows/Android 双平台）
- 项目命名方案

## 协议边界

- **支持**：HTTP、HTTPS、WebSocket、TCP
- **不支持**（cloudflared 官方限制）：UDP、QUIC、ICMP、广播/组播