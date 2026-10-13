# 02. 가짜 EC2를 워커로 조인 (실측 완료)

**결론: 된다.** EKS API(노드그룹)로는 노드를 못 늘리지만, 에뮬레이터가 띄운 **k3s 서버에
직접 agent를 붙이면** 컨트롤플레인 + 워커 N대 구조가 만들어진다.

```
NAME           STATUS   ROLES                  VERSION
32fc79ffc7a7   Ready    control-plane,master   v1.31.4+k3s1   ← MiniStack이 띄운 "EKS"
fake-ec2-1     Ready    <none>                 v1.31.4+k3s1   ← rancher/k3s 이미지
fake-ec2-2     Ready    <none>                 v1.31.4+k3s1   ← 일반 Ubuntu + k3s 바이너리
fake-ec2-3     Ready    <none>                 v1.31.4+k3s1   ← scripts/fake-ec2-join.sh 로 추가
```

[03](03-deploy-nginx.md)의 "워커에만 배치" 매니페스트가 그대로 동작했다
(floci/MiniStack 단독일 때는 Pending이었다). 파드가 가짜 EC2들에 분산되고,
컨트롤플레인 노드로 NodePort에 접근해도 노드 간 라우팅으로 응답이 온다.

## 원리

에뮬레이터의 "EKS 클러스터"는 진짜 k3s 서버 컨테이너다. k3s 서버는
`/var/lib/rancher/k3s/server/node-token`에 조인 토큰을 갖고 있으므로,
같은 도커 네트워크의 다른 컨테이너가 `서버 IP:6443 + 토큰`으로 agent 조인할 수 있다.

**에뮬레이터를 우회하는 방식**이라는 점을 기억할 것. EKS API는 이 노드들을 모른다
(`describe-nodegroup`은 계속 처음 값 그대로).

## 사용법

```bash
./scripts/fake-ec2-join.sh fake-ec2-1            # rancher/k3s 이미지 (6초)
./scripts/fake-ec2-join.sh fake-ec2-2 ubuntu     # 일반 Ubuntu에 설치 (apt 포함 1~2분)
CLUSTER=ms-test ./scripts/fake-ec2-join.sh ...   # 클러스터가 여러 개일 때는 이름 지정 (아니면 거부)
kubectl get nodes

docker rm -fv fake-ec2-1                         # "EC2 종료" (-v: 익명 볼륨까지 삭제)
#   → 약 45초 뒤 노드가 NotReady(Ready=Unknown)로 바뀌고 그대로 남는다 (실측)
kubectl delete node fake-ec2-1                   # 서버 쪽 정리
```

스크립트는 kubeconfig가 필요 없다. 서버 IP·토큰·버전을 `docker`로 읽고,
정리 작업도 서버 컨테이너 안의 `kubectl`로 한다. 맥과 리눅스(Ubuntu 24.04)에서 같은 스크립트로 확인했다.

```text
리눅스에서 실행한 예:
lx-ec2-1 기동 → server=https://172.17.0.7:6443 (k3s, v1.31.4+k3s1)
→ Ready, 호스트에서 컨테이너 IP(172.17.0.7:6443) kubeconfig로 get nodes 확인
```

## 실제 EKS 부트스트랩과 비교

| 단계 | 실제 EKS (AL2023) | 이 실습 (k3s agent) |
|---|---|---|
| 노드 소프트웨어 | EKS 최적화 AMI에 포함 | `rancher/k3s` 이미지 또는 바이너리 설치 |
| 어디로 붙나 | userData `NodeConfig`의 `apiServerEndpoint` | `K3S_URL=https://<서버IP>:6443` |
| 서버 신원 확인 | `certificateAuthority` (CA) | 토큰 앞부분에 CA 해시 포함 (`K10<hash>::...`) |
| **노드 인증** | **IAM 역할 → access entry(`EC2_LINUX`)** | **공유 토큰** |
| 실행 주체 | `nodeadm` → kubelet | `k3s agent` (kubelet 내장) |
| 등록 결과 | `kubectl get nodes`에 Ready | 동일 |

흐름("엔드포인트와 신원 정보를 받아 kubelet이 스스로 등록")은 같다.
**가장 큰 차이는 인증**이다. 실제 EKS에서 제일 많이 막히는 IAM·access entry 부분은
여기서 공유 토큰 하나로 대체되므로 **연습되지 않는다.**

## 실측 중 만난 문제

| 증상 | 원인 | 해결 |
|---|---|---|
| Ubuntu agent가 계속 `Waiting to retrieve agent configuration` | `"overlayfs" snapshotter cannot be enabled` — 컨테이너 루트가 이미 overlay라 그 안에 overlay를 못 만든다 | `/var/lib/rancher/k3s` 등을 **볼륨으로** 마운트 (`rancher/k3s` 이미지는 이미 볼륨으로 선언돼 있어서 문제없었다) |
| 같은 이름으로 다시 붙이면 거부 | `Node password rejected, duplicate hostname` — 서버가 그 호스트명의 비밀번호를 기억함. **노드 객체를 지우지 않고 컨테이너만 바꿨을 때** 생긴다 (`kubectl delete node`를 하면 시크릿도 같이 지워진다) | `kubectl -n kube-system delete secret <이름>.node-password.k3s` (스크립트가 자동 처리 — 대조 실험으로 확인) |
| k3s 컨테이너가 바로 죽음 | `inotify_init: too many open files` | inotify 한도 상향 — 맥·리눅스 방법은 [00](00-setup-mac-linux.md) |
| (예방) 버전 | agent가 서버보다 새 버전이면 안 된다 | 스크립트가 실행 중인 서버에 `k3s --version`으로 물어 같은 버전을 쓴다 |
| (예방) 이름 충돌 | 같은 이름 컨테이너가 이미 있으면 `docker run` 실패 | 스크립트가 아무것도 건드리기 전에 중단하고 지우는 명령을 알려준다 |
| (예방) 권한 | kubelet·containerd·flannel이 커널 기능을 쓴다 | `--privileged` 필수 |

## 네트워크 메모

- MiniStack의 k3s 서버는 **기본 `bridge` 네트워크**(172.17.0.x)에 있다. 기본 bridge는
  이름 해석이 안 되므로 **IP로** 붙는다. 서버 컨테이너를 다시 만들면 IP가 바뀔 수 있다.
- 스크립트는 **기본 bridge만** 쓴다. 서버의 bridge IP로 붙고, 가짜 EC2도 bridge에 뜬다.
  사용자 정의 네트워크(`floci-net` 등)를 쓰려면 서버를 그 네트워크에 `docker network connect`하고
  가짜 EC2도 `--network`로 같은 곳에 띄워야 하는데, 에뮬레이터가 서버 컨테이너를 재생성하면
  연결이 풀리므로 이 실습에서는 쓰지 않는다.
- 파드 네트워크는 k3s 기본 flannel(VXLAN)이 노드 컨테이너 사이에 자동으로 깔린다.

## floci에서도 되나

원리상 같다(k3s 서버 + node-token). 다만 floci는 노드그룹 조작 시 클러스터 컨테이너를
교체하려 들고 실패하면 죽는 문제가 있었으므로([01](01-emulator-eks.md)),
**이 실습은 MiniStack 기준**으로 했다. floci로는 실측하지 않았다.
