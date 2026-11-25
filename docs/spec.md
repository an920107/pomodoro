# 智慧無觸控番茄鐘 — 系統架構與介面規格書 (v1.2)

本文件為「嵌入式期末專案 — 智慧番茄鐘」之系統規格與軟硬體介面合約（Interface Control Document）。ESP32 韌體端（C）與手機端（Flutter）開發者應以此文件為唯一標準（Single Source of Truth），進行獨立開發與聯調測試。

> **版本變更紀錄**：
> *   **v1.2**：全面統一通訊封包格式為 `{"cmd": <int>, "data": {...}}`（回應帶入 `"code": <int>`）；所有指令、狀態、類型與錯誤碼改為數值 Enum；GATT Characteristics 精簡為 `RPC` 與 `Status` 兩條通道，大幅簡化雙端解析器實作。
> *   **v1.1**：確立全系統文字編碼採用純 ASCII（`0x20` ~ `0x7E`）；`TodoList` 改為單筆指令操作並擴充上限至 10 筆。

---

## 1. 系統架構與設計原則

### 1.1 職責劃分（Single Source of Truth）
為了確保斷線後系統仍能正常運作，本專案採用 **「ESP32 為主（Master）、App 為輔（Controller/Viewer）」** 的架構：

*   **ESP32 端（C / 建議使用 ESP-IDF）**：
    *   **狀態主導權**：掌管番茄鐘的計時器、狀態機、距離感測判斷、LED、蜂鳴器與螢幕顯示。
    *   **離線運作能力**：即使手機斷線，ESP32 依然獨立完成倒數、離位暫停與結束提醒，並將完成的紀錄暫存於本地端（NVS / RAM Ring Buffer），待連線後同步給 App。
    *   **本地持久化**：儲存基本設定（專注/休息時間、提示音開關、To-Do List、Phase 2 時區）。
*   **手機端（Flutter）**：
    *   **設定與遙控介面**：提供圖形化介面設定時間、編輯 To-Do List、發送控制指令。
    *   **長期資料儲存**：接收 ESP32 同步的專注紀錄，存入手機本地資料庫（如 SQLite / Hive）以供查詢歷史報表。
    *   **手機系統整合**：在專注期間觸發勿擾模式（DND）或應用程式鎖定。

### 1.2 開發階段劃分
*   **Phase 1 (MVP 核心功能)**：BLE 通訊、番茄鐘計時、距離感測離位暫停、LED/蜂鳴器、實體按鈕切換顯示（倒數時間 / To-Do List）、手機設定與歷史紀錄、基本斷線重連同步。
*   **Phase 2 (進階擴充)**：螢幕顯示「現在時間」、時區設定、透過 Matter over Wi-Fi 接入 Apple Home / Google Home。

---

## 2. 系統狀態機 (State Machine)

ESP32 內部維護以下狀態，App 端僅負責接收並呈現對應 UI，不可自行捏造狀態。

| 狀態代碼 (`state`) | 狀態名稱 | 說明 | LED 狀態 | 距離感測器行為 |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `IDLE` | 待機中，尚未開始計時 | 熄滅 | 不觸發暫停（僅可選擇性回報是否在位） |
| `1` | `FOCUS_RUNNING` | 專注倒數中 | 熄滅 | **啟用**：離位超過寬限期 -> 轉為 `FOCUS_PAUSED_AWAY` |
| `2` | `FOCUS_PAUSED_USER` | 使用者手動暫停（透過 App） | 慢閃（可選） | 停用（不會因為回到座位而自動繼續） |
| `3` | `FOCUS_PAUSED_AWAY` | 系統偵測到離位而自動暫停 | **恆亮** | **啟用**：回到座位超過確認期 -> 自動轉回 `FOCUS_RUNNING` |
| `4` | `BREAK_RUNNING` | 休息倒數中 | 熄滅 | **停用**（休息時間允許且鼓勵離開座位） |
| `5` | `BREAK_PAUSED_USER` | 休息手動暫停 | 慢閃（可選） | 停用 |

### 狀態轉換與蜂鳴器規則
1.  **開始專注 (`IDLE` -> `FOCUS_RUNNING`)**：蜂鳴器響起「開始提示音」（例如：短嗶 1 聲）。
2.  **專注結束 (`FOCUS_RUNNING` 倒數至 0)**：
    *   蜂鳴器響起「結束提示音」（例如：長嗶 2 聲）。
    *   ESP32 產生一筆 `Session Log`（結果為 `0: COMPLETED`）。
    *   狀態自動轉為 `IDLE`（建議 Phase 1 轉為 `IDLE` 並由使用者決定何時開始休息，避免使用者沒注意到就開始算休息時間）。
