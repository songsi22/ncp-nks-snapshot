# NKS VolumeSnapshot Backup

Naver Cloud Platform (NCP) Managed Kubernetes Service (NKS)의 PVC 스냅샷을 백업/복원/관리하는 스크립트 모음입니다.

## Overview

NKS 클러스터의 PersistentVolumeClaim(PVC)을 VolumeSnapshot으로 백업하고, 보관 주기가 지난 스냅샷을 자동 삭제하며, 필요시 수동으로 스냅샷을 생성/삭제/조회할 수 있습니다.

## Features

- **주기적 백업**: cron 등 스케줄러와 연동하여 자동 백업
- **만료 스냅샷 자동 삭제**: 설정한 보관 주기(일수) 경과 스냅샷 자동 정리
- **NKS 버전별 API 자동 선택**: Kubernetes 1.33 이상은 `v1`, 미만은 `v1beta1` 사용
- **Interactive 삭제 모드**: 번호로 선택해서 삭제 (안전장치)
- **Multi-platform 지원**: PowerShell (Windows), Bash (Linux/macOS)
- **config.json 기반 설정**: 초기 설정 한 번으로 반복 사용
- **명시적 초기화 모드**: 모든 스크립트에서 `--init` / `-Init` 옵션으로 재설정 가능

## File Structure

| 파일 | 설명 |
|------|------|
| `nks-snapshot-cron.ps1` | PowerShell: 주기적 백업 + 만료 삭제 |
| `nks-snapshot-cron.sh` | Bash: 주기적 백업 + 만료 삭제 |
| `nks-snapshot-create.ps1` | PowerShell: 일회성 스냅샷 생성 |
| `nks-snapshot-create.sh` | Bash: 일회성 스냅샷 생성 |
| `nks-snapshot-delete.ps1` | PowerShell: 스냅샷 삭제 (interactive/필터 지원) |
| `nks-snapshot-delete.sh` | Bash: 스냅샷 삭제 (interactive/필터 지원) |
| `nks-snapshot-list.ps1` | PowerShell: 스냅샷 목록 조회 |
| `nks-snapshot-list.sh` | Bash: 스냅샷 목록 조회 |
| `config.json` | 설정 파일 (초기화 시 자동 생성) |

## Requirements

- **kubectl**: Kubernetes 클러스터 접근 가능해야 합니다.
- **jq**: Bash 스크립트 사용 시 필수 (macOS: `brew install jq`, Linux: `apt-get install jq`)
- **PowerShell**: Windows 환경에서만 필요

## Quick Start

### 1. 초기 설정 (처음 한 번)

스크립트를 처음 실행하면 자동으로 초기화 모드로 들어갑니다. 필요한 정보를 입력하세요:

```powershell
# PowerShell - 처음 실행 시 자동으로 초기화
.\nks-snapshot-cron.ps1
# 또는 -Init 옵션으로 명시적 초기화 (config.json이 있어도 재초기화)
.\nks-snapshot-cron.ps1 -Init

# Bash - 처음 실행 시 자동으로 초기화
./nks-snapshot-cron.sh
# 또는 --init 옵션으로 명시적 초기화 (config.json이 있어도 재초기화)
./nks-snapshot-cron.sh --init
```

**모든 스크립트에서 초기화 가능:**

```powershell
# PowerShell - create/list/delete 도 초기화 가능
.\nks-snapshot-create.ps1 -Init
.\nks-snapshot-list.ps1 -Init
.\nks-snapshot-delete.ps1 -Init

# Bash - create/list/delete 도 초기화 가능
./nks-snapshot-create.sh --init
./nks-snapshot-list.sh --init
./nks-snapshot-delete.sh --init
```

**초기화 시 입력 항목:**
- **Retention days**: 스냅샷 보관 기간 (일)
- **Namespaces**: 백업 대상 네임스페이스 (쉼표로 구분, 예: default,staging,monitoring)
- **SnapshotClass**: VolumeSnapshotClass 이름 (기본값: nks-block-storage)

스크립트가 자동으로 Kubernetes 서버 버전을 감지하여 적절한 API 버전을 선택합니다.

또는 config.json 파일을 수동으로 생성:

```json
{
  "retention_days": 7,
  "nks_version": "1.32",
  "namespaces": ["default", "staging"],
  "snapshot_class": "nks-block-storage",
  "api_version": "snapshot.storage.k8s.io/v1beta1",
  "created_at": "2026-03-05T00:00:00Z"
}
```

### 2. 주기적 백업 (cron 설정)

```powershell
# PowerShell - Windows Task Scheduler 또는 직접 실행
.\nks-snapshot-cron.ps1

# Bash - crontab에 등록
crontab -e
# 추가:매일 03:00에 실행
0 3 * * * /path/to/nks-snapshot-cron.sh
```

