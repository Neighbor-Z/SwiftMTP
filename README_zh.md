<p align="center">
<img height="128" src="https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/MTPIcon-macOS-Default-128x128@2x.png">
</p>



<h1 align="center">SwiftMTP</h1>

<p align="center">
<a href="https://neighbor-z.github.io/swiftmtp-website">网页</a> ·
<a href="https://github.com/Neighbor-Z/SwiftMTP/releases">Releases</a>
</p>

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg?style=flat)](https://github.com/Neighbor-Z/SwiftMTP/)[![Platform: macOS 12.0+](https://img.shields.io/badge/Platform-macOS%2012.0%2B-blue.svg?style=flat)](https://github.com/Neighbor-Z/SwiftMTP/releases/latest)[![License: GPL](https://img.shields.io/badge/License-GPL-green.svg)](https://github.com/Neighbor-Z/SwiftMTP/blob/main/LICENSE)

**SwiftMTP** 是一个专为 macOS 打造的现代轻量级原生 MTP (Media Transfer Protocol) 文件管理器。基于 Swift 构建，旨在为 Android 设备或其他 MTP 设备提供流畅、稳定的文件传输体验。

启发自 OpenMTP， SwiftMTP 使用了优化的后端，实现相同高效传输体验的同时保持简洁轻量。

---

## 新推出

`swiftmtp-cli` 是一个功能强大、轻量级的 macOS 命令行工具，旨在轻松管理 MTP 设备。它用 Swift 原生构建，并由全新 `Gomtp` 后端提供支持，允许用户轻松使用 AI Agent 与连接的 Android 设备或相机快速交互。

![CLI](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/CLI.png)

`swiftmtp-cli` 位于 `SwiftMTP.app/Contents/MacOS`。

使用指南 `CLI_USAGE.md` 可通过“文件 - 导出 CLI 使用指南”菜单获得。

---

## 功能特性

- **即插即用**：自动识别连接的 MTP 设备并管理多存储分区。
- **原生浏览**：极速浏览设备目录，支持层级导航。
- **双向传输**：支持文件的上传与下载，包括 **拖拽功能 (Drag-and-Drop)**。
- **文件管理**：支持在设备上直接创建文件夹、重命名、删除文件。
- **实时反馈**：提供清晰的传输进度条与状态提示。
- **安全可靠**：不需要 ADB/USB 调试。
- **多语支持**:   利用 `Localizable.xcstrings` 支持多种语言。
- **自然语言搜索**：像对话一样自然地查找文件。只需输入您要查找的内容，例如“上周的照片”或“2024 年的工作文档”。
- **智能设备分析**：获取有关设备硬件状态、连接健康度以及潜在性能优化的深度见解。

### AI 细节

SwiftMTP 目前支持 2 种实现智能的方式：Apple Foundation 模型和 AI API 接入。

Apple Foundation 模型是 Apple 的一种设备端模型，它完全运行在本地。它具有固定的 4096 Tokens 的 Context 窗口，运行在 macOS 26 或更新版本且正确启用了 Apple Intelligence 的系统上。

AI API 接入同时支持 OpenAI 和 Anthropic 两种格式的 API。在 API Endpoint 中需要填写完整的地址，包括 `v1/messages` 或类似字符串。在 Model Name 中显式指定需要使用的模型，建议使用 `flash` 或类似模型。

### 隐私与安全

- **启用提示：** 初次在 SwiftMTP 设置中将 AI 模式从 `None` 设为其他选项时，SwiftMTP 会弹出一个 Notice 告知使用 AI 功能的注意事项。必须完整阅读并同意所有事项才能激活 AI 相关的功能。
- **本地推理：** 使用 Apple Foundation 模型进行的推理完全在设备端本地进行。
- **手动触发：** 所有 AI 相关的功能都需要手动触发。
- **仅元数据：** 在 API 模式下，项目的元数据（如名称、类型和修改日期等）以及设备的型号、USB 连接信息等将可能会按需发送给 AI 提供商用于建立 Context。您的文件内容**永远不会**被上传或共享。

---

## 截图

![Main UI](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/screenshot.png)

| "文件"菜单和快捷键                | "前往"菜单和快捷键              |
| ------------------------------------------------ | -------------------------------------------- |
| ![File Menu](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/file_menu_in_Tahoe.png) | ![Go Menu](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/go_menu_in_Tahoe.png) |

| 自然语言搜索                                      | 智能设备分析                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| ![NLSearch](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/NLSearch.png) | ![DIA](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/Device_Info_Analysis.png) |


---



|                  | SwiftMTP     | OpenMTP    | 开源项目A       | A from MAS | B from MAS                          | C from MAS |
| :--------------- | :----------- | ---------- | --------------- | :--------- | ----------------------------------- | ---------- |
| **架构**         | 🟢 通用       | ⚠️分开打包  | 🔴 仅 Apple 芯片 | 🟢 通用     | 🔴 仅 Apple 芯片                     | 🟢 通用     |
| **macOS 支持**   | 12.0+        | 11.0+      | 13.0+           | 🟢 10.15+   | 12.0+                               | 🔴 14.6+    |
| **体积**         | 🟢 < 20MB     | 🔴 360MB    | 🟢 < 20MB        | 🟢 < 20MB   | 🟢 < 20MB                            | 🟢 < 20MB   |
| **传输速度**     | 🟢 快         | 🟢 快       | 一般            | 🔴 慢       | 一般                                | 🔴 无法识别 |
| **用户界面**     | 🟢 Swift 原生 | 🔴 网页前端 | 原生            | 接近原生   | 接近原生                            | 接近原生   |
| **本地化**       | 🟢 多语       | ⚠️仅英语    | ⚠️仅英语         | ⚠️仅英语    | 🔴 只显示拉丁字母，其他字符 '?' 乱码 | ⚠️仅英语    |
| **拖拽功能**     | 🟢 支持       | 🟢 支持     | 🟢 支持          | -          | 🔴 不支持                            | -          |
| **ADB/USB 调试** | 🟢 无需       | 🟢 无需     | 🔴 需要          | -          | -                                   | -          |



## 项目结构

项目采用模块化设计，通过 C Shim 层实现 Swift 与底层驱动的通信：

```text
SwiftMTP/
├──SwiftMTP/             # Swift 主程序
│   ├── App/             # 应用入口 (SwiftMTPApp.swift)
│   ├── Views/           # SwiftUI 视图组件
│   ├── Models/          # 数据模型
│   └── Services/        # 核心逻辑
├──GomtpShim/            # C 语言桥接层 (Bridging Swift & MTP Kernel)            
├──lib/                  # 运行时依赖 (gomtp.dylib, libusb.dylib)
└──swiftmtp-cli/         # cli 相关
````

-----

## 快速开始

### 安装

下载[发行版](https://github.com/Neighbor-Z/SwiftMTP/releases/latest)或通过 homebrew 安装：

```bash
brew tap neighbor-z/swiftmtp && brew install --cask swiftmtp
```

### 构建

#### 条件

  - **Xcode 15.0+**
  - **macOS 12.0+**

#### 步骤

1.  打开 `SwiftMTP.xcodeproj`
3.  选择目标平台（macOS）
4.  点击 **Run**

-----

## 已实现

- [x] 拖拽传输功能
- [x] 自动识别设备并连接
- [x] 传输进度条与状态提示
- [x] 多选项目并导出
- [x] “前往”和“文件”菜单
- [x] 个人收藏
- [x] 空格键快速预览
- [x] 文件列表字体大小设置
- [x] 粘贴导入
- [x] 多设备连接 (v1.1)
- [x] 取消传输 (v1.1)

## 常见问题

**为什么我看到 OpenSession after reset: LIBUSB_ERROR_NOT_FOUND ？**

这可能是其他软件占用 MTP 资源或是设备连接问题。请先确保“预览”“图像捕捉”“Android 文件传输”等可能占用 MTP 资源的软件未在运行。对于“Android 文件传输”，即便它不在前台运行，它在系统后台也会运行“Android File Transfer Agent”以便实时检测 USB MTP 设备的接入并自动启动主程序。您可以在“活动监视器”中退出“Android File Transfer Agent”。随后，请重新连接或重启设备。

**macOS 无法验证此 App ？**

这是因为 App 没有以 Apple 希望的方式发布。Apple 要求开发者每年支付 99 USD 才能获得所谓的“安全签名”。请前往 系统设置-隐私与安全性，向下滚动至“安全性”部分并同意 App 运行。如果问题依旧存在，请打开“终端”执行下列命令，随后再重试打开 App。

```bash
sudo xattr -rd com.apple.quarantine /Applications/SwiftMTP.app
```

## 开源协议

本项目基于 [GPL](https://github.com/Neighbor-Z/SwiftMTP/blob/main/LICENSE) 开源。

-----

**关于 AI**： 涉及 AI 辅助；代码片段都经过了人工审查和测试。

**渴望反馈！** 如果你发现了 Bug 或有新功能建议，请提交 [Issue](https://github.com/Neighbor-Z/SwiftMTP/issues) 或 Pull Request。

**支持项目**: [☕️ Buy Me a Coffee](https://buymeacoffee.com/neighbor_z)
