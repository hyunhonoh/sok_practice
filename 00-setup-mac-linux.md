# 00. 환경 준비 — 맥 / 리눅스

## 구조

```
리눅스:  커널 ──────────── docker ── MiniStack ── k3s(컨트롤플레인) + 가짜 EC2(워커)
맥:      colima VM(vz) ── docker ── MiniStack ── k3s(컨트롤플레인) + 가짜 EC2(워커)
              ↑ 이 한 겹만 다르고 그 위는 동일
```

맥에는 리눅스 커널이 없어서 VM이 한 겹 필요하다. colima는 lima 위에 올라간 래퍼로,
VM 생성·docker 설치·소켓 노출·`docker context` 등록까지 자동으로 해준다.
**docker 소켓 위로는 리눅스와 완전히 같다.** 같은 명령·스크립트·매니페스트를 양쪽에서 쓴다.

## 맥 (Apple Silicon)

```bash
brew install colima docker kubectl awscli
softwareupdate --install-rosetta --agree-to-license   # --vz-rosetta 에 필요 (이미 있으면 그냥 넘어간다)

# vz + Rosetta: 나중에 amd64 전용 이미지(Splunk)를 돌리기 위해
# kubernetes=false: colima 내장 k3s는 쓰지 않는다 (에뮬레이터가 k3s를 띄운다)
colima start --cpu 6 --memory 8 --vm-type vz --vz-rosetta --kubernetes=false
# 이미 colima VM이 있으면 vm-type·Rosetta 설정은 바뀌지 않는다 → colima delete 후 다시, 또는 -p 새프로필

# inotify 한도 — 기본 128이면 k3s가 여러 개 뜰 때 즉사한다 (아래 트러블슈팅 참고)
colima ssh -- bash -c 'printf "fs.inotify.max_user_instances = 1024\nfs.inotify.max_user_watches = 1048576\n" \
  | sudo tee /etc/sysctl.d/99-k8s-inotify.conf && sudo sysctl --system >/dev/null'
```

확인:

```bash
colima status                       # "macOS Virtualization.Framework", "arch: aarch64" 가 보여야 한다
docker info --format '{{.Architecture}}'            # aarch64
colima ssh -- ls /proc/sys/fs/binfmt_misc/rosetta   # 파일이 있으면 Rosetta 등록됨
```

맥 특이사항:
- **컨테이너 IP(172.17.x.x)에 맥에서 직접 접근할 수 없다.** VM 안쪽 네트워크이기 때문.
  호스트에 publish된 포트(`localhost:4567`, `localhost:16443` 등)만 쓴다.
  colima가 publish된 포트를 맥으로 자동 포워딩한다.
- **amd64 전용 이미지(Splunk)는 노드에 직접 load해야 한다.** arm64 노드의 kubelet이
  amd64판만 있는 이미지를 받지 않기 때문 → `scripts/load-image.sh` ([04](04-splunk-operator.md))
- colima 메모리는 호스트 RAM의 절반 정도가 상한선.
- colima 설정의 `disk:` 값은 VM 생성 시점에 고정된다. 나중에 설정만 바꾸면
  `colima list`에는 바뀐 값이 보이지만 실제 디스크는 그대로다.

## 리눅스

```bash
# 준비물: git, curl (없으면 sudo apt-get install -y git curl)
# Docker Engine (배포판 패키지 또는 공식 스크립트)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER      # 적용하려면 로그아웃 후 다시 로그인 (또는 맨 끝에 newgrp docker)

# inotify 한도
printf "fs.inotify.max_user_instances = 1024\nfs.inotify.max_user_watches = 1048576\n" \
  | sudo tee /etc/sysctl.d/99-k8s-inotify.conf && sudo sysctl --system

# 커널 모듈 (대부분 이미 로드돼 있음)
sudo modprobe -a overlay br_netfilter
printf "overlay\nbr_netfilter\n" | sudo tee /etc/modules-load.d/k8s.conf

# kubectl (Debian/Ubuntu 기준 — dpkg 아키텍처 이름이 k8s 배포 경로와 같다)
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl

# aws CLI v2 — 반드시 실제 실행 파일로 설치한다 (아래 주의 참고)
sudo apt-get install -y unzip
curl -sLo awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip
```

