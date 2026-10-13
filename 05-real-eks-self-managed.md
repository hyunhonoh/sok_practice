# 05. 실제 EKS + 자체 EC2 워커 (참고, 미착수)

> **주의: 이 문서는 아직 실행해본 적 없는 초안이다.**
> 명령과 설정은 조사·경험 기반이며 실측으로 검증되지 않았다.
> 실제로 돌려본 뒤 결과에 맞춰 고칠 것. 특히 엔드포인트·CA·CIDR 같은 값은
> 반드시 `aws eks describe-cluster` 출력에서 가져와야 한다.

## 전제

하려는 것은 **self-managed 노드그룹**이다. 관리형(managed) 노드그룹이 아니라,
EC2를 직접 띄워 kubelet이 EKS 컨트롤플레인에 조인하게 만드는 방식.
EKS 초기부터 있던 원래 방식이고 지금도 정식 지원된다.

**이 부분은 로컬에서 재현할 수 없다.** 막히는 지점이 전부 AWS 쪽 통합
(IAM, access entry, 보안그룹, 부트스트랩)에 있기 때문이다.
에뮬레이터(floci·MiniStack)도 kind도 여기는 흉내내지 못한다 → [01](01-emulator-eks.md), [02](02-fake-ec2-join.md) 참고.

## 필요한 도구 (현재 미설치)

```bash
brew install awscli eksctl
aws configure          # 또는 SSO
aws sts get-caller-identity   # 자격증명 확인
```

## 비용 감각

- EKS 컨트롤플레인: **시간당 $0.10** (클러스터당, 노드 수 무관) — **표준 지원 버전일 때만.**
  표준 지원이 끝난 버전은 연장 지원 요금 **시간당 $0.60**(6배)이 붙는다. 아래 버전 항목 참고.
- EC2 t3.medium ap-northeast-2: 시간당 약 $0.05 × 2대
- eksctl 기본 VPC는 **NAT 게이트웨이**를 만든다: 시간당 약 $0.06 + 데이터 처리 요금
- EBS 볼륨(노드당 20GB gp3): 몇 시간이면 무시할 수준
- 합계 대략 **시간당 $0.3 (약 400원)**. 몇 시간 테스트면 1~2천 원 수준.
- 다 쓰고 반드시 삭제할 것. 컨트롤플레인은 켜둔 시간만큼 계속 과금된다.

*가격은 2026-10 기준 어림값. 실제 요금은 확인 필요.*

## 경로 A — eksctl (간단, 권장)

eksctl은 `nodeGroups`(self-managed)와 `managedNodeGroups`를 키 이름으로 구분한다.

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: sok-test
  region: ap-northeast-2
  version: "1.36"     # 표준 지원 버전으로. 1.33은 2026-07-29 표준 지원 종료 → 연장 요금
                      # 지원 일정: https://endoflife.date/amazon-eks

nodeGroups:                      # ← managedNodeGroups 가 아니다 = self-managed
  - name: ng-self
    instanceType: t3.medium
    desiredCapacity: 2
    amiFamily: AmazonLinux2023
    volumeSize: 20
```

```bash
eksctl create cluster -f cluster.yaml      # 15~20분
kubectl get nodes                           # 조인 확인
kubectl apply -f manifests/web-test.yaml    # 03에서 쓴 것 그대로 (Namespace 포함)
eksctl delete cluster -f cluster.yaml       # 끝나면 반드시
```

IAM 역할·보안그룹·access entry·부트스트랩 유저데이터를 eksctl이 알아서 만든다.
**조인이 되는지만 보고 싶다면 이 경로가 맞다.**

## 경로 B — 수동 (절차를 이해하고 싶을 때)

조인에 필요한 요소는 네 가지다. 하나라도 빠지면 노드가 `kubectl get nodes`에 안 나온다.

### 1. 노드 IAM 역할

EC2가 맡을 역할에 다음을 붙인다.

- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryPullOnly` (이미지 pull만. 기존 `...ReadOnly`도 동작하지만 권한이 더 넓다)
- `AmazonEKS_CNI_Policy` (VPC CNI를 노드 역할로 쓸 때. Pod Identity/IRSA로 분리하는 게 권장)

### 2. 인증 연결 — access entry

노드 IAM 역할을 클러스터가 **노드로** 인정하게 해야 한다.

access entry는 클러스터 인증 모드가 `API` 또는 `API_AND_CONFIG_MAP`일 때만 쓸 수 있다.
`CONFIG_MAP`뿐인 클러스터에서는 실패하므로 먼저 확인한다.

```bash
aws eks describe-cluster --name sok-test --query cluster.accessConfig.authenticationMode
# CONFIG_MAP 이면:
aws eks update-cluster-config --name sok-test --access-config authenticationMode=API_AND_CONFIG_MAP

aws eks create-access-entry \
  --cluster-name sok-test \
  --principal-arn arn:aws:iam::<ACCOUNT>:role/<NODE_ROLE> \
  --type EC2_LINUX
```

예전에는 `kube-system/aws-auth` ConfigMap을 직접 편집했다. 지금도 동작하지만
access entry가 현재 권장 방식이다. `API_AND_CONFIG_MAP`은 둘을 함께 쓰며 옮겨가기 위한 모드이고,
**같은 역할을 양쪽에 동시에 등록하지는 말 것.**

### 3. 보안그룹

