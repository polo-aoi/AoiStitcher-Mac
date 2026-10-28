# AoiStitcher 项目交接说明（Tasks 1–4）

> 面向接手者（Code X / 新开发者）的自包含说明。读完即可继续，无需追问背景。

## 0. 项目简介

AoiStitcher 是一款 macOS 拼图（照片拼版）软件，用 Swift 实现，SwiftUI 与 AppKit 混合（`NSViewRepresentable`、Quick Look 预览等）。  
本轮迭代围绕「项目库」做了 4 项改动：引入全局项目根目录与老数据自动迁移、首页卡片封面与右键菜单、纯引用式导入（不再复制原图）、以及缺图修复。

## 1. 当前状态

- Tasks 1–4 **全部完成**。
- 库代码全量编译通过；10 组回归测试共 **565 项**全部通过。
- 真实 UI / 系统交互行为（见第 8 节）需在 Xcode 构建出的 App 中手动验收。

## 2. 关键文件

| 文件                                      | 职责                    |
| --------------------------------------- | --------------------- |
| `AoiStitcher/AppPreferences.swift`      | 项目根目录配置（UserDefaults） |
| `AoiStitcher/ProjectLibraryStore.swift` | 项目库核心：持久化、导入、修复、缩略图   |
| `AoiStitcher/ProjectLibraryView.swift`  | 首页卡片与右键菜单             |
| `AoiStitcher/AppSettingsView.swift`     | 设置页「项目存储位置」           |
| `scripts/test-project-library.sh`       | 回归测试脚本                |

## 3. Task 1 — 全局项目根目录 + 老项目迁移

**目标**：把项目数据从应用容器（Application Support）挪到用户可见、易备份的全局目录，并自动迁移旧数据。  
**改动**：

- `AppPreferences`：新增 `projectRootKey`（`UserDefaults`，**不**入 `preferenceKeys`，防止"恢复默认"误挪数据）、`defaultProjectRootName = "AoiStitcher 项目"`、`projectRootURL()`（nonisolated，默认 `~/Pictures/AoiStitcher 项目/`）。
- `ProjectLibraryStore`：静态 `projectsDirectory` 改名为 `legacyProjectsDirectory`（应用容器路径，作为迁移**源**）；新增 `configuredProjectsDirectory(in:)` 读取 `AppPreferences.projectRootURL()`。`init` 默认参数改为 `configuredProjectsDirectory()`；新增 `migrateLegacyProjectsIfNeeded()`，仅在 `projectsDirectory == configuredProjectsDirectory()`（即生产环境，跳过测试临时目录）时执行：扫描遗留目录中 UUID 命名的项目子文件夹 → 移动到新根目录 → 刷新列表 → 删除空的遗留目录。两处 `protectedDirectories` 改为 `[directory, legacyProjectsDirectory]`。
- `AppSettingsView`：通用设置新增「项目存储位置」区块——显示当前路径 +「更改位置…」（NSOpenPanel 选文件夹写入 `projectRootKey`）+ 提示「重启后生效」。  
  **约定**：项目文件夹沿用 **UUID 命名**（改名不挪动底层目录）。

## 4. Task 2 — 首页卡片封面 + 右键菜单

**目标**：首页不再显示空文件夹图标，改为封面拼图，并支持右键操作。  
**改动**：

- `ProjectLibraryStore`：`ProjectSummary` 扩展 `coverAssets: [ProjectSummaryCoverAsset]`（取前 3 张 active 资产的 id/fileName/contentRevision/sourcePath/isReference），`summary()` 填充。新增方法：
  - `revealProjectInFinder(id:)`（NSWorkspace 定位到访达）
  - `renameProject(id:to:)`（改名称并刷新，不动 UUID 目录）
  - `deleteProject(id:)`（移到废纸篓）
  - `cachedCoverThumbnail` / `requestCoverThumbnail(projectID:asset:)`（独立封面加载器，`Task.detached` 后台解码，结果存 NSCache，key=`cover/<projectID>/<assetID>`）
- `ProjectLibraryView`：新增 `ProjectCoverImage`（异步加载）与 `ProjectCoverCard`（首张大图 + 右侧最多 2 张小图；「共 N 张」角标；空项目占位卡；底部项目名 + 更新时间）。卡片 = `Button`（左键打开）+ `.contextMenu`（打开 / 重命名… / 在访达中显示 / 删除项目…）。重命名用 sheet，删除用 confirmationDialog（提示移废纸篓不影响原图）。

