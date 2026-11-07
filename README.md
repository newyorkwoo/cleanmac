# CleanMac

[English](#english)

原生 macOS 清理與優化工具（SwiftUI）。所有處理都在本機進行，不會上傳任何資料。

## 安裝

需要 macOS 14 以上版本。Release 提供的安裝映像只支援 Apple Silicon（M 系列晶片）。

1. 到 [Releases](https://github.com/newyorkwoo/cleanmac/releases/latest) 下載 `CleanMac.dmg` 並開啟，把 CleanMac 拖到「應用程式」資料夾。
2. App 尚未經過 Apple 公證，第一次開啟時 macOS 會阻擋。到「系統設定 > 隱私權與安全性」選擇「強制打開」即可。
3. 建議到「系統設定 > 隱私權與安全性 > 完整磁碟取用權限」加入 CleanMac，否則垃圾桶和部分 App 資料無法掃瞄。

## 從原始碼建置

建置需要 Xcode 命令列工具。

```sh
scripts/package.sh --install   # 建置、產生 dist/CleanMac.dmg 並安裝（請先結束 App）
scripts/package.sh             # 只產生 .app 和 .dmg
swift test                     # 執行測試
```

腳本會用這台 Mac 上的 Apple Development 憑證簽署，所以重新建置後不必重新授權；沒有憑證時會改用臨時簽署。
這個簽署只適合自己使用：App 未經 Apple 公證，分享給別人時 macOS 會阻擋。

## 語言

側邊欄左下角可切換繁體中文、简体中文、日本語、English、한국어、Latina，選擇會保留，第一次開啟時會跟隨系統語言。

- 翻譯在 `Sources/CleanMacCore/Translations.swift`，以繁體中文原文為鍵。新增介面文字請用 `L("...")` 並加入翻譯，漏掉時測試會失敗。
- App 選單列和系統對話框由 macOS 提供，重新開啟 App 後才會跟著切換。macOS 沒有拉丁文資源，所以選拉丁文時這些部分會顯示英文。

## 功能

| 功能 | 說明 |
| --- | --- |
| 智慧掃瞄 | 一次檢查勾選的項目，並顯示磁碟、記憶體與 CPU 狀態 |
| 垃圾檔案 | 快取、記錄檔、Xcode 與開發工具快取、舊安裝檔、iOS 備份、已移除 App 的殘留 |
| 大型檔案 | 依大小或日期列出個人檔案 |
| 重複檔案 | 以 SHA-256 比對內容，每組至少保留一份 |
| 相似照片 | 以裝置端 Vision 分析找出近乎相同的照片 |
| 磁碟地圖 | 以方塊圖呈現空間用量，可逐層查看 |
| 記憶體 | 用量、記憶體壓力、占用最多的程序，以及執行 `purge` 釋放快取 |
| 開機項目 | 停用或啟用 LaunchAgents／Daemons，管理登入項目 |
| 應用程式 | 依名稱、大小或上次使用排序。解除安裝時會深度清除相關資料，包含 `/Library` 中的系統項目、背景服務和輔助工具 |
| 安全檢查 | SIP、Gatekeeper、FileVault、防火牆、軟體更新、App 簽章與可疑開機項目 |
| 檔案粉碎 | 以隨機資料覆寫後刪除 |
| 選單列 | 隨時查看記憶體、CPU 與磁碟狀態 |

## 安全設計

- 掃瞄不會刪除檔案，清理前一定會先確認。
- 除了垃圾桶類別和檔案粉碎，所有清理都是移到垃圾桶，可以救回。
- 所有刪除都經過 `PathGuard`，會拒絕系統路徑、家目錄主要資料夾、鑰匙圈和 `.ssh` 等位置。
- 不會跟隨符號連結，也不會讀取尚未下載的雲端檔案。
- 解除安裝是唯一會動到 `/Library` 的清理：只處理 bundle ID、完整 App 名稱或背景服務設定明確對應到該 App 的項目，不碰 Apple 的項目，並且需要管理者密碼。系統項目同樣移到垃圾桶，要放回時也需要密碼。

## 限制

- 安全檢查不是防毒軟體，沒有惡意程式資料庫，只比對已知廣告軟體名稱和可疑特徵。
- 第三方 App 的更新只檢查 Homebrew，不檢查其他來源。
- 檔案粉碎在 SSD／APFS 上無法保證物理抹除，敏感資料請搭配 FileVault。
- `purge` 只清除檔案快取。macOS 本來就會自動管理記憶體，效果通常短暫。
- 內建於 App 中的背景項目（SMAppService）無法在此列出，請到系統設定調整。
- 深度解除安裝不會依安裝套件的檔案清單刪除，也不會移除安裝記錄（receipts），所以名稱對不上 App 的檔案可能會留下。

## English

A native macOS cleanup and optimization tool built with SwiftUI. Everything runs locally, and no data is uploaded.

### Installation

Requires macOS 14 or later. The disk image on the Releases page supports Apple Silicon (M-series chips) only.

1. Download `CleanMac.dmg` from [Releases](https://github.com/newyorkwoo/cleanmac/releases/latest), open it, and drag CleanMac to the Applications folder.
2. The app isn't notarized by Apple, so macOS blocks it the first time you open it. Go to System Settings > Privacy & Security and choose Open Anyway.
3. We recommend adding CleanMac under System Settings > Privacy & Security > Full Disk Access. Without it, the Trash and some app data can't be scanned.

### Language

Use the picker at the bottom left of the sidebar to switch between 繁體中文, 简体中文, 日本語, English, 한국어 and Latina. Your choice is saved, and the first launch follows the system language.

- Translations are in `Sources/CleanMacCore/Translations.swift`, keyed by the Traditional Chinese source text. Wrap new UI text in `L("...")` and add its translations. Tests fail if any are missing.
- The app's menu bar and system dialogs come from macOS, so they change language only after you reopen the app. macOS has no Latin resources, so these parts appear in English when Latin is selected.

### Features

| Feature | Description |
| --- | --- |
| Smart Scan | Checks all selected items at once and shows disk, memory and CPU status |
| Junk Files | Caches, logs, Xcode and developer tool caches, old installers, iOS backups, and leftovers from removed apps |
| Large Files | Lists personal files by size or date |
| Duplicate Files | Compares contents with SHA-256 and keeps at least one copy in each group |
| Similar Photos | Finds near-identical photos using on-device Vision analysis |
| Disk Map | Shows space usage as a treemap you can drill into |
| Memory | Usage, memory pressure, top processes, and running `purge` to free caches |
| Startup Items | Disables or enables LaunchAgents and LaunchDaemons, and manages login items |
| Applications | Sorts by name, size or last used. Uninstalling also removes related data, including system items, background services and helper tools in `/Library` |
| Security Check | SIP, Gatekeeper, FileVault, firewall, software updates, app signatures, and suspicious startup items |
| File Shredder | Overwrites files with random data, then deletes them |
| Menu Bar | Shows memory, CPU and disk status at any time |