### 3. 일회성 스냅샷 생성

```powershell
# PowerShell - config.json의 namespaces 사용
.\nks-snapshot-create.ps1

# 특정 네임스페이스만
.\nks-snapshot-create.ps1 -Namespaces @("default")

# Dry-run (테스트)
.\nks-snapshot-create.ps1 -DryRun

# 설정 재초기화
.\nks-snapshot-create.ps1 -Init
```

```bash
# Bash
./nks-snapshot-create.sh

# 특정 네임스페이스만
./nks-snapshot-create.sh --namespaces "default,staging"

# Dry-run (테스트)
./nks-snapshot-create.sh --dry-run

# 설정 재초기화
./nks-snapshot-create.sh --init
```

### 4. 스냅샷 목록 조회

```powershell
.\nks-snapshot-list.ps1

# 특정 네임스페이스만
.\nks-snapshot-list.ps1 -Namespaces @("default")

# 설정 재초기화
.\nks-snapshot-list.ps1 -Init
```

```bash
./nks-snapshot-list.sh

# 특정 네임스페이스만
./nks-snapshot-list.sh --namespaces "default,staging"

# 설정 재초기화
./nks-snapshot-list.sh --init
```

### 5. 스냅샷 삭제

삭제는 **안전을 위해 기본적으로 interactive 모드**로 실행됩니다.

```powershell
# PowerShell - 필터 없이 실행 시 선택 모드
.\nks-snapshot-delete.ps1

# 특정 이름으로 삭제
.\nks-snapshot-delete.ps1 -Name "snapshot-data-20260305120000"

# 기간范围内 삭제
.\nks-snapshot-delete.ps1 -From "2026-03-01T00:00:00Z" -To "2026-03-05T23:59:59Z"

# 만료된 스냅샷만 삭제 (config.json의 retention_days 기준)
.\nks-snapshot-delete.ps1 -Expired

# Dry-run으로 미리 확인
.\nks-snapshot-delete.ps1 -Expired -DryRun

# 설정 재초기화
.\nks-snapshot-delete.ps1 -Init
```

```bash
# Bash
./nks-snapshot-delete.sh

# 특정 이름으로 삭제
./nks-snapshot-delete.sh --name "snapshot-data-20260305120000"

# 기간范围内 삭제
./nks-snapshot-delete.sh --from "2026-03-01T00:00:00Z" --to "2026-03-05T23:59:59Z"

# 만료된 스냅샷만 삭제
./nks-snapshot-delete.sh --expired

# Dry-run으로 미리 확인
./nks-snapshot-delete.sh --expired --dry-run

# 설정 재초기화
./nks-snapshot-delete.sh --init
```

#### Interactive 삭제 (선택 모드)

필터 없이 실행하거나 `--interactive` 옵션을 사용하면:

1. 삭제 가능한 스냅샷 목록이 번호와 함께 표시됩니다.
2. 번호를 입력하여 선택합니다.
3. 선택 후 최종 확인을 한 번 더 합니다.

```
[1] default  snapshot-mydata-20260301100000  2026-03-01T10:00:00Z
[2] default  snapshot-mydata-20260302100000  2026-03-02T10:00:00Z
[3] default  snapshot-mydata-20260303100000  2026-03-03T10:00:00Z
Enter selection (e.g., 1,3-5 or all): 1,3
Delete 2 snapshot(s)? Type 'y' to continue: y
deleted: snapshot-mydata-20260301100000 (default)
deleted: snapshot-mydata-20260303100000 (default)
```

선택 입력 형식:
- `all` - 전체 선택
- `1,3,5` - 개별 번호
- `2-5` - 범위 선택
- `1,3-6,9` - 혼합

## Configuration (config.json)

| 필드 | 필수 | 설명 | 기본값 |
|------|------|------|--------|
| `retention_days` | Yes | 스냅샷 보관 기간 (일) | 7 |
| `namespaces` | Yes | 백업 대상 네임스페이스 배열 | `["default"]` |
| `snapshot_class` | Yes | VolumeSnapshotClass 이름 | `nks-block-storage` |
| `nks_version` | Auto | Kubernetes 서버 버전 | 자동 감지 |
| `api_version` | Auto | VolumeSnapshot API 버전 | 자동 결정 |
| `created_at` | Auto | 설정 생성 일시 | 자동 기록 |

## 초기화 모드

모든 스크립트에서 `config.json`이 없어도 자동으로 초기화되며, `--init` (Bash) / `-Init` (PowerShell) 옵션으로 명시적으로 재초기화할 수 있습니다.

