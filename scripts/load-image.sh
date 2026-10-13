#!/usr/bin/env bash
# [arm64 호스트 전용 — 맥, arm64 리눅스] amd64 전용 이미지를 가짜 EC2 노드의 containerd에 넣는다.
# kind 의 `kind load docker-image` 와 같은 원리.
# 사용: ./load-image.sh <이미지[:태그]> [노드 컨테이너...]      노드 생략 시 fake-ec2-* 전부
#   예: ./load-image.sh splunk/splunk:10.4.0
#
# 왜 필요한가
#   splunk/splunk 은 "아키텍처 목록" 형식인데 목록에 linux/amd64 하나뿐이다.
#   arm64 노드의 kubelet(containerd CRI)은 목록에서 자기 아키텍처를 못 찾으면
#   pull 을 거부하고(no match for platform), 미리 받아둬도 이미지를 숨긴다.
#   목록을 뺀 "단일 이미지" 형식으로 넣으면 kubelet 이 그대로 쓰고, 실행은 Rosetta(맥)가 맡는다.
#   x86_64 호스트에서는 노드가 원래 amd64 라 필요 없다.
set -euo pipefail
IMAGE=${1:?이미지 (예: splunk/splunk:10.4.0)}; shift
NODES=("$@")

case "$(docker info --format '{{.Architecture}}')" in
  x86_64|amd64) echo "x86_64 호스트 — 노드가 amd64 라 load 가 필요 없다. kubelet 이 직접 받는다."; exit 0 ;;
esac

# 이미지 이름 정리: 다이제스트는 지원하지 않고, 태그가 없으면 :latest
case "$IMAGE" in *@*) echo "다이제스트(@sha256:...) 형식은 지원하지 않는다. 태그로 지정할 것"; exit 1 ;; esac
LAST=${IMAGE##*/}
[[ "$LAST" == *:* ]] || IMAGE="${IMAGE}:latest"
REPO=${IMAGE%:*}; TAG=${IMAGE##*:}

if [ ${#NODES[@]} -eq 0 ]; then
  while IFS= read -r n; do NODES+=("$n"); done < <(docker ps --format '{{.Names}}' | grep '^fake-ec2-' | sort)
fi
[ ${#NODES[@]} -gt 0 ] || { echo "노드 컨테이너가 없다 (fake-ec2-*)"; exit 1; }

# 노드가 준비됐는지 먼저 확인 (Ubuntu 노드는 기동 후 1~2분 동안 k3s 를 설치하는 중이다)
for n in "${NODES[@]}"; do
  docker exec "$n" test -S /run/k3s/containerd/containerd.sock 2>/dev/null \
    || { echo "[$n] 아직 준비되지 않았다 — kubectl get nodes 에서 Ready 가 된 뒤 다시 실행"; exit 1; }
done

# 1. 호스트 docker 에 amd64 판을 받는다 (이미 있으면 건너뜀)
if [ "$(docker image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null)" != amd64 ]; then
  docker pull --platform linux/amd64 "$IMAGE"
fi

# 2. 한 번만 묶는다: amd64 만 save → 아키텍처 목록(index.json) 제거 → manifest.json 기반 단일 이미지
TMP=$(mktemp "${TMPDIR:-/tmp}/load-image.XXXXXX")
trap 'rm -f "$TMP"' EXIT
docker save --platform linux/amd64 "$IMAGE" | python3 -c '
import sys, tarfile
s = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
d = tarfile.open(fileobj=sys.stdout.buffer, mode="w|")
for m in s:
    if m.name in ("index.json", "oci-layout"):
        continue
    d.addfile(m, s.extractfile(m) if m.isfile() else None)
d.close()' > "$TMP"

# 3. 각 노드에 넣고 kubelet 이 보는지 확인
for n in "${NODES[@]}"; do
  # rancher/k3s 이미지 노드는 ctr·crictl 단독 바이너리, Ubuntu 노드는 k3s 하위 명령
  if docker exec "$n" sh -c 'command -v ctr' >/dev/null 2>&1; then
    CTR=(ctr -a /run/k3s/containerd/containerd.sock); CRICTL=(crictl)
  else
    CTR=(k3s ctr); CRICTL=(k3s crictl)
  fi
  echo "[$n] $IMAGE 넣는 중..."
  docker exec -i "$n" "${CTR[@]}" -n k8s.io images import --platform linux/amd64 - < "$TMP" >/dev/null
  out=$(docker exec "$n" "${CRICTL[@]}" images 2>/dev/null)
  if awk -v r="$REPO" -v t="$TAG" '($1==r || $1=="docker.io/"r || $1=="docker.io/library/"r) && $2==t {f=1} END {exit !f}' <<< "$out"; then
    echo "[$n] 완료 — kubelet 이 이미지를 본다"
  else
    echo "[$n] 실패 — kubelet 에 이미지가 보이지 않는다"; exit 1
  fi
done