- 노드 → 컨트롤플레인: **443/tcp**
- 컨트롤플레인 → 노드: **10250/tcp** (kubelet), **443/tcp** (웹훅·metrics-server 등이 쓴다 — 권장)
- 노드 ↔ 노드: **전체 트래픽** (VPC CNI는 파드가 VPC IP를 그대로 쓰므로 포트를 좁히기 어렵다)

클러스터 보안그룹을 노드에도 그대로 붙이면(자기참조 규칙) 가장 단순하다.

### 4. 부트스트랩 유저데이터

AL2023은 `nodeadm`을 쓴다 (AL2의 `/etc/eks/bootstrap.sh`는 구 방식).
**MIME multipart 형식을 권장한다.** nodeadm은 `NodeConfig` YAML만 단독으로 넣어도 읽지만,
다른 셸 스크립트와 섞거나 관리형 노드그룹의 시작 템플릿에 넣을 때는 MIME이 필수다.

```
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY"

--BOUNDARY
Content-Type: application/node.eks.aws

apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: sok-test
    apiServerEndpoint: <describe-cluster 의 endpoint>
    certificateAuthority: <describe-cluster 의 certificateAuthority.data>
    cidr: <describe-cluster 의 kubernetesNetworkConfig.serviceIpv4Cidr>
--BOUNDARY--
```

값 뽑기:

```bash
aws eks describe-cluster --name sok-test \
  --query 'cluster.{ep:endpoint,ca:certificateAuthority.data,cidr:kubernetesNetworkConfig.serviceIpv4Cidr}'
```

AMI는 EKS 최적화 AMI를 쓴다 (SSM 파라미터로 조회):

```bash
aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/x86_64/standard/recommended/image_id \
  --query 'Parameter.Value' --output text
```

## 조인 실패 시 확인 순서

1. `kubectl get nodes` 에 안 보임 → 노드 안에서 `journalctl -u kubelet -f`
2. `Unauthorized` → access entry 누락 또는 principal ARN 오타
3. 타임아웃 → 보안그룹 443, 또는 프라이빗 서브넷에서 엔드포인트 도달 불가
4. `nodeadm` 오류 → 유저데이터 MIME 형식 깨짐, CA/CIDR 값 오류

## 확인 후 할 것

- `manifests/web-test.yaml` 적용 → 워커에만 배치되는지 ([03](03-deploy-nginx.md)과 동일 결과여야 함)
- 노드 drain/삭제 후 재조인 (self-managed의 실제 운영 부담이 여기 있다)
- `eksctl delete cluster` 또는 수동 리소스 전부 삭제 — **과금 중단 확인**

---

## 부록 — 조인 후 무슨 일이 일어나는가

실제 EKS에서 막혔을 때 어느 단계인지 짚기 위한 흐름. 전체는 이렇다.

```
EC2 부팅 (EKS 최적화 AMI에 kubelet·containerd·kube-proxy·CNI 포함)
  → userData(nodeadm)가 "클러스터 X에 붙어라" 설정
  → kubelet이 EKS API에 자기 등록 → Ready
  → kubectl create (파드)
  → 스케줄러가 노드 선택
  → 그 노드의 kubelet이 이미지 pull
  → 컨테이너 실행
```

### "클러스터링"이 아니라 노드 등록이다

노드끼리 짝을 맺는 게 아니다. **각 노드의 kubelet이 컨트롤플레인에 혼자 전화를 거는**
단방향 등록이다. 노드는 서로의 존재를 몰라도 된다.
등록할 때 자기 자원(CPU, 메모리, 최대 파드 수)을 함께 보고하고,
스케줄러는 그 숫자를 보고 배치를 결정한다.

### "빈 EC2"가 붙는 게 아니다

조인하려면 EC2 안에 kubelet · containerd · kube-proxy · CNI가 있어야 한다.
**EKS 최적화 AMI에 이미 전부 들어 있다.** userData가 하는 일은 설치가 아니라
"어느 클러스터에 붙을지" 알려주고 kubelet을 시작하는 것뿐이다.
그래서 설정에 클러스터 이름·엔드포인트·CA가 들어간다.

### 파드는 노드 하나에서 돈다

- 기본: 스케줄러가 알아서 고른다
- `nodeSelector` / `affinity`: "이런 조건의 노드 중에서" — 권장
- `nodeName`: 스케줄러 우회, 강제 지정 — **운영에선 피할 것.**
  그 노드가 죽으면 파드가 다른 데로 옮겨가지 못하고 사라진다.

### 이미지는 미리 넣어둘 필요가 없다

파드가 배치된 **직후에** 그 노드의 kubelet이 레지스트리에서 받아온다.
kind에서 실측한 이벤트:

```
Pulling  "httpd:2.4-alpine"
Pulled   ... in 4.855s, size: 24039926 bytes
Created / Started
```

**이미지는 노드별 로컬 캐시**다. 공유 저장소가 없으므로 노드 10대면 10번 받아 10벌 저장한다.
두 번째부터는 캐시가 있어 즉시 뜬다(`imagePullPolicy: IfNotPresent`가 기본).

여기서 EKS 특유의 함정 두 개가 나온다. 위 IAM/네트워크 항목이 필요한 이유다.

1. **ECR 프라이빗 저장소** → 노드 IAM 역할에 ECR 읽기 권한이 없으면 `ImagePullBackOff`.
   조인은 성공했는데 이미지만 못 받는 상황이라 원인을 찾기 헷갈린다.
2. **프라이빗 서브넷** → NAT 게이트웨이나 ECR VPC 엔드포인트가 없으면 pull에서 타임아웃.
