# 01. EKS 컨트롤플레인 — 에뮬레이터 (MiniStack, floci 비교)

## 실습 경로 — MiniStack (이것만 따라 하면 된다)

[00](00-setup-mac-linux.md)에서 MiniStack을 띄우고 환경 변수를 설정한 상태에서:

```bash
aws eks create-cluster --name ms-test \
  --role-arn arn:aws:iam::000000000000:role/eks-role \
  --resources-vpc-config subnetIds=subnet-00000001,subnet-00000002
aws eks wait cluster-active --name ms-test                 # 15초 안팎
aws eks update-kubeconfig --name ms-test --alias ministack-eks
# kubectl은 매번 'aws eks get-token'을 부른다. 위 환경변수가 없는 새 터미널에서도 되도록 kubeconfig에 넣어 둔다
kubectl config set-credentials arn:aws:eks:ap-northeast-2:000000000000:cluster/ms-test \
  --exec-env=AWS_ENDPOINT_URL=http://localhost:4567 --exec-env=AWS_ACCESS_KEY_ID=test \
  --exec-env=AWS_SECRET_ACCESS_KEY=test --exec-env=AWS_DEFAULT_REGION=ap-northeast-2
kubectl get nodes
# 32fc79ffc7a7   Ready   control-plane,master   ← 노드 1개 = 컨트롤플레인
```

MiniStack이 `ministack-eks-000000000000-ap-northeast-2-ms-test`라는 k3s 컨테이너를 띄운다.
이것이 "EKS 컨트롤플레인"이다. 워커는 [02](02-fake-ec2-join.md)에서 붙인다.

`kubectl`이 `The connection to the server 127.0.0.1:xxxxx was refused`를 내면 다른 클러스터(kind 등)
컨텍스트를 보고 있는 것이다 → `kubectl config use-context ministack-eks`.

---

> **아래는 비교 기록이다. 따라 하지 말 것.**
> floci를 띄우면 `AWS_ENDPOINT_URL`이 4566으로 바뀌어 MiniStack 실습과 섞이고,
> [02](02-fake-ec2-join.md)의 스크립트는 MiniStack 컨테이너만 찾는다.

## floci 비교 기록 (2026-10-13)

처음에는 문서·이슈만 읽고 "floci로는 안 된다"고 판단했으나, 실제로 설치해서 확인했다.
**결론은 같지만 근거가 추측에서 실측으로 바뀌었다.**

한 줄 요약: **웹서버는 실제로 뜬다. 그러나 "컨트롤플레인 + 별도 워커" 모양은 못 본다.**

### 설치

```bash
docker run -d --name floci -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  floci/floci:latest
curl -s localhost:4566/_floci/health
```

- 이미지 `floci/floci:latest` (공식, floci-io/floci, 324MB) — **arm64 멀티아치**라 맥에서 네이티브로 돈다
- 버전 2.2.0, edition `community`
- `docker.sock` 마운트 필수 (자기가 컨테이너를 띄워야 하므로)
- 조작에는 aws CLI 필요: `brew install awscli`

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_ENDPOINT_URL=http://localhost:4566
```

기본 VPC/서브넷(`subnet-default-ap-northeast-2-a` 등)은 자동 생성돼 있다.

### 함정 1 — inotify 한도 (중요)

k3s 컨테이너가 뜨자마자 죽는다. 로그를 봐야 알 수 있다.

```
E kubelet.go:1686] "Failed to start cAdvisor" err="inotify_init: too many open files"
```

colima VM 기본값이 `fs.inotify.max_user_instances=128`인데, kind 노드 3개가 이미
쓰고 있어서 모자랐다. **floci 문제가 아니라 로컬 k8s 전반에 해당한다.**

→ 맥·리눅스 설정 방법은 [00](00-setup-mac-linux.md)의 inotify 항목 (재부팅해도 유지되는 파일 방식).
floci는 컨테이너가 죽어도 클러스터를 `ACTIVE`라고 계속 보고하므로,
`aws eks describe-cluster`만 믿지 말고 `docker ps`로 확인할 것.

### 함정 2 — kubeconfig 인증

`aws eks update-kubeconfig`로 만든 컨텍스트는 쓸 수 없다.

```
error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

