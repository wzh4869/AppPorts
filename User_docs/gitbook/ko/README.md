---
description: "AppPorts 설치부터 앱과 데이터 마이그레이션, 일상적인 관리까지 안내합니다."
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
icon: "book-open"
---

# AppPorts

## 외장 드라이브가 세상을 구합니다 <a href="#외장-드라이브가-세상을-구합니다" id="외장-드라이브가-세상을-구합니다"></a>

<a href="faststart.md" class="button primary">빠른 시작</a> <a href="AppPorts.md" class="button secondary">소개</a>

**여기에서 시작하세요**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>시작하기</strong></td><td>AppPorts를 다운로드하고 설치한 뒤 첫 실행에 필요한 권한을 설정합니다.</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>외장 저장 장치 가이드</strong></td><td>외장 드라이브의 선택, 포맷과 사용 조건을 확인합니다.</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>문제 해결</strong></td><td>증상에 따라 권한과 마이그레이션 상태를 점검하고 복구 방법을 찾습니다.</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

**핵심 기능 살펴보기**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>바로가기 화살표 없는 마이그레이션</strong></td><td>클릭 한 번으로 대용량 앱을 외장 저장 장치로 옮깁니다. 로컬에는 가벼운 실행 셸만 남고 Finder에 바로가기 화살표가 표시되지 않으며 Launchpad와 앱 메뉴에도 정상적으로 표시됩니다.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>자동 업데이트 보호</strong></td><td>Sparkle, Electron 등 자체 업데이트 기능이 있는 앱을 감지해 ‘잠금 마이그레이션’을 제공합니다. 로컬 앱이 외장 저장 장치의 사본보다 최신 버전이면 ‘내보내기 대기’로 표시합니다.</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>데이터 디렉토리 관리</strong></td><td>~/Library/ 하위 디렉토리, ~/.npm 등의 데이터를 외장 저장 장치로 옮깁니다. WeChat 채팅 기록과 같은 샌드박스 컨테이너 데이터는 마운트 마이그레이션으로 외장 APFS 드라이브에 옮기며 서명은 변경하지 않습니다.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