## 5. Task 3 — 纯引用导入 + 缺图检测

**目标**：导入不再复制原图，只记录原文件位置（Lightroom 式），并检测缺图。  
**改动**：

- `ProjectLibraryStore`：`ProjectAsset` 新增 `isReference: Bool = false`（`L50`，旧复制项目默认 false）；原 `copyImages` 改名为 `referenceImages`（`L1642`），**只记录 `sourcePath`，不复制字节**；`performImport` 在 `Task.detached` 前先算出 `destination`；`assetURL(_:)` 对引用资产直接解析 `sourcePath`。`ProjectSummary` 新增 `missingCount`（`L300`），`summary()` 用 `FileManager` 存在性检查统计缺图（引用→`sourcePath`，复制→`Originals/文件名`）。
- 导入面板文案改为「项目只记录照片位置，不复制原图；移动原文件后可用「修复项目」重新连接。」
- **复制导入功能已整体删除**，模型为纯引用。

## 6. Task 4 — 修复项目（重连缺失源文件）

**目标**：原图被移动/改名导致缺图时，用户指定新位置批量重连。  
**改动**：

- `ProjectLibraryStore`：`repairProject(id:locatingIn:)`（`L703–747`）枚举所选文件夹（含子目录）建立「文件名→URL」索引，把缺失的引用资产（`isReference` 且 `sourcePath` 不存在）重连到新位置，更新 `sourcePath`/`sourceFileSize`/`contentRevision` 并保存；返回重连数量。
- `ProjectLibraryView`：右键「修复项目…」（`L287`，缺图数为 0 时禁用）→ `repairProject(_:)`（`L202`，NSOpenPanel 选文件夹）→ `library.repairProject(id:locatingIn:)`（`L210`）。
- 编译修复（本任务唯一阻塞，已解决）：`L713` 的 `for url in enumerator {` 改为 `for case let url as URL in enumerator {`（`enumerator` 元素是 `Any`，需转为 `URL` 才能调 `resourceValues`）。

## 7. 构建与验证

- 环境：Xcode 26.2 / macOS 14.6，arm64+x86_64 通用构建，无沙箱、无开发者签名。
- 回归：`zsh scripts/test-project-library.sh`（10 组，565 项）。
  - ⚠️ 该脚本会编译 `Item.swift`（Xcode 模板残留的 SwiftData 文件），在独立 `swiftc` 下被沙箱挡住宏插件而**失败**。正确做法：
    - (a) 在 Xcode 内跑测试；**或**
    - (b) 临时脚本排除 `Item.swift`（及 `AoiStitcherApp.swift`）。
  - ⚠️ 本机 `swiftc` **不识别** `--dangerouslyDisableSandbox` 参数（报 unknown argument），排除文件即可，不要加该参数。
- 验证结果：排除 `Item.swift` + `AoiStitcherApp.swift` 后全量编译通过，10 组回归 565 项全过。

## 8. 仍需手动验收的 UI 行为

回归测试覆盖库逻辑，**不覆盖**真实 UI / 系统交互。请在构建出的 App 中确认：

1. 首页卡片封面拼图 +「共 N 张」角标显示正常；
2. 右键五项菜单（打开 / 重命名 / 修复项目 / 在访达中显示 / 删除）均生效；
3. 导入为纯引用（不复制原图）；
4. 移动原图 → 卡片显示缺图角标 → 右键「修复项目…」选新位置可重连；
5. 启动后老项目自动从应用容器迁移到 `~/Pictures/AoiStitcher 项目/`；
6. 设置页「项目存储位置」可改路径，重启后生效；
7. 照片素材区空格预览 + 方向键翻页时选择框实时跟随（本轮回之前已完成，一并验收）。

## 9. 后续可迭代方向（可选）

- 项目文件夹改用友好名称（当前为 UUID）；
- 封面加载器对超大 / 异常图片的边界处理；
- 修复项目的模糊匹配（目前仅按精确文件名）。

---

*生成于 2026-10-28。Tasks 1–4 已全部完成并通过 565 项回归。*
