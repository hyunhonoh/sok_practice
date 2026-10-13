#!/usr/bin/env bash
# 에뮬레이터(MiniStack)가 띄운 k3s 서버에 "가짜 EC2" 컨테이너를 워커로 조인시킨다.
# 사용: [CLUSTER=<EKS 클러스터명>] ./fake-ec2-join.sh <이름> [k3s|ubuntu]
#   k3s    : rancher/k3s 이미지로 agent 실행 (빠름, 기본값)
#   ubuntu : 일반 Ubuntu에 k3s 바이너리를 설치해서 실행 (EC2 부트스트랩과 비슷)
set -euo pipefail
NAME=${1:?노드 이름}; MODE=${2:-k3s}
case "$MODE" in k3s|ubuntu) ;; *) echo "모드는 k3s 또는 ubuntu"; exit 1;; esac

# MiniStack은 클러스터마다 ministack-eks-<계정12자리>-<리전>-<클러스터명> 컨테이너를 띄운다
PATTERN='^ministack-eks-'
[ -n "${CLUSTER:-}" ] && PATTERN="^ministack-eks-[0-9]{12}-[a-z]{2}-[a-z]+-[0-9]+-${CLUSTER}\$"
SERVERS=$(docker ps --format '{{.Names}}' | grep -E "$PATTERN" || true)
[ -n "$SERVERS" ] || { echo "MiniStack EKS 클러스터 컨테이너가 없다 (CLUSTER=${CLUSTER:-미지정})"; exit 1; }
[ "$(echo "$SERVERS" | wc -l)" -eq 1 ] || { echo "클러스터가 여러 개다. CLUSTER=<이름> 으로 지정:"; echo "$SERVERS"; exit 1; }
SERVER=$SERVERS

# 같은 이름의 컨테이너가 있으면 아무것도 건드리기 전에 중단한다
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "컨테이너 $NAME 이(가) 이미 있다. 지우려면: docker rm -fv $NAME"; exit 1
fi

# 가짜 EC2는 기본 bridge에 뜨므로 서버의 bridge IP로 붙는다
SERVER_IP=$(docker inspect "$SERVER" --format '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}')
[ -n "$SERVER_IP" ] || { echo "$SERVER 가 기본 bridge 네트워크에 없다"; exit 1; }
TOKEN=$(docker exec "$SERVER" cat /var/lib/rancher/k3s/server/node-token)
# 에이전트 버전은 서버보다 높으면 안 된다 → 실행 중인 서버에게 직접 묻는다 (이미지 태그가 latest여도 정확)
K3S_VER=$(docker exec "$SERVER" k3s --version | awk 'NR==1{print $3}')   # 예: v1.31.4+k3s1
case "$(docker info --format '{{.Architecture}}')" in
  x86_64|amd64)  BIN=k3s ;;
  aarch64|arm64) BIN=k3s-arm64 ;;
  *) echo "지원하지 않는 아키텍처"; exit 1 ;;
esac

# 같은 이름으로 다시 붙일 때 "Node password rejected" 방지
# (노드 객체를 지우지 않고 컨테이너만 바꾼 경우 서버에 옛 비밀번호가 남아 있다)
docker exec "$SERVER" kubectl -n kube-system delete secret "$NAME.node-password.k3s" --ignore-not-found >/dev/null 2>&1 || true

COMMON=(--name "$NAME" --hostname "$NAME" --privileged
        -e K3S_URL="https://$SERVER_IP:6443" -e K3S_TOKEN="$TOKEN")

if [ "$MODE" = k3s ]; then
  docker run -d "${COMMON[@]}" "rancher/k3s:${K3S_VER/+/-}" agent --node-label role=web >/dev/null
else
  # containerd는 overlay 위에 overlay를 못 만든다 → 데이터 경로를 볼륨으로
  docker run -d "${COMMON[@]}" \
    -v /var/lib/rancher/k3s -v /var/lib/kubelet -v /var/lib/cni -v /var/log \
    ubuntu:24.04 bash -c "
      apt-get update -qq && apt-get install -y -qq curl ca-certificates iptables >/dev/null 2>&1 &&
      curl -sfL -o /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/download/${K3S_VER/+/%2B}/$BIN &&
      chmod +x /usr/local/bin/k3s && echo '[bootstrap] k3s 설치 완료' &&
      exec k3s agent --node-label role=web" >/dev/null
fi
echo "$NAME 기동 → server=https://$SERVER_IP:6443 ($MODE, $K3S_VER)"
echo "지울 때: docker rm -fv $NAME && kubectl delete node $NAME"
