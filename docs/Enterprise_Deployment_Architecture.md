# 企业级全自动部署架构说明

本文档基于仓库当前实现整理，描述实际的构建链路、WinPE 运行时行为、首启阶段逻辑，以及各脚本之间的职责边界。

## 1. 项目目标与边界

当前项目实现的是一套面向 `amd64`、仅支持 `UEFI` 的 Windows 自动部署方案，核心目标如下：

- 通过 Windows ADK 生成可复用的 WinPE 工作目录。
- 将自动化逻辑注入 `boot.wim`，而不是依赖手工修改启动介质。
- 从准备好的 USB 或 ISO 中自动发现唯一合法的 `install.wim` 源。
- 自动清空目标磁盘、重建 GPT 分区、应用系统镜像并写入引导。
- 在离线阶段写入 `unattend.xml`、`SetupComplete.cmd` 与首登脚本。
- 在首次登录阶段按需初始化 Docker 并执行预置载荷脚本。

不在当前实现范围内的事项：

- Legacy BIOS 启动。
- 多镜像源自动择优。
- 多目标磁盘自动判定。
- 基于业务脚本退出码的完整重试机制。

## 2. 构建阶段

### 2.1 `Build-WinPEAutoDeploy.ps1`

这是项目的核心“制品生成”脚本，职责不是直接做 USB 或 ISO，而是生成一个已经注入自动化逻辑的 WinPE 工作目录。

实际行为：

1. 校验管理员权限。
2. 重建 ADK 所需环境变量，避免必须从专用 ADK shell 启动。
3. 调用 `copype.cmd` 生成标准 WinPE 工作目录。
4. 挂载 `media\sources\boot.wim`。
5. 将下列模板渲染后写入挂载镜像内的 `Windows\System32`：
   - `deploy.cmd`
   - `diskpart-uefi.txt`
   - `startnet.cmd`
   - `firstboot.ps1`
   - `register-firstboot.ps1`
   - `SetupComplete.cmd`
   - `unattend.xml`
6. 使用 `__TARGET_DISK__`、`__WIM_INDEX__` 两个令牌将部署参数固化进运行时脚本。
7. 成功时提交挂载，失败时丢弃挂载结果。

默认参数：

- `-Architecture amd64`
- `-WinPEWorkDir C:\WinPE_AutoDeploy_amd64`
- `-WimIndex 1`
- `-TargetDisk 0`

设计特点：

- 只注入必要的运行文件，不额外给 WinPE 注入大体积可选组件。
- `install.wim` 不进入 `boot.wim`，而是在部署时从介质上发现。
- 重新构建时要求 `-Force`，避免在未知旧目录上增量修改。

### 2.2 `Prepare-WinPEUsb.ps1`

该脚本负责把已有工作目录转为物理部署介质，执行的是“破坏性重建 USB”流程。

实际行为：

1. 校验管理员权限。
2. 校验 `WinPEWorkDir\media`、`install.wim`、ADK 工具是否存在。
3. 读取目标磁盘信息并执行安全检查：
   - 若磁盘被 Windows 标记为 `IsBoot` 或 `IsSystem`，立即拒绝。
   - 若总容量不足以容纳 FAT32 启动分区、`install.wim` 和额外 1 GB 缓冲区，立即拒绝。
   - 若总线类型不是 `USB`，只给出警告，不阻止继续。
   - 若传入了 `-DockerImagesDirectory`，也会在任何清盘操作前先校验该目录是否存在。
4. 清空目标磁盘并初始化为 `MBR`。
5. 创建双分区结构：
   - 分区 1：FAT32，默认 2048 MB，卷标 `WINPE`
   - 分区 2：NTFS，占用剩余空间，卷标 `IMAGES`
6. 使用 `MakeWinPEMedia.cmd /UFD` 将 WinPE 启动文件写入 FAT32 分区。
7. 在 NTFS 分区写入：
   - `\sources\install.wim`
   - `\sources\winpe-autodeploy.tag`
