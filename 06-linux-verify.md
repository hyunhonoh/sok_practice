# 06. 리눅스 실측 체크리스트

맥에서는 00~04를 전부 실측했다. **리눅스는 "클러스터 생성 → 가짜 EC2 조인 → kubectl"까지만**
(colima VM 안의 Ubuntu 24.04 arm64) 확인했고, nginx·Operator·Splunk와 **x86_64 리눅스 전체**는 미검증이다.
이 문서는 그 빈칸을 채우기 위한 순서다. 사람이든 에이전트든 위에서부터 따라 하고, 결과를 맨 아래 표에 기록한다.

## 0. 환경 기록 (먼저)

```bash
uname -m; . /etc/os-release; echo "$PRETTY_NAME"
nproc; free -g | awk 'NR==2{print $2"GB RAM"}'; df -h /var/lib/docker 2>/dev/null || df -h /
docker version --format '{{.Server.Version}}' 2>/dev/null; stat -fc %T /sys/fs/cgroup
getenforce 2>/dev/null || echo "SELinux 없음"
```

**`uname -m` 결과에 따라 경로가 갈린다.**

| `uname -m` | 의미 | Splunk 단계 |
|---|---|---|
| `x86_64` | 기본 경로. 가장 쉬울 것으로 예상 | load 불필요, Rosetta 불필요 |
| `aarch64` | 맥과 같은 문제(amd64 전용 이미지) + Rosetta 없음 | QEMU binfmt **+** `load-image.sh` 필요, 느림. **미검증** |

권장: 메모리 8GB 이상, `/var/lib/docker` 여유 20GB 이상.
맥 위의 UTM 같은 VM이면 `aarch64`라서 권하지 않는다.

## 1. 환경 준비 — [00](00-setup-mac-linux.md) "리눅스"

- Docker 설치 후 **다시 로그인**(docker 그룹 적용). `docker ps`가 sudo 없이 되어야 한다.
- inotify 설정 파일, 커널 모듈(`modprobe -a`), kubectl, **aws CLI는 실제 설치**(alias 불가).
- kubectl 설치 줄은 Debian/Ubuntu용(`dpkg`)이다. RHEL 계열이면
  `ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')`로 바꿔 쓴다.
- SELinux가 `Enforcing`이면 기록해 두고 그대로 진행해 본다. 막히면 그 사실 자체가 결과다.

기대: `sysctl fs.inotify.max_user_instances` → `1024`

## 2. MiniStack + EKS 컨트롤플레인 — [01](01-emulator-eks.md)

00의 "공통" 절(저장소 clone, MiniStack 기동, `export AWS_*`) → 01의 "실습 경로".

기대 (맥 실측):
- `aws eks wait cluster-active` 15초 안팎
- `kubectl get nodes` → 노드 1개, `control-plane,master`
- 리눅스만: `docker inspect` 로 본 서버 IP(`172.17.0.x`)로 호스트에서 바로 접근된다

## 3. 가짜 EC2 조인 — [02](02-fake-ec2-join.md)

```bash
time ./scripts/fake-ec2-join.sh fake-ec2-1            # 맥: Ready 6초
time ./scripts/fake-ec2-join.sh fake-ec2-2 ubuntu     # 맥: apt 포함 1~2분
for n in fake-ec2-1 fake-ec2-2; do
  until kubectl wait --for=condition=Ready node/$n --timeout=10s >/dev/null 2>&1; do sleep 5; done
done
kubectl get nodes -o wide
```

기대: 3개 노드 `Ready`. 스크립트 출력의 버전이 서버와 같다(`v1.31.4+k3s1`).
x86_64에서는 스크립트가 `k3s`(amd64) 바이너리를 고른다 — 맥과 다른 분기라 **여기가 첫 확인 지점**이다.

## 4. nginx — [03](03-deploy-nginx.md)

```bash
kubectl apply -f manifests/web-test.yaml
kubectl -n web-test rollout status deploy/web
kubectl -n web-test get pods -o wide          # NODE 가 fake-ec2-* 만
```

기대: 파드 2개가 워커에만. 컨트롤플레인 노드 컨테이너에서 `wget -qO- localhost:30080` → nginx 페이지.

## 5. Operator 3.2.0 + Standalone — [04](04-splunk-operator.md) 경로 B

`x86_64`면 **load 단계를 건너뛴다.** 확인 겸 한 번 실행해 보면:

```bash
./scripts/load-image.sh splunk/splunk:10.4.0
# 기대: "x86_64 호스트 — 노드가 amd64 라 load 가 필요 없다..." 출력 후 종료 (미검증 분기)
```

그다음 04 경로 B → 공통(워커 배치) → 공통(Standalone).
**`SPLUNK_GENERAL_TERMS`는 Splunk General Terms 동의다. 에이전트는 사용자 확인 없이 넣지 않는다.**

