# AGENTS.md — 이 저장소에서 일하는 에이전트용 안내

사람용 설명은 [README.md](README.md). 이 파일은 그 위에 **작업 규칙과 현재 할 일**만 더한다.

## 이 저장소는

EKS 관리형 컨트롤플레인 + 직접 붙인 EC2 워커 구조를 로컬 docker로 재현하는 실습 기록이다.

```
MiniStack(AWS 에뮬레이터) ──만듦──▶ k3s 서버 = "EKS 컨트롤플레인"
                                        ▲ 서버 IP:6443 + node-token
가짜 EC2 컨테이너(k3s agent) ───조인───┘   ← nginx, Splunk Operator, Splunk는 여기에만
```

문서는 실습 순서대로 번호가 붙어 있다: 00 환경 → 01 컨트롤플레인 → 02 조인 → 03 nginx →
04 Operator+Splunk → 05 실제 EKS(참고) → 06 리눅스 실측 체크리스트.

## 지금 할 일

**리눅스 실측 — [06-linux-verify.md](06-linux-verify.md)를 위에서부터 따라 하고 결과 표를 채운다.**
맥(Apple Silicon)은 00~04 전부 실측했고, 리눅스는 조인까지만(arm64 VM) 확인한 상태다.
x86_64 리눅스는 전혀 확인하지 않았다.

## 규칙

1. **실제로 본 출력이 있는 것만 "실측"으로 적는다.** 추정·예상은 "미검증"으로 남긴다.
   문서의 기존 "미검증" 표시를 바꿀 때는 근거가 된 출력(명령과 결과)을 함께 적는다.
2. **문서의 명령은 그대로 실행해 본다.** 안 되면 문서를 고치고, 무엇이 왜 안 됐는지 트러블슈팅 표에 남긴다.
   환경 탓(배포판·SELinux 등)이면 그 조건을 명시한다.
3. **`SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com`은 Splunk General Terms 동의다.**
   사용자 확인 없이 설정하지 않는다.
4. **푸시는 사용자 승인 후에만.** 커밋은 해도 된다.
5. 공개 저장소다. 넣지 말 것: 실제 자격증명, Splunk admin 비밀번호(시크릿에서 꺼낸 값),
   개인 경로(`/home/<사용자>/...`, `/Users/...`), 사설 호스트명·IP(도커 기본 bridge `172.17.x.x`는 괜찮다).
   AWS 값은 에뮬레이터용 더미(`test`, 계정 `000000000000`)만 쓴다.
6. `splunk-operator-cluster.yaml`(3MB)은 커밋하지 않는다(.gitignore). 문서에는 공식 릴리스 URL을 쓴다.
7. 스크립트를 고치면 `shellcheck scripts/*.sh`를 통과시키고 실행 권한(755)을 유지한다.
   bash로 작성한다(맥 기본 셸 zsh와 단어 분리 동작이 다르다 — 문서의 명령 예시도 bash·zsh 둘 다에서 되게).
8. 문서는 한국어. 기존 문서의 어조(평서문, 표·코드블록 위주)를 따른다.
9. 정리 명령은 실습 리소스만 지운다(`fake-ec2-*`, `ministack*`, 해당 kubeconfig 항목).
   다른 컨테이너·클러스터·이미지는 건드리지 않는다.

## 자주 쓰는 확인

```bash
kubectl config current-context                    # ministack-eks 여야 한다
kubectl get nodes -o wide                         # control-plane,master = "EKS", <none> = 가짜 EC2
kubectl get pod -A -o wide                        # NODE 열 — 워크로드는 fake-ec2-* 에만
kubectl -n splunk-operator get standalone s1 -o jsonpath='{.status.phase}: {.status.message}'
docker ps -a --format '{{.Names}}\t{{.Status}}'   # 죽은 k3s 컨테이너가 있는가
```

## 맥에서 이미 겪은 함정 (리눅스에서도 나올 수 있음)

| 증상 | 원인 | 문서 |
|---|---|---|
| k3s 컨테이너 즉사 `inotify_init: too many open files` | inotify 한도 128 | 00 |
| `k get pod`가 `127.0.0.1:xxxxx refused` | 다른 클러스터 컨텍스트 | 01 |
| 새 터미널에서 kubectl 인증 실패 | `update-kubeconfig` 재실행으로 exec-env 소실 | 01, 03 |
| 가짜 EC2 조인 무한 대기 `overlayfs snapshotter` | Ubuntu 노드에 볼륨 누락 | 02 |
| `Node password rejected` | 같은 이름 재조인 | 02 |
| Splunk `no match for platform` | arm64 노드 + amd64 전용 이미지 → load | 04 |
| Standalone `Error`, 파드 없음 | 3.x에서 `SPLUNK_GENERAL_TERMS` 누락 | 04 |
