# WinPE Auto Deploy 项目交付级 SOP

## 1. 文档信息

文档名称：WinPE Auto Deploy 项目标准操作规程（SOP）

文档版本：v1.0

适用版本：当前仓库主线实现，校验日期为 2026-04-14

适用范围：基于 WinPE 的 Windows 11 UEFI 自动部署、双分区介质制作、首登 Docker 载荷导入与应用初始化

目标读者：项目交付经理、实施工程师、运维工程师、镜像制作人员、测试人员

## 2. 交付目标

本 SOP 用于指导交付团队在受控环境下，完成 WinPE 自动部署介质制作、目标设备系统下发、首登载荷执行、日志验收与问题定位，确保部署过程可重复、可审计、可回滚、可交接。

本项目的核心能力包括：构建带自动化逻辑的 WinPE 启动环境；在 WinPE 中自动发现唯一合法镜像源；清空目标磁盘并重建固定 GPT 分区布局；应用指定索引的 `install.wim`；写入 UEFI 启动项；将 OOBE、WinRE 和首登自动化脚本注入目标系统；在首次用户登录后等待 Docker Desktop 就绪并执行约定的载荷脚本。

## 3. 系统边界与重要约束

本方案仅支持 `amd64` 架构，仅支持 UEFI 启动目标机，不支持 BIOS/Legacy 启动。

部署阶段会清空目标磁盘。USB 制作阶段会清空所选 USB 磁盘。任何操作前都必须再次核对磁盘编号。

WinPE 运行时只接受“恰好一个”合法镜像源。合法镜像源必须同时存在 `\sources\install.wim` 和 `\sources\winpe-autodeploy.tag`。若没有找到或找到多个，部署会在动盘前终止。

首登载荷执行当前按有序服务目录识别：`C:\Payload\DockerImages\NN-name\` 下的 `load_images.bat` 和 `install_service.bat`。新增服务时只需新增目录并遵循命名约定，无需引入 `payload-manifest.json`。

`firstboot.ps1` 使用 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` 而非 `RunOnce`，因此 Docker 未就绪或载荷返回非零时，会在后续登录时继续重试，直到成功或人工处理。

## 4. 角色与职责

交付经理负责确认交付范围、冻结镜像版本、审批目标磁盘策略、确认现场变更窗口和验收标准。

镜像制作工程师负责准备 `install.wim`、确认映像索引、验证镜像完整性，并提供需要随介质下发的 Docker 载荷目录。

实施工程师负责执行 WinPE 工作目录构建、USB/ISO 介质制作、现场部署、首登观察、日志回收和初步排障。

测试或验收人员负责在虚拟机和目标硬件上完成功能验收，重点检查磁盘布局、OOBE 行为、WinRE 状态、Docker 就绪状态、载荷执行结果和日志完整性。

## 5. 目录与关键组件说明

`scripts/Build-WinPEAutoDeploy.ps1`：生成 WinPE 工作目录，挂载 `boot.wim`，把模板渲染后注入 `Windows\System32`。

`scripts/Prepare-WinPEUsb.ps1`：把目标 USB 盘重建为双分区介质。第一分区 FAT32 供 UEFI 启动，第二分区 NTFS 存放 `install.wim`、标记文件和可选载荷。

`scripts/Generate-WinPEIso.ps1`：把现有 WinPE 工作目录打成 ISO，可选择在临时 staging 树中附带 `install.wim` 与载荷。

`scripts/Export-CleanWinPEIso.ps1`：生成纯净 ADK WinPE ISO，不含任何项目自动化逻辑。

`templates/deploy.cmd`：WinPE 内的主部署入口，负责发现介质、分区、应用系统、写入引导、注入文件、复制载荷和保存日志。

`templates/diskpart-uefi.txt`：目标机磁盘分区模板。固定生成 EFI、MSR、Windows、Recovery 四个分区。

`templates/unattend.xml`：设置 `zh-CN` 区域语言，仅跳过 OOBE 网络页面，其余首次开机流程保持 Windows 标准行为。