```bash
time kubectl -n splunk-operator wait standalone/s1 --for=jsonpath='{.status.phase}'=Ready --timeout=20m
kubectl get pod -A -o wide
```

기대·기록:
- Standalone `Ready`까지 시간 — 맥은 이미지 load 후 152초. **리눅스는 이 시간에 이미지 pull(수 GB)이 포함된다.**
  `kubectl -n splunk-operator describe pod splunk-s1-standalone-0`의 Events에서 `Pulled ... in Xs`를 따로 기록
- Operator·Splunk 파드가 `fake-ec2-*`에만
- Splunk 응답 (04 "확인하는 법"의 curl) → `"version":"10.4.0"`, 웹 UI HTTP 200
- **x86_64에서는 Rosetta 없이 직접 실행돼야 한다:**
  ```bash
  N=$(kubectl -n splunk-operator get pod splunk-s1-standalone-0 -o jsonpath='{.spec.nodeName}')
  docker exec "$N" sh -c 'for d in /proc/[0-9]*; do c=$(tr "\0" " " < $d/cmdline 2>/dev/null); case "$c" in *"splunkd -p 8089 start"*) echo "$c";; esac; done' | grep -v "sh -c"
  # 맥:     /mnt/lima-rosetta/rosetta /opt/splunk/bin/splunkd -p 8089 start
  # x86_64: /opt/splunk/bin/splunkd -p 8089 start   ← 기대
  ```
- `docker stats --no-stream`의 Splunk 노드 메모리 — 맥 약 2.1GB

## 6. (선택) Operator 2.8.1 — 04 경로 A

5를 04의 "정리"로 지운 뒤. 기대: Splunk 9.4.3, `SPLUNK_GENERAL_TERMS` 없이 Ready, 맥은 111초.

## 7. 정리 — [README](README.md) "전체 정리"

기대: `docker ps -a --filter name=ministack-eks`가 비어 있고, `fake-ec2-*` 컨테이너·볼륨이 남지 않는다.

## 막혔을 때 진단 순서

1. `docker ps -a` — 죽은 컨테이너가 있으면 `docker logs <이름> | tail -30`
   (k3s `inotify_init: too many open files` → 1단계 inotify)
2. `kubectl config current-context` — `ministack-eks`인가
3. `kubectl get nodes -o wide`, `kubectl get pod -A -o wide`
4. `kubectl -n <ns> describe pod <파드>`의 Events — `ImagePullBackOff`의 메시지 원문
5. `kubectl -n splunk-operator get standalone s1 -o jsonpath='{.status.phase}: {.status.message}'`
6. Operator 로그: `kubectl -n splunk-operator logs deploy/splunk-operator-controller-manager --tail=50`

각 문서의 트러블슈팅 표: [00](00-setup-mac-linux.md#트러블슈팅-맥리눅스-공통), [02](02-fake-ec2-join.md#실측-중-만난-문제), [04](04-splunk-operator.md#공통--standalone)

## 결과 기록

실행하면서 채운다. 맥 값은 비교용.

| 항목 | 맥 (실측) | 리눅스 |
|---|---|---|
| `uname -m` / 배포판 / docker | arm64 / macOS + colima 0.10.1 / 29 | |
| 클러스터 ACTIVE | 15초 | |
| fake-ec2-1 (k3s) Ready | 6초 | |
| fake-ec2-2 (ubuntu) Ready | 1~2분 | |
| nginx 워커 배치 | ✅ | |
| `load-image.sh` | 필요 (pull 포함 약 3분) | x86_64: 즉시 종료 기대 |
| Operator 3.2.0 Running | ✅ arm64 네이티브 | |
| Splunk 10.4.0 이미지 pull | (load로 대체) | |
| Standalone Ready | 152초 | |
| splunkd 실행 방식 | Rosetta 경유 | Rosetta 없이 기대 |
| Splunk 메모리 | 약 2.1GB | |
| (선택) 2.8.1 + 9.4.3 Ready | 111초 | |
| 정리 후 잔여 | 없음 | |
| 막힌 곳 / 해결 | 맥: arm64 이미지 거부 → load | |

## 다 끝나면 문서에 반영

- [00](00-setup-mac-linux.md) "검증 범위" 표에 리눅스 행 추가·수정 (배포판·아키텍처·버전)
- [04](04-splunk-operator.md) "버전별 차이" 표에 리눅스 결과, "미검증" 표시를 실측으로
- [README](README.md) 흐름 표의 상태
- 리눅스에서만 나온 문제는 해당 문서의 트러블슈팅 표에
- **실제로 본 출력이 있는 것만 "실측"으로 바꾼다.** 추정은 계속 "미검증"으로 둔다.
