# sok_practice

Splunk Operator for Kubernetes practice

**EKS 관리형 컨트롤플레인 + 직접 붙인 EC2 워커** 구조를 로컬(맥·리눅스)에서 재현하고,
그 위에 nginx → Splunk Operator 순서로 배포해보는 실습.

AWS 계정·비용 없이 docker 하나로 돈다.

## 흐름

| 단계 | 문서 | 상태 |
|---|---|---|
| 00 | [환경 준비 — 맥 / 리눅스](00-setup-mac-linux.md) | ✅ 맥·리눅스(aarch64) 실측 |
| 01 | [EKS 컨트롤플레인 — 에뮬레이터 (floci · MiniStack)](01-emulator-eks.md) | ✅ 실측 |
| 02 | [가짜 EC2를 워커로 조인](02-fake-ec2-join.md) | ✅ 실측 |
| 03 | [nginx 배포 — 워커에만](03-deploy-nginx.md) | ✅ 실측 |
| 04 | [Splunk Operator 배포](04-splunk-operator.md) | ⬜ **최종 목표**, 준비 절차만 |
| 05 | [실제 EKS + 자체 EC2 (참고)](05-real-eks-self-managed.md) | ⬜ 미착수 초안 |

## 구조

```
                     ┌──────────── docker (맥: colima VM / 리눅스: 네이티브) ────────────┐
aws CLI ──:4567──▶   │ MiniStack ──띄움──▶ k3s 서버 = "EKS 컨트롤플레인"                  │
                     │                         ▲ 서버 IP:6443 + node-token                │
kubectl ──:16443──▶  │                         │                                           │
                     │      fake-ec2-1 (k3s agent) ── fake-ec2-2 (Ubuntu + k3s) ...      │
                     │          └── nginx / Splunk Operator 파드는 여기에만 ──┘            │
                     └────────────────────────────────────────────────────────────────────┘
```

## 빠른 시작

[00](00-setup-mac-linux.md)으로 docker 환경을 준비한 뒤, 맥·리눅스 공통:

```bash
git clone https://github.com/hyunhonoh/sok_practice.git && cd sok_practice   # 이후 모든 명령은 여기서

# 1. 에뮬레이터
docker run -d --name ministack -p 4567:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock ministackorg/ministack:latest
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=ap-northeast-2 AWS_ENDPOINT_URL=http://localhost:4567

# 2. EKS 컨트롤플레인
aws eks create-cluster --name ms-test --role-arn arn:aws:iam::000000000000:role/eks-role \
  --resources-vpc-config subnetIds=subnet-00000001,subnet-00000002
aws eks wait cluster-active --name ms-test
aws eks update-kubeconfig --name ms-test --alias ministack-eks

# 3. 가짜 EC2 워커
./scripts/fake-ec2-join.sh fake-ec2-1            # rancher/k3s 이미지 (수 초)
./scripts/fake-ec2-join.sh fake-ec2-2 ubuntu     # 일반 Ubuntu + k3s 설치 (1~2분)
kubectl get nodes

# 4. nginx (워커에만)
kubectl apply -f manifests/web-test.yaml           # Namespace 포함, 다시 실행해도 안전
kubectl -n web-test get pods -o wide
```

## 전체 정리

```bash
kubectl delete -f manifests/web-test.yaml
docker rm -fv $(docker ps -aq --filter name=fake-ec2-)        # -v: 익명 볼륨까지
aws eks delete-cluster --name ms-test                         # k3s 서버 컨테이너도 사라진다
docker rm -f ministack
kubectl config delete-context ministack-eks
kubectl config delete-cluster arn:aws:eks:ap-northeast-2:000000000000:cluster/ms-test
kubectl config delete-user    arn:aws:eks:ap-northeast-2:000000000000:cluster/ms-test

colima stop          # 맥: VM 정지 (지우려면 colima delete — 이미지·볼륨 전부 삭제)
```

## 왜 "에뮬레이터 + 가짜 EC2"인가

floci·MiniStack의 EKS는 **진짜 k3s를 띄우지만 노드가 하나(컨트롤플레인 겸용)뿐**이다.
`create-nodegroup`을 해도 노드가 늘지 않는다 — floci는 실패하며 클러스터가 죽고,
MiniStack은 `ACTIVE`라고 답하지만 실제 노드는 그대로다. ([01](01-emulator-eks.md))

그래서 EKS API는 컨트롤플레인을 만드는 데만 쓰고, **워커는 그 k3s 서버에 직접 조인**시킨다.
흐름("엔드포인트 + 신원 정보 → kubelet이 스스로 등록")은 실제 EKS 부트스트랩과 같지만,
**인증은 다르다** — 실제 EKS는 IAM 역할 + access entry, 여기서는 공유 토큰.
IAM 쪽은 이 실습으로 연습되지 않는다. ([02](02-fake-ec2-join.md), [05](05-real-eks-self-managed.md))

## 파일

```
00-setup-mac-linux.md          환경 준비, 검증 범위, 공통 트러블슈팅
01-emulator-eks.md             floci · MiniStack 실측 비교
02-fake-ec2-join.md            조인 원리, 실제 EKS 부트스트랩과 비교, 막혔던 것들
03-deploy-nginx.md             워커 전용 배포와 결과
04-splunk-operator.md          Operator 받기·패치·적용, amd64/Rosetta 제약
05-real-eks-self-managed.md    실제 AWS에서 할 때 (미검증 초안)
scripts/fake-ec2-join.sh       가짜 EC2 조인 스크립트
manifests/web-test.yaml        nginx 매니페스트 (실제 EKS에서도 그대로)
```

## 2.8.1 operator url 변경

- 2025년 3월 18일부로 변경 됨.

```bash
gcr.io/kubebuilder/kube-rbac-proxy:v0.13.1
-> registry.k8s.io/kubebuilder/kube-rbac-proxy:v0.13.1
```

공식 2.8.1 릴리스 파일은 아직 `gcr.io` 그대로라 받은 뒤 한 줄 치환이 필요하다 → [04](04-splunk-operator.md)
