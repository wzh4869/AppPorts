---
icon: "rocket"
description: "下載並安裝 AppPorts，完成首次啟動所需的授權。"
layout:
  width: "default"
  outline:
    visible: true
---

# 快速開始
## 安裝AppPorts <a href="#安裝appports" id="安裝appports"></a>
安裝 AppPorts 需要以下兩個前置需求   
1. 擁有一個穩定的外部存儲媒介（如硬盤）
2. 操作系統不低於 macOS 12.0 (Monterey) 或更高版本

{% stepper %}
{% step %}

### 下載 <a href="#下載" id="下載"></a>
前往 [Github releases](https://github.com/wzh4869/AppPorts/releases)頁下載最新版本 dmg 安裝包

{% hint style="success" %}

如此鏈接無法打開，請訪問此鏈接來獲取安裝包[直鏈網盤](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


{% endstep %}

{% step %}

### 安裝並啓動 <a href="#安裝並啓動" id="安裝並啓動"></a>
1. 打開 .dmg 安裝包  
2. 將應用拖動到 Application 文件夾中
3. 啓動應用

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


{% endstep %}

{% step %}

### 必要授權 <a href="#必要授權" id="必要授權"></a>
首次運行時，AppPorts 需要完全磁盤訪問權限來讀取和修改 /Applications 目錄。
1. 打開系統設置 → 隱私與安全性。
選擇完全磁盤訪問權限。  
2. 點擊 + 按鈕，添加 AppPorts，然後打開開關。   
3. 重新啓動 AppPorts。   

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)
   
{% endstep %}
{% endstepper %}

#### AppStore 應用自更新授權 <a href="#appstore-應用自更新授權" id="appstore-應用自更新授權"></a>
macOS 15.1（Sequoia） 及以上操作系統的用戶，需在 AppStore 中開啓 “下載並安裝大型 App 到獨立存儲盤“ 來確保 AppPorts 創建外部存儲的/application 文件夾以支持對 AppStore 應用自動更新 
{% hint style="warning" %}
**⚠️ macOS 15.1（Sequoia） 的之前版本系統因操作系統限制暫不支持該功能**

需在 AppPorts 右上角設置-勾選開啓來自 AppStore 應用的遷移功能。後續應用更新需手動二次遷移以覆蓋。
{% endhint %}
   
1. 打開 AppStore
2. 在狀態欄中點擊設置-勾選“下載並安裝大型 App 到獨立存儲盤“並選擇與 AppPorts 中外部存儲庫相同的外置存儲媒介
 
![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
