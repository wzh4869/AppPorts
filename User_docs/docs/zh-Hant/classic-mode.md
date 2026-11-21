# 經典模式

「經典資料遷移模式」保留了較早版本使用符號連結處理容器資料的方式。它預設關閉，主要供仍依賴舊遷移的使用者理解和處理現狀。

## 開啟後改變什麼 {#changes}

開啟後，適用的容器項目可以提供舊式連結遷移及相關連結管理操作。具體目錄仍需通過保護與衝突檢查，不會因為開啟開關就全部可遷移。

目前版本中，**遷移和重簽名是分開的操作**。開啟經典模式不等於同意自動重簽，也不恢復舊版「遷移後重簽名」的流程。手動重簽的用途和限制見[設定與權限](/docs/settings#manual-signing)。

## 為什麼不作為預設方式 {#why}

容器存取受系統限制，符號連結指向容器外部後，應用可能讀不到資料。過去用重簽名改變應用身份的做法，還可能影響沙盒、鑰匙圈或應用組權限；在已測試的 macOS 27 環境中，部分應用因此無法正常啟動。

這並不是所有應用都會失敗的保證，也不是「只要重新簽一次就能修好」。預設推薦對符合條件的資料使用[掛載遷移](/docs/datamigrae/baseinfo#mount)，保留真實應用簽名。

## 怎樣檢視和關閉 {#settings}

在主視窗開啟「設定」，找到「經典資料遷移模式（不推薦）」。開啟前需要閱讀確認說明；不需要舊式遷移時保持關閉即可。

[![「經典資料遷移模式」位於設定頁。圖中的開關已關閉，可使用下方的按鈕查看完整說明。](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-classic-zh-hant-cc5d2c2c4e8a3c5c.png?sign=hQ2VQzYHDKsQRK42BujMoygWhNQnLafbleGezpOmlGY%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-classic-zh-hant-cc5d2c2c4e8a3c5c.png?sign=hQ2VQzYHDKsQRK42BujMoygWhNQnLafbleGezpOmlGY%3D%3A0)

*「經典資料遷移模式」位於設定頁。圖中的開關已關閉，可使用下方的按鈕查看完整說明。*

**關閉開關不會自動還原已存在的連結，也不會恢復過去改過的簽名。** 原有資料需要按實際狀態單獨處理，不能只看開關位置判斷已經完成升級。

## 已經使用舊方式怎麼辦 {#transition}

1. 連線原外接磁碟，結束關聯應用，保留現有資料和備份。
2. 對舊符號連結遷移的容器資料使用「還原」，讓資料回到原位置。
3. 若應用曾被替換簽名，按[macOS 27 升級與修復](/docs/macos-27)處理。
4. 檢查應用與資料正常後，需要外接存放時再選擇掛載遷移。

沒有合適 APFS 儲存時，可以讓容器資料繼續留在本機。不要只為繞過格式要求而開啟經典模式。

相關內容：[還原與接回](/docs/restore) · [符號連結實驗](/docs/blog/why-mount-and-apfs#symlink-experiment) · [經典模式詞條](/docs/glossary#classic-mode)

舊版開關與自動簽名的詳細變化儲存在[歷史功能歸檔](/docs/archive/data-signing)。