`templates/SetupComplete.cmd`：在系统部署后启用 WinRE，并注册首登自动化入口。

`templates/register-firstboot.ps1`：向 `HKLM\...\Run` 注册 `CodexFirstBoot`。

`templates/firstboot.ps1`：首次登录后等待 Docker Desktop 就绪，按目录名前缀顺序扫描 `C:\Payload\DockerImages\NN-name\`，依次执行每个服务目录内的 `load_images.bat` 与 `install_service.bat`，全部成功后写入完成标记并删除 Run 项。

## 6. 前置条件

执行机构建与介质制作的主机必须为 Windows，且已安装 Windows ADK 与 WinPE Add-on。脚本默认 ADK 根目录为 `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit`。

所有 PowerShell 构建脚本必须在管理员权限会话中运行。

必须准备可用的 `install.wim`，并明确应部署的索引号。若不清楚索引号，应先通过 DISM 或镜像管理流程确认。

若需要导入 Docker 镜像或安装应用，必须准备好 `DockerImagesDirectory` 目录，并按 `NN-name` 服务目录组织文件。至少确认每个服务目录内的 `load_images.bat`、`install_service.bat`、相关 `.tar` 镜像包以及脚本依赖文件存在并可执行。

目标机必须以 UEFI 模式启动，且实施人员必须确认被清空的目标磁盘编号与项目预期一致。

## 7. 交付前检查清单

1. 确认 ADK 和 WinPE Add-on 安装完成。
2. 确认仓库内 `scripts`、`templates`、`docs` 目录文件齐全。
3. 确认 `install.wim` 文件存在、可读、版本正确。
4. 确认目标镜像索引号，例如 `1`。
5. 确认部署目标磁盘编号，例如 `0`。
6. 确认 USB 介质磁盘编号，例如 `1`，且不是宿主机系统盘。
7. 若使用载荷，确认载荷目录存在且文件名符合当前实现约定。
8. 确认测试阶段优先使用虚拟机验证，硬件环境部署前已有一轮成功验证。

## 8. 标准作业流程

### 8.1 构建自定义 WinPE 工作目录

在管理员 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Build-WinPEAutoDeploy.ps1 `
  -Force `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -WimIndex 1 `
  -TargetDisk 0
```

该步骤会重新创建 WinPE 工作目录，运行 `copype.cmd`，挂载 `media\sources\boot.wim`，并把模板文件渲染后注入到 `Windows\System32`。其中 `__TARGET_DISK__` 和 `__WIM_INDEX__` 会被替换为实际值。

成功标准：命令结束后看到 WinPE 工作目录就绪提示；`C:\WinPE_AutoDeploy_amd64\media\sources\boot.wim` 存在；后续可继续执行 USB 或 ISO 制作。

失败处理：优先检查是否管理员权限、ADK 路径是否正确、`copype.cmd` 与 `DISM` 是否可用、模板文件是否缺失，以及已有工作目录是否已被 `-Force` 允许重建。

### 8.2 制作双分区部署 USB

在管理员 PowerShell 中执行：

```powershell
.\scripts\Prepare-WinPEUsb.ps1 `
  -UsbDiskNumber 1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim
```

如需附带 Docker 载荷：

```powershell
.\scripts\Prepare-WinPEUsb.ps1 `
  -UsbDiskNumber 1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim `
  -DockerImagesDirectory C:\Payload\DockerImages
```

该步骤会清空所选 USB 盘，强制转为 `MBR`，创建 FAT32 启动分区和 NTFS 镜像分区，调用 `MakeWinPEMedia.cmd /UFD` 向 FAT32 分区写入 WinPE 启动内容，并在 NTFS 分区内写入 `\sources\install.wim` 与 `\sources\winpe-autodeploy.tag`。如指定载荷，还会复制到 `\payload\docker-images`。

成功标准：脚本返回 `USB preparation completed.`；可见一个标记为 `WINPE` 的 FAT32 分区和一个标记为 `IMAGES` 的 NTFS 分区；NTFS 分区下存在 `sources\install.wim` 和 `sources\winpe-autodeploy.tag`。

