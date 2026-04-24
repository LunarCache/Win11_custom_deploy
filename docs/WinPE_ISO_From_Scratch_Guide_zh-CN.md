# Windows 11 WinPE 自动部署 ISO 制作指南

## 1. 文档目的

本文档面向本仓库的实施、交付与镜像制作人员，说明如何基于当前项目从零开始制作一套可用于 Windows 11 自动部署的 ISO 镜像，并补齐当前仓库未脚本化提供的 `install.wim` 捕获流程。

本文档严格以当前仓库实现为准，覆盖以下完整链路：

1. 准备参考机并固化系统内容
2. 执行 `Sysprep` 泛化
3. 导出纯净 WinPE ISO
4. 使用纯净 WinPE 捕获 `install.wim`
5. 基于项目脚本构建自定义 WinPE 工作目录
6. 把 `install.wim` 与可选载荷打包进最终 ISO
7. 在虚拟机或目标硬件上验证自动部署结果

## 1.1 项目链接

- GitHub 仓库地址：https://github.com/LunarCache/Win11_custom_deploy
- 本地仓库路径：`C:\Users\ERAZER\workspace\Intern\Win11_custom_deploy`

## 2. 仓库内关键文件与职责

### 2.1 scripts 目录

- `scripts/Build-WinPEAutoDeploy.ps1`
  - 负责构建项目专用 WinPE 工作目录。
  - 通过 `copype.cmd` 建立标准 WinPE 目录树。
  - 挂载 `media\sources\boot.wim`。
  - 把 `deploy.cmd`、`startnet.cmd`、`unattend.xml` 以及首登自动化脚本注入 `Windows\System32`。
  - 可选通过 `-DriversDirectory` 把离线驱动目录嵌入到 `boot.wim` 根目录下的 `X:\drivers-payload`。
  - 分区脚本由 `deploy.cmd` 动态生成，不再使用独立的 `diskpart-uefi.txt` 模板文件。
  - 仅注入运行逻辑，不会把 `install.wim` 直接写进 `boot.wim`。

- `scripts/Generate-WinPEIso.ps1`
  - 把现有 WinPE 工作目录打包为 ISO。
  - 可选把 `install.wim` 和 `payload\docker-images` 注入临时 staging 树后再打包。
  - 不污染原始 `WinPEWorkDir\media` 内容。

- `scripts/Prepare-WinPEUsb.ps1`
  - 制作双分区 U 盘。
  - 第一个分区为 FAT32 启动分区，第二个分区为 NTFS 数据分区。
  - 把 `install.wim`、`winpe-autodeploy.tag` 和可选载荷写入数据分区。
  - 该脚本会清空所选 USB 磁盘。

- `scripts/Export-CleanWinPEIso.ps1`
  - 导出不带项目自动化逻辑的纯净 WinPE ISO。
  - 适用于参考机维护、故障恢复和抓取 `install.wim`。
  - 这是补齐捕获流程时最关键的脚本。

- `scripts/Common-WinPEHelpers.ps1`
  - 负责 ADK 环境变量设置、外部命令调用、临时目录创建、标记文件写入和 payload 复制等公共能力。

### 2.2 templates 目录

- `templates/startnet.cmd`
  - WinPE 启动后的最小入口。
  - 先执行 `wpeinit`，再调用 `X:\Windows\System32\deploy.cmd`。

- `templates/deploy.cmd`
  - WinPE 内的主部署脚本。
  - 从 `C:` 到 `Z:` 扫描唯一合法镜像源。
  - 合法源必须同时存在 `\sources\install.wim` 与 `\sources\winpe-autodeploy.tag`。
  - 动态生成 DiskPart 脚本并清空目标盘，创建可配置的 GPT 分区布局（EFI、MSR、Windows、可选 Data、Recovery）。
  - 使用 `DISM /Apply-Image` 应用指定索引。
  - 使用 `BCDBoot` 重建 UEFI 启动文件。
  - 如果 `X:\drivers-payload` 存在，则使用 `DISM /Add-Driver /Recurse` 注入离线驱动。
  - 把 `unattend.xml`、`SetupComplete.cmd` 与首登脚本注入到部署后的系统。
  - 如果源介质包含 `\payload\docker-images`，则复制到 `W:\Payload\DockerImages`。
  - 把日志保存到 WinPE RAM 盘、已部署系统和源介质。

