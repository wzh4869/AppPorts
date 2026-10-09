---
icon: "rocket"
description: "AppPorts를 다운로드하고 설치한 뒤 첫 실행에 필요한 권한을 설정합니다."
layout:
  width: "default"
  outline:
    visible: true
---

# 시작하기

## AppPorts 설치 <a href="#appports-설치" id="appports-설치"></a>

AppPorts 설치에는 다음 두 가지 전제 조건이 필요합니다:
1. 안정적인 외장 저장소 장치 (예: 하드 드라이브)
2. macOS 12.0 (Monterey) 이상의 운영 체제

{% stepper %}
{% step %}

### 다운로드 <a href="#다운로드" id="다운로드"></a>

[Github releases](https://github.com/wzh4869/AppPorts/releases) 페이지에서 최신 .dmg 설치 파일을 다운로드하세요.

{% hint style="success" %}

위 링크를 열 수 없는 경우, 이 링크에서 설치 파일을 다운로드하세요 [direct download](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


{% endstep %}

{% step %}

### 설치 및 실행 <a href="#설치-및-실행" id="설치-및-실행"></a>
1. .dmg 설치 파일을 엽니다
2. 애플리케이션을 Applications 폴더로 드래그합니다
3. 애플리케이션을 실행합니다

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


{% endstep %}

{% step %}

### 필요한 권한 <a href="#필요한-권한" id="필요한-권한"></a>

처음 실행 시 AppPorts는 /Applications 디렉토리를 읽고 수정하기 위해 전체 디스크 접근 권한이 필요합니다.
1. 시스템 설정 → 개인정보 보호 및 보안을 엽니다.
전체 디스크 접근을 선택합니다.
2. + 버튼을 클릭하고 AppPorts를 추가한 다음 스위치를 켭니다.
3. AppPorts를 재시작합니다.

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)

{% endstep %}
{% endstepper %}

#### App Store 앱 자체 업데이트 권한 <a href="#app-store-앱-자체-업데이트-권한" id="app-store-앱-자체-업데이트-권한"></a>

macOS 15.1 (Sequoia) 이상의 사용자는 App Store에서 "외장 드라이브에 대용량 앱 다운로드 및 설치"를 활성화해야 AppPorts가 외장 저장소 `/Applications` 폴더를 생성하여 App Store 앱의 자동 업데이트를 지원할 수 있습니다.
{% hint style="warning" %}
**⚠️ macOS 15.1 (Sequoia) 이전 시스템은 OS 제한으로 인해 이 기능을 지원하지 않습니다**

AppPorts 설정에서 "App Store 앱 마이그레이션 허용" 설정을 활성화해야 합니다. 이후 앱 업데이트 시 수동으로 재마이그레이션하여 덮어써야 합니다.
{% endhint %}

1. App Store를 엽니다
2. 상태 표시줄에서 설정을 클릭하고 "외장 드라이브에 대용량 앱 다운로드 및 설치"를 체크하여, AppPorts 외장 저장소 라이브러리와 동일한 외장 저장소 장치를 선택합니다

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