失败处理：先确认所选磁盘不是系统盘；确认 USB 容量足够；确认 `install.wim` 和可选载荷目录在动盘前就已通过路径校验；若磁盘总线类型不是 USB，脚本只会告警不会阻止执行，现场必须人工复核。

### 8.3 生成测试 ISO

若用于虚拟机测试，可执行：

```powershell
.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -Force
```

若希望把 `install.wim` 与载荷直接打进 ISO，可执行：

```powershell
.\scripts\Generate-WinPEIso.ps1 `
  -WinPEWorkDir C:\WinPE_AutoDeploy_amd64 `
  -InstallWimPath C:\Images\install.wim `
  -DockerImagesDirectory C:\Payload\DockerImages `
  -Force
```

该脚本不会修改原始工作目录。当提供 `InstallWimPath` 或 `DockerImagesDirectory` 时，会先复制出一个临时 staging 目录，把文件注入 staging，再调用 `MakeWinPEMedia.cmd /ISO` 打包，并在结束后清理 staging。

成功标准：指定 ISO 文件生成成功，且原始 `WinPEWorkDir\media` 内容未被污染。

### 8.4 导出纯净 WinPE ISO

如需维护、抓镜像或排除项目自动化因素影响，可执行：

```powershell
.\scripts\Export-CleanWinPEIso.ps1 -Force
```

默认输出为 `C:\WinPE_Clean_amd64` 和 `C:\WinPE_Clean_amd64.iso`。该产物不包含本项目注入的 `deploy.cmd`、首登脚本和 `unattend.xml`。

## 9. 目标机部署流程

### 9.1 启动前检查

确认目标机 BIOS/UEFI 中已启用 UEFI 启动。

确认已连接部署 USB，或虚拟机已挂载带镜像源的 ISO。

确认现场没有额外插入其他也包含 `\sources\install.wim` 与 `\sources\winpe-autodeploy.tag` 的介质，以免触发多候选保护逻辑。

### 9.2 WinPE 自动部署过程

目标机进入 WinPE 后，`startnet.cmd` 会先执行 `wpeinit`，随后直接调用 `X:\Windows\System32\deploy.cmd`。

`deploy.cmd` 会扫描 `C:` 到 `Z:`，寻找唯一合法镜像源。若找到零个或多个，流程会在清盘前中止并提示错误。

找到唯一镜像源后，脚本会依据 `diskpart-uefi.txt` 清空目标磁盘并创建以下布局：

1. EFI 分区，100 MB，盘符 `S:`
2. MSR 分区，16 MB
3. Windows 主分区，盘符 `W:`，由剩余空间扣减 1024 MB 后形成
4. Recovery 分区，约 1024 MB，盘符 `R:`

随后脚本会执行以下动作：