3.  **中途停止 (`ANY` -> `IDLE`)**：
    *   若原本在 `FOCUS_*` 狀態且已專注超過 1 分鐘，產生一筆 `Session Log`（結果為 `1: ABORTED`，記錄實際專注秒數）。
4.  **提示音開關 (`mute = true`)**：上述所有蜂鳴器動作皆靜音，僅透過螢幕與 LED 提示。

---

## 3. BLE 通訊協定與統一封包規格

全系統統一採用 **純 ASCII 編碼（可列印字元 `0x20` ~ `0x7E`）** 與 **單一封包框架**，所有單次封包皆小於 **120 bytes**，確保 Android 與各代 iOS 裝置皆可一次無痛傳輸。

### 3.1 基礎連線參數與 GATT 結構
將所有指令收斂至 `RPC` 通道，並將每秒主動推播的 `Status` 獨立出來（避免 1Hz 的狀態推播與 RPC 指令回應互相干擾）：

*   **裝置廣播名稱 (Device Name)**：`SmartPomodoro`（或 `Pomodoro_XXXX`，後四碼為 MAC 尾碼）
*   **MTU 協商**：連線後 **Android 端必須主動呼叫 `requestMtu(512)`**（iOS 自動協商），ESP32 端須設定 `ble_att_set_preferred_mtu(512)`。
*   **Primary Service UUID**：`a0b1c2d3-e4f5-4678-9abc-def012345600`

| 名稱 | UUID | 權限 | 方向 | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| **RPC** | `...5601` | `WRITE`, `NOTIFY` | 雙向 (Req/Res) | 所有控制、設定、To-Do、歷史同步的統一指令通道 |
| **Status** | `...5602` | `READ`, `NOTIFY` | ESP32 -> App | 即時狀態推播（狀態變更立即發送，計時中每 1 秒發送） |

*(註：`...5601` 代表 `a0b1c2d3-e4f5-4678-9abc-def012345601`。)*

---

### 3.2 統一封包框架 (Unified Envelope)

雙邊只需撰寫**一套** JSON 解析與打包函式：

*   **請求封包 (App -> ESP32，寫入 `RPC`)**：
    ```json
    {"cmd": 202, "data": {"t": "Write Report"}}
    ```
    *   `cmd` (`int`)：指令編號（見 3.3 節）。
    *   `data` (`object`)：參數物件；若該指令無參數，請帶入空物件 `{}`。

*   **回應 / 推播封包 (ESP32 -> App，透過 `RPC` 或 `Status` Notify)**：
    ```json
    {"cmd": 202, "code": 0, "data": {"i": 2, "id": 15, "len": 3}}
    ```
    *   `cmd` (`int`)：原樣回傳對應的請求指令編號（`Status` 推播固定為 `1`）。
    *   `code` (`int`)：執行結果狀態碼（`0` 代表成功，非 `0` 代表錯誤，見 3.4 節）。
    *   `data` (`object`)：回傳資料；若無回傳內容或發生錯誤，回傳 `{}`。

> **App 端實作提醒（序列佇列）**：Flutter 端對 `RPC` 通道應實作一個 **Command Queue**，每次僅發送一個 `WRITE`，等待 `RPC Notify` 回傳相同 `cmd` 的回應（設定 3 秒 Timeout）後再發送下一筆，即可保證請求與回應嚴格一對一對應。

---

### 3.3 指令編號總表 (`cmd` Enum)

建議 ESP32 (`protocol.h`) 與 Flutter (`protocol.dart`) 直接照以下編號定義常數：

#### A. 系統狀態推播 (`1` — 走 `Status` Characteristic)
| `cmd` | 常數名稱 | 說明 |
| :--- | :--- | :--- |
| `1` | `EVT_STATUS` | 狀態變更立即 Notify，計時中每 1 秒 Notify，亦支援 App 主動 `READ` |

