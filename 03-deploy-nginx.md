# 03. nginx 배포 — 워커(가짜 EC2)에만 (실측 완료)

**결론: 컨트롤플레인을 건드리지 않고 워커에만 웹서버를 배포하는 것이 된다.**
EKS 관리형 컨트롤플레인 + 자체 EC2 워커와 스케줄링 관점에서 같은 모양이다.

## 전제

[01](01-emulator-eks.md)로 클러스터를 만들고 [02](02-fake-ec2-join.md)로 가짜 EC2를 1대 이상 붙인 상태.

```bash
aws eks update-kubeconfig --name ms-test --alias ministack-eks   # MiniStack은 이걸로 인증된다
kubectl get nodes
# 32fc79ffc7a7   Ready   control-plane,master
# fake-ec2-1     Ready   <none>
# fake-ec2-2     Ready   <none>
```

## 배포

```bash
kubectl apply -f manifests/web-test.yaml        # Namespace까지 포함 — 여러 번 실행해도 된다
kubectl -n web-test rollout status deploy/web
```

[manifests/web-test.yaml](manifests/web-test.yaml) 요점:

- `nodeAffinity`로 `node-role.kubernetes.io/control-plane` **미보유 노드에만** 배치.
  테인트에 기대지 않고 명시적으로 지정한다. 실제 EKS에서도 그대로 동작한다.
- `podAntiAffinity`(preferred)로 워커 간 분산
- `Namespace web-test` 포함 — 한 번의 apply로 끝나고 다시 실행해도 안전하다
- `Service type: NodePort`, nodePort 30080
- `nginx:1.27-alpine` — **멀티아치**라 arm64/amd64 어디서나 에뮬레이션 없이 뜬다

## 결과

```
web-5ff648fc94-bbs5g   Running   fake-ec2-1
web-5ff648fc94-bp79g   Running   fake-ec2-1      ← 워커 1대일 때

(fake-ec2-2 조인 후 replicas=4, rollout restart)
   1 fake-ec2-1
   3 fake-ec2-2                                    ← 워커에만, 분산됨. 컨트롤플레인 0개
```

접근 확인 — **파드가 없는 컨트롤플레인 노드**로 NodePort를 찔러도 응답이 온다:

```bash
docker exec <ministack-eks-...컨테이너> wget -qO- localhost:30080 | grep title
# <title>Welcome to nginx!</title>
```

kube-proxy가 노드 간 포워딩을 하고, 노드 컨테이너 사이에는 k3s 기본 flannel(VXLAN)이 깔려 있기 때문이다.
실제 EKS에서도 동일하게 동작한다.

호스트에서 직접 열어보려면:

```bash
kubectl -n web-test port-forward svc/web 8080:80     # 맥·리눅스 공통
# 리눅스는 컨테이너 IP로 바로: curl http://<가짜 EC2 IP>:30080
```

## 가짜 EC2 없이 에뮬레이터만 쓰면

같은 매니페스트가 **Pending**이 된다. 노드가 컨트롤플레인 하나뿐이기 때문이다.

```
0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector
```

이 실습에서 가짜 EC2 조인([02](02-fake-ec2-join.md))이 필요한 이유다.

## 참고 — kind로 먼저 확인한 결과

에뮬레이터 없이 kind 멀티노드(control-plane 1 + worker 2)로도 같은 매니페스트를 확인했다.

```
web-...-4msw5   Running   cka-worker2
web-...-grmwc   Running   cka-worker       ← 워커 2대에 분산
NodePort 30080: worker, worker2, control-plane 모두 HTTP 200
```

kind는 노드가 생성 시점에 이미 조인된 상태로 만들어져서 **조인 과정 자체는 볼 수 없다.**
스케줄링·서비스 검증만 필요하면 kind가 가장 간단하다.

## 이미지는 어디서 오나

파드가 배치된 **직후에** 그 노드의 kubelet이 레지스트리에서 받아온다. 미리 넣어둘 필요가 없다.

```
Pulling  "httpd:2.4-alpine"
Pulled   ... in 4.855s, size: 24039926 bytes
Created / Started
→ 파드가 뜬 노드에만 이미지가 생긴다 (노드별 로컬 캐시)
```

## 정리

```bash
kubectl delete -f manifests/web-test.yaml       # 네임스페이스째 삭제
```

클러스터·가짜 EC2까지 전부 지우는 방법은 [README의 전체 정리](README.md#전체-정리).
