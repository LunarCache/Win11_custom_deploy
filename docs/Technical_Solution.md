# WinPE Auto Deploy 技术方案

## 1. 方案目标

本方案用于构建一个基于 WinPE 的 Windows 11 自动部署体系，覆盖以下能力：

- 基于 Windows ADK 生成可复用的 WinPE 工作目录
- 将仓库内的自动化脚本和模板注入 `boot.wim`
- 从部署介质自动发现唯一合法的 `install.wim` 源
- 自动清空目标磁盘、重建 GPT 分区、应用系统镜像并重建引导
- 在系统首次登录阶段执行 Docker 初始化和业务载荷脚本

该方案面向 `amd64 + UEFI` 场景，不覆盖 Legacy BIOS 与多镜像源自动择优。

## 2. 总体架构

整体分为三个阶段：

1. 构建阶段  
   使用 `Build-WinPEAutoDeploy.ps1` 生成 WinPE 工作目录，并将 `deploy.cmd`、`unattend.xml`、`SetupComplete.cmd`、`firstboot.ps1` 等文件写入 `boot.wim`。

2. 部署阶段  
   目标机启动进入 WinPE 后，由 `startnet.cmd` 调用 `deploy.cmd`，完成镜像源扫描、磁盘分区、系统应用、WinRE 配置和文件下发。

3. 首次登录阶段  
   进入已部署系统后，`SetupComplete.cmd` 注册 `CodexFirstBoot`，`firstboot.ps1` 在用户登录时启动 Docker Desktop、等待 daemon 就绪，并执行 `load_images.bat` 与 `install_appstore.bat`。

## 3. 关键组件职责

### 3.1 构建与介质生成

- `scripts/Build-WinPEAutoDeploy.ps1`  
  负责创建 WinPE 工作目录、挂载 `boot.wim`、渲染模板令牌并注入运行时文件。

- `scripts/Prepare-WinPEUsb.ps1`  
  负责制作双分区部署 U 盘：FAT32 启动分区 + NTFS 镜像分区。

- `scripts/Generate-WinPEIso.ps1`  
  负责将现有工作目录打包成 ISO，可选注入 `install.wim` 与 payload。

### 3.2 WinPE 运行时

- `templates/startnet.cmd`  
  作为 WinPE 启动入口，调用 `wpeinit` 后进入主部署脚本。

- `templates/deploy.cmd`  
  作为核心部署引擎，完成源扫描、DiskPart 分区、`DISM /Apply-Image`、`BCDBoot`、WinRE 配置以及首登脚本下发。

- `templates/unattend.xml`  
  仅负责语言区域和 OOBE 网络页跳过，不承担完整无人值守安装逻辑。

### 3.3 首次登录自动化

- `templates/SetupComplete.cmd`  
  在系统安装末期启用 WinRE，并注册 `register-firstboot.ps1`。

- `templates/register-firstboot.ps1`  
  在 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` 下创建 `CodexFirstBoot`。

- `templates/firstboot.ps1`  
  首次登录时完成以下动作：
  - 注册 `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\DockerDesktopAutoStart`
  - 优先执行 `docker desktop start`
  - 必要时回退启动 `Docker Desktop.exe`
  - 等待 `Docker Desktop` 进程出现
  - 使用短窗口 `docker info` 检查 daemon 是否 ready
  - 依次执行 `load_images.bat` 与 `install_appstore.bat`

## 4. 数据与执行流

### 4.1 部署介质输入

部署介质最小结构如下：

```text
\sources\install.wim
\sources\winpe-autodeploy.tag
\payload\docker-images\load_images.bat          optional
\payload\docker-images\install_appstore.bat     optional
\payload\docker-images\*.tar                    optional
```

### 4.2 部署输出

部署完成后，目标系统中会生成以下关键内容：

```text
C:\Payload\DockerImages\...
C:\ProgramData\FirstBoot\firstboot.ps1
C:\ProgramData\FirstBoot\register-firstboot.ps1
C:\Windows\Setup\Scripts\SetupComplete.cmd
```

## 5. 日志设计

日志分为两层：

- 部署日志  
  - `X:\AutoDeploy.log`
  - `C:\Windows\Temp\AutoDeploy.log`
  - `\<deployment-media>\DeployLogs\AutoDeploy.log`

- 首次登录日志  
  - `C:\ProgramData\FirstBoot\setupcomplete.log`
  - `C:\ProgramData\FirstBoot\register-firstboot.log`
  - `C:\ProgramData\FirstBoot\firstboot.log`
  - `C:\ProgramData\FirstBoot\PayloadLogs\load_images_<timestamp>.log`
  - `C:\ProgramData\FirstBoot\PayloadLogs\install_appstore_<timestamp>.log`

其中 `install_appstore.bat` 的用户名和密码只在控制台显示，不写入持久化日志。

## 6. 风险与约束

- 部署脚本会清空目标磁盘，`Prepare-WinPEUsb.ps1` 会清空指定 U 盘。
- 运行时只接受“恰好一个”合法镜像源，避免错误介质被误用。
- 当前 Docker 自动化依赖 Docker Desktop，而不是独立的 Windows `dockerd` 服务方案。
- payload 自动执行仍按固定文件名发现：`load_images.bat`、`install_appstore.bat`。

## 7. 建议阅读顺序

建议按以下顺序阅读代码和脚本：

1. `scripts/Build-WinPEAutoDeploy.ps1`
2. `templates/deploy.cmd`
3. `templates/firstboot.ps1`
4. `scripts/Prepare-WinPEUsb.ps1`
5. `scripts/Generate-WinPEIso.ps1`

这条顺序对应“构建 -> 部署 -> 首登自动化 -> 介质分发”的真实技术链路。
