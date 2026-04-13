# 企业级全自动系统部署技术方案 (Enterprise Automated Deployment Architecture)

## 1. 项目背景与目标

本项目旨在提供一套高度可靠、可复用的企业级 Windows 系统全自动裸机部署（Wipe and Reload）框架。
核心目标包括：
*   **100% 零人工干预 (Zero-Touch)**：从插入介质开机到进入配置完毕的桌面，全程无需用户点击任何按钮或输入信息。
*   **统一的交付链路**：一套 WinPE 构建工程，同时支持物理机（双分区 USB 介质）和虚拟机（Standalone ISO）。
*   **强大的 Payload 分发能力**：不仅自动应用基础系统镜像 (`install.wim`)，还支持通用的载荷（如 Docker 镜像、应用安装脚本）随系统一起部署并在首次登录时自动执行。

## 2. 系统架构设计

本框架分为三个独立但紧密协作的阶段：**构建期 (Authoring)**、**WinPE 运行时 (Deployment)** 和 **Windows 首启期 (Post-Deployment)**。

### 2.1 构建期 (Authoring Phase)
负责基于 Windows ADK 生成定制化的 WinPE 环境及部署介质。

*   **`Build-WinPEAutoDeploy.ps1`**：核心预处理脚本。它利用 `copype` 准备工作目录，挂载 `boot.wim`，并将自动化执行引擎 (`deploy.cmd`, `startnet.cmd` 等) 及配置文件（如 `unattend.xml`）注入其中。该脚本执行极简原则，不向 WinPE 注入庞大的可选组件（OC），以保持启动介质极小的体积和极快的加载速度。
*   **`Prepare-WinPEUsb.ps1`**：物理机介质生成脚本。采用双分区架构：
    *   分区 1 (FAT32, 引导区)：存放 WinPE 系统，确保在所有 UEFI 固件上的最高兼容性。
    *   分区 2 (NTFS, 数据区)：突破 FAT32 的 4GB 单文件限制，用于存放体积庞大的 `install.wim`、防错标记文件 (`winpe-autodeploy.tag`) 以及可选的后置安装载荷文件夹 (`\payload\docker-images`)。
*   **`Generate-WinPEIso.ps1`**：虚拟机介质生成脚本。可将 WinPE 环境、`install.wim` 及载荷文件夹打包为一个独立的、自包含的 ISO 文件，便于在 Hyper-V 或 VMware 等虚拟化平台上进行测试和部署。

### 2.2 WinPE 运行时 (Deployment Phase)
目标机器从制作好的 U 盘或 ISO 启动后自动进入本阶段。

*   **`startnet.cmd`**：WinPE 的原生入口，初始化网络和即插即用设备后，立即移交控制权给执行引擎。
*   **`deploy.cmd`**：自动化部署的主引擎，执行以下严格序列：
    1.  **强一致性源发现**：扫描所有盘符，严格匹配包含 `\sources\install.wim` 和 `\sources\winpe-autodeploy.tag` 的路径。此设计防止了多磁盘环境下错误覆盖现有系统盘或意外应用非预期的系统镜像。
    2.  **磁盘分区重建**：调用 `diskpart /s diskpart-uefi.txt` 将目标磁盘（默认 Disk 0）彻底清空并转换为 GPT 格式，构建标准的 UEFI 布局：EFI 引导区 (S:)、MSR 保留区、Windows 系统区 (W:) 及独立的 Recovery 恢复区 (R:)。
    3.  **镜像应用与引导修复**：利用原生 `DISM` 释放镜像，并调用 `BCDBoot` 重建 EFI 引导。
    4.  **OOBE 旁路与 WinRE 配置**：
        *   将预先准备好的无人值守应答文件 (`unattend.xml`) 精准放置到新系统的 `W:\Windows\Panther` 目录下。
        *   直接调用刚刚解压好的目标系统盘内的工具 (`W:\Windows\System32\reagentc.exe`) 将系统恢复环境（WinRE）精准定位到恢复分区，无需依赖臃肿的 WinPE 组件。
    5.  **Payload 预埋**：将随介质分发的 `\payload\docker-images` 下的所有文件（脚本、Docker 镜像等）拷贝至新系统的 `C:\Payload\DockerImages`。
    6.  **持久化日志**：在重启前，将部署日志从内存盘备份到新系统盘 (`C:\Windows\Temp\AutoDeploy.log`)，确保部署过程可被追溯。

### 2.3 Windows 首启期 (Post-Deployment Phase)
操作系统第一次启动时的全自动收尾阶段。

*   **无人值守 OOBE (`unattend.xml`)**：由于 WinPE 阶段的预埋，Windows 会静默处理所有的开箱体验（语言选择、隐私协议、网络连接等），自动创建一个具有强密码的本地 `Admin` 账户，并通过 `<AutoLogon>` 机制直接无缝登录到桌面。
*   **系统初始化收尾 (`SetupComplete.cmd`)**：这是 Windows OOBE 结束时的钩子。它不仅会执行 `reagentc /enable` 真正激活 WinRE，更会向系统的 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` 注册表写入一个名为 `CodexFirstBoot` 的自启项，指向我们的终极执行脚本 `firstboot.ps1`。
*   **环境依赖保障与 Payload 执行 (`firstboot.ps1`)**：由于直接进入桌面，脚本立即被 `Run` 键触发。它的设计极其强健：
    1.  **依赖唤醒**：主动探测并启动 `Docker Desktop.exe` 的图形界面，强制触发底层的 WSL2 引擎和 Docker 服务的初始化。
    2.  **死循环等待**：通过不断轮询探测引擎状态（最多等待 5 分钟），确保环境 100% 就绪。若超时，脚本会主动 `exit 1`。由于使用的是持久的 `Run` 键而非 `RunOnce`，下一次用户登录或重启后，脚本会重试，直到成功。
    3.  **自动部署**：执行所有的前置动作后，脚本寻找并调起通用的用户自定义配置脚本（如 `install_appstore.bat`），完成最终的容器导入和业务系统（如 1Panel）启动。
    4.  **安全自毁**：当（且仅当）业务脚本正常退出后，`firstboot.ps1` 会删除自身的 `Run` 注册表键，并在目录下生成防重复的 `done.tag` 标记，宣告整个企业级系统交付流程圆满结束。

## 3. 安全性与可靠性考量

1.  **严格的灾难预防机制**：
    *   如果目标机器找不到标记文件，部署直接拒绝开始。
    *   如果目标磁盘（Disk 0）恰好被识别为系统当前引导磁盘，USB 制作脚本会抛出异常拒绝操作，防止“自杀式格式化”。
2.  **可追踪的统一日志系统**：
    *   每个核心步骤均前置了 `[INFO]`、`[WARNING]` 或 `[ERROR]` 标记。
    *   `deploy.cmd` 的日志记录在系统盘持久保存；首启自动化 (`firstboot.ps1`) 和注册表操作的详细记录持久保存在 `C:\ProgramData\FirstBoot\` 中，极大地方便了大规模部署时的故障排查。
3.  **避免死锁的机制**：
    *   废弃了早期依赖 WinPE 内部可选组件库的复杂方案，全面改用目标系统的原生工具（如直接调用解压后 C 盘内的 `reagentc.exe`），彻底消除了因 WinPE 环境语言包不一致或组件残缺带来的不稳定因素。