*   **`Status` 回傳範例**：
    ```json
    {
      "cmd": 1,
      "code": 0,
      "data": {
        "state": 1,
        "rem": 1485,
        "tot": 1500,
        "away": false,
        "todo_id": 12,
        "unsynced": 2
      }
    }
    ```
    *   `state` (`int`)：對應第 2 節狀態機（`0`~`5`）。
    *   `rem` / `tot` (`int`)：剩餘秒數 / 本階段總秒數。
    *   `away` (`bool`)：感測器目前是否判定離位。
    *   `todo_id` (`int`)：目前專注綁定的待辦 ID（`-1` 表示未綁定）。
    *   `unsynced` (`int`)：ESP32 本地尚未同步的歷史紀錄筆數（`> 0` 時 App 應觸發同步）。

---

#### B. 系統與計時控制 (`10` ~ `19` — 走 `RPC`)
| `cmd` | 常數名稱 | Request `data` | Response `data` (成功時) | 說明 |
| :--- | :--- | :--- | :--- | :--- |
| `10` | `CMD_SYNC_TIME` | `{"epoch":1763970900,"tz":28800}` | `{}` | 校準系統 UTC 時間與時區偏移秒數（台灣為 `28800`） |
| `11` | `CMD_START_FOCUS` | `{"todo_id":12}` | `{}` | 開始專注（`todo_id` 傳 `-1` 表示不綁定項目） |
| `12` | `CMD_START_BREAK` | `{}` | `{}` | 開始休息 |
| `13` | `CMD_PAUSE` | `{}` | `{}` | 手動暫停目前計時 |
| `14` | `CMD_RESUME` | `{}` | `{}` | 恢復手動暫停的計時 |
| `15` | `CMD_STOP` | `{}` | `{}` | 停止計時並回到 `IDLE` |

---

#### C. 裝置設定 (`100` ~ `109` — 走 `RPC`)
修改後 ESP32 須立即寫入 NVS 保存。

| `cmd` | 常數名稱 | Request `data` | Response `data` (成功時) | 說明 |
| :--- | :--- | :--- | :--- | :--- |
| `100` | `CMD_CFG_GET` | `{}` | `{"focus_min":25,"break_min":5,"mute":false,"away_cm":80,"away_grace":5}` | 讀取目前所有設定 |
| `101` | `CMD_CFG_SET` | `{"focus_min":25,"break_min":5,"mute":false,"away_cm":80,"away_grace":5}` | `{}` | 更新設定（支援全量寫入；`focus_min`: 1~120, `break_min`: 1~60） |

---

#### D. 待辦事項操作 (`200` ~ `209` — 走 `RPC`)
*   **規則**：索引 `i`, `j` 為 **0-based**；清單上限 **10 筆**（`MAX_TODOS = 10`）；標題 `t` 僅限 **ASCII `0x20`~`0x7E`**，長度 **1~24 字元**。
*   **內部 `id`**：ESP32 於 `append` 時自動分配遞增的 `uint16_t` 唯一編號，不隨 `swap` 或 `delete` 改變，供歷史紀錄綁定使用。
*   **持久化**：凡呼叫 `202`~`205` 修改清單，ESP32 須立即寫入 NVS 並刷新螢幕（若處於 To-Do 畫面）。

| `cmd` | 常數名稱 | Request `data` | Response `data` (成功時) | 說明 |
| :--- | :--- | :--- | :--- | :--- |
| `200` | `CMD_TODO_GET_LEN` | `{}` | `{"len":3,"max":10}` | 取得目前筆數 `len` 與上限 `max` |
| `201` | `CMD_TODO_GET` | `{"i":0}` | `{"i":0,"id":12,"t":"Embedded Final","d":false}` | 取得第 `i` 筆的詳細內容（`d`: 是否完成） |
| `202` | `CMD_TODO_APPEND` | `{"t":"Write Report"}` | `{"i":2,"id":15,"len":3}` | 新增項目至尾端（預設 `d: false`） |
| `203` | `CMD_TODO_UPDATE` | `{"i":0,"t":"Final Demo","d":true}` | `{}` | 更新第 `i` 筆（`t` 與 `d` 皆為選填，傳哪個就更新哪個） |
| `204` | `CMD_TODO_DELETE` | `{"i":1}` | `{"len":2}` | 刪除第 `i` 筆，後方項目自動遞補 |
| `205` | `CMD_TODO_SWAP` | `{"i":0,"j":2}` | `{}` | 交換索引 `i` 與 `j` 的位置（支援拖曳排序） |

---

#### E. 歷史紀錄同步 (`300` ~ `309` — 走 `RPC`)
ESP32 本地佇列建議容量至少 20 筆（存於 NVS，滿時採 FIFO 覆蓋最舊資料）。