```powershell
# 자동 초기화: config.json이 없으면 자동으로 초기화 모드로 들어감
.\nks-snapshot-create.ps1

# 명시적 초기화: config.json이 있어도 재설정 가능
.\nks-snapshot-create.ps1 -Init
.\nks-snapshot-list.ps1 -Init
.\nks-snapshot-delete.ps1 -Init
.\nks-snapshot-cron.ps1 -Init
```

```bash
# 자동 초기화: config.json이 없으면 자동으로 초기화 모드로 들어감
./nks-snapshot-create.sh

# 명시적 초기화: config.json이 있어도 재설정 가능
./nks-snapshot-create.sh --init
./nks-snapshot-list.sh --init
./nks-snapshot-delete.sh --init
./nks-snapshot-cron.sh --init
```

## NKS 버전과 API 버전

NKS(NCP Managed Kubernetes) 클러스터의 Kubernetes 버전에 따라 VolumeSnapshot API가 다릅니다:

| Kubernetes 버전 | API Version |
|----------------|--------------|
| 1.33 이상 | `snapshot.storage.k8s.io/v1` |
| 1.32 이하 | `snapshot.storage.k8s.io/v1beta1` |

스크립트는 서버 버전을 자동으로 감지하여 적절한 API 버전을 사용합니다.

## 예시: Daily Backup with Cron

### Linux/macOS

```bash
# 1. 스크립트에 실행 권한 부여
chmod +x nks-snapshot-cron.sh

# 2. crontab 편집
crontab -e

# 3. 매일 새벽 3시에 실행 (PATH와 KUBECONFIG 필수)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
KUBECONFIG=/home/<username>/.kube/config
0 3 * * * /path/to/nks-snapshot-cron.sh >> /var/log/nks-snapshot.log 2>&1
```

**Cron 실행 시 주의사항:**
- `PATH`에 `kubectl`, `jq`, 인증 플러그인(`ncp-iam-authenticator` 등)이 포함되어야 합니다.
- `KUBECONFIG` 환경변수로 kubeconfig 파일 경로를 명시하세요.
- 스크립트는 기본적으로 실행 파일 기준 디렉터리의 `config.json`을 사용합니다.

### Windows

```powershell
# PowerShell로 직접 실행
.\nks-snapshot-cron.ps1

# Windows Task Scheduler를 사용하여 매일 새벽 3시에 실행
# 작업 스케줄러 > 작업 만들기 > 트리거: 매일 03:00, 동작: powershell -ExecutionPolicy Bypass -File "C:\path\to\nks-snapshot-cron.ps1"
```

## Troubleshooting

### "kubectl is required" 오류

kubectl가 PATH에 있는지 확인하세요.

```bash
# 설치 확인
kubectl version --client

# 클러스터 연결 확인
kubectl cluster-info
```

### "jq is required" 오류 (Bash only)

```bash
# macOS
brew install jq

# Ubuntu/Debian
apt-get install jq

# CentOS/RHEL
yum install jq
```

### 스냅샷이 생성되지 않는 경우

1. PVC가 해당 네임스페이스에 있는지 확인:
   ```bash
   kubectl get pvc -n <namespace>
   ```

2. VolumeSnapshotClass가 존재하는지 확인:
   ```bash
   kubectl get volumesnapshotclass
   ```

3. 권한 확인 (RBAC):
   ```bash
   kubectl auth can-i create volumesnapshot
   ```

### 삭제确认 안，求助

`--dry-run` 옵션으로 먼저 확인하세요:

```bash
./nks-snapshot-delete.sh --expired --dry-run
```

### Cron에서 스냅샷이 생성되지 않는 경우

Cron 환경은 인터랙티브 셸과 다른 환경입니다. 다음을 확인하세요:

1. ** PATH 확인**: cron은 제한된 PATH로 실행됩니다. 전체 경로를 명시하세요:
   ```bash
   PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
   ```

2. **KUBECONFIG 설정**: cron 환경에는 `~/.kube/config`가 자동으로 로드되지 않습니다:
   ```bash
   KUBECONFIG=/home/<username>/.kube/config
   ```

3. **인증 플러그인 경로**: `ncp-iam-authenticator` 등 exec 인증 플러그인이 PATH에 있는지 확인하세요.

4. **로그로 원인 확인**:
   ```bash
   tail -f /var/log/nks-snapshot.log
   ```

스크립트는 실행 시 다음 정보를 로그에 출력합니다:
- 실행 사용자
- KUBECONFIG 경로
- kubectl current-context
- 각 네임스페이스별 생성/삭제 결과

## License

MIT License

## Contributing

Pull Request 환영합니다!