8. 如果指定了 `-DockerImagesDirectory`，则递归复制到 `\payload\docker-images\`

设计原因：

- USB 介质用 `MBR + FAT32` 启动分区，提高可移动介质的固件兼容性。
- 数据分区用 NTFS，规避 FAT32 单文件 4 GB 限制。

### 2.3 `Generate-WinPEIso.ps1`

该脚本不会重新构建 `boot.wim`，而是将现有工作目录直接打包成 ISO。

实际行为：

- 默认输出 ISO 到 `WinPEWorkDir` 下，名称为 `<工作目录名>.iso`
- 若传入 `-InstallWimPath` 或 `-DockerImagesDirectory`，会先复制整个工作目录到临时 staging 目录
- 再向临时目录注入 `media\sources\install.wim`、`winpe-autodeploy.tag` 和 `media\payload\docker-images`
- 然后调用 `MakeWinPEMedia.cmd /ISO`

实现注意点：

- 原始工作目录不会被 ISO 打包过程污染。
- 临时 staging 目录在打包结束后会被清理。
- 可选输入路径会在 staging 创建前先完成校验；如果后续步骤失败，临时 staging 目录仍会进入清理流程。

### 2.4 `Export-CleanWinPEIso.ps1`

该脚本生成完全不带项目自动化逻辑的“纯净 WinPE ISO”，适合手工维护、故障排查或在虚拟机中采集新镜像。

与主构建脚本的关键区别：

- 不挂载 `boot.wim`
- 不注入任何模板
- 直接基于 ADK 生成标准 WinPE 媒体并打包为 ISO

## 3. WinPE 运行时架构

### 3.1 启动入口

`startnet.cmd` 非常简单，只做两件事：

1. 调用 `wpeinit`
2. 调用 `X:\Windows\System32\deploy.cmd`

这种设计保证 WinPE 启动入口保持极简，全部业务逻辑集中在 `deploy.cmd`。

### 3.2 `deploy.cmd` 的真实流程

`deploy.cmd` 是整个部署过程的主引擎，当前实现流程如下：

1. 初始化日志到 `X:\AutoDeploy.log`
2. 读取构建阶段渲染进去的：
   - `TARGET_DISK`
   - `WIM_INDEX`
3. 调用 `:scan_sources` 扫描 `C:` 到 `Z:`，寻找同时满足以下条件的卷：
   - `\sources\install.wim`
   - `\sources\winpe-autodeploy.tag`
4. 如果匹配数为 0 或大于 1，则立即停止，且不会修改目标盘
5. 直接使用构建阶段已渲染完成的 `diskpart-uefi.txt`
6. 调用 `diskpart /s` 清空并重建目标盘
7. 校验 `W:` 和 `S:` 是否生成成功
8. 执行：
   - `dism /Apply-Image`
   - `bcdboot W:\Windows /s S: /f UEFI`
9. 执行后续子流程：
   - `:stage_unattend_xml`
   - `:configure_winre`
   - `:stage_firstboot_assets`
10. 持久化日志并重启

### 3.3 磁盘布局

`diskpart-uefi.txt` 固定生成如下 GPT 布局：

1. EFI 分区，100 MB，盘符 `S:`
2. MSR 分区，16 MB
3. Windows 主分区，盘符 `W:`
4. Recovery 分区，盘符 `R:`

恢复分区在创建后立即设置为 Windows Recovery GPT 类型，并写入隐藏属性：

- `id=de94bba4-06d1-4d40-a16a-bfd50179d6ac`
- `gpt attributes=0x8000000000000001`

### 3.4 WinRE 配置策略

WinRE 配置分两步：

- WinPE 阶段执行：
  - `W:\Windows\System32\reagentc.exe /Setreimage /Path W:\Windows\System32\Recovery /Target W:\Windows`
- 首启阶段执行：
  - `reagentc /enable`

这套做法的特点是：

- 不依赖给 WinPE 额外注入完整恢复相关组件
- 直接使用刚展开到目标系统中的 `reagentc.exe`

## 4. 离线阶段注入内容

### 4.1 `unattend.xml`

当前实际配置不是“完全无人值守的一切细节自定义”，而是聚焦以下事项：

- 语言区域固定为 `zh-CN`
- 仅跳过 OOBE 中的无线网络设置页
- 其余首次启动流程保持标准 Windows OOBE

因此，文档中如果把它描述成“复杂的企业域接入或全量 OOBE 自定义”，都不准确。当前实现只是一个偏简化的离线区域设置加网络页跳过配置。

### 4.2 首启相关文件

`deploy.cmd` 会把以下文件复制进已部署系统：

- `W:\ProgramData\FirstBoot\firstboot.ps1`
- `W:\ProgramData\FirstBoot\register-firstboot.ps1`
- `W:\Windows\Setup\Scripts\SetupComplete.cmd`

如果这些文件任一缺失，当前实现不会中止部署，只会记一条 warning 并继续完成系统安装。

### 4.3 Payload 复制逻辑

若源介质存在 `\payload\docker-images\`，`deploy.cmd` 会递归复制整个目录到：

```text
W:\Payload\DockerImages
```

这里复制是“全量复制目录内容”，但自动执行逻辑只识别其中两个脚本：

- `load_images.bat`
- `install_appstore.bat`

其他文件只会被原样带入系统，不会被自动执行。

## 5. Windows 首启阶段

### 5.1 `SetupComplete.cmd`

该脚本在 OOBE 接近结束时运行，职责非常明确：

1. 创建 `C:\ProgramData\FirstBoot`
2. 记录 `setupcomplete.log`
3. 执行 `reagentc /enable`
4. 调用 `register-firstboot.ps1`

如果注册失败，当前实现只记录 warning，不会让系统安装失败。

### 5.2 `register-firstboot.ps1`

该脚本通过以下位置注册首登任务：

```text
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\CodexFirstBoot
```

其命令行本质上是：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\FirstBoot\firstboot.ps1
```

这里使用的是 `Run` 而不是 `RunOnce`，原因是允许 Docker 尚未就绪时在后续登录再次执行。

### 5.3 `firstboot.ps1`

这是首启逻辑的最终执行点。当前实现可以概括为：

1. 初始化日志文件 `C:\ProgramData\FirstBoot\firstboot.log`
2. 创建 `C:\ProgramData\FirstBoot\PayloadLogs`
3. 为每个 payload 脚本生成独立日志路径并写回 `firstboot.log`
4. 如果已存在 `done.tag`，则删除 Run 注册并退出
5. 如果 `C:\Payload\DockerImages` 不存在：
   - 写入 `done.tag`
   - 删除 Run 注册
   - 正常退出
6. 查找 `docker.exe`
7. 定位 `Docker Desktop.exe`
8. 向 `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run` 写入 `DockerDesktopAutoStart`
9. 优先执行 `docker desktop start` 在后台启动 Docker Desktop
10. 如有需要，回退到直接启动 `Docker Desktop.exe`
11. 等待 `Docker Desktop` 进程出现
12. 启动 `com.docker.service` / `docker` 等相关服务（若存在）
13. 通过短窗口 `docker info` 探测确认 daemon 已就绪
14. Docker 就绪后，按存在性执行：
   - `load_images.bat`
   - `install_appstore.bat`
15. `load_images.bat` 通过统一的批处理日志辅助函数隐藏执行，并按与 `install_appstore.bat` 相同的格式写入独立 payload 日志
16. `install_appstore.bat` 保持可见控制台窗口，非敏感执行细节写入独立 payload 日志，最终用户名与密码只显示在控制台，且成功后窗口不会立即关闭
17. 仅当所有已发现的 payload 脚本都返回 `0` 时才创建 `done.tag`
18. 仅在上述成功条件满足时删除 Run 注册

### 5.4 真实的重试语义

这一点是文档最容易写错的地方。当前实现的重试语义是：

- 如果 `docker.exe` 缺失，脚本 `exit 1`，Run 项保留，下次登录重试
- 如果 Docker 始终未就绪，脚本 `exit 1`，Run 项保留，下次登录重试
- 如果 `load_images.bat` 或 `install_appstore.bat` 返回非 0 或执行异常，错误会被记录，Run 项保留，下次登录重试
- 只有当 Docker 与 payload 全部完成成功时，脚本才会创建 `done.tag` 并移除 Run 项

因此，当前实现已经覆盖两类自动重试：Docker 前置条件失败，以及 payload 脚本失败。

## 6. 日志与可观测性

### 6.1 WinPE 阶段

主日志位于：

- `X:\AutoDeploy.log`

部署成功或失败前，`deploy.cmd` 会尝试持久化到：

- `W:\Windows\Temp\AutoDeploy.log`
- `\<部署介质>\DeployLogs\AutoDeploy.log`

日志格式使用：

- `[INFO]`
- `[WARNING]`
- `[ERROR]`

### 6.2 首启阶段

首启相关日志位于：

- `C:\ProgramData\FirstBoot\setupcomplete.log`
- `C:\ProgramData\FirstBoot\register-firstboot.log`
- `C:\ProgramData\FirstBoot\firstboot.log`
- `C:\ProgramData\FirstBoot\PayloadLogs\load_images_<timestamp>.log`
- `C:\ProgramData\FirstBoot\PayloadLogs\install_appstore_<timestamp>.log`

## 7. 风险与当前实现限制

根据当前代码，下面这些限制应在所有相关文档中明确说明：

1. 目标磁盘由构建阶段固化，运行时不会动态选择。
2. WinPE 只接受“恰好一个”合法镜像源，多源环境下会直接拒绝。
3. `unattend.xml` 当前不会预建本地管理员账户，也不会自动登录；后置自动化依赖首次成功用户登录后触发。
4. payload 自动执行仍只识别固定文件名 `load_images.bat` 与 `install_appstore.bat`。
5. `Generate-WinPEIso.ps1` 通过临时 staging 打包，额外增加了一次目录复制开销。

## 8. 建议的阅读顺序

如果要继续深入实现，推荐按以下顺序阅读：

1. `scripts\Build-WinPEAutoDeploy.ps1`
2. `templates\deploy.cmd`
3. `templates\firstboot.ps1`
4. `templates\SetupComplete.cmd`
5. `scripts\Prepare-WinPEUsb.ps1`
6. `scripts\Generate-WinPEIso.ps1`

这样可以先理解“构建时如何注入”，再理解“运行时如何执行”，最后再看介质分发与测试产物。