- `templates/unattend.xml`
  - 配置 OOBE 跳过：隐藏网络设置和隐私设置页面。账户创建页面保持可见。
  - 不配置语言、区域、产品密钥或其他 OOBE 应答。

- `templates/SetupComplete.cmd`
  - 在部署后启用 WinRE，随后执行 `register-firstboot.ps1` 注册首登自动化任务。

- `templates/register-firstboot.ps1`
  - 向 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` 注册 `CodexFirstBoot`。
  - 若检测到 Docker Desktop，则同时注册 `HKLM\...\Run\DockerDesktopAutoStart`。

- `templates/firstboot-launcher.vbs`
  - 用隐藏窗口方式启动 `firstboot.ps1`，避免登录时先弹出空白控制台。

- `templates/firstboot.ps1`
  - 在用户首次成功登录后执行。
  - 检测 `C:\Payload\DockerImages\NN-name\` 目录。
  - 尝试启动并等待 Docker Desktop 就绪。
  - 顺序执行每个服务目录中的 `load_images.bat` 和 `install_service.bat`。
  - 对名称匹配 `*win11-install` 的服务显示 1Panel 凭据窗口，对名称匹配 `*CIKE-install` 的服务显示 CIKE 成功信息窗口。
  - 所有脚本成功后写入 `done.tag` 并移除 Run 项；失败则保留 Run 项，在下次登录继续重试。

## 3. 当前方案的重要约束

- 仅支持 `amd64`。
- 仅支持 UEFI，不支持 Legacy BIOS。
- `Prepare-WinPEUsb.ps1` 会清空目标 USB 盘。
- `deploy.cmd` 会清空目标设备磁盘。
- 自动部署要求运行时只发现一个合法镜像源；若找到零个或多个，部署将中止。
- `Build-WinPEAutoDeploy.ps1` 不负责生成 `install.wim`。因此参考机镜像捕获必须作为交付前置流程单独执行。

## 4. 环境与前置条件

### 4.1 构建主机要求

- Windows 主机
- 已安装 Windows ADK 与 WinPE Add-on
- 使用管理员权限打开 PowerShell
- 具备足够的本地磁盘空间，建议至少 30 GB 空闲空间，用于 WinPE 工作目录、临时 staging 目录和 `install.wim`

脚本默认 ADK 根目录为：

```text
C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit
```

### 4.1.1 Windows ADK 与 WinPE Add-on 安装流程

根据微软官方当前文档，制作本项目所需 WinPE 介质时，必须先安装 Windows ADK，再安装与之匹配版本的 Windows PE Add-on。两者版本必须对应，且 ADK 至少需要安装 `Deployment Tools` 组件。

建议原则：

- 如果条件允许，优先选择与目标 Windows 版本相匹配的 ADK
- 以微软官方 ADK 下载页为准选择版本，不在本文档中固定某个最新版本号
- 如果所选 ADK 版本发布了 servicing patch，应按微软官方说明安装对应补丁

推荐执行顺序如下：

1. 打开微软官方 ADK 下载页，确认适合当前目标 Windows 版本的 ADK 版本  
   `https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install`
2. 下载对应版本的 `Windows ADK`
3. 运行 ADK 安装程序
4. 在功能选择界面至少勾选 `Deployment Tools`
5. 完成 ADK 安装
6. 回到同一官方页面，下载与该 ADK 完全匹配版本的 `Windows PE add-on`
7. 运行 `Windows PE add-on` 安装程序并完成安装
8. 如所选 ADK 版本支持补丁机制，再访问微软官方 ADK patch 页面，安装最新补丁  
   `https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-servicing`
9. 安装完成后，重新打开一个管理员 PowerShell 窗口，验证本项目脚本能否找到默认 ADK 路径

安装时建议只保留本项目必需组件，最小集合如下：

- `Deployment Tools`
- `Windows PE add-on`

若安装后本项目脚本无法识别 ADK，优先检查以下项：

- ADK 是否安装在默认路径
- 是否先安装 ADK 再安装 WinPE Add-on
- ADK 与 WinPE Add-on 版本是否一致
- PowerShell 是否重新打开
- 目标主机是否有权限访问 `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`

### 4.2 参考机要求

- 建议使用虚拟机作为参考机，以便复刻与回滚
- 参考机应安装目标版本的 Windows 11
- 所有需要预置到最终镜像中的全局软件、驱动和基础配置都应在参考机内完成

### 4.3 目标材料

至少准备以下内容：

- 参考机系统
- 本仓库代码
- 一个用于保存 `install.wim` 的本地磁盘或外接磁盘
- 可选的 `DockerImagesDirectory`

## 5. 总体流程

推荐按以下顺序执行：

1. 在参考机安装并定制 Windows 11
2. 进入审核模式或在交付约定的定制窗口内完成软件与配置固化
3. 执行 `Sysprep /oobe /generalize /shutdown`
4. 在构建主机上执行 `scripts/Export-CleanWinPEIso.ps1 -Force`
5. 用纯净 WinPE ISO 启动参考机
6. 在 WinPE 中确认 Windows 分区盘符并抓取 `install.wim`
7. 回到构建主机执行 `scripts/Build-WinPEAutoDeploy.ps1`
8. 使用 `scripts/Generate-WinPEIso.ps1` 把 `install.wim` 和可选 payload 打包进最终 ISO
9. 在虚拟机完成一轮完整自动部署验证
10. 验证通过后再用于现场硬件部署或再制作 USB

## 6. 参考机制作与 install.wim 捕获流程

### 6.1 安装与定制参考机

推荐在虚拟机中全新安装目标版本的 Windows 11。完成安装后，执行以下工作：

- 安装项目要求的全局软件与运行库
- 安装基础驱动或通用驱动
- 完成 Windows 更新
- 删除明显无用的临时文件
- 清理浏览器缓存、下载目录和一次性安装包
- 如果镜像对本地账户、语言包或区域设置有固定要求，应在此阶段一并确认

建议在参考机上保留一份《镜像变更清单》，记录：

- 操作系统版本与补丁水平
- 安装的软件名称与版本
- 被停用或调整的系统组件
- 任何需要在验收时复核的本地策略

### 6.2 执行 Sysprep 泛化

在参考机内以管理员身份打开命令提示符，执行：

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown
```

