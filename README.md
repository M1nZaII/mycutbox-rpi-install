# MyCutBox Pi — 원클릭 설치 (토큰리스)

기존 설치 방식(private repo clone + GitHub 토큰 입력 + `install.sh` 수동 실행)을 없애고,
**웹에서 받아 → 마법사 → 자동 실행·OTA** 로 바꾸는 배포 구성입니다.

## 구성 요소

| 파일 | 위치 | 역할 |
|---|---|---|
| `mycutbox-install.sh` | 공개 설치 repo + 웹(`/rp`) | 다운로드되는 부트스트랩 설치 마법사 (비밀값 없음) |
| `mycutbox-installer.desktop` | 공개 설치 repo | Pi 데스크톱 더블클릭 → 터미널 마법사 실행 |
| `/install` 페이지 | `MyCutBox-web-MJ` | 한 줄 명령 + 다운로드 안내 페이지 |
| `/rp` rewrite | `MyCutBox-web-MJ/next.config.mjs` | `https://<사이트>/rp` → 공개 설치 repo raw 스크립트 |

## 동작 흐름

```
사용자: curl -fsSL https://install.mycutbox.com/rp | bash   (또는 데스크톱 아이콘 더블클릭)
  │
부트스트랩(mycutbox-install.sh):
  ├─ Docker 없으면 설치
  ├─ 공개 GHCR 이미지 pull                 (토큰 불필요 — 이미지가 public)
  ├─ 호스트 파일을 공개 설치 repo에서 받기  (토큰 불필요 — repo가 public)
  ├─ whiptail 마법사(또는 플레인/비대화형)로 매장·Firestore 키·Slack 수집
  └─ install.sh 실행 → systemd user 유닛 + linger → 부팅마다 자동 실행
```

## 준비: 이 3가지는 수동(1회)

1. **GHCR 이미지 public 전환**
   GitHub → 해당 사용자/조직의 Packages → `mycutbox-rpi-agent` → Package settings →
   Change visibility → **Public**. (이러면 `docker pull` 에 토큰이 필요 없어집니다.)

2. **공개 설치 repo 생성** — 예: `github.com/m1nzaii/mycutbox-rpi-install` (Public)
   여기에 호스트 파일들이 올라갑니다. 아래 CI가 private 원본 repo에서 자동 동기화합니다.
   부트스트랩이 기대하는 최소 파일: `install.sh`, `mycutbox-ota-update.sh`,
   `docker-compose.yml`, `AGENT_VERSION`, `scripts/fleet-*.mjs`, `mycutbox-install.sh`,
   `mycutbox-installer.desktop`.

3. **(선택) 서브도메인** `install.mycutbox.com` → 웹앱으로. 없으면 사이트 기본 도메인의
   `/rp`, `/install` 을 그대로 쓰면 됩니다. `.desktop`·`/install` 페이지의 URL 상수만 맞추세요.

## CI: private → public 동기화

`.github/workflows/sync-public-installer.yml` (아래) 가 `main` push 또는 릴리스 시
호스트 파일만 골라 공개 설치 repo로 푸시합니다.

필요 시크릿: `INSTALLER_REPO_TOKEN` — 공개 설치 repo에 push 권한이 있는 PAT(또는 deploy key).
(private 원본 → public 미러 단방향)

## 구현 완료 (2026-07-21)

- **install.sh 호환**: 공개 이미지(토큰 없음)여도 `docker compose up` 이 진행되도록 게이트 완화.
- **env 통일**: `mycutbox-ota-update.sh` 가 읽고/쓸 수 있는 env 를 자동 선택
  (`/etc/mycutbox/env` 가 읽히면 그대로, 아니면 `~/.pi/.env` 폴백). rp3 유저 OTA 가 태그를
  못 읽어 fleet skip 이 깨지던 버그를 해결.
- **OTA 토큰리스**: `update_agent_repo` 가 **공개 설치 repo tarball(토큰 없음)을 1순위**로 받고,
  실패 시 **기존 private git pull 로 자동 폴백**. 호스트 파일(install.sh·ota-update.sh·compose·
  AGENT_VERSION·usbPrint.cjs·fleet-*.mjs)을 공개 경로에서 갱신. 컨테이너 런타임(print.mjs 등)은
  공개 이미지 pull(토큰 없음)로 처리.
- **Pilot 토큰리스**: CI 미러가 `pilot` 브랜치도 public repo 의 같은 이름 브랜치로 동기화하고,
  refresh 가 PILOT_ACTIVE 시 public repo 의 `pilot` 브랜치를 받는다.

> usbPrint.cjs 는 GVFS(iPhone/USB) 마운트가 컨테이너로 안 들어가서 호스트에서 실행되며,
> 공개 이미지에 이미 포함돼 있으므로 공개 설치 repo 에도 포함(노출 수준 동일).
