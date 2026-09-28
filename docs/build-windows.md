# Windows 平台构建指南（阅读M / MReader）

> 面向本机（Windows 开发机）的构建与排错。**其他平台见 `README.md` 的平台清单**；
> 本文只讲 Windows，因为它是本项目 P0 平台之一，且有几处**只在 Windows 上才会踩到**的坑。
>
> 维护：M2b-T09 收官时建档（`M2b-T01` 的 `Q4 ③` 遗留项「Developer Mode 构建文档」在此闭环）。

---

## 1. 为什么必须先开「开发人员模式（Developer Mode）」

Flutter 在 Windows 上构建**含原生插件**的桌面/移动应用时，构建系统需要对 `windows/flutter/ephemeral/`
下的插件目录建**符号链接**（symlink）。普通用户默认没有创建符号链接的权限，于是构建会直接失败并提示：

```
Building with plugins requires symlink support.

Please enable Developer Mode in your system settings. Run
  start ms-settings:developers
to open Settings.
```

本工程依赖多个原生插件（`pdfrx`、`liquid_glass_widgets` 等），**必然触发**此检查。

### 开启方式（任选其一）

- **图形界面**：`设置` → `隐私和安全性` → `开发者选项` → 打开「**开发人员模式**」。
  命令行直达：`start ms-settings:developers`
- **注册表（管理员 PowerShell，不改界面）**：

  ```powershell
  # 1 = 开启，0 = 关闭
  New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
    -Name AllowDevelopmentWithoutDevLicense -PropertyType DWORD -Value 1 -Force
  ```

### 快速自检

```powershell
# 应输出 1（已开）/ 0 或不存在（未开）
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
  -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
```

> **诚实降级**：不开 Developer Mode 时，`flutter build windows` / `flutter build apk`（含插件）会失败，
> 但 `flutter analyze` 与纯 Dart 测试不受影响。若只是跑测试，可不理会本节。

---

## 2. 桌面构建前置（Visual Studio 工具链）

Windows 桌面目标（`flutter build windows`）需要 **Visual Studio 2022** 的
「**使用 C++ 的桌面开发**」工作负载（含 MSVC v143 + Windows 10/11 SDK）。

```powershell
flutter doctor -v      # 看 "Visual Studio - develop Windows apps" 一节是否 ✅
```

Android 目标（`flutter build apk`）另需 **Android SDK / JDK 17**（本机 JDK 17 已就绪）。

---

## 3. 本机特有的两个坑（都已实证）

### 3.1 Gradle 全局 init 脚本 vs Flutter 3.47+

**症状**：Android 构建在解析 `dev.flutter.flutter-plugin-loader` 时**约 861ms 秒挂**。

**根因**：Flutter 3.47+ 起，`packages/flutter_tools/gradle` 作为 `includeBuild`
（报错里显示为 `project ':gradle'`）自带 `settings.gradle.kts` 并设置
`FAIL_ON_PROJECT_REPOS`；而本机 `~/.gradle/init.d/` 下的镜像脚本（aliyun + flutter engine 仓库）
会用 `gradle.beforeProject` 给**每个工程**注入 `maven { }`，于是被它拒绝。

**处置**：该 `init.d` 脚本已改为「读取该构建的 `settings.gradle.kts` 文本，若含
`FAIL_ON_PROJECT_REPOS` 则整体跳过注入」（2026-09-24，原脚本已备份 `*.bak.20260924`）。
换机器时若重现，按同一思路处理：**不要给 Flutter 的 includeBuild 注入工程级仓库**。

### 3.2 玻璃特效观感（`Q3`）

本机 Windows 的玻璃被库**静态封顶 `standard`**（PRD §11.4 末条，1.7.0 已复核），与
Android 主力机（Impeller 默认启用）**观感不一致**。

> ⚠️ **2026-09-28 修正**：原注「本机 Windows 走 **Skia 轻量路径**」的前提**已失效**——
> 项目已于 **2026-09-24 升至 Flutter 3.47.5**，而 Windows 获得 Impeller ANGLE 渲染路径
> 只需 Flutter ≥3.47，**门槛现已满足**。Windows 与 Android 观感仍可能不同，但**原因已转为
> 库自身的平台封顶策略**（`_shouldSkipPremiumPreload()` 对 `windows` 返回 `true`），
> 不再是「没有 Impeller ANGLE」。**实际观感差异待在 Windows 上重新实测**。

**不要在 Windows 上反复调玻璃视觉**——视觉调优集中在 Android 真机一次性完成
（PRD `Q1`/`Q3`；`schedule.md` §4.2 的 N-5 已写明该约束）。

---

## 4. 常用构建 / 运行命令

```powershell
flutter pub get                       # 拉依赖（本机 pub 缓存：D:\pub_cache）
flutter analyze                       # 静态检查（不需要 Developer Mode）
flutter test                          # 全量测试（把 tmp_book/ 放好可跑真样本冒烟）
bash tool/test.sh parse               # 分组局部测试（见 docs/tech-usage.md）
flutter build windows --debug         # 桌面调试构建（需要 Developer Mode + VS2022）
flutter build apk --debug             # Android 调试包
flutter run -d windows                # 桌面直跑
flutter run -d <android-device-id>    # Android 真机直跑
```

> **本项目的协作约定**：`flutter` / `build` / `adb` 等命令由**负责人手动执行**；
> AI 只产出可执行命令文本与代码/文档，并自动完成 `git commit`。

---

## 5. 排错速查

| 现象 | 处置 |
|---|---|
| `Building with plugins requires symlink support` | 开 Developer Mode（§1） |
| Android 解析 plugin-loader 秒挂 | 检查 `~/.gradle/init.d/` 全局注入（§3.1） |
| `Unable to find suitable Visual Studio toolchain` | 装 VS2022「使用 C++ 的桌面开发」工作负载 |
| pub 解析慢 / 失败 | 确认 `PUB_CACHE=D:\pub_cache`；必要时 `flutter pub cache repair` |
| PDF 打不开、提示加密 | 预期行为：加密 PDF 明确拒绝（`Q4 ④`），非缺陷 |
| 中文乱码（重定向到文件） | Git Bash 用 `... 2>&1 \| (printf '\xEF\xBB\xBF'; cat) > out.txt`；PowerShell 见 `docs/tech-usage.md` 同条 |

---

## 6. 验收对应关系

- Windows 构建属于 §17「跨里程碑持续项」的五平台发布验收（`M4-T08`）范围；
- 本文件在 `M2b-T09` 建档，作为**五平台冒烟备料**的 Windows 分册（总清单见 `docs/acceptance-M2b.md`）。