说明如下：

- `/generalize` 用于清理与硬件、SID 和设备枚举相关的系统特定信息
- `/oobe` 用于使目标机首次启动时进入标准 OOBE 流程
- `/shutdown` 用于在泛化完成后直接关机，避免被再次启动污染镜像状态

关键要求：

- Sysprep 完成关机后，不要让参考机再正常进入 Windows 桌面
- 一旦参考机再次启动到泛化后的系统，建议重新检查状态，必要时重新制作参考机并重新执行 Sysprep

### 6.3 导出纯净 WinPE ISO

在构建主机的管理员 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Export-CleanWinPEIso.ps1 -Force
```

默认输出：

- `C:\WinPE_Clean_amd64`
- `C:\WinPE_Clean_amd64.iso`

该脚本的作用是生成不含当前项目自动部署逻辑的原生 WinPE 介质，以便安全地执行镜像抓取。它不会注入 `deploy.cmd`、`unattend.xml` 或首登脚本，因此不会误触发目标盘自动清空流程。

### 6.4 使用纯净 WinPE 启动参考机

将 `C:\WinPE_Clean_amd64.iso` 挂载到参考机并从 UEFI 启动。进入 WinPE 后，先确认盘符映射，不要假定 Windows 分区仍然是 `C:`。

建议执行：

```cmd
diskpart
list vol
exit
```

或者直接逐个检查：

```cmd
dir C:\
dir D:\
dir E:\
```

目标是确认：

- 哪个分区是参考机的 Windows 系统分区
- 哪个分区或外接磁盘用于保存抓取结果

### 6.5 捕获 install.wim

假设：

- 参考机系统分区为 `C:`
- 用于保存镜像的目标盘为 `D:`

执行：

```cmd
DISM /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:"Win11_Custom_Image" /Compress:max /CheckIntegrity /Verify
```

说明：

- `/CaptureDir:C:\` 指向已泛化完成的 Windows 分区根目录
- `/ImageFile:D:\install.wim` 指向输出文件
- `/Name:"Win11_Custom_Image"` 定义镜像名称
- `/Compress:max` 优先压缩率，减少成品体积
- `/CheckIntegrity` 与 `/Verify` 用于提高抓取阶段的数据完整性检查

如果需要同时保存多个索引，也可以先抓取为单索引 WIM，再使用 DISM 追加或导出；但当前仓库部署逻辑默认通过 `-WimIndex` 选择索引，交付时应尽量保证索引定义清晰稳定。

### 6.6 抓取后的检查

回到构建主机后，先检查镜像信息：

```powershell
Get-WindowsImage -ImagePath C:\Images\install.wim
```

或：

```cmd
dism /Get-ImageInfo /ImageFile:C:\Images\install.wim
```

确认内容：

- `install.wim` 文件可正常读取
- 镜像索引号明确
- 名称、描述与项目约定一致

若后续 `Build-WinPEAutoDeploy.ps1` 准备使用 `-WimIndex 1`，则必须确认期望部署的系统映像确实位于索引 `1`。

## 7. 构建项目自定义 WinPE 工作目录

在构建主机管理员 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 `
  -Force `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -WimIndex 1 `
  -TargetDisk auto
