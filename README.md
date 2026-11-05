# MissionClose — 窗口匹配修复版

在 macOS 调度中心（Mission Control）和 App Exposé 的窗口缩略图上，直接关闭、最小化或进入全屏。

这是 [beqaabu/MissionClose](https://github.com/beqaabu/MissionClose) 的公开分叉，基于提交 `ac2fef9`，由 [YunYu-Mzz](https://github.com/YunYu-Mzz) 维护本地修复。保留上游 MIT 许可证及原作者署名。本仓库当前提供源码，尚未发布可下载的安装包。

![上游功能演示，非本分叉的验证录像](site/demo.gif)

## 本分叉的改动

- 优先用系统窗口编号和所属进程匹配缩略图，减少微信等应用中标题不同、同名窗口造成的问题。
- 补充主窗口、焦点窗口和直接窗口子节点，处理部分 App 的窗口列表不完整的情况。
- 关闭前刷新目标窗口，避免优先使用已失效的缓存。
- 不再把辅助功能读取超时或权限不足误报为“窗口已经关闭”。
- 修复浮层按钮尺寸更新及“关闭其他窗口”的结果汇总。
- 关闭请求后确认真实窗口消失，清理按钮浮层，并自动重新打开调度中心以重新排列剩余缩略图。
- 添加只读诊断入口，以及不依赖签名证书的本机构建脚本。

详细说明见 [LOCAL_FIXES.md](LOCAL_FIXES.md)。[UPSTREAM_README.md](UPSTREAM_README.md) 保留上游说明，其中的下载、网站及 Homebrew 命令属于原项目。

## 构建

需要 macOS 13 或更高版本，以及 Xcode Command Line Tools。修复版目前在 Apple Silicon、macOS 26.5 上做过本地构建和部分实际验证；未对所有系统版本、应用及显示器配置验证。

```sh
git clone https://github.com/YunYu-Mzz/MissionClose.git
cd MissionClose
./tools/test.sh
./build-local.sh
```

产物为 `build/MissionClose.app`。默认只构建，不安装、不修改证书信任或隐私授权。

先退出正在运行的 MissionClose，再安装：

```sh
INSTALL=1 ./build-local.sh
```

安装路径是 `~/Applications/MissionClose.app`，旧版会备份到仓库的 `backups/`。请避免同时运行上游版本和本分叉，它们目前使用相同的 App 标识及偏好设置。

如有已经配置好的稳定代码签名身份：

```sh
SIGN_IDENTITY='签名身份名称或 SHA-1' INSTALL=1 ./build-local.sh
```

默认使用 ad-hoc 签名，重新编译后可能需要重新授予辅助功能权限。需要通用架构构建时可用上游脚本：`ADHOC=1 NO_INSTALL=1 ./build.sh`。

## 使用

默认在后台运行，**不显示顶部菜单栏图标**。需要调整设置或退出时，从访达或 Spotlight 再次打开 MissionClose，点击 **Settings…**。其中的 **Show Menu Bar Icon** 可随时恢复图标，选择会在重启后保留。

在 **系统设置 → 隐私与安全性 → 辅助功能** 中添加安装后的 MissionClose，并开启权限。欢迎窗口应显示 `Accessibility access granted`。若旧条目仍对应旧版本，先移除旧条目，再添加新 App。

打开调度中心，把鼠标移到窗口缩略图上：

| 操作 | 按钮或快捷键 |
| --- | --- |
| 关闭当前窗口 | × 或 ⌘W |
| 最小化窗口 | − 或 ⌘M |
| 进入全屏 | 全屏按钮 |
| 退出对应 App | ⌥ + × 或 ⌘Q |
| 关闭同一 App 的其他窗口 | ⌘⌥W |

快捷键作用于鼠标悬停的缩略图。关闭窗口与退出 App 是不同操作。

**关闭后重新排列：** 默认开启 **Refresh Layout After Closing**。确认窗口消失后，会自动收起、重新打开一次调度中心，让 macOS 清除旧占位并重新计算布局，因此会有短暂的退出/进入动画。布局及缩略图比例仍由系统决定，不保证无间隙铺满屏幕。可以在 Settings… 中关闭此选项。

刷新等待期间按 Esc、点击别处、滑动切换桌面会取消自动重开；关闭取消或窗口仍在等待保存时不会据此判定关闭成功。App Exposé（单个应用的窗口总览）仅清理按钮，不自动重开，以免应用退出后切换到其他应用的总览。

## 已知限制

- **备忘录的兼容问题尚未彻底修复。** 实测有时调度中心显示缩略图，但备忘录返回空的辅助功能窗口列表。这时无法安全关闭；先打开备忘录主窗口，再进入调度中心，曾恢复窗口识别，但不保证永久解决。
- 找不到准确的窗口编号、同名同形窗口无法区分时，会拒绝操作，避免关闭错误窗口。
- 使用了部分未公开的 macOS 接口及行为，系统升级后可能需要调整。
- 已通过 52 项单元检查、完整构建及签名校验，并做过部分真实窗口的只读匹配验证。新增刷新流程包含退出、重开、取消及超时的状态检查；调度中心完整动画和浮层点击流程仍需实际使用验证，自动化工具不能可靠操作该系统总览。
- 应用中的更新检查指向本分叉；在发布首个 Release 前，手动检查更新可能提示没有可用版本。不要使用上游 Homebrew 命令来更新本分叉。

## 诊断与隐私

菜单中的 **Write Read-Only Diagnostics** 会把诊断写入 `~/Library/Logs/MissionClose-probe.txt`；失败日志位于 `~/Library/Logs/MissionClose.log`。

也可运行：

```sh
open -n "$HOME/Applications/MissionClose.app" --args --probe
```

直接从终端执行二进制时，权限状态可能受启动程序影响；确认后台 App 自身权限请看欢迎窗口或从运行中的 App 菜单生成诊断。

诊断包含窗口标题、应用名称、进程编号及本机路径，可能涉及私人信息，提交 issue 前请自行删去敏感内容。日志、签名材料、备份和构建产物均已加入忽略规则。诊断不会自动上传；版本检查会访问 GitHub。

## 许可证与致谢

[MIT License](LICENSE)。原项目作者：Beqa Abuladze。保留原项目的署名、图标和示例素材；本仓库的演示素材来自上游，并非本分叉新增功能的验证记录。
