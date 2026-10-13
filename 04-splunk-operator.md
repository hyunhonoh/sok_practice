# 04. Splunk Operator 배포 (실측 완료)

[03](03-deploy-nginx.md)까지 끝난 상태(컨트롤플레인 + 가짜 EC2 워커 2대)에서 Operator와
Splunk Standalone 1대를 **워커에만** 올린다. 2.8.1과 3.2.0 두 버전을 모두 실측했다(2026-10-14, 맥).

```
00 환경 → 01 EKS 컨트롤플레인 → 02 가짜 EC2 조인 → 03 nginx → 04 Operator + Splunk  ← 여기
```

## 버전별 차이 (요약)

| | **2.8.1** | **3.2.0** (2026-09 최신) |
|---|---|---|
| 기본 Splunk 이미지 | `splunk/splunk:9.4.3` | `splunk/splunk:10.4.0` |
| Operator 이미지 | amd64 단일 → 맥에선 Rosetta | **amd64 + arm64** → 맥에서도 네이티브 |
| 사이드카 | kube-rbac-proxy (2/2) | 없음 (1/1) |
| 매니페스트 패치 | **필요** — gcr.io 한 줄 | 불필요 |
| `SPLUNK_GENERAL_TERMS` | 항목 없음, **필요 없음** | **필수** — 기본값이 비어 있다 |
| 맥 결과 | ✅ Ready (이미지 load 후 111초) | ✅ Ready (동의 설정 후 152초) |
| Splunk 메모리 (안정 후) | 약 1.2GB | 약 2.1GB |

3.0.0도 같은 구조다(`splunk/splunk:10.0.0`, `SPLUNK_GENERAL_TERMS` 비어 있음 — 매니페스트로 확인, 실행은 안 함).

## arm64 호스트(맥)에서만 — Splunk 이미지 load (먼저 할 것)

`splunk/splunk`는 **amd64판만 있다.** arm64 가짜 EC2(맥, arm64 리눅스)에서 그냥 띄우면:

```
Failed to pull image "splunk/splunk:9.4.3": ... no match for platform in manifest: not found
```

- `splunk/splunk`는 "아키텍처 목록" 형식인데 목록에 `linux/amd64` 하나뿐이다.
  arm64 노드의 kubelet(containerd)은 목록에서 자기 아키텍처를 못 찾으면 받지 않는다.
- `ctr images pull --platform linux/amd64`로 미리 받아도 소용없다. **kubelet이 그 이미지를 숨긴다**
  (`crictl images`에 안 나온다).
- Operator 2.8.1 이미지는 됐던 이유: 목록 없는 **단일 형식**이라 아키텍처 검사를 하지 않는다.

그래서 **목록을 뺀 단일 형식으로 노드에 직접 넣는다** (kind의 `kind load docker-image`와 같은 원리).
실행은 Rosetta가 맡는다.

```bash
./scripts/load-image.sh splunk/splunk:9.4.3     # 2.8.1 용
./scripts/load-image.sh splunk/splunk:10.4.0    # 3.2.0 용
# 실측: 호스트 pull 포함 약 3분 / 이미 받아둔 이미지면 노드 2대에 1분 안팎
```

스크립트가 하는 일: 노드 준비 확인 → 호스트 docker에 amd64판 pull → `docker save --platform linux/amd64`
→ `index.json` 제거(한 번만) → 각 `fake-ec2-*`의 containerd에 `ctr images import --platform linux/amd64`
→ `crictl images`로 kubelet이 보는지 확인. x86_64 호스트에서는 아무것도 하지 않고 끝난다.

워커가 `Ready`가 된 뒤에 실행한다. Ubuntu 방식 노드는 기동 후 1~2분 동안 k3s를 설치하는 중이라,
그 사이에 돌리면 "아직 준비되지 않았다"로 멈춘다.

**모든 워커에 넣어야 한다.** Splunk 파드가 어느 워커에 뜰지 미리 알 수 없다
(실측: 9.4.3은 fake-ec2-1, 10.4.0은 fake-ec2-2에 떴다).
노드를 새로 붙이면 그 노드에도 다시 넣는다.

> 리눅스 x86_64에서는 이 단계가 필요 없을 것이다. 노드가 원래 amd64라 kubelet이 알아서 받는다 (미검증).
> arm64 리눅스는 맥과 같은 문제가 생기고, Rosetta 대신 QEMU binfmt 등록([00](00-setup-mac-linux.md))과
> 이 load가 함께 필요할 것이다 (미검증).

