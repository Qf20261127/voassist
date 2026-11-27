# 旁白 Pro（VoAssist）修复版 — 构建说明

## 一、修了什么

日志确认的根因：方案里的音色标识写的是 `com.apple.voice.super-compact.zh-CN.Tingting`，而 iPhone 上实际只有 `com.apple.voice.compact.zh-CN.Tingting`，取音色失败后静默无声。

改了 3 处，都在"找不到就降级"这一层，不改变原有行为：

| 文件 | 改动 |
|---|---|
| `Sources/BoostCore/SharedSettings.swift` | 新增 `VoiceEntry.candidateIDs()`：把标识里的质量层级（super-compact / compact / premium / enhanced）互换，生成候选列表 |
| `Sources/BoostCore/SystemVoice.swift` | `resolve()` 改为三级查找：① 精确标识与候选层级 ② 扩展上报的可用声音列表里同语言的第一项 ③ 该语言的系统默认声音 |
| `App/AppModel.swift` | ① 选择页回退过滤从"只认 `.super-compact.`"改为"所有 Apple 自带声音"，避免婷婷在列表里根本不出现；② 默认方案生成时把写死的标识替换成这台设备实际有的那个（先精确、再同语言同名、再同语言第一个） |
| `Sources/BoostCore/SystemVoice.swift` | 另外每次取音色都写一行诊断日志 `voice lookup … -> 实际标识`，日志里能直接看出命中了哪个层级、或为何失败 |
| `Sources/BoostCore/SystemVoice.swift` | 创建 `AVSpeechSynthesizer` 前激活 `AVAudioSession`（`.playback` + `.mixWithOthers/.duckOthers`）并置 `usesApplicationAudioSession = true`，每次合成前再确认一次。iOS 16 的 `write` 没有活动会话就静默不回调，这正是扩展无声的直接原因 |

原始文件已备份在 `_orig_backup/`，改动补丁为 `_orig_backup/改动.patch`。

## 二、在 GitHub 上出 ipa（不需要 Mac）

> 现状（2026-11-27 已完成）：仓库已建好 <https://github.com/Qf20261127/voassist>，代码已推送，Actions 第 3 次运行成功，ipa 已挂在 Release：<https://github.com/Qf20261127/voassist/releases/download/build-3/VoAssist.ipa>（1.59 MB）。下面的步骤留作以后重新出包用。

1. 在 GitHub 新建一个**私有**仓库（例如 `voassist-fix`）。
2. 把本目录内容推上去：

```bash
cd 旁白 Pro-修复版
git remote set-url origin https://github.com/<你的账号>/voassist-fix.git
git add -A && git commit -m "fix: 音色标识层级降级，修复 iOS 16 上无声"
git branch -M main
git push -u origin main
```

3. 打开仓库 → **Actions** → 左侧 `build-ipa` → 右侧 **Run workflow** → Run。
4. 等约 5～10 分钟，进入这次运行，在页面底部 **Artifacts** 下载 `VoAssist-unsigned-ipa`，解压得到 `VoAssist.ipa`。

私有仓库每月有 2000 分钟免费额度，macOS runner 按 10 倍计费，仍足够跑几十次。

## 三、装到手机（TrollStore）

1. 把 `VoAssist.ipa` 传到手机（AirDrop / 文件 App / 局域网都行）。
2. 用**巨魔商店（TrollStore）** 打开该 ipa → Install。
3. 装完打开 App，先确认：
   - 方案列表里有"婷婷+Samantha"；
   - 点试听，能听到婷婷的声音。
4. 再到 设置 → 辅助功能 → 朗读内容 → 声音 → 中文（普通话），把"旁白 Pro：婷婷+Samantha"选上。

## 四、为什么必须是 TrollStore

Workflow 产出的是**未签名 ipa**，里面是用 `ldid` 伪签并写入了 `group.com.zdyi.voassist` 这个 App Group 权限。TrollStore 安装时会保留这些 entitlements，所以 App 和语音扩展能共享方案文件。

用免费 Apple ID 自签（Sideloadly / AltStore）**不行**：免费个人团队不支持 App Groups，扩展读不到方案，装上照样无声。

## 五、验证失败时看哪里

App 内 → 日志 → 导出，重点看：

- `扩展可用的声音` 里是否有 `com.apple.voice.compact.zh-CN.Tingting`；
- `语音扩展的记录` 里这次是否出现了 **render / 合成** 记录（原日志只有 init，说明请求没进到合成）；
- 试听时提示文字：`合成失败：noVoice` = 仍然取不到音色；`timedOut` = 引擎卡住；显示秒数但没声音 = 播放层问题。

## 六、编译验证情况（2026-11-27 已跑通）

Actions 在 `macos-15` runner 上编译通过（run 3），第 6 处音频会话修复随代码一起编译，`swift test` 与 `xcodebuild -scheme VoAssist -sdk iphoneos -configuration Release` 均成功。

构建过程中踩到并已修掉的两点：

| 现象 | 处理 |
|---|---|
| `ldid -S` 在 runner 上直接 `ldid.cpp(852): _assert(): false` | workflow 改为先试 `ldid`，失败则回退 `codesign --force --sign - --entitlements <plist>` 做 ad-hoc 伪签名，两条路径都写入 entitlements |
| Artifact 下载需要登录，本机网络不稳 | 构建成功后用 `softprops/action-gh-release` 自动挂到 Release，公开链接可直接下 |
| 本地浅克隆推送报 `did not receive expected object` | 用 `git fetch --unshallow https://github.com/myjy/VoAssist.git` 补齐历史后推送正常 |

ipa 实测校验：`Payload/VoAssist.app/VoAssist` 与 `PlugIns/VoAssistVoice.appex/VoAssistVoice` 两个二进制里都含 `com.apple.security.application-groups` 与 `group.com.zdyi.voassist`；扩展标识 `com.zdyi.voassist.voice`，AudioComponent 为 `ausp / VoAs / Zdyi`，MinimumOSVersion 16.0，版本 1.0.0 (31)。

原作者署名与许可证：Apache-2.0，见 `LICENSE`。
