# Getting Started

## Installing AppPorts <a href="#installing-appports" id="installing-appports"></a>

Installing AppPorts requires the following two prerequisites:
1. A stable external storage device (such as a hard drive)
2. Operating system no lower than macOS 12.0 (Monterey) or later

### Download <a href="#download" id="download"></a>

Go to [Github releases](https://github.com/wzh4869/AppPorts/releases) page to download the latest .dmg installer

{% hint style="success" %}

If the above link cannot be opened, please visit this link to get the installer [direct download](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


### Install and Launch <a href="#install-and-launch" id="install-and-launch"></a>
1. Open the .dmg installer
2. Drag the application to the Applications folder
3. Launch the application

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


### Required Authorization <a href="#required-authorization" id="required-authorization"></a>

On first run, AppPorts needs Full Disk Access permission to read and modify the /Applications directory.
1. Open System Settings → Privacy & Security.
Select Full Disk Access.
2. Click the + button, add AppPorts, then toggle the switch on.
3. Restart AppPorts.

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)

#### App Store App Self-Update Authorization <a href="#app-store-app-self-update-authorization" id="app-store-app-self-update-authorization"></a>

Users with macOS 15.1 (Sequoia) or later need to enable "Download and install large apps to an external drive" in the App Store to ensure AppPorts creates an external storage `/Applications` folder to support automatic updates for App Store apps.
{% hint style="warning" %}
**⚠️ Systems before macOS 15.1 (Sequoia) do not support this feature due to OS limitations**

You need to enable the "Allow migration of App Store apps" setting in AppPorts settings. Subsequent app updates require manual re-migration to overwrite.
{% endhint %}

1. Open the App Store
2. In the status bar, click Settings and check "Download and install large apps to an external drive," selecting the same external storage device as the AppPorts external storage library

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
