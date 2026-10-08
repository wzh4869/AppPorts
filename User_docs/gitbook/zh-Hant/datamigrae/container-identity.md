# 容器資料、沙盒與簽名身分

{% hint style="success" %}
**一句話結論**

`~/Library/Containers/` 和 `~/Library/Group Containers/` 裡的資料屬於**沙盒應用程式**。這類資料用"捷徑"（符號連結）搬到外接磁碟是讀不到的；AppPorts 以前靠「重簽名此應用」繞過這一點，代價是應用程式在 macOS 27 上可能無法開啟，登入狀態也可能遺失。

從 1.9.0 起，容器資料改用[掛載遷移](mount-migration.md)，簽名一個位元組都不變更。已經被重簽名過的應用程式需要重新安裝，步驟見 [macOS 27 升級說明](../macos-27.md)。
{% endhint %}

這篇文件解釋來龍去脈。如果你的應用程式已經打不開了，直接去 [macOS 27 升級說明](../macos-27.md) 看修復步驟。

## 容器是什麼 <a href="#容器是什麼" id="容器是什麼"></a>

macOS 上大部分應用程式執行在"沙盒"裡：系統給每個應用程式分配一個專屬資料夾，就是 `~/Library/Containers/<Bundle ID>/`，應用程式只能在裡面讀寫。App Store 上架的應用程式必須這樣，微信、QQ 音樂這類官網下載的應用程式也大多這樣。多個應用程式共享的資料放在 `~/Library/Group Containers/`。

判斷一個應用程式是不是沙盒應用程式，看它的授權資訊裡有沒有 `com.apple.security.app-sandbox`：

```bash
codesign -d --entitlements - --xml /Applications/WeChat.app 2>/dev/null | grep -c app-sandbox
# 输出 1 就是沙盒应用
```

有一點容易被忽略：**主程式不沙盒，不代表它的容器可以隨便動。** Chrome、Edge 的主程式不在沙盒裡，但它們的小工具和延伸功能各有自己的容器；那些容器的主人是沙盒行程。所以 AppPorts 對 `Containers` 下的所有目錄一視同仁，不看主程式。

## 搬走容器資料的三條路 <a href="#搬走容器資料的三條路" id="搬走容器資料的三條路"></a>

| 做法 | 結果 | 原因 |
|------|------|------|
| 複製到外接磁碟，原地留符號連結 | 應用程式能開啟，但讀不到資料；微信會報「儲存位置不能使用」 | 沙盒檢查的是連結**指向哪裡**，指向容器外就拒絕。指向外接磁碟和指向桌面結果一樣 |
| 符號連結 + Ad-hoc 重簽名 | macOS 26 及以下能用；升到 27 後可能按兩下秒退（微信已確認，QQ 音樂仍能開） | 重簽名把沙盒身分拆了，符號連結才"生效"。但它同時清除了應用程式和容器之間的歸屬關係，27 起系統要核對這層關係 |
| 把外接磁碟上的一個 APFS 卷宗掛載到原目錄 | 正常，簽名不變更 | 路徑沒有離開容器，沙盒放行；資料在外接磁碟上會彈一次系統授權對話框，按一下允許即可 |