`aws eks get-token`이 만드는 IAM 토큰을 검증할 웹훅이 k3s에 없기 때문이다.
k3s 관리자 kubeconfig를 직접 꺼내 쓴다.

```bash
docker exec floci-aws-eks-<클러스터명> cat /etc/rancher/k3s/k3s.yaml \
  | sed 's|https://127.0.0.1:6443|https://localhost:6500|' > floci-kubeconfig.yaml
export KUBECONFIG=floci-kubeconfig.yaml
```

### 결과

#### 클러스터 생성 — 된다

```bash
aws eks create-cluster --name sok-web \
  --role-arn arn:aws:iam::000000000000:role/eks-role \
  --resources-vpc-config subnetIds=subnet-default-ap-northeast-2-a,subnet-default-ap-northeast-2-c
```

15초만에 ACTIVE. `floci-aws-eks-sok-web` 컨테이너 **1개**가 뜬다 (`rancher/k3s:latest`).

#### 노드 — 1개뿐이고 그게 컨트롤플레인

```
NAME                                                  STATUS  ROLES          VERSION
i-fadaaea35bfe39ffa.ap-northeast-2.compute.internal   Ready   control-plane  v1.34.1+k3s1

instance-type 라벨: k3s          ← t3.medium 같은 게 아님
존:                 ap-northeast-2a
```

이름만 EC2처럼 꾸몄다. **API가 보고하는 버전과 실체가 다르다** —
`describe-cluster`는 `1.29`, 실제 k3s는 `v1.34.1`.

#### 노드그룹 생성 — 실패하고 클러스터까지 죽인다

`desiredSize=3`, `instanceTypes=t3.medium`으로 요청한 결과
(이 시도는 첫 번째 클러스터 `sok-test`에서 했다. 그 클러스터가 죽어서 위의 `sok-web`을 새로 만들었다):

```
status: CREATE_FAILED
health: NodeCreationFailure "Could not apply node capacity; the previous node was restored"

floci 로그:
WARN  Could not replace EKS cluster sok-test for node capacity: Status 304; restoring surviving node
INFO  Adopted surviving k3s container ... for EKS cluster sok-test
```