두 경로 중 하나만 고른다. **같은 클러스터에서 버전을 바꾸려면 먼저 아래 [정리](#정리)를 실행한다**
(파일 이름이 같고, 이전 CRD·Operator·Standalone이 남는다). Standalone의 Splunk 버전은 Operator가 정한다.

## 경로 A — Operator 2.8.1 (Splunk 9.4.3)

```bash
curl -sLO https://github.com/splunk/splunk-operator/releases/download/2.8.1/splunk-operator-cluster.yaml
# 2025-03-18 이후 gcr.io 쪽 이미지를 받을 수 없다 — 공식 파일은 아직 gcr.io 그대로
sed -i.bak 's|gcr.io/kubebuilder/kube-rbac-proxy|registry.k8s.io/kubebuilder/kube-rbac-proxy|' \
  splunk-operator-cluster.yaml
kubectl apply -f splunk-operator-cluster.yaml --server-side
kubectl wait --for=condition=Established crd/standalones.enterprise.splunk.com
```

이어서 아래 [공통 — 워커에만 배치](#공통--워커에만-배치)와 [공통 — Standalone](#공통--standalone).

## 경로 B — Operator 3.2.0 (Splunk 10.4.0)

```bash
curl -sLO https://github.com/splunk/splunk-operator/releases/download/3.2.0/splunk-operator-cluster.yaml
kubectl apply -f splunk-operator-cluster.yaml --server-side       # 패치 불필요
kubectl wait --for=condition=Established crd/standalones.enterprise.splunk.com

# Splunk General Terms 동의 — Operator Deployment의 환경변수다 (Standalone CR이 아니다)
kubectl -n splunk-operator set env deploy/splunk-operator-controller-manager \
  SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
```

> **이 값은 [Splunk General Terms](https://www.splunk.com/en_us/legal/splunk-general-terms.html)에
> 동의한다는 뜻이다.** Operator README도 읽고 동의할 때만 넣으라고 한다. 별도 라이선스를 넣지 않으면
> Splunk는 체험(trial) 라이선스로 동작한다.

이어서 아래 공통 단계.

### 동의를 빼먹으면

**파드가 아예 만들어지지 않는다.** Splunk가 떴다 죽는 게 아니라 Operator가 CR 검증에서 거부한다.
그래서 `kubectl get pod`에는 아무것도 안 보이고, 원인은 Standalone 상태에만 있다.

```bash
kubectl -n splunk-operator get standalone s1 -o jsonpath='{.status.phase}: {.status.message}'
# Error: license not accepted, please adjust SPLUNK_GENERAL_TERMS to indicate you have
#        accepted the current/latest version of the license. See README file for additional information
```

동의 값을 넣으면 Operator가 재시작되고, 같은 CR을 다시 처리해서 파드를 만든다(CR을 다시 만들 필요 없음).
값은 Splunk 파드까지 전달된다.

```
SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
SPLUNK_START_ARGS=--accept-license
```

2.8.1 + Splunk 9.4.3에는 필요 없다. 9.4.3 이미지의 시작 스크립트(`/sbin/entrypoint.sh`)는
`--accept-license`만 검사한다(이미지 안에서 확인).

## 공통 — 워커에만 배치

Operator Deployment에는 affinity가 **없다**(두 버전 모두). k3s 서버 노드에는 컨트롤플레인 테인트도 없어서,
그대로 두면 운에 따라 서버 노드에 뜬다. nginx와 같은 조건을 덧붙인다.

```bash
kubectl -n splunk-operator patch deploy splunk-operator-controller-manager --type merge -p \
'{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":
{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"DoesNotExist"}]}]}}}}}}}'
kubectl -n splunk-operator rollout status deploy/splunk-operator-controller-manager
```

2.8.1은 patch 직후 약 35초 동안 로그가 `attempting to acquire leader lease`에서 멈춘 것처럼 보인다.
이전 파드가 쥐고 있던 리더 리스가 만료되길 기다리는 것이라 정상이다.

## 공통 — Standalone

[manifests/standalone.yaml](manifests/standalone.yaml) — 워커 고정 affinity가 들어 있다.
이미지 버전은 Operator가 정한다.

```bash
kubectl apply -f manifests/standalone.yaml
kubectl -n splunk-operator wait standalone/s1 --for=jsonpath='{.status.phase}'=Ready --timeout=15m
```

맥 실측 2~3분(이미지를 미리 load한 경우). 리눅스 x86_64는 이때 이미지(수 GB)를 받으므로 더 걸린다(미검증).
진행 상황은 `kubectl -n splunk-operator describe pod splunk-s1-standalone-0`의 Events에서 본다.

끝나지 않을 때:

| 증상 | 원인 |
|---|---|
| `standalone` PHASE `Error`, 파드 없음, 메시지 `license not accepted` | 3.x에서 `SPLUNK_GENERAL_TERMS` 누락 |
| 파드 `ImagePullBackOff`, 이벤트 `no match for platform in manifest` | arm64 호스트에서 `load-image.sh` 누락 (또는 새로 붙인 노드에 안 넣음) |
| 파드 `ContainerCreating`이 오래감 | 이미지를 받는 중 (리눅스) — Events에서 `Pulling` 확인 |

PVC 두 개(`etc` 10Gi, `var` 100Gi)가 k3s 기본 `local-path`로 만들어진다. 실제 디스크는 쓰는 만큼만 쓴다.

## 확인하는 법

```bash
kubectl get nodes -o wide            # ROLES: control-plane,master = "EKS", <none> = 내 EC2
kubectl get pod -A -o wide           # NODE 열 — Operator·Splunk가 fake-ec2-* 에 있어야 한다
kubectl -n splunk-operator get standalone
```

실측 (3.2.0):

```
NAMESPACE        NAME                                                 READY  STATUS   NODE
kube-system      coredns-ccb96694c-rhs4q                              1/1    Running  32fc79ffc7a7   ← 컨트롤플레인
kube-system      local-path-provisioner-5cf85fd84d-hm82f              1/1    Running  32fc79ffc7a7
splunk-operator  splunk-operator-controller-manager-8485865785-ffqmz  1/1    Running  fake-ec2-1     ← 내 EC2
splunk-operator  splunk-s1-standalone-0                               1/1    Running  fake-ec2-2     ← 내 EC2
```

> 실제 EKS에서는 `kubectl get nodes`에 컨트롤플레인이 **아예 안 나온다** (AWS가 숨겨서 관리).
> 그래서 coredns 같은 기본 부품도 EC2 워커에 뜬다. 여기서는 k3s 서버가 노드로 보인다는 점만 다르다.

Splunk가 실제로 응답하는지:

```bash
PW=$(kubectl -n splunk-operator get secret splunk-splunk-operator-secret -o jsonpath='{.data.password}' | base64 -d)
kubectl -n splunk-operator exec splunk-s1-standalone-0 -- \
  curl -sk -u "admin:$PW" "https://localhost:8089/services/server/info?output_mode=json" | grep -o '"version":"[^"]*"'
kubectl -n splunk-operator port-forward pod/splunk-s1-standalone-0 8000:8000   # 브라우저 http://localhost:8000 (admin / 위 PW)
```

실측: 9.4.3·10.4.0 모두 `os_name: Linux`, `cpu_arch: x86_64`로 보고하고 웹 UI가 HTTP 200.

## 맥에서 amd64가 도는 방식 — Rosetta

```
$ docker exec fake-ec2-2 cat /proc/<splunkd pid>/cmdline
/mnt/lima-rosetta/rosetta /opt/splunk/bin/splunkd -p 8089 start
```

VM → docker → 가짜 EC2 컨테이너 → containerd, **두 겹 중첩 안쪽에서도 Rosetta가 실행한다.**
가능한 이유는 colima가 Rosetta를 `F`(fix binary) 플래그로 등록하기 때문이다.

```
$ colima ssh -- cat /proc/sys/fs/binfmt_misc/rosetta
enabled
interpreter /mnt/lima-rosetta/rosetta
flags: OCF          ← F: 커널이 등록 시점에 인터프리터를 열어 두어 어느 컨테이너 안에서든 쓴다
```

colima를 `--vm-type vz --vz-rosetta`로 시작해야 한다([00](00-setup-mac-linux.md)).
Rancher Desktop의 "VZ + Enable Rosetta support"와 같은 메커니즘이다.

## 리소스

- colima 8GB에서 Operator + Standalone 1대 + 가짜 EC2 2대 + MiniStack이 여유 있게 돈다
  (다른 클러스터(kind 등)는 꺼둘 것).
- Splunk 10.4.0이 9.4.3보다 무겁다(약 2.1GB vs 1.2GB, 기동 직후 CPU 100% 안팎).
- SearchHeadCluster는 파드 3개 이상이라 로컬에서는 무리. 실제 EKS에서 볼 것.

## 정리

```bash
kubectl -n splunk-operator delete standalone s1
kubectl delete -f splunk-operator-cluster.yaml     # 네임스페이스·CRD·PVC까지 삭제된다 (실측)
```