前兩條已經在 macOS 27 上實測確認，第三條也是。原始日誌見[實驗紀錄：符號連結](https://app.gitbook.com/s/ND8nWiaPokAkDK7Ae7Wg/zhi-nan/research/sandbox-symlink)和[實驗紀錄：掛載點](https://app.gitbook.com/s/ND8nWiaPokAkDK7Ae7Wg/zhi-nan/research/sandbox-mountpoint)。

## 重簽名到底動了什麼 <a href="#重簽名到底動了什麼" id="重簽名到底動了什麼"></a>

Ad-hoc 重簽名（`codesign --force --deep --sign -`）會從應用程式裡清除：

| 遺失的內容 | 後果 |
|------------|------|
| `com.apple.security.app-sandbox` | 應用程式不再以沙盒身分執行 |
| `com.apple.security.application-groups` | 讀不到 `Group Containers` 裡的共享資料 |
| `keychain-access-groups` | 讀不到鑰匙圈裡的登入狀態、資料庫金鑰 |
| Team ID | 系統核對"這個容器是不是你的"時對不上 |

應用程式不會當場出問題。它以一般行程身分去讀自己的容器，macOS 26 及以下放行；27 上如果系統裡已存有它舊簽名的授權記錄，就會因為"程式碼要求不比對"被拒絕：

```
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData
  (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files): denied
runningboardd: termination reported by launchd (0, 0, 65280)
```

同一臺機器、同一個重簽名過的微信：

| 系統 | 表現 |
|------|------|
| macOS 26.6.2 | 連續用了兩天半，正常 |
| macOS 27.0 | 每次啟動約 0.4 秒後退出 |

{% hint style="warning" %}
**"以前一直沒事"不是安全的證據**

重簽名後能正常用幾週甚至幾個月，問題只在下一次大版本升級時爆發，升級前後沒有任何提示。而且原始開發者的憑證不在你的電腦上，清除的授權沒法重新簽回去，只能重新安裝。
{% endhint %}

## 為什麼從終端能開啟 <a href="#為什麼從終端能開啟" id="為什麼從終端能開啟"></a>

排查時容易被這一點誤導。系統按"責任行程"記賬：從 Finder 或 Dock 按兩下時，應用程式自己是責任行程，用自己的身分申請權限，被拒；從終端或某個已有完整磁碟取用權限的程式裡啟動時，責任行程算在宿主頭上，應用程式相當於借用了宿主的權限。

所以"終端裡能起來"不算修好。判斷標準只有 Finder / Dock 按兩下。

## 自查 <a href="#自查" id="自查"></a>

把 `/Applications/WeChat.app` 換成你要查的應用程式：

```bash
# 1. 签名身份
codesign -dv --verbose=4 /Applications/WeChat.app 2>&1 | grep -E "Authority|TeamIdentifier|Signature"

# 2. 授权（正常输出一段 XML；只有 Executable= 一行说明已被抹掉）
codesign -d --entitlements - /Applications/WeChat.app

# 3. 容器里有没有指向外置盘的符号链接
find ~/Library/Containers/<Bundle ID> -maxdepth 6 -type l -exec readlink {} \; 2>/dev/null

# 4. 复现一次，看系统有没有拒绝
open -a /Applications/WeChat.app; sleep 3
log show --last 1m --style compact 2>/dev/null | grep -iE "rejected approval request|deny\(1\) file-read-data"
```

| 觀察結果 | 意義 |
|----------|------|
| `Signature=adhoc` 且 `TeamIdentifier=not set` | 已被重簽名；打不開時需要重新安裝應用程式 |
| 第 3 步有輸出且指向 `/Volumes/...` | 容器裡還有舊的符號連結，需要先還原 |
| 日誌有 `kTCCServiceSystemPolicyAppData ... denied` | 正在被拒絕取用自己的容器（重簽名導致） |
| 日誌有 `deny(1) file-read-data /Volumes/...` | 沙盒拒絕跟隨符號連結（資料在外接磁碟導致） |

兩種日誌可能同時出現，對應兩個獨立的問題，要分別處理。

## 修復 <a href="#修復" id="修復"></a>

順序不能亂，否則重新安裝完的應用程式看到的仍是符號連結，會誤以為重新安裝沒用：

1. **還原容器資料**：在 AppPorts「應用程式資料」頁把該應用程式所有「已連結」的容器目錄逐個「還原」回本機。
2. **重新安裝應用程式**：從官方管道覆蓋安裝，恢復原始簽名和沙盒。容器資料不會被重新安裝刪除。
3. **需要的話再掛載遷移**：重新安裝後容器目錄會顯示「掛載遷移」，想繼續放到外接磁碟就再遷一次。

新版 AppPorts 的「恢復原始簽名」可以從完整備份恢復原應用程式，無需開發者私鑰。舊版只有身分名稱的記錄需要選擇同版本官方原版，或從官方管道重新安裝；詳見[簽名備份與恢復](resign.md#qian-ming-bei-fen-yu-hui-fu)。恢復簽名前仍需先還原經典模式遷移的容器目錄。

詳細步驟和已遷移到外接磁碟的應用程式怎麼處理，見 [macOS 27 升級說明](../macos-27.md#xiu-fu)。

## 真實案例 <a href="#真實案例" id="真實案例"></a>

2026 年 9 月，一臺真實機器上的完整過程：

| 時間 | 事件 |
|------|------|
| 9/15 04:46 | AppPorts 把微信聊天資料目錄遷移到外接磁碟，原地留符號連結 |
| 9/15 04:47 | AppPorts 對微信執行 Ad-hoc 重簽名 |
| 9/16 至 9/18 | macOS 26.6.2 下微信正常使用兩天半 |
| 9/18 04:46 | 升級到 macOS 27.0 |
| 9/18 起 | 每次啟動約 0.4 秒後退出 |
| 9/18 05:04 | 使用者還原資料並再次重簽名，問題依舊 |
| 9/18 | 還原資料 + 從官網重新安裝微信，恢復正常，聊天記錄完整 |

資料從頭到尾沒有損壞。真正的埋伏是重簽名，它在升級前沒有任何症狀。

## 相關文件 <a href="#相關文件" id="相關文件"></a>

- [macOS 27 升級說明](../macos-27.md)：升級前檢查清單和修復步驟
- [掛載遷移](mount-migration.md)：新方案怎麼用
- [為什麼外接磁碟必須是 APFS](../why-apfs.md)
- [重簽名與當機防護](resign.md)：重簽名功能現在的邊界
