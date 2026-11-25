# Smart Pomodoro（智慧互動式桌面番茄鐘 App — Phase 1 MVP）

本專案為智慧型實體桌面番茄鐘之 Android Flutter 伴侶 App（Phase 1 MVP），通訊介面、狀態機與系統互動行為皆嚴格對齊 [`docs/spec.md`](../docs/spec.md) **v1.2**。

---

## 1. 功能與架構概覽

- **通訊協定層 (`lib/core/protocol/`)**：
  - 實作 `v1.2` JSON-over-GATT 協定模型與常數（Service `...5600`、RPC `...5601`、Status `...5602`、`maxPacketBytes = 120`、純 ASCII `0x20..0x7E` 檢查）。
  - 單線序列命令佇列 (`RpcCommandQueue`) 與 3 秒逾時重試保護，確保同一時間僅有一筆進行中的 RPC，避免與 1Hz `EVT_STATUS` 互搶。
- **雙軌藍牙儲存庫 (`lib/data/ble/`)**：
  - `BleRepository` 抽象介面支援兩種模式即時切換：
    - `MockBleRepository`：純 Dart 虛擬 ESP32 韌體，完整模擬 NVS 持久化、1Hz 倒數推播、離位暫停、斷電重啟、斷線背景倒數與歷史紀錄佇列。
    - `RealBleRepository`：使用 `flutter_blue_plus` 執行 BLE 掃描、Android `requestMtu(512)`、訂閱 Notify 與指數退避重連（前 5 次每 3 秒、後續每 10 秒）。
  - `HandshakeCoordinator`：嚴格執行 §4.2 五步驟重連握手（`MTU(512)` -> `Subscribe` -> `CMD_SYNC_TIME (10)` -> `READ Status` / `CMD_CFG_GET (100)` / `CMD_TODO_GET (200~201)` -> `CMD_HIST_PEEK (300)` / SQLite / `CMD_HIST_ACK (301)`）。
- **本地歷史資料庫與統計 (`lib/data/local/`, `lib/ui/stats/`)**：
  - `SqliteAppDatabase`（`pomodoro.db`）採用複合鍵 `(log_id, raw_start_epoch, duration_sec, type, result)` 去重寫入、`known_todos` 歷史名稱快照、未校時紀錄 (`start == 0`) 接收估算標記。
- **Android 原生專注守護 (`android/.../FocusGuardService.kt`)**：
  - Foreground Service（`foregroundServiceType="specialUse"`）於 `FOCUS_RUNNING` 時開啟系統勿擾模式（並於暫停/離位/停止還原）、以 `UsageStatsManager.queryEvents` 每 500ms 偵測前景黑名單 App 並透過 `WindowManager` 顯示全螢幕鎖定遮罩，內建原生 `SystemClock.elapsedRealtime()` `(rem + 2)s` 斷線安全閥。
- **一般使用模式 vs 開發者除錯模式 (`DebugModeController`)**：
  - 首次啟動預設為 **一般使用模式**（隱藏 Mock 模擬面板、自檢與封包監看器，僅呈現真實 BLE 連線介面與專注流程）。
  - 連續點擊底部導覽列「**設定**」分頁 **5 次**（3 秒內）即可開啟 `DebugModeSheet`（開發者除錯模式選單），即時啟用 `Mock 虛擬韌體模擬器`、`BLE 封包即時監看器`、`通訊與虛擬韌體自檢` 或重置模擬 NVS；關閉 Debug Mode 時會自動切回真實藍牙模式。
- **內建除錯工具（Debug 模式可見）**：
  - 計時頁 `Mock 虛擬韌體模擬器`：無硬體即可模擬離位／回座、快轉剩 5 秒／已過 65 秒、斷線重連、注入未校時紀錄、斷電重啟。
  - 設定頁 `BLE 封包即時監看器` (`PacketInspectorScreen`)：免接電腦即時檢視與篩選 `[BLE-TX]` / `[BLE-RX]` / `[SYNC]` / `[GUARD]` / `[APP]` 日誌，支援標籤篩選、排序切換、複製與清除。

---

## 2. 開發環境與建置測試指令

專案鎖定使用 **FVM Flutter SDK**（`app/.fvm/flutter_sdk/bin/flutter`）：

```bash
cd app

# 下載相依套件
.fvm/flutter_sdk/bin/flutter pub get

# 靜態分析（須為 0 issues）
.fvm/flutter_sdk/bin/flutter analyze

# 執行全部單元、Widget 與 Milestone 1-4 驗收測試
.fvm/flutter_sdk/bin/flutter test

# 打包 Debug / Release APK（含 R8 混淆驗證）
.fvm/flutter_sdk/bin/flutter build apk --debug
.fvm/flutter_sdk/bin/flutter build apk --release
```

---

## 3. Android 權限與 ADB 實機驗證指令

FocusGuard 功能需下列 Android 權限（可透過 App 內「專注守護設定」前往系統設定開啟，或開發階段以 ADB 授予）：

```bash
# 安裝 Release APK
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 授予 FocusGuard 與 BLE 測試權限（非 root 除錯指令）
adb shell cmd notification allow_dnd com.example.pomodoro
adb shell appops set com.example.pomodoro GET_USAGE_STATS allow
adb shell appops set com.example.pomodoro SYSTEM_ALERT_WINDOW allow
adb shell pm grant com.example.pomodoro android.permission.POST_NOTIFICATIONS

# 檢視 BLE 封包與原生專注守護日誌
adb logcat -s flutter:V FocusGuard:D

# 客觀查驗系統勿擾模式 (0 = ZEN_MODE_OFF, 1 = ZEN_MODE_IMPORTANT_INTERRUPTIONS)
adb shell dumpsys notification | grep mZenMode

# 測試系統藍牙開關與重連健壯性
adb shell cmd bluetooth_manager disable
adb shell cmd bluetooth_manager enable
```

> **Android 12+ 提示**：系統內建「設定 (`com.android.settings`)」頁面受作業系統 `HIDE_NON_SYSTEM_OVERLAY_WINDOWS` 保護旗標限制會自動隱藏第三方懸浮窗，實機驗證全螢幕遮罩時建議將一般應用程式（如 `com.google.android.calculator` 或 Chrome）加入黑名單進行測試。
