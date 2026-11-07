# win-disk-rescue

Windows 磁盘空间诊断与回收工具。**先告诉你空间去哪了，再问你敢不敢删。**

不是又一个"清缓存"软件。清缓存那点收益，一次浏览器更新就长回来了。这个工具找的是真正吃盘的东西：WSL 虚拟磁盘、固定大小的页面文件、解压完忘了删的压缩包、被塞在 `\Microsoft\` 任务路径下伪装的恶意启动项。

```
  win-disk-rescue
  mode: Scan   [DRY RUN - nothing is deleted]
  root: C:\
  admin: False
```

## 为什么不用现成的清理软件

| 现成清理软件 | win-disk-rescue |
|---|---|
| 扫 `%TEMP%`、缩略图、回收站 | 一样扫，但会告诉你这些只值几个 G |
| 不碰 `pagefile.sys` | 检测并建议改成系统托管（常见能省 10G+） |
| 不知道 WSL 的存在 | 找到 `ext4.vhdx` 并支持在线搬盘 / 压缩 |
| 不认"解压完没删的包" | 逐个比对压缩包和同名解压目录，只删确认多余的那个 |
| 把伪装的计划任务当系统组件 | 按路径 + 签名 + 元数据打分，专抓 `\Microsoft\Windows\AppID\HandleCommand` 这种货色 |
| 删了没法回滚 | 默认只读；`-Apply` 才动手；注册表项自动备份成 JSON |

## 快速开始

```powershell
# 1. 先看报告，什么都不删（默认就是这个模式）
.\Invoke-DiskRescue.ps1

# 2. 清缓存、临时文件、回收站、Edge 自动启动垃圾
.\Invoke-DiskRescue.ps1 -Mode Safe -Apply

# 3. 需要管理员的深度维护：DISM 组件清理 + 页面文件 + 压缩 WSL 盘
.\Invoke-DiskRescue.ps1 -Mode Admin -Apply -Elevate

# 4. 一次全做
.\Invoke-DiskRescue.ps1 -Mode All -Apply -Elevate

# 5. 把 WSL 发行版整个搬到别的盘（小容量系统盘的最大收益）
.\Invoke-DiskRescue.ps1 -Mode Admin -Apply -Elevate -WslDistro Ubuntu -WslDestination D:\wsl\Ubuntu

# 6. 机器导出的 JSON，方便批量分析
.\Invoke-DiskRescue.ps1 -Json > report.json
```

> **PowerShell 5.1 也能跑**（Windows 10/11 自带的就是这个）。不需要装 PowerShell 7。

### 执行策略

如果提示脚本被禁止运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-DiskRescue.ps1
```

或者只放开当前进程：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 三种模式

### `Scan`（默认）

纯只读，什么都不改。输出：

- 各盘容量和占用率
- 根目录下最大的文件夹
- 单个最大的文件（含 `pagefile.sys`）
- **可搬移的大件**：WSL 虚拟盘、OEM 驱动备份、页面文件、休眠文件
- **可回收的缓存**（按规则文件扫，带每项大小）
- **解压后多余的压缩包**
- **自启动项清单 + 可疑度评分**

### `Safe`

不需要管理员权限：

- 清规则文件里列的缓存目录（`minAgeDays` 控制保留天数）
- 清空回收站
- 删掉 Edge 每开一次就多一条的 `MicrosoftEdgeAutoLaunch_*`
- 禁用遥测 / 推广类计划任务（OneDrive、PlatformExperiencesHelper、SoftLanding…）
- `-IncludeArchives`：删解压后多余的压缩包
- `-DisableRun`：清第三方 `Run` 项（白名单里的保留，删前自动备份 JSON）

### `Admin`

需要 `-Elevate`：

- `DISM /StartComponentCleanup` 回收 WinSxS 里的旧组件
- 页面文件改成系统托管（固定 20G 的机器通常能省 8～12G）
- 压缩 `ext4.vhdx`
- 搬移 WSL 发行版
- 停用 / 删除评分超线的可疑自启动项

## 参数

| 参数 | 说明 |
|---|---|
| `-Mode Scan\|Safe\|Admin\|All` | 运行模式，默认 `Scan` |
| `-Apply` | 真的执行。**不加这个一律是预演** |
| `-Elevate` | 需要管理员时自动弹 UAC 重启自己 |
| `-Root` | 分析哪个盘 / 目录，默认系统盘 |
| `-Top N` | 显示前几个大目录 / 大文件，默认 12 |
| `-IncludeArchives` | 删解压后多余的压缩包 |
| `-DisableRun` | 清第三方注册表自启动项 |
| `-KeepRun` | 保留的项名，支持通配符，如 `-KeepRun 'Steam*','Everything'` |
| `-WslDistro` / `-WslDestination` | 搬移指定 WSL 发行版 |
| `-Yes` | 跳过逐项确认 |
| `-Json` | 只输出 JSON |

