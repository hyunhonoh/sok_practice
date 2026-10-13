#!/usr/bin/env bash
# [맥 전용] amd64 전용 이미지를 arm64 가짜 EC2 노드의 containerd에 넣는다 (kind load 와 같은 원리).
# 사용: ./load-image.sh <이미지> [노드 컨테이너...]      노드 생략 시 fake-ec2-* 전부
#   예: ./load-image.sh splunk/splunk:10.4.0
#
# 왜 필요한가
#   splunk/splunk 은 "아키텍처 목록" 형식인데 목록에 linux/amd64 하나뿐이다.
#   arm64 노드의 kubelet(containerd CRI)은 목록에서 자기 아키텍처를 못 찾으면
#   pull 을 거부하고(no match for platform), 미리 받아둬도 이미지를 숨긴다.
#   목록을 뺀 "단일 이미지" 형식으로 넣으면 kubelet 이 그대로 쓰고, 실행은 Rosetta 가 맡는다.
#   (x86_64 리눅스에서는 필요 없다 — 노드가 원래 amd64 다.)
set -euo pipefail
IMAGE=${1:?이미지 (예: splunk/splunk:10.4.0)}; shift
NODES=("$@")
if [ ${#NODES[@]} -eq 0 ]; then
  while IFS= read -r n; do NODES+=("$n"); done < <(docker ps --format '{{.Names}}' | grep '^fake-ec2-' | sort)
fi
[ ${#NODES[@]} -gt 0 ] || { echo "노드 컨테이너가 없다 (fake-ec2-*)"; exit 1; }

# 1. 호스트 docker 에 amd64 판을 받는다 (이미 있으면 건너뜀)
if [ "$(docker image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null)" != amd64 ]; then
  docker pull --platform linux/amd64 "$IMAGE"
fi

# docker save 결과에서 아키텍처 목록(index.json)을 빼는 필터 → manifest.json 기반 단일 이미지가 된다
STRIP='import sys,tarfile
s=tarfile.open(fileobj=sys.stdin.buffer,mode="r|"); d=tarfile.open(fileobj=sys.stdout.buffer,mode="w|")
for m in s:
    if m.name in ("index.json","oci-layout"): continue
    d.addfile(m, s.extractfile(m) if m.isfile() else None)
d.close()'

for n in "${NODES[@]}"; do
  # rancher/k3s 이미지 노드는 ctr 단독 바이너리, Ubuntu 노드는 k3s ctr
  if docker exec "$n" sh -c 'command -v ctr' >/dev/null 2>&1; then
    CTR=(ctr -a /run/k3s/containerd/containerd.sock)
  else
    CTR=(k3s ctr)
  fi
  echo "[$n] $IMAGE 넣는 중..."
  docker save "$IMAGE" | python3 -c "$STRIP" \
    | docker exec -i "$n" "${CTR[@]}" -n k8s.io images import --platform linux/amd64 - >/dev/null
  if docker exec "$n" sh -c 'command -v crictl >/dev/null && crictl images || k3s crictl images' 2>/dev/null \
       | grep -q "${IMAGE%:*} *${IMAGE##*:}"; then
    echo "[$n] 완료 — kubelet 이 이미지를 본다"
  else
    echo "[$n] 실패 — kubelet 에 이미지가 보이지 않는다"; exit 1
  fi
done