1. `DISM /Apply-Image` 把指定索引映像应用到 `W:\`
2. `BCDBoot W:\Windows /s S: /f UEFI` 写入 UEFI 启动文件
3. 把 `unattend.xml` 复制到 `W:\Windows\Panther\unattend.xml`
4. 使用 `W:\Windows\System32\reagentc.exe /Setreimage` 设置 WinRE 路径
5. 把 `firstboot.ps1`、`register-firstboot.ps1` 和 `SetupComplete.cmd` 注入目标系统
6. 若源介质存在 `\payload\docker-images`，则复制到 `W:\Payload\DockerImages`
7. 保存日志并自动重启

注意：`unattend.xml`、WinRE 配置和首登资源注入都属于“有警告但不中断”的步骤。也就是说，这些步骤若失败，主部署仍可能完成，但日志中会留下 warning，验收阶段必须复核。

## 10. 首次开机与首登阶段

系统首次进入已部署的 Windows 后，`SetupComplete.cmd` 会优先执行 `reagentc /enable`，然后尝试调用 `register-firstboot.ps1` 注册 `CodexFirstBoot`。

首个成功用户登录后，`firstboot.ps1` 自动执行。其逻辑如下：

1. 若 `C:\ProgramData\FirstBoot\done.tag` 已存在，则清理 Run 注册并退出。
2. 若 `C:\Payload\DockerImages` 不存在，则视为无需载荷，直接写入 `done.tag` 并退出。
3. 若找不到 `docker.exe`，则返回失败，让 Run 项保留，等待下次登录重试。
4. 若发现 Docker Desktop，可写入 `HKCU\...\Run\DockerDesktopAutoStart`，为未来登录建立自启动。
5. 脚本优先执行 `docker desktop start`，失败后回退为直接启动 `Docker Desktop.exe`。
6. 最多轮询 10 次 Docker Desktop 进程出现情况，每次间隔 2 秒。
7. 进程出现后，再按 `2,2,3,5,8,8` 秒节奏多次执行 `docker info`，确认 daemon 已就绪。
8. Docker 就绪后，按目录名前缀顺序遍历 `C:\Payload\DockerImages\NN-name\`；每个服务目录内如存在 `load_images.bat` 则先执行，如存在 `install_service.bat` 则随后执行。
9. 任一载荷返回非零时，本次首登流程不写完成标记，等待下次登录继续重试。
10. 全部成功后，若 `10-win11-install\install_service.bat` 成功，还会弹出 1Panel 凭据窗口，然后写入 `done.tag` 并移除 Run 项。

## 11. 运行结果验收标准

### 11.1 构建验收

`Build-WinPEAutoDeploy.ps1` 执行成功，无挂载残留，`boot.wim` 可正常生成且后续能用于 USB 或 ISO 制作。

### 11.2 介质验收

部署 USB 的 FAT32 启动分区可被 UEFI 识别；NTFS 数据分区中存在 `install.wim` 与 `winpe-autodeploy.tag`；如有载荷，`payload\docker-images` 目录结构完整。

### 11.3 部署验收

目标机成功自动分区并应用系统；Windows 分区位于 `W:`；EFI 分区位于 `S:`；部署后自动重启，无需人工干预。

### 11.4 系统验收

Windows 首次进入 OOBE 时语言区域为 `zh-CN`，网络页面被隐藏，其余流程保持正常；完成首次登录后，若存在载荷则能够进入 Docker 启动与载荷执行流程。

### 11.5 日志验收

至少应回收以下日志之一：`X:\AutoDeploy.log`、`C:\Windows\Temp\AutoDeploy.log`、源介质 `DeployLogs\AutoDeploy.log`。首登阶段还应检查 `C:\ProgramData\FirstBoot\setupcomplete.log`、`register-firstboot.log`、`firstboot.log` 及 `PayloadLogs\*.log`。

## 12. 常见检查命令

核查 USB 或目标磁盘信息：

```powershell
Get-Disk | Select-Object Number, FriendlyName, BusType, PartitionStyle, Size, IsBoot, IsSystem
Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, SizeRemaining, Size
Get-Partition -DiskNumber 1 | Select-Object PartitionNumber, DriveLetter, Type, Size
```

核查部署介质关键文件：

```powershell
Get-Item U:\EFI\Boot\bootx64.efi, U:\sources\boot.wim, V:\sources\install.wim, V:\sources\winpe-autodeploy.tag
```

核查 WinRE：

```powershell
reagentc /info
```

核查首登注册项：

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
```

核查 Docker 状态：

```powershell
docker info
Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
```

## 13. 故障处理 SOP

### 13.1 WinPE 未找到合法镜像源

现象：启动后提示未找到准备好的介质，且未开始分区。

处理：检查数据分区中是否同时存在 `\sources\install.wim` 和 `\sources\winpe-autodeploy.tag`；检查是否插入了多个带同样标记的介质；检查 ISO/USB 中是否误删标记文件。

### 13.2 发现多个候选镜像源

现象：日志中列出多个候选介质并停止。

处理：移除多余介质，保留唯一部署源后重启 WinPE。此保护机制是设计行为，不建议绕过。

### 13.3 DiskPart 或 DISM 失败

现象：部署在分区或应用镜像阶段失败。