**노드 용량을 바꾸려면 클러스터 컨테이너를 통째로 교체**하려 든다.
노드가 곧 클러스터 컨테이너이기 때문이다. 교체에 실패하면 복구를 시도하는데,
이번에는 복구된 컨테이너가 `Exited (1)`로 죽었고 API는 계속 ACTIVE를 보고했다.
→ 알려진 이슈 [#5392](https://github.com/floci-io/floci/issues/5392) 재현.

#### 웹서버 배포 — 된다

[03](03-deploy-nginx.md)의 매니페스트를 **그대로 쓰면 안 뜬다**:

```
web-67f758c787-jtgc9   Pending
0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector
```

"컨트롤플레인이 아닌 노드"라는 조건을 만족하는 노드가 없다. 조건을 빼면 뜬다:

```
web2-8656fb7cb6-2sj95   Running   i-fadaaea35bfe39ffa...
web2-8656fb7cb6-cmdgz   Running   i-fadaaea35bfe39ffa...   ← 둘 다 같은 노드
NodePort 32407 → <title>Welcome to nginx!</title>
```

**진짜 k3s에서 진짜 nginx가 실제로 서비스된다.** "API만 흉내내는 것"이 아니다.
다만 노드가 하나라 분산이 불가능하다.

## 비교

| | floci | kind | 실제 EKS |
|---|---|---|---|
| 웹서버 배포·서비스 | ✅ | ✅ | ✅ |
| 컨트롤플레인 + **별도 워커** | ❌ 노드 1개 | ✅ 워커 2대 | ✅ |
| [03](03-deploy-nginx.md) 매니페스트 그대로 | ❌ Pending | ✅ | ✅ |
| 노드 추가/삭제/drain | ❌ 거부·실패 | △ 재생성 필요 | ✅ |
| **EKS API 호출 흐름** | ✅ | ❌ | ✅ |
| IAM·access entry·부트스트랩 | ❌ | ❌ | ✅ |

**floci의 쓸모는 "EKS API를 호출하는 코드(Terraform/CDK/SDK) 테스트"다.**
클러스터 토폴로지를 보려면 kind, 조인 절차를 보려면 실제 EKS.

## 노드 조인을 연습하려면

에뮬레이터의 노드그룹 API로는 노드가 늘지 않는다. **이 저장소의 선택은 에뮬레이터가 띄운 k3s 서버에
가짜 EC2를 직접 조인시키는 것이다 → [02](02-fake-ec2-join.md) (실측 완료).**

조사 단계에서 검토한 다른 대안(미검증):

| 도구 | 조인 연습 | 비고 |
|---|---|---|
| **k3d** | ◎ | `k3d node create --cluster` 로 **돌아가는 클러스터에 에이전트 추가**. 가장 가볍다. 미설치 |
| **k3s 수동** (server + agent) | ◎ | 토큰 + 서버 URL 한 줄로 조인. 절차가 가장 투명하다 |
| **kubeadm on lima** | ◎ | 가장 충실(인증서·토큰·kubelet). lima로 VM 여러 대를 띄워 kubeadm init/join |
| **minikube** | ○ | `--nodes N`. 노드 추가는 되지만 EKS와 무관 |
| **EKS Hybrid Nodes** | ✅ 진짜 | 실제 EKS 컨트롤플레인 + 외부(로컬) 노드. **vCPU-시간당 과금**(1구간 약 $0.020) + 클러스터 요금. 안정적 네트워크 연결 필요 |

EKS 고유 부분(IAM 역할, access entry, 부트스트랩)은 **어느 로컬 도구로도 재현 불가**다.
→ [05](05-real-eks-self-managed.md)

## floci 정리 방법

floci가 남기는 것:
- 컨테이너: `floci`, `floci-aws-eks-<이름>`, `floci-aws-ecr-registry`
- 볼륨: `floci-aws-ecr-registry-data`, `floci-aws-eks-<이름>`
- 네트워크: `floci-aws-vpc-4566-<리전>-vpc-default-<리전>`
- kubeconfig: `update-kubeconfig`로 만든 컨텍스트·클러스터·유저 항목 (ARN 이름)

---

## 부록 — MiniStack 비교 실측 (2026-10-13)

floci와 같은 자리(무료 LocalStack 대체, 포트 4566, MIT)를 노리는 도구.
같은 절차로 확인했다.

```bash
docker run -d --name ministack -p 4567:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ministackorg/ministack:latest          # 69MB, arm64 네이티브
export AWS_ENDPOINT_URL=http://localhost:4567
```

| | floci 2.2.0 | MiniStack |
|---|---|---|
| 이미지 | 324MB | **69MB** |
| EKS 클러스터 | k3s 컨테이너 1개 (포트 6500) | k3s 컨테이너 1개 (포트 16443) |
| 노드 수 | 1 (control-plane) | 1 (control-plane,master) |
| `create-nodegroup` (desiredSize=2) | **CREATE_FAILED + 클러스터 사망** | **ACTIVE**, 클러스터 멀쩡 |
| 노드그룹이 실제 노드를 만드나 | ❌ | ❌ **메타데이터만** — 노드 수 그대로 1 |
| 노드그룹 라벨(`role=web`) 반영 | ❌ | ❌ |
| `aws eks update-kubeconfig` 인증 | ❌ k3s.yaml 꺼내야 함 | **✅ 그대로 됨** |
| k8s 버전 | v1.34.1+k3s1 | v1.31.4+k3s1 |
| nginx 배포·NodePort 응답 | ✅ | ✅ (2개 모두 같은 노드) |

MiniStack이 **API 흉내는 더 매끄럽다** — 노드그룹이 실패하지 않고, kubeconfig 인증도 된다.
하지만 **노드그룹이 실제 노드를 만들지 않는 건 똑같다.** 컨테이너 수도 노드 수도 그대로 1이고
노드그룹 라벨도 노드에 안 붙는다. "API는 ACTIVE인데 실체는 변화 없음"이라 오히려
모르고 쓰면 더 헷갈릴 수 있다.

결론: **EKS API 테스트용으로는 MiniStack이 floci보다 낫다. 토폴로지 검증은 둘 다 불가.**