```

该步骤的真实行为如下：

1. 校验管理员权限
2. 设置 ADK 运行环境变量
3. 使用 `copype.cmd` 创建标准 WinPE 目录树
4. 挂载 `media\sources\boot.wim`
5. 将模板文件渲染后注入挂载镜像的 `Windows\System32`
6. 把 `__TARGET_DISK__`、`__WIM_INDEX__` 以及分区参数替换为实际参数值
7. 提交并卸载 `boot.wim`

此阶段不会把 `install.wim` 放入 `boot.wim`，因此最终 ISO 或 USB 仍然需要额外提供 `\sources\install.wim` 和 `\sources\winpe-autodeploy.tag`。

`-TargetDisk auto` 当前在 WinPE 运行时解析为磁盘 `0`，并不会根据磁盘容量、总线类型或是否可移动自动推断。若现场设备磁盘编号不稳定，应在交付前改用明确磁盘号并完成实机验证。

如果需要离线驱动注入，可在构建阶段增加 `-DriversDirectory C:\Drivers\MyHardware`。该目录会被复制进 `boot.wim` 的 `X:\drivers-payload`，部署时由 `deploy.cmd` 注入到 `W:\`。最终 ISO 或 USB 上的 `payload\drivers` 目录不会被当前运行时自动扫描。

## 8. 准备可选的 Docker 载荷目录

如果希望目标机首次登录后自动导入镜像并安装服务，应准备 `DockerImagesDirectory`，推荐目录形态如下：

```text
C:\Payload\DockerImages\
+-- 10-win11-install\
|   +-- load_images.bat
|   +-- install_service.bat
|   +-- *.tar
+-- 20-CIKE-install\
|   +-- load_images.bat
|   +-- install_service.bat
|   +-- *.tar
+-- NN-other-service\
    +-- load_images.bat
    +-- install_service.bat
    +-- other files
