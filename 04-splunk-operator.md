# 04. Splunk Operator 배포 (최종 목표)

nginx 배포([03](03-deploy-nginx.md))가 끝난 뒤의 최종 단계. 여기 적힌 것은 **조사 결과와 준비 절차**이고,
Operator를 이 구성에서 실제로 띄워서 확인한 기록은 아직 없다.

## 흐름에서의 위치

```
00 환경 → 01 EKS 컨트롤플레인 → 02 가짜 EC2 조인 → 03 nginx → 04 Operator  ← 여기
```

nginx와 같은 경로(워커 노드에 배치)로 Operator를 올리는 것이 최종 목표다.
**아직 실측하지 않았다.** 아래는 준비 절차와 예상되는 제약이다.

## Operator 매니페스트 받기 (2.8.1)

3MB 파일이라 저장소에는 넣지 않는다. 공식 릴리스에서 받아 **한 줄만 고친다.**

```bash
curl -sLO https://github.com/splunk/splunk-operator/releases/download/2.8.1/splunk-operator-cluster.yaml

# 2025-03-18 이후 gcr.io 쪽 이미지를 더 이상 받을 수 없다
sed -i.bak 's|gcr.io/kubebuilder/kube-rbac-proxy|registry.k8s.io/kubebuilder/kube-rbac-proxy|' \
  splunk-operator-cluster.yaml
grep -n 'kube-rbac-proxy:' splunk-operator-cluster.yaml   # registry.k8s.io 로 바뀌었는지 확인

kubectl apply -f splunk-operator-cluster.yaml --server-side
```

- 공식 2.8.1 릴리스 파일은 **지금도 `gcr.io` 주소 그대로**다(2026-10 확인).
  위 치환 한 줄이 원본과의 유일한 차이다.
- `--server-side`가 필요하다. CRD가 커서 client-side apply는 어노테이션 크기 제한에 걸린다.
- 최신 릴리스는 **3.2.0**(2026-09-24)이다. 3.x에서 이 문제가 남아 있는지는 확인하지 않았다.

포함된 리소스 (2.8.1 파일 실측):
Namespace `splunk-operator`, CRD 8개, RBAC(ServiceAccount·Role·ClusterRole 등), ConfigMap 2, Service 2,
**PVC 1** (`splunk-operator-app-download`, 10Gi, StorageClass 미지정 → 기본값 사용),
Deployment `splunk-operator-controller-manager`.

- **예시 CR(Standalone 등)은 들어 있지 않다.** Splunk 인스턴스는 직접 CR을 써서 만든다 (아래).
- PVC는 기본 StorageClass가 필요하다. MiniStack의 k3s에는 `local-path (default)`가 있다(확인함).

## 워커에만 배치하기

Operator Deployment에는 affinity·nodeSelector가 **없다**(실측). 그대로 두면 컨트롤플레인 노드에도
배치될 수 있으므로, nginx와 같은 조건을 덧붙인다.

```bash
kubectl -n splunk-operator patch deploy splunk-operator-controller-manager --type merge -p \
'{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":
{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"DoesNotExist"}]}]}}}}}}}'
kubectl -n splunk-operator get pods -o wide        # NODE 가 fake-ec2-* 인지 확인
```

patch 문법은 같은 구조의 Deployment에 서버 dry-run으로 확인했다. Operator 자체에는 아직 적용해보지 않았다.

## Standalone 만들기 (미검증)

CRD 확인 결과 `Standalone`은 `enterprise.splunk.com/v4`(저장 버전)이고 `spec.affinity`를 지원한다.

```yaml
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: s1
  namespace: splunk-operator
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
```

```bash
kubectl apply -f standalone.yaml
kubectl -n splunk-operator get standalone,pods -o wide -w
```

`splunk/splunk` 이미지는 5GB가 넘어 첫 pull에 시간이 걸린다. 가짜 EC2마다 따로 받는다(노드별 캐시).

## 가장 큰 제약 — amd64 전용

레지스트리에서 직접 확인(2026-10-13):

```
splunk/splunk:latest          → linux/amd64 만
splunk/splunk:9.4.1           → linux/amd64 만
splunk/splunk-operator:2.8.1  → linux/amd64 만
rancher/k3s:latest            → amd64, arm64, arm     (클러스터 자체는 무관)
```

Apple Silicon 맥(arm64)에서는 **Rosetta 에뮬레이션이 필수**다.
`nginx` 같은 멀티아치 이미지와 달리 선택의 여지가 없다.

리눅스 호스트가 x86_64라면 거기서는 이 문제가 아예 없다.

## Rosetta 상태

colima는 이미 Rosetta가 켜져 있다. 추가 설정 불필요.

```yaml
# ~/.colima/default/colima.yaml
vmType: vz        # Apple Virtualization.framework
rosetta: true
binfmt: true
```

VM 안에서 등록 확인됨: `/proc/sys/fs/binfmt_misc/rosetta` 존재.

Rancher Desktop의 "VM Type: VZ + Enable Rosetta support"와 **같은 메커니즘**이다.
(Rancher Desktop도 내부적으로 lima를 쓴다.) 따로 설치할 이유가 없다.

## 중첩 깊이 — 근거상 동작 예상, Splunk로는 미측정

```
1단:  VM 커널 → containerd → 파드                              colima 내장 k3s, Rancher Desktop
2단:  VM 커널 → docker → 노드 컨테이너 → containerd → 파드     kind, 에뮬레이터 k3s, **가짜 EC2**
```

Rosetta 인터프리터는 VM의 `/mnt/lima-rosetta/rosetta`에 있어서, 노드 컨테이너 안에서는
그 경로가 보이지 않는다. 그래도 동작할 것으로 보는 근거는 등록 플래그다.

```
$ colima ssh -- cat /proc/sys/fs/binfmt_misc/rosetta
enabled
interpreter /mnt/lima-rosetta/rosetta
flags: OCF          ← F (fix binary)
```

`F` 플래그가 있으면 커널이 **등록 시점에 인터프리터 파일을 열어 둔다.** 이후에는 어느 마운트
네임스페이스(컨테이너 안의 컨테이너 포함)에서 실행해도 그 열린 파일을 쓴다. 따라서 2단에서도
amd64 바이너리가 Rosetta로 실행될 것으로 예상한다.

다만 **Splunk 이미지로 실제 확인한 것은 아니다.** Rosetta로도 일부 바이너리는 실패할 수 있다.
안 되면 파드가 `exec format error` 등으로 죽는다. 그때는 QEMU binfmt를 등록하는 우회
(`docker run --privileged --rm tonistiigi/binfmt --install amd64`)를 시도한다.

실제 EKS(amd64 EC2)나 x86_64 리눅스에서는 이 문제가 전혀 없다. Apple Silicon 맥에서만 생기는 제약이다.

## 리소스 요구

- Standalone 1개: 대략 2 CPU / 4GB. 에뮬레이션 오버헤드 추가.
- SearchHeadCluster: 파드 3개 이상. 로컬에서는 사실상 무리.
- 호스트 RAM의 절반 정도를 colima에 할당하는 것이 상한선 (예: 18GB 맥 → 8~10GB).
- **먼저 Standalone 하나로 확인하고, SHC는 실제 EKS에서 볼 것.**
