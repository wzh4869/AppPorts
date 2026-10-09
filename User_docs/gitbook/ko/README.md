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
  title:
    visible: false
  description:
    visible: false
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## 외장 드라이브가 세상을 구합니다 <a href="#외장-드라이브가-세상을-구합니다" id="외장-드라이브가-세상을-구합니다"></a>

AppPorts 설치부터 앱과 데이터 마이그레이션, 일상적인 관리까지 안내합니다.

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">AppPorts에 대해 무엇이 궁금한가요?</button>

<a href="faststart.md" class="button primary">빠른 시작</a> <a href="AppPorts.md" class="button secondary">소개</a>

<h3 align="center">여기에서 시작하세요 <a href="#undefined-1" id="undefined-1"></a></h3>

<p align="center">처음 사용하기부터 앱과 데이터 마이그레이션까지, 필요한 가이드를 선택하세요.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>시작하기 <a href="#start-1" id="start-1"></a></h4></td><td>AppPorts의 개요, 설치, 권한과 기본 설정을 확인합니다.</td><td><a data-mention href="faststart.md">빠른 시작</a></td><td><a data-mention href="AppPorts.md">소개</a></td><td><a data-mention href="settings.md">설정</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>앱 마이그레이션 <a href="#start-2" id="start-2"></a></h4></td><td>앱을 옮기거나 복원하는 방법과 유형별 전략을 알아봅니다.</td><td><a data-mention href="core.md">핵심 기능</a></td><td><a data-mention href="migration-strategy/portal.md">마이그레이션 전략</a></td><td><a data-mention href="migration-strategy/strategy-map.md">앱 유형별 전략</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>데이터 마이그레이션 <a href="#start-3" id="start-3"></a></h4></td><td>데이터 디렉토리 작업, 도구 데이터 감지와 컨테이너 마운트 마이그레이션을 확인합니다.</td><td><a data-mention href="datamigrae/operation.md">데이터 마이그레이션 가이드</a></td><td><a data-mention href="datamigrae/tools.md">도구 디렉토리 감지</a></td><td><a data-mention href="datamigrae/mount-migration.md">컨테이너 마운트 마이그레이션</a></td></tr>
</tbody>
</table>

***

<h3 align="center">저장 장치와 일상 관리 <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">외장 드라이브 요구 사항, 업데이트 안내와 문제 해결 가이드를 확인합니다.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>외장 저장 장치 <a href="#maintain-1" id="maintain-1"></a></h4></td><td>외장 드라이브 선택 기준, APFS가 필요한 경우와 호환성 제한을 확인합니다.</td><td><a data-mention href="storage-guide.md">외장 저장 장치 가이드</a></td><td><a data-mention href="why-apfs.md">APFS 요구 사항</a></td><td><a data-mention href="limitations.md">호환성 및 제한 사항</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>업데이트 및 유지 관리 <a href="#maintain-2" id="maintain-2"></a></h4></td><td>앱 업데이트, macOS 27의 변경 사항, 컨테이너 데이터와 서명 ID의 관계를 알아봅니다.</td><td><a data-mention href="migration-strategy/updater-detection.md">자체 업데이트 앱 식별</a></td><td><a data-mention href="macos-27.md">macOS 27 업그레이드</a></td><td><a data-mention href="datamigrae/container-identity.md">컨테이너 데이터와 서명</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>문제 해결 <a href="#maintain-3" id="maintain-3"></a></h4></td><td>증상별 확인 절차, 자주 묻는 질문과 로그 진단 방법을 찾습니다.</td><td><a data-mention href="troubleshooting.md">문제 해결</a></td><td><a data-mention href="faq.md">자주 묻는 질문</a></td><td><a data-mention href="logging.md">로그 및 진단</a></td></tr>
</tbody>
</table>

***

<h3 align="center">핵심 기능 살펴보기 <a href="#undefined-2" id="undefined-2"></a></h3>

<p align="center">AppPorts의 세 가지 핵심 기능을 알아봅니다.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>바로가기 화살표 없는 마이그레이션</strong></td><td>클릭 한 번으로 대용량 앱을 외장 저장 장치로 옮깁니다. 로컬에는 가벼운 실행 셸만 남고 Finder에 바로가기 화살표가 표시되지 않으며 Launchpad와 앱 메뉴에도 정상적으로 표시됩니다.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>자동 업데이트 보호</strong></td><td>Sparkle, Electron 등 자체 업데이트 기능이 있는 앱을 감지해 ‘잠금 마이그레이션’을 제공합니다. 로컬 앱이 외장 저장 장치의 사본보다 최신 버전이면 ‘내보내기 대기’로 표시합니다.</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>데이터 디렉토리 관리</strong></td><td>~/Library/ 하위 디렉토리, ~/.npm 등의 데이터를 외장 저장 장치로 옮깁니다. WeChat 채팅 기록과 같은 샌드박스 컨테이너 데이터는 마운트 마이그레이션으로 외장 APFS 드라이브에 옮기며 서명은 변경하지 않습니다.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">더 알아보기 <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>변경 이력 <a href="#explore-1" id="explore-1"></a></h4></td><td>버전별 변경 사항과 수정 내용을 확인합니다.</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>실험 기록 <a href="#explore-2" id="explore-2"></a></h4></td><td>샌드박스, 마운트, 드라이브 분리와 시스템 시작에 관한 실험 기록을 확인합니다.</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>기여하기 <a href="#explore-3" id="explore-3"></a></h4></td><td>개발, 테스트와 문서 개선에 참여하는 방법을 알아봅니다.</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