```

当前实现约束如下：

- 只扫描 `NN-name` 形式的目录
- 每个服务目录最多识别两个固定脚本名：`load_images.bat` 和 `install_service.bat`
- 若目录存在但没有这两个脚本，会被记录并跳过
- 任一脚本非零退出都会触发下一次登录重试

### 8.1 新增 Docker 服务时需要补充的代码内容

如果新增服务能够遵循现有 `NN-name` 目录、`load_images.bat`、`install_service.bat` 约定，通常不需要修改 WinPE 核心脚本，只需要新增一个服务目录并把它作为 `DockerImagesDirectory` 的一部分打包进 ISO 或 USB。需要落地的代码内容如下：

1. 新增服务目录

   例如新增 `30-my-service`：

   ```text
   C:\Payload\DockerImages\
   +-- 30-my-service\
       +-- load_images.bat
       +-- install_service.bat
       +-- my-service-image.tar
       +-- docker-compose.yml
   ```

   目录名前两位数字决定执行顺序。`templates/firstboot.ps1` 中的 `Get-OrderedPayloadDirectories` 只会识别匹配 `^\d{2}-.+` 的目录，并按目录名排序。

2. 编写 `load_images.bat`

   该脚本用于导入 Docker 镜像，建议把第一个参数作为日志文件路径使用，因为 `templates/firstboot.ps1` 会用如下形式调用它：

   ```cmd
   call "C:\Payload\DockerImages\30-my-service\load_images.bat" "C:\ProgramData\FirstBoot\PayloadLogs\30-my-service_load_images_<timestamp>.log"
   ```

   示例：

   ```bat
   @echo off
   setlocal
   set "LOG=%~1"
   if "%LOG%"=="" set "LOG=%TEMP%\30-my-service_load_images.log"

   >> "%LOG%" echo [%DATE% %TIME%] Loading Docker image for 30-my-service...
   docker load -i "%~dp0my-service-image.tar" >> "%LOG%" 2>&1
   if errorlevel 1 exit /b 1

   >> "%LOG%" echo [%DATE% %TIME%] Docker image loaded successfully.
   exit /b 0
   ```

3. 编写 `install_service.bat`

   该脚本用于创建目录、复制配置、执行 `docker compose up -d` 或其他安装动作，同样应使用第一个参数写入日志，并用退出码表达结果。

   示例：

   ```bat
   @echo off
   setlocal
   set "LOG=%~1"
   if "%LOG%"=="" set "LOG=%TEMP%\30-my-service_install_service.log"

   >> "%LOG%" echo [%DATE% %TIME%] Installing 30-my-service...
   if not exist "C:\MyService" mkdir "C:\MyService" >> "%LOG%" 2>&1
   copy /y "%~dp0docker-compose.yml" "C:\MyService\docker-compose.yml" >> "%LOG%" 2>&1
   if errorlevel 1 exit /b 1

   pushd "C:\MyService"
   docker compose up -d >> "%LOG%" 2>&1
   set "RESULT=%ERRORLEVEL%"
   popd
   if not "%RESULT%"=="0" exit /b %RESULT%

   >> "%LOG%" echo [%DATE% %TIME%] 30-my-service installed successfully.
   exit /b 0
   ```

4. 确认基础镜像内已安装 Docker Desktop

   `templates/firstboot.ps1` 不负责安装 Docker Desktop，它只负责查找 `docker.exe`、启动 Docker Desktop、等待 daemon 就绪，然后执行 payload。若新增服务依赖 Docker，Docker Desktop 应在制作参考机和捕获 `install.wim` 前完成安装。

5. 重新打包 ISO 或 USB

   只新增服务目录时，重新执行 `Generate-WinPEIso.ps1 -DockerImagesDirectory ...` 或 `Prepare-WinPEUsb.ps1 -DockerImagesDirectory ...` 即可。`scripts/Generate-WinPEIso.ps1` 和 `scripts/Prepare-WinPEUsb.ps1` 只负责把 payload 复制到介质的 `\payload\docker-images`，不会理解服务内部业务逻辑。

只有在下列情况出现时，才需要修改仓库模板脚本本身：

- 需要识别除 `load_images.bat`、`install_service.bat` 以外的新脚本名：修改 `templates/firstboot.ps1` 的 `Invoke-PayloadService`
- 需要改变目录命名规则或排序规则：修改 `templates/firstboot.ps1` 的 `Get-OrderedPayloadDirectories`
- 需要改变 Docker 启动、等待、重试、完成标记或 Run 项清理逻辑：修改 `templates/firstboot.ps1` 主流程
- 需要像当前 `*win11-install`、`*CIKE-install` 一样在服务成功后弹出凭据或提示窗口：在 `Invoke-PayloadService` 中增加对应服务名判断，并新增独立 helper 函数
- 需要改变 payload 从介质复制到系统盘的位置：修改 `templates/deploy.cmd` 的 `:stage_docker_payloads`，同时同步 `templates/firstboot.ps1` 中的 `$dockerPayloadDir`

修改 `templates/firstboot.ps1`、`templates/deploy.cmd`、`templates/SetupComplete.cmd` 或 `templates/register-firstboot.ps1` 后，必须重新运行 `scripts/Build-WinPEAutoDeploy.ps1`，因为这些模板是在构建阶段注入到 `boot.wim` 的。只重新打包 ISO 不能把模板脚本改动写入已有 `boot.wim`。

## 9. 生成最终自动部署 ISO

### 9.1 最常用命令

在管理员 PowerShell 中执行：

```powershell
.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim `
  -DockerImagesDirectory C:\Payload\DockerImages `
  -Force
