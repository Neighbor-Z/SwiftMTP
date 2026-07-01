# `swiftmtp-cli` - CLI Usage Guide

This document is designed to help everyone including AI agents understand and utilize the `swiftmtp-cli` tool. `swiftmtp-cli` is a macOS command-line utility for interacting with MTP (Media Transfer Protocol) devices. It is located in `SwiftMTP.app/Contents/MacOS`.

## Overview

The tool operates in two primary modes:
1. **Stateless Mode**: Execute a single command and exit immediately. Ideal for scripting and automated tasks where keeping state is unnecessary.
2. **Interactive Shell (REPL)**: Maintains a stateful connection (e.g., current working directory). Extremely useful for sequential operations, avoiding the overhead of re-initializing the device connection for every command.

---

## 1. Stateless Commands

### 1.1 Global Options
- **`-h`, `--help`, `help`**: Display the usage menu and exit.
- **`-v`, `--version`, `version`**: Display version information, architecture, and OS details, then exit.

### 1.2 Device & Storage Discovery
Before interacting with files, you must identify the target `deviceId` and `storageId`.

- **List Connected Devices**
  ```bash
  swiftmtp-cli devices
  ```
  **Output format**: `<deviceId>\tdevice\t<Model> (<Manufacturer>)`
  *Note: The full `deviceId` is usually a string formatted as `vendorId|productId|serialNumber`. You can use any of the pipe-separated parts as `deviceId` for the following commands.*

- **List Device Storages**
  ```bash
  swiftmtp-cli storages <deviceId>
  ```
  **Output format**: `<storageId>\t<Storage Name> (<FreeSpace> free / <TotalSpace> total)`
  *Note: You will need both the `deviceId` and the `storageId` (usually an integer like `65537`) for file operations.*

### 1.3 File Operations

- **List Directory (`ls`)**
  ```bash
  swiftmtp-cli ls [-a] <deviceId> <storageId> <path>
  ```
  * `-a`, `-l`, `-al`, `-la`: Optional flags to include hidden files (files starting with `.`).
  * `<path>`: Must be an absolute path (e.g., `/` or `/DCIM`).
  
  **Output format**: `<DIR|     > <Size>  <DateModified>  <FileName>`
  *Note: Output is sorted alphabetically by file name, case-insensitively.*

- **Download Files/Directories (`pull`)**
  ```bash
  swiftmtp-cli pull <deviceId> <storageId> <remotePath> <localPath>
  ```
  Downloads the file or directory from the MTP device to the local macOS filesystem.

- **Upload Files/Directories (`push`)**
  ```bash
  swiftmtp-cli push <deviceId> <storageId> <localPath> <remotePath>
  ```
  Uploads the local file or directory to the specified path on the MTP device.

---

## 2. Interactive Shell (REPL) Mode

If you need to execute multiple commands on the same device sequentially, it is highly recommended to use the interactive shell.

**Start the Shell**:
```bash
swiftmtp-cli shell <deviceId> <storageId>
```

Upon launching, the tool will connect to the device and provide an interactive prompt:
```text
mtp:/>
```

### Available Shell Commands:
- **`pwd`**: Print the current working directory on the MTP device.
- **`ls [-a] [path]`**: List the contents of the current directory. You can provide an optional `path` to list a specific directory relative to the current path, and `-a` to show hidden files.
- **`cd <path>`**: Change the current working directory. The path can be relative to the current directory or an absolute path (starting with `/`).
- **`pull <remote_path> <local_path>`**: Download from the device. Relative remote paths are evaluated against the current working directory.
- **`push <local_path> <remote_path>`**: Upload to the device.
- **`help`**: Print the shell help menu.
- **`exit`** or **`quit`**: Terminate the session and exit the CLI.

---

## Technical Notes & Best Practices for AI Agents

1. **Path Resolution in Shell**: The shell correctly resolves absolute and relative paths. When in doubt about your current location, use `pwd`.
2. **Progress Bars**: During `pull` and `push` operations, a CLI progress bar will dynamically write to `stdout` using carriage returns (`\r`). The progress bar is automatically cleared from the terminal once the transfer completes. The completion message will be printed on a new line (`\nPull complete.` or `\nPull failed.`).
3. **Synchronous Execution**: Operations in `swiftmtp-cli` are strictly synchronous and block until completion, making it safe and predictable for automated scripting environments.
4. **Device Connection State**: Ensure that the device is fully attached and unlocked (some devices restrict MTP access when the screen is locked). If `devices` returns an empty list, verify physical connectivity and device permissions.