| `cmd` | 常數名稱 | Request `data` | Response `data` (成功時) | 說明 |
| :--- | :--- | :--- | :--- | :--- |
| `300` | `CMD_HIST_PEEK` | `{}` | `{"log_id":104,"start":1763960000,"dur":1500,"type":0,"res":0,"todo_id":12}` | 讀取最舊一筆未同步紀錄（若佇列為空，回傳 `code: 20`） |
| `301` | `CMD_HIST_ACK` | `{"log_id":104}` | `{"unsynced":1}` | App 確認存檔後通知 ESP32 刪除該筆紀錄，並回傳剩餘筆數 |

*   **歷史紀錄欄位數值定義**：
    *   `type` (`int`)：`0` = 專注 (`FOCUS`)、`1` = 休息 (`BREAK`)。
    *   `res` (`int`)：`0` = 正常完成 (`COMPLETED`)、`1` = 中途停止 (`ABORTED`)。
    *   `start` (`int`)：開始時的 Unix Timestamp（若尚未校時則為 `0`，App 收到 `0` 時以當下接收時間估算）。

---

### 3.4 狀態與錯誤碼總表 (`code` Enum)

| `code` | 常數名稱 | 說明 |
| :--- | :--- | :--- |
| `0` | `ERR_OK` | 執行成功 |
| `1` | `ERR_INVALID_JSON` | JSON 語法錯誤，或缺少 `cmd` / `data` 欄位 |
| `2` | `ERR_UNKNOWN_CMD` | 未知的 `cmd` 編號 |
| `3` | `ERR_INVALID_PARAM` | 參數型別錯誤、缺少必要參數或數值超出合法範圍 |
| `4` | `ERR_INVALID_STATE` | 當前狀態機不允許執行此指令（例如 `IDLE` 時呼叫 `CMD_PAUSE`） |
| `10` | `ERR_TODO_FULL` | To-Do 清單已達 10 筆上限，無法 `APPEND` |
| `11` | `ERR_TODO_OUT_OF_RANGE` | To-Do 索引 `i` 或 `j` 超出 `0 ~ len-1` 範圍 |
| `12` | `ERR_TODO_INVALID_TITLE` | 標題為空、超過 24 字元、或包含非 ASCII 字元 |
| `20` | `ERR_HIST_EMPTY` | 歷史紀錄佇列目前為空（無待同步資料） |
| `21` | `ERR_HIST_ID_MISMATCH` | `CMD_HIST_ACK` 的 `log_id` 與佇列最舊紀錄不符 |

---

## 4. 斷線處理與資料同步機制

藍牙連線極易因手機進入背景、使用者帶手機離開座位、或訊號干擾而中斷，雙邊必須嚴格實作以下機制：

### 4.1 斷線當下的行為
1.  **ESP32 端**：
    *   **不中斷計時**：番茄鐘照常運作，距離感測、LED、蜂鳴器、實體按鈕均不受影響。
    *   **自動恢復廣播**：BLE `DISCONNECT` 事件觸發後，ESP32 必須立即重新開啟 BLE Advertising，等待手機重連。
    *   **離線紀錄**：若在斷線期間倒數結束，將紀錄寫入 History 佇列並存於 NVS（防止斷電遺失）。
2.  **Flutter App 端**：
    *   **UI 提示**：頂部顯示「裝置已斷線，嘗試重連中...」，並鎖定控制與 To-Do 編輯按鈕（避免無效操作）。
    *   **自動重連機制**：啟動背景掃描與指數退避重連（例如每 3 秒嘗試重連，失敗 5 次後改為每 10 秒）。
    *   **勿擾/鎖定處理**：若斷線前處於 `FOCUS_RUNNING`，App 應**維持**勿擾/鎖定狀態，並依據斷線前最後收到的 `rem` 進行本地倒數估算；若本地倒數歸零仍未重連，則自動解除手機鎖定，避免使用者手機被永久鎖死（**安全閥機制**）。