```

若不需要附带 payload，可省略 `-DockerImagesDirectory`：

```powershell
.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim `
  -Force
```

### 9.2 该脚本的实际打包逻辑

根据当前代码，`Generate-WinPEIso.ps1` 会：

1. 校验 `WinPEWorkDir\media` 是否存在
2. 校验 `MakeWinPEMedia.cmd` 是否存在
3. 若指定了 `InstallWimPath` 或 `DockerImagesDirectory`
   - 创建临时 staging 根目录
   - 把整个 `WinPEWorkDir` 复制到 staging
   - 把 `install.wim` 复制到 `staging\media\sources\install.wim`
   - 生成 `staging\media\sources\winpe-autodeploy.tag`
   - 把 payload 复制到 `staging\media\payload\docker-images`
4. 调用 `MakeWinPEMedia.cmd /ISO` 生成最终 ISO
5. 删除 staging 临时目录

`winpe-autodeploy.tag` 的作用非常重要。运行时 `deploy.cmd` 并不是看到 `install.wim` 就直接使用，而是要求同一分区上同时存在：

- `\sources\install.wim`
- `\sources\winpe-autodeploy.tag`

这样可以降低误选其他 WIM 介质的风险。

### 9.3 默认输出位置

如果不显式指定 `-IsoPath`，默认输出为：

```text
C:\WinPE_AutoDeploy_amd64\WinPE_AutoDeploy_amd64.iso
```

## 10. 最终 ISO 启动后的运行机制

目标机从最终 ISO 启动后，会按以下逻辑工作：

1. `startnet.cmd` 运行 `wpeinit`
2. 调用 `deploy.cmd`
3. `deploy.cmd` 扫描 `C:` 到 `Z:` 的所有已挂载卷
4. 必须且只能找到一个合法镜像源
5. 动态生成 DiskPart 脚本并清空目标磁盘
6. 创建 EFI、MSR、Windows、可选 Data、Recovery 分区
7. 对 `W:\` 执行 `DISM /Apply-Image`
8. 对 `S:\` 执行 `BCDBoot`
9. 如存在 `X:\drivers-payload`，则离线注入驱动
10. 将 `unattend.xml` 写入 `W:\Windows\Panther`
11. 对已部署系统执行 `reagentc /Setreimage`
12. 注入 `SetupComplete.cmd`、`firstboot.ps1`、`register-firstboot.ps1` 与 `firstboot-launcher.vbs`
13. 如存在 payload，则复制到 `W:\Payload\DockerImages`
14. 保存日志并关机，下一次开机进入已部署 Windows 的 OOBE

## 11. 首次开机与首登后的行为

部署后的 Windows 启动后，系统会执行以下动作：

- `SetupComplete.cmd` 尝试 `reagentc /enable`
- `SetupComplete.cmd` 调用 `register-firstboot.ps1`
- `register-firstboot.ps1` 在 `HKLM\...\Run` 下创建 `CodexFirstBoot`，并在检测到 Docker Desktop 时创建 `DockerDesktopAutoStart`
- 用户首次登录后，`firstboot-launcher.vbs` 以隐藏方式启动 `firstboot.ps1`
- `firstboot.ps1` 检查 `C:\Payload\DockerImages`
- 若不存在 payload，则直接写入完成标记并退出
- 若存在 payload，则查找 `docker.exe`
- Docker 未就绪或任一 payload 失败时，保留 Run 项，等待下次登录重试
- 全部完成后写入 `C:\ProgramData\FirstBoot\done.tag`

## 12. 建议的验证步骤

至少执行以下验证：

### 12.1 install.wim 验证

- `Get-WindowsImage -ImagePath C:\Images\install.wim`
- 确认索引号、名称和大小符合预期
- 尽量在虚拟机完成一次还原验证

### 12.2 ISO 验证

- 在 Hyper-V、VMware 或其他 UEFI 虚拟机中挂载最终 ISO
- 确保运行时只看到一个合法源
- 验证自动分区、应用映像、WinPE 关机和下次开机进入 OOBE 的流程

### 12.3 首登验证

- 验证 OOBE 无线网络页面是否被隐藏
- 验证其他 OOBE 流程是否保持 Windows 标准行为
- 验证 `SetupComplete.cmd` 是否产生 `setupcomplete.log`
- 验证 `firstboot.log` 是否记录 Docker 检测与 payload 执行

### 12.4 日志验证

至少应检查以下路径中的一个或多个：

- `X:\AutoDeploy.log`
- `C:\Windows\Temp\AutoDeploy.log`
- `\<源介质>\DeployLogs\AutoDeploy.log`
- `C:\ProgramData\FirstBoot\setupcomplete.log`
- `C:\ProgramData\FirstBoot\register-firstboot.log`
- `C:\ProgramData\FirstBoot\firstboot.log`
- `C:\ProgramData\FirstBoot\PayloadLogs\*.log`

## 13. 常用命令清单

### 13.1 构建与打包

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

.\scripts\Export-CleanWinPEIso.ps1 -Force

.\scripts\Build-WinPEAutoDeploy.ps1 `
  -Force `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -WimIndex 1 `
  -TargetDisk auto

