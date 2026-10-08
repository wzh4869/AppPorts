# Core Features

This page covers the core functionality for app package migration. For migrating data within apps, see [Data Migration](datamigrae/baseinfo.md).

## Migrate Apps to External Storage <a href="#migrate-apps-to-external-storage" id="migrate-apps-to-external-storage"></a>

1. Select a single app or long-press and drag to select multiple apps (or Cmd+click to select apps)
2. Click the "Migrate to External" button at the bottom
3. Wait for migration to complete

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/gonomoral.gif?sign=tzb_Y7YRR9uTc4uunpWXJWYs8dOXLEa0S0AQH-qcB4I=:0)
{% hint style="success" %}
**Note**

At 100% migration progress, there may be a 1-2 second pause while creating local links
{% endhint %}

### Updated Local Apps <a href="#updated-local-apps" id="updated-local-apps"></a>

If a migrated app is later reinstalled or updated locally while the external storage still contains the old copy, AppPorts marks it as "Pending Move Out" when it can confirm the version relationship. Migrating it again moves the newer local app to external storage and replaces the old external copy.

AppPorts only cleans the external target automatically when it can confirm the target is the old copy, an AppPorts-managed portal, or a stale AppPorts migration remnant. If the external location contains an unrelated real app, migration stops with a conflict instead of overwriting it.

## Move External Apps Back to Local <a href="#move-external-apps-back-to-local" id="move-external-apps-back-to-local"></a>
1. Select the app in the External Apps library
2. Click "Move Back to Local"
![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/qianhui.gif?sign=VDEq_lQvfhnb1vhUljwh3PVhNFkwjpKcRAeQ-Ht5Mnc=:0)

{% hint style="warning" %}
**Local Conflict Protection**

When moving an app back, AppPorts will not overwrite a same-name real local app or a symbolic link that does not belong to the current external app. Only AppPorts-recognized local entries for the same app are removed automatically.
{% endhint %}

## Link External Apps to Local <a href="#link-external-apps-to-local" id="link-external-apps-to-local"></a>
1. Select the app in the External Apps library
2. Click "Link to Local"
![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/linkback.gif?sign=3xdVe7IFYcMfwNt1K9WMk8ZQYIlNMWngjZoTkNwA610=:0)

## Unlink <a href="#unlink" id="unlink"></a>
Click the Unlink button on the right side of the linked apps list.
![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/jiechu.gif?sign=CLDMEQxHts1S2mBEnka9HUYT2XMzcnBwX1Sjfas9Dho=:0)