### 4.2 重新連線後的握手流程 (Reconnection Handshake)
每次 BLE 連線成功（包含初次連線與斷線重連），Flutter 端必須依序執行以下步驟：
1.  **協商 MTU**：Android 呼叫 `requestMtu(512)`（iOS 跳過此步）。
2.  **訂閱 Notify**：依序開啟 `RPC` (`...5601`) 與 `Status` (`...5602`) 的 Notify。
3.  **時間同步**：發送 `cmd: 10 (CMD_SYNC_TIME)`。
4.  **拉取最新狀態與設定**：
    *   主動 `READ` `Status` (`...5602`)。
    *   發送 `cmd: 100 (CMD_CFG_GET)` 取得最新設定。
    *   同步 To-Do List：發送 `cmd: 200 (CMD_TODO_GET_LEN)` 取得 `len`，接著以迴圈依序發送 `cmd: 201 (CMD_TODO_GET)` (`i = 0 .. len-1`) 重建清單。
5.  **補齊離線紀錄**：若 `Status.data.unsynced > 0`，進入迴圈發送 `cmd: 300 (CMD_HIST_PEEK)` -> 存入 App DB -> 發送 `cmd: 301 (CMD_HIST_ACK)`，直到回傳 `code: 20 (ERR_HIST_EMPTY)` 或 `unsynced == 0`。

---

## 5. ESP32 韌體開發規格 (C)

### 5.1 建議開發環境與架構
*   **Framework**：強烈建議使用 **ESP-IDF (v5.x)** 搭配 FreeRTOS（原生支援 NimBLE、`cJSON`，且為 Phase 2 `esp-matter` 唯一官方環境）。
*   **FreeRTOS Task 建議切分**：
    *   `sensor_task`：每 100ms 讀取距離感測器並做濾波。
    *   `timer_task`：1 秒精準計時（或使用 `esp_timer`）推進狀態機並觸發 `Status` Notify。
    *   `ui_task`：處理實體按鈕中斷/消抖（Debounce）、更新螢幕畫面、控制 LED/蜂鳴器。
    *   `ble_task`：接收 `RPC` 寫入事件，透過單一 `switch (cmd)` 分派處理（使用 Mutex 保護共用資料結構）。

### 5.2 距離感測器防誤觸演算法（必做細節）
無論使用 ToF（如 VL53L0X）或超音波（如 HC-SR04），原始數值都會有雜訊，**不可直接用單次讀值判斷離位**：
1.  **濾波**：取連續 5 次量測的**中位數濾波 (Median Filter)**，去除異常極值。
2.  **遲滯區間 (Hysteresis)**：假設 `away_cm = 80`，則：
    *   距離 `> 85 cm` 判定為「離開候選」。
    *   距離 `< 75 cm` 判定為「在位候選」。
    *   介於 `75 ~ 85 cm` 之間維持原狀態，防止在邊界反覆跳動。
3.  **寬限時間 (Grace Period)**：
    *   在 `FOCUS_RUNNING` 時，必須連續 `away_grace`（預設 5 秒）處於「離開候選」，才正式切換為 `FOCUS_PAUSED_AWAY` 並點亮 LED。
    *   在 `FOCUS_PAUSED_AWAY` 時，必須連續 **2 秒** 處於「在位候選」，才自動恢復為 `FOCUS_RUNNING` 並熄滅 LED。

### 5.3 螢幕顯示與按鈕互動
*   **顯示模式切換（短按按鈕）**：
    *   模式 A：**倒數模式**（大字體顯示 `MM:SS`、目前狀態圖示、靜音圖示、藍牙連線圖示）。
    *   模式 B：**To-Do List 模式**（條列顯示清單事項，超過螢幕行數可自動輪播或透過短按捲動）。
    *   模式 C（Phase 2）：**現在時間模式**（顯示 `HH:MM` 與日期）。
*   **實體按鈕長按功能（防呆備案）**：
    *   長按 2 秒：切換「提示音開關 (`mute`)」並立即更新 NVS。
*   **純 ASCII 字型規範**：
    *   全系統僅支援 **ASCII 可列印字元（`0x20` ~ `0x7E`）**，ESP32 端只需內建輕量級英數點陣字型（如 6x8 / 8x16）。
    *   處理 `CMD_TODO_APPEND` / `CMD_TODO_UPDATE` 時，須驗證每個 byte 落於 `0x20 <= c && c <= 0x7E`，否則回傳 `code: 12 (ERR_TODO_INVALID_TITLE)`。

---

## 6. Flutter App 開發規格

