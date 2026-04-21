# OEM Package vs Win11_custom_deploy 能力对照分析

> 对比对象：`OS_AXB35-02_StrixPoint_CNXQ5_Win11Pro_64_25H2_UP7840_CN(Default)US_RZ717_Realtek8125_260408z`
> 分析日期：2026-04-20

## 一、总览对比

| 能力维度 | OEM 包 | 当前项目 | 差距等级 |
|----------|--------|----------|----------|
| WinPE 启动 | ✅ boot.wim | ✅ boot.wim | — |
| 磁盘检测 & 选择 | ✅ 自动检测 NVMe/SATA/eMMC，排除可移动设备 | ✅ `auto` 选择第一块硬盘（disk 0），或指定磁盘号 | — |
| 分区创建 | ✅ 灵活（单系统/双系统/自定义C盘/D盘/一键恢复分区） | ✅ 灵活（自定义C盘大小/D盘/卷标/Recovery大小） | — |
| 镜像释放 | ✅ Install.wim + .swm 分卷支持 | ⚠️ 仅 Install.wim | 🟡 有限 |
| 驱动注入 | ✅ 预嵌入 WIM（工厂模式） | ✅ 动态注入模式（部署时 DISM /Add-Driver） | — |
| Unattend.xml | ✅ 多阶段（generalize/specialize/auditUser/oobeSystem） | ✅ oobeSystem pass（跳过网络和隐私设置） | — |
| WinRE 配置 | ✅ 独立 Recovery 分区 + winre.wim 复制 | ⚠️ Setreimage 指向内置路径，Recovery 分区未使用 | 🟡 有限 |
| 一键恢复 | ✅ 完整 BCD 创建 + 按键进 WinRE | ❌ 无 | 🔴 缺失 |
| BIOS 刷写 | ✅ 支持 Insyde/AMI | ❌ 无 | ⚪ 视需求 |
| OEM 品牌（壁纸/Logo/主题） | ✅ 完整 | ❌ 无 | 🔴 缺失 |
| 首次启动自动化 | ❌ 无（留给 Audit 模式手动处理） | ✅ Docker + Payload 自动化 | 🟢 优势 |
| 日志系统 | ⚠️ 无结构化日志 | ✅ 三重日志持久化（RAM + OS + Media） | 🟢 优势 |
| 源发现安全 | ⚠️ 靠目录名猜测 | ✅ tag 文件 + 唯一性校验 | 🟢 优势 |
| 构建工具链 | ❌ 无（手动拼包） | ✅ PowerShell 脚本化构建 | 🟢 优势 |
| 错误处理 | ⚠️ 简单 `goto :Error` | ✅ 分级 warning/error + handle_step_result | 🟢 优势 |

---

## 二、关键缺失详情

### ✅ P0：驱动注入机制

**现状（已实现）**：`deploy.cmd` 在 DISM /Apply-Image 后执行 `DISM /Add-Driver /Recurse`。

**OEM 包方案**：预嵌入模式（驱动已 baked 进 WIM）。

**本项目方案**：动态注入模式（部署时从 Payload 目录注入）。

**目录结构**：
```
payload/
└── drivers/
    ├── README.md              ← 驱动目录说明
    ├── chipset/               ← 芯片组驱动
    │   └── *.inf, *.sys, *.dll
    ├── graphics/              ← 显卡驱动
    ├── network/               ← 网卡驱动
    └── audio/                 ← 音频驱动
```

**部署流程**：
```
DISM /Apply-Image → DISM /Add-Driver /Recurse → bcdboot → 首次启动
```

---

### ✅ P0：增强 Unattend.xml

**现状（已实现）**（templates/unattend.xml）：
```xml
<settings pass="oobeSystem">
    <OOBE>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <!-- HideOnlineAccountScreens and HideLocalAccountScreen are commented out -->
        <ProtectYourPC>3</ProtectYourPC>
    </OOBE>
</settings>
```

**说明**：OEM 包需要 generalize pass 是因为其工厂流程包含 sysprep /generalize。
本项目的流程不包含 sysprep 步骤，驱动在 DISM /Add-Driver 时已直接写入 Driver Store，无需 generalize pass 保护。

**注意**：当前 unattend.xml 仅跳过网络设置和隐私页面，账户创建屏幕保持可见。如需跳过账户创建，需取消注释 `HideOnlineAccountScreens` 和 `HideLocalAccountScreen`。

---

### 🔴 P1：OEM 品牌定制

**OEM 包注入内容**：
| 类型 | 目标路径 | 来源 |
|------|----------|------|
| 壁纸 | `w:\Windows\web\wallpaper\img0.jpg` | `Scripts/*.jpg` |
| OEM Logo | `w:\Windows\OEM\oemlogo.bmp` | `Scripts/oemlogo.bmp` |
| 主题 | unattend.xml `<Themes>` | 配置文件 |
| 开始菜单 | `w:\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml` | `images/LayoutModification.xml` |
| OOBE 信息 | `w:\windows\System32\oobe\info\` | `Scripts/info/` |

**建议结构**：
```
payload/
└── branding/
    ├── wallpaper.jpg
    ├── oemlogo.bmp
    ├── LayoutModification.xml  ← 可选
    └── oobe-info/              ← 可选，OOBE 品牌信息
```

---

### 🟡 P1：WinRE 独立恢复分区

**现状问题**：
- Recovery 分区（R:）创建了但没使用
- `reagentc /Setreimage /Path W:\Windows\System32\Recovery` 指向 Windows 分区内置路径
- 没有 `winre.wim` 的独立存放

**正确做法**（参考 Main.cmd 479-535 行）：
```batch
# 1. 创建 Recovery 分区并分配盘符 R:
# 2. 复制 winre.wim 到独立路径
md R:\recovery\windowsre
xcopy %InstallPath%\Winre.wim R:\recovery\windowsre /fy

# 或从已释放的 Windows 中移动
move W:\Windows\System32\recovery\winre.wim R:\recovery\windowsre

# 3. 设置 WinRE 路径
reagentc /SetREImage /Path R:\recovery\windowsre /Target W:\Windows

# 4. 设置 GPT 类型（已做）
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
```

---

### 🟡 ~~P1：分区灵活性~~ ✅ 已实现

**现状（已改进）**：分区脚本现在动态生成，支持：
- 自定义 C 盘大小（`-WindowsPartitionSizeGB`）
- 创建 D 盘（`-CreateDataPartition`）
- 自定义卷标（`-WindowsPartitionLabel`, `-DataPartitionLabel`）
- 自定义 Recovery 分区大小（`-RecoverySizeMB`）

**OEM 包支持**（Main.cmd 382-451 行）：

| 变量 | 作用 | 本项目对应参数 |
|------|------|----------------|
| `DefinedCSize` | 自定义 C 盘大小（GB） | `-WindowsPartitionSizeGB` |
| `CreateDriveD` | 创建 D 盘 | `-CreateDataPartition` |
| `DefinedCName`/`DefinedDName` | 自定义盘符名称 | `-WindowsPartitionLabel` / `-DataPartitionLabel` |
| `OneKeyRecovery` | 一键恢复分区（带 GUID） | ❌ 未实现（P2） |

**实现方式**：
- `deploy.cmd` 中的 `:generate_diskpart_script` 子程序根据 token 动态生成 diskpart 脚本
- 不再使用 `diskpart-uefi.txt` 模板文件（已删除）

---

### 🟡 P2：SWM 分卷支持

**场景**：FAT32 U 盘不支持 >4GB 文件，install.wim 需拆分为 .swm。

**OEM 包做法**（Main.cmd 167-188 行）：
```batch
# 检测 .swm 文件
dir /a-d /b *.swm

# 应用时使用 /SWMFile 参数
DISM /Apply-Image /ImageFile:"%SWM1%" /SWMFile:"%SWM2%" /SWMFile:"%SWM3%" ...
```

---

### 🔴 P2：一键恢复环境

**OEM 包实现**（Main.cmd 568-626 行）：
```batch
# 1. 创建独立恢复分区（带 GUID）
create partition primary size=200
set id="98F0F6CD-820A-D30E-0DC6-6E31B980D2EB"

# 2. 解压 Boot 引导文件到 EFI\OEM
7z x Boot64.zip -oT:\EFI\OEM\

# 3. 创建专用 BCD
bcdedit /createstore BCD
bcdedit /create {bootmgr}
bcdedit /create {ramdisk-device}
bcdedit /create {recovery-osloader}