处理：检查目标磁盘健康、只读状态和容量；检查 `diskpart-uefi.txt` 是否被改动；检查 `install.wim` 是否损坏；检查目标机是否以 UEFI 模式启动。

### 13.4 BCDBoot 失败

现象：映像应用成功，但无法写入启动文件。

处理：确认 `S:` EFI 分区已创建；检查 `W:\Windows` 是否完整；必要时进入 WinPE 手动执行 `bcdboot W:\Windows /s S: /f UEFI` 复测。

### 13.5 SetupComplete 或首登脚本未执行

现象：系统进入桌面，但没有任何首登动作，或日志缺失。

处理：检查 `C:\Windows\Setup\Scripts\SetupComplete.cmd` 和 `C:\ProgramData\FirstBoot\register-firstboot.ps1` 是否已注入；检查 `setupcomplete.log` 是否记录了 PowerShell 调用失败；检查系统策略是否阻断脚本执行。

### 13.6 Docker 未就绪导致反复重试

现象：每次登录都会再次触发 `firstboot.ps1`。

处理：检查 `docker.exe` 是否存在；检查 `Docker Desktop.exe` 是否安装；查看 `firstboot.log` 中是卡在进程出现还是 `docker info` 就绪；必要时手动启动 Docker Desktop 并再次登录。

### 13.7 载荷执行失败

现象：某个服务目录中的 `load_images.bat` 或 `install_service.bat` 返回非零，系统重复重试。

处理：查看 `C:\ProgramData\FirstBoot\PayloadLogs\` 下对应日志；修复载荷脚本后重新登录触发；若要跳过载荷，可在确认业务允许后手动修复 Run 项与完成标记。

## 14. 变更控制要求

凡是涉及以下内容的变更，都必须同步更新 README、技术文档和本 SOP，并至少完成一轮虚拟机验证：

1. 目标磁盘选择策略
2. `diskpart-uefi.txt` 分区布局
3. 镜像源发现机制
4. `unattend.xml` OOBE 行为
5. 首登自动化重试逻辑
6. 载荷目录结构和文件命名约定

若调整了 `deploy.cmd`、`firstboot.ps1`、`SetupComplete.cmd` 或 USB 介质制作逻辑，交付前必须补充“操作影响说明”“风险说明”“验证记录”和“回滚方式”。

## 15. 回滚与恢复策略

本项目没有“原地回滚”能力。因为部署阶段会清空目标磁盘，回滚的正确方式应是重新下发上一个受控版本的 `install.wim`，或使用标准企业恢复流程恢复整机。

若仅首登载荷阶段失败，而基础系统已成功部署，可采用以下保守恢复策略：

1. 保留已部署系统，不重新下发 OS。
2. 根据 `firstboot.log` 与 `PayloadLogs` 修复 Docker 或载荷问题。
3. 重新登录触发自动重试。
4. 若需要人工结束流程，必须在确认业务完成的前提下，手动清理 `HKLM\...\Run\CodexFirstBoot` 并视情况补写 `C:\ProgramData\FirstBoot\done.tag`。

## 16. 最终交付建议

项目对外正式交付时，建议随包提供以下内容：

1. 当前仓库代码快照或标签版本
2. 本 SOP 文档
3. 已验证的 `install.wim` 版本信息与索引说明
4. 部署 USB 或 ISO 制作记录
5. 虚拟机验证记录
6. 现场硬件部署验收记录
7. 常见问题与日志路径说明

## 17. 附录：推荐执行顺序

1. 在构建机上安装 ADK 与 WinPE Add-on。
2. 准备并验证 `install.wim`。
3. 运行 `Build-WinPEAutoDeploy.ps1` 构建工作目录。
4. 先运行 `Generate-WinPEIso.ps1` 在虚拟机完成验证。
5. 验证通过后运行 `Prepare-WinPEUsb.ps1` 制作现场 USB。
6. 在目标硬件上执行部署并回收日志。
7. 完成首次登录与载荷验收。
8. 归档日志、镜像版本、SOP 和验收记录，形成正式交付包。