## 规则文件（改这里，不用改代码）

### `rules/junk-paths.json`

```json
{
  "cacheDirs": [
    { "path": "%LOCALAPPDATA%\\Temp", "reason": "user temp folder", "minAgeDays": 1 }
  ],
  "relativeCacheNames": ["Cache", "Code Cache", "GPUCache"],
  "cacheScanRoots": ["%LOCALAPPDATA%", "%APPDATA%"]
}
```

- `path` 支持 `%环境变量%` 和 `~`（用户目录）
- `minAgeDays`：只删比这个天数更老的文件，0 表示全删
- `relativeCacheNames`：在 AppData 里按名字匹配的缓存文件夹（Chrome / Electron 应用的那一套）
- 想加自己的目录，往 `cacheDirs` 里加一条就行

### `rules/autostart-allowlist.json`

这里列的项永远不会被标记或禁用：

```json
{ "entries": [
  { "name": "RtkAudUService*", "match": "RtkAudUService64", "why": "Realtek audio" }
] }
```

## 可疑自启动是怎么判的

每个自启动项按规则加分，**≥3 分才报出来**：

| 特征 | 分 |
|---|---|
| 非 Windows 程序却注册在 `\Microsoft\...` 任务路径下 | +4 |
| 数字签名无效 / 没有签名 | +3 |
| 名字故意模仿系统组件（HiddenLoader、RUXIM…） | +3 |
| 没有公司 / 版本信息 | +2 |
| 文件名像随机串（`etywRHcV63I0`） | +2 |
| 从 Temp / Downloads 目录启动 | +2 |
| 计划任务指向的文件根本不存在 | +2 |
| 签名有效的 Program Files 软件 | −4 |

举个真实案例，这个工具只报了一条，就是真木马：

```
[score 12] ScheduledTask: HandleCommand
         - non-Windows binary registered under \Microsoft\Windows\AppID\
         - not validly signed: C:\Program Files\RUXIM\HiddenLoaders.exe
         - no company/version metadata
         - name imitates a Windows component
```

它的手法值得记住：把自己伪装成微软的「AD RMS 权限策略模板」计划任务，登录后延迟 30 秒启动、以最高权限运行，还顺手把自己的目录加进 Defender 白名单。

## 安全设计

1. **默认不删任何东西。** 不加 `-Apply` 永远只是打印 "would delete"。
2. **硬性保护路径。** `C:\Windows\System32`、`WinSxS`、`Fonts`、`C:\Program Files`、`C:\Users` 这些根目录本身，即使用户在规则里写了也会被拒绝。
3. **删压缩包前先比对。** 必须找到同名解压目录，且目录大小 ≥ 压缩包的一半，才认定"已经解压过"。
4. **注册表改动先备份。** 输出到 `reports/autorun-backup-时间戳.json`。
5. **每步都写日志。** `reports/rescue-时间戳.log`。
6. **删除失败不重试、不绕过。** 被占用的文件直接跳过并记录。

## 输出

```
reports/
  rescue-20261107-195214.log          # 完整操作日志
  autorun-backup-20261107-195214.json # 自启动项备份
```

## 目录结构

```
win-disk-rescue/
├─ Invoke-DiskRescue.ps1   入口：参数解析、模式分发
├─ lib/
│  ├─ Common.ps1           日志、大小计算、带护栏的删除
│  ├─ Scan.ps1             只读盘点（大目录、大文件、缓存、压缩包、自启动评分）
│  ├─ CleanSafe.ps1        免提权清理
│  └─ CleanAdmin.ps1       需要提权的维护
├─ rules/
│  ├─ junk-paths.json      缓存目录规则
│  └─ autostart-allowlist.json  自启动白名单
└─ reports/                日志与备份（不入库）
```

## 想加自己的规则

最常见的两种需求：

**加一个要清理的目录** —— 编辑 `rules/junk-paths.json`，往 `cacheDirs` 加一行，路径用 `%变量%`。

**误报某个自启动项** —— 编辑 `rules/autostart-allowlist.json`，加 `{"name": "你的程序名", "match": "exe名"}`。`name` 支持通配符。

## 已知限制

- 只处理 NTFS 上的本地盘，网络盘和 BitLocker 锁定的盘会被跳过
- `-Mode Admin` 的每一步都要管理员权限，非提权状态下会明确提示并跳过，不会静默失败
- 搬移 WSL 会先 `wsl --shutdown`，正在运行的 Linux 任务会被中断
- 页面文件改动需要重启才生效

## License

MIT。随便用，出事别找我。