> **주의 — `aws`를 docker alias로 대신하면 안 된다.** `aws eks update-kubeconfig`가 만드는 kubeconfig는
> kubectl이 `aws` 실행 파일을 직접 호출해 토큰을 받는 방식(`exec: command: aws`)이라,
> 셸 alias는 kubectl에 보이지 않는다. 클러스터 생성 같은 단발 명령만 컨테이너로 돌릴 때는 alias도 된다.

리눅스 특이사항:
- **호스트에서 컨테이너 IP로 바로 접근된다.** k3s API를 `https://172.17.0.x:6443`로 직접 쓸 수 있다
  (publish된 포트 `localhost:16443`도 된다).
- x86_64 리눅스라면 Splunk(amd64 전용)가 **에뮬레이션 없이** 네이티브로 돈다.
- arm64 리눅스라면 Splunk(amd64)를 위해 QEMU binfmt 등록
  (`docker run --privileged --rm tonistiigi/binfmt --install amd64`)과 맥과 같은 이미지 load
  (`scripts/load-image.sh`, [04](04-splunk-operator.md))가 둘 다 필요할 것이다. **미검증.**

## 공통 — 저장소 받기

```bash
git clone https://github.com/hyunhonoh/sok_practice.git && cd sok_practice
```

이후 모든 명령은 저장소 루트에서 실행한다 (`./scripts/...`, `manifests/...`).

## 공통 — MiniStack 기동

```bash
docker run -d --name ministack -p 4567:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ministackorg/ministack:latest

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_ENDPOINT_URL=http://localhost:4567

curl -s localhost:4567/_ministack/health | head -c 200
```

호스트 포트를 4567로 한 것은 floci(4566)와 동시에 띄워 비교했기 때문이다.
MiniStack만 쓴다면 4566으로 해도 된다(그때는 `AWS_ENDPOINT_URL`도 맞춘다).
`docker.sock` 마운트는 필수다. MiniStack이 k3s 컨테이너를 직접 띄우기 때문.

## 검증 범위 (정직하게)

| 환경 | 검증 |
|---|---|
| 맥 Apple Silicon + colima 0.10.1 (vz, Rosetta), docker 29 | ✅ 01~04 전 과정 (Operator 2.8.1·3.2.0, Splunk 9.4.3·10.4.0) |
| 리눅스 Ubuntu 24.04 **aarch64**, docker 29.2.1, cgroup v2 | ✅ 클러스터 생성 → 가짜 EC2 조인 → 호스트에서 컨테이너 IP로 kubectl (k3s.yaml 사용. `update-kubeconfig` 경로는 맥에서만 확인) |
| 리눅스 **x86_64** 실물 서버 | ❌ 미검증 (스크립트는 아키텍처를 자동 판별한다) |
| SELinux 강제 배포판(RHEL/Fedora) | ❌ 미검증. `--privileged` 컨테이너에 추가 설정이 필요할 수 있다 |

리눅스 검증은 colima VM(Ubuntu 24.04) 안에서 리눅스 사용자와 똑같이 명령을 실행하는 방식으로 했다.
네이티브 docker 위에서의 동작은 같지만, 별도 물리 서버에서 돌려본 것은 아니다.

## 트러블슈팅 (맥·리눅스 공통)

| 증상 | 원인 | 해결 |
|---|---|---|
| k3s 컨테이너가 뜨자마자 `Exited (1)` | `inotify_init: too many open files` (기본 한도 128) | 위 inotify 설정 (맥은 `colima ssh`로, 리눅스는 호스트에서 바로) |
| API는 `ACTIVE`인데 k3s 접속 불가 | 에뮬레이터는 k3s 컨테이너가 죽어도 상태를 갱신하지 않는다 | `docker ps -a`로 컨테이너 상태와 로그 확인 |
| 노드 조인이 영원히 대기 | 아래 [02](02-fake-ec2-join.md) 표 참고 | |