# 4. 配置 ramdisk 启动 winre.wim
bcdedit /set {default} device ramdisk=[R:]\recovery\windowsre\winre.wim,{guid}
```

---

## 三、本项目优势保留

| 优势 | 说明 | 建议 |
|------|------|------|
| 三重日志 | RAM + OS + Media 持久化 | ✅ 保留 |
| Payload 自动化 | Docker + 服务安装 + 自动清理 | ✅ 保留 |
| Tag 文件安全校验 | 防止误选错误镜像 | ✅ 保留 |
| 结构化错误处理 | warning/error 分级 | ✅ 保留 |
| PowerShell 构建 | Build/Prepare/Generate 脚本 | ✅ 保留并扩展 |

---

## 四、实施进度

### ✅ P0（核心能力）— 已完成
| 序号 | 能力 | 状态 |
|------|------|------|
| 1 | 驱动注入机制（DISM /Add-Driver） | ✅ 已实现 |
| 2 | 智能磁盘检测（排除 USB） | ✅ 已实现 |
| 3 | 增强 Unattend.xml（跳过网络和隐私设置） | ✅ 已实现 |

### ✅ P1（专业度提升）— 部分完成
| 序号 | 能力 | 状态 |
|------|------|------|
| 4 | OEM 品牌定制扩展点 | ⏳ 待实现 |
| 5 | WinRE 独立恢复分区 | ⏸️ 暂不调整（现代 Windows 默认设计已变化） |
| 6 | 分区灵活性（自定义大小/D盘） | ✅ 已实现 |

### P2（锦上添花）
| 序号 | 能力 | 状态 |
|------|------|------|
| 7 | SWM 分卷支持 | ⏳ 待实现 |
| 8 | 一键恢复环境 | ⏳ 待实现 |

---

## 五、OEM 包核心流程参考

```
┌─────────────────────────────────────────────────────────────────┐
│  Main.cmd 执行流程                                               │
│                                                                  │
│  1. 磁盘检测                                                     │
│     diskpart list disk → detail disk → 识别类型 → 选择内置磁盘   │
│                                                                  │
│  2. 分区创建                                                     │
│     EFI(100M) → MSR(16M) → Windows → Recovery(512M-1G)          │
│     [可选] OneKeyRecovery 分区（带 GUID）                        │
│                                                                  │
│  3. 镜像释放                                                     │
│     DISM /Apply-Image /Index:1                                   │
│     [支持 .swm 分卷：/SWMFile 参数]                              │
│                                                                  │
│  4. WinRE 配置                                                   │
│     复制 winre.wim → R:\recovery\windowsre                       │
│     reagentc /SetREImage /Path R:\recovery\windowsre            │
│                                                                  │
│  5. 启动配置                                                     │
│     bcdboot W:\Windows /s S: /f UEFI                            │
│     [一键恢复] 创建 EFI\OEM\Boot + BCD                           │
│                                                                  │
│  6. OEM 定制                                                     │
│     复制壁纸、Logo、LayoutModification.xml                       │
│     复制 unattend.xml → W:\Windows\Panther                      │
│     复制 Factory 脚本、OEM 文件                                  │
│                                                                  │
│  7. 首次启动                                                     │
│     OOBE 或 Audit 模式（由 Unattend.xml 控制）                    │
│     [Audit/Unattend.xml] 强制进入审计模式                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## 六、文件映射对照

| OEM 包文件 | 对应本项目 | 说明 |
|------------|-----------|------|
| `Scripts/Main.cmd` | `templates/deploy.cmd` | 核心部署脚本 |
| `scripts/Prepare-WinPEUsb.ps1` | 制备 USB，OEM 无对应脚本 | 本项目优势 |
| `images/Unattend.xml` | `templates/unattend.xml` | 已增强（完整 OOBE 跳过） |
| `images/Audit/Unattend.xml` | — | 审计模式专用 |
| `images/Install.wim` | 部署时提供 | 镜像文件 |
| `images/Winre.wim` | — | 需支持复制到 Recovery 分区 |
| `images/DriverInfolist.txt` | — | 驱动清单，可生成用于验证 |
| `images/Public/amd64/` | — | 公共镜像（空目录，release 包不用） |
| `Boot/` | ADK 自带 | WinPE 启动文件 |
| `sources/boot.wim` | ADK + Build 脚本注入 | WinPE 核心镜像 |

---

## 七、下一步行动

待确认后，按 P0 → P1 → P2 优先级逐步补充。