### 6.1 建議套件與輸入限制
*   **BLE 通訊**：`flutter_blue_plus`（支援 MTU 協商與跨平台重連）。
*   **本地資料庫**：`sqflite` 或 `hive`（儲存歷史專注紀錄，供圖表統計用）。
*   **狀態管理**：`Riverpod` 或 `Provider`（將 BLE 連線與裝置狀態封裝為全域 State）。
*   **To-Do 輸入驗證**：在文字輸入框加入 `FilteringTextInputFormatter.allow(RegExp(r'[\x20-\x7E]'))` 與 `maxLength: 24`，並透過 `ReorderableListView` 對應 `cmd: 205 (CMD_TODO_SWAP)`。

### 6.2 「鎖定應用程式與關閉通知」的平台限制與實作策略
*   **Android（較容易實作）**：
    *   **關閉通知 (DND)**：使用 `flutter_dnd` 套件取得「勿擾模式存取權」，於 `FOCUS_RUNNING` 時開啟靜音/勿擾，結束或暫停時恢復。
    *   **鎖定應用程式**：透過 Android Native Channel 結合 `UsageStatsManager` 與 `SYSTEM_ALERT_WINDOW`（懸浮視窗權限），偵測到前景為黑名單 App 時彈出全螢幕遮罩。
*   **iOS（系統限制極嚴格）**：
    *   不允許第三方 App 直接開關勿擾模式；鎖定其他 App 需付費開發者帳號並申請 `FamilyControls` 審核。
    *   **務實解法**：若主力為 Android 則完整實作；若為 iOS，建議改採「專注模式保持螢幕常亮 + 偵測退到背景超過 5 秒發送本地推播警告」，並輔以 iOS 捷徑教學。

---

## 7. Phase 2 擴充架構預留 (時間與 Matter over Wi-Fi)

1.  **晶片選型注意**：Matter over Wi-Fi + BLE 對 RAM/Flash 消耗極大，若確定做 Phase 2，硬體建議優先選用 **ESP32-S3** 或 **ESP32-C6**（8MB Flash 以上）。
2.  **時間來源策略**：Phase 1 靠 `cmd: 10 (CMD_SYNC_TIME)` 校時；Phase 2 連上 Wi-Fi 後自動啟動 SNTP 校時，並沿用 `tz` 偏移量轉換當地時間。
3.  **Matter 裝置模型對應**：註冊為 **On/Off Plug-in Unit（智慧開關）** + **Occupancy Sensor（人體存在感測器）**，實現「開關即專注、入座狀態連動智慧檯燈」。

---

## 8. 雙邊獨立開發與聯調計畫 (Mock Strategy)

### 8.1 獨立測試工具
*   **ESP32 開發者**：使用手機 App **nRF Connect for Mobile** 連線至 ESP32：
    *   只需訂閱 `RPC` (`...5601`) 與 `Status` (`...5602`) 兩條 Notify。
    *   直接對 `RPC` 寫入統一格式 JSON 進行測試，例如：
        *   開始專注：`{"cmd":11,"data":{"todo_id":-1}}`
        *   新增待辦：`{"cmd":202,"data":{"t":"Study C"}}`
        *   讀取長度：`{"cmd":200,"data":{}}`
*   **Flutter 開發者**：建立 `BleRepository` 抽象介面，實作 `MockBleRepository`（用純 Dart 模擬相同的 `cmd` / `code` / `data` 回應與 1Hz `EVT_STATUS` 串流）與 `RealBleRepository`，前期不需等待硬體即可完成所有 UI 與同步邏輯。

### 8.2 整合里程碑建議
1.  **Milestone 1 (介面握手)**：完成掃描連線、MTU 協商、訂閱 `RPC` 與 `Status`，並驗證 `cmd: 10 (SYNC_TIME)` 回傳 `{"cmd":10,"code":0,"data":{}}`。
2.  **Milestone 2 (核心閉環)**：測試 `cmd: 11 (START_FOCUS)` -> 蜂鳴器響並每秒收到 `cmd: 1 (EVT_STATUS)` -> 離位 5 秒觸發 LED 亮與 `state: 3` -> 回座恢復。
3.  **Milestone 3 (設定與清單 CRUD)**：完整測試 `cmd: 100~101` 與 `cmd: 200~205`，確認 ESP32 螢幕即時更新且斷電重開機後資料仍在（NVS 驗證）。
4.  **Milestone 4 (斷線壓力測試)**：計時中關閉藍牙 -> 等倒數結束 -> 重開藍牙 -> 確認自動重連並透過 `cmd: 300 / 301` 補齊離線歷史紀錄。