.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim `
  -DockerImagesDirectory C:\Payload\DockerImages `
  -Force
```

### 13.2 install.wim 抓取

```cmd
DISM /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:"Win11_Custom_Image" /Compress:max /CheckIntegrity /Verify
```

### 13.3 镜像信息检查

```powershell
Get-WindowsImage -ImagePath C:\Images\install.wim
```

```cmd
dism /Get-ImageInfo /ImageFile:C:\Images\install.wim
```

### 13.4 磁盘与卷检查

```powershell
Get-Disk | Select-Object Number, FriendlyName, BusType, PartitionStyle, Size, IsBoot, IsSystem
Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, SizeRemaining, Size
Get-Partition -DiskNumber 1 | Select-Object PartitionNumber, DriveLetter, Type, Size
```

## 14. 风险点与控制建议

### 14.1 盘符误判风险

在 WinPE 中盘符不稳定，因此抓取 `install.wim` 前必须先检查卷映射；部署阶段也不要假设源介质始终是固定盘符。

### 14.2 多镜像源风险

如果 ISO、USB 或额外挂载磁盘上同时存在多个合法源，`deploy.cmd` 会拒绝继续，以避免误部署。测试环境中应尽量只挂载一个有效镜像源。

### 14.3 目标盘误清空风险

`Build-WinPEAutoDeploy.ps1` 中的 `-TargetDisk` 会被渲染到 `deploy.cmd` 中，最终由 WinPE 执行。交付前必须明确目标盘编号约定，并优先在虚拟机验证。

### 14.4 install.wim 版本漂移风险

若参考机更新后重新抓取镜像，必须重新确认索引号、镜像名称和文件哈希，避免文档、脚本参数和实际镜像不一致。

## 15. 结论

当前仓库已经完整覆盖了“自定义 WinPE 构建、自动部署运行时、ISO 打包、USB 制作、首登自动化”的主链路，但没有内置“参考机抓取 `install.wim`”脚本。实际交付时，应把以下动作视为标准闭环：

1. 用 `Export-CleanWinPEIso.ps1` 生成纯净 WinPE 抓镜像介质
2. 对参考机执行 `Sysprep`
3. 在纯净 WinPE 中使用 `DISM /Capture-Image` 抓取 `install.wim`
4. 用 `Build-WinPEAutoDeploy.ps1` 构建项目自动化 WinPE
5. 用 `Generate-WinPEIso.ps1` 把 `install.wim` 和可选 payload 打包进最终 ISO

只要按本文档执行，就能形成一套从参考机制作到最终自动部署 ISO 交付的完整、可审计流程。
