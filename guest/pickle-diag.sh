#!/usr/bin/env bash
# pickle-diag — 게스트 VM의 상태를 한 번에 찍는 읽기 전용 진단 스크립트.
#
# 지원 문의에 첨부할 스냅샷을 만드는 용도입니다: 부하, 메모리, 디스크, 실패한
# 서비스, 상위 프로세스, 네트워크 상태를 사람이 읽는 형태로 출력합니다. 아무것도
# 바꾸지 않고, 상주하지도 않습니다 — 필요할 때 받아서 한 번 실행하는 스크립트입니다.
# 배포판 공용: 기본 유틸리티(uptime, free, df, ps, ip)만 사용하므로 Ubuntu·Debian·
# Rocky 어느 이미지에서든 그대로 동작합니다.
#
# 사용:
#   bash pickle-diag.sh            # 화면 출력
#   bash pickle-diag.sh > diag.txt # 파일로 저장해 문의에 첨부
#
# 일부 항목(dmesg, 저널)은 root가 아니면 비어 있을 수 있습니다. 그 항목이 필요하면
# sudo로 실행하세요. 출력에는 비밀값이 들어가지 않지만, 프로세스 목록과 주소가
# 담기므로 공개 게시판보다는 지원 창구로 전달하는 쪽이 좋습니다.
set -uo pipefail

section() { printf '\n== %s\n' "$1"; }

echo "pickle-diag $(date '+%Y-%m-%d %H:%M:%S %z') — $(hostname)"

section "시스템"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null
  echo "OS: ${PRETTY_NAME:-unknown}"
fi
echo "커널: $(uname -r)"
echo "가동 시간: $(uptime -p 2>/dev/null || uptime)"

section "부하 (프로세서 $(nproc 2>/dev/null || echo '?')개 기준)"
read -r l1 l5 l15 _ < /proc/loadavg
echo "load average: 1분 $l1 / 5분 $l5 / 15분 $l15"

section "메모리"
free -h

section "디스크"
df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null || df -h
echo
echo "# 사용률이 높으면 어떤 디렉터리가 큰지: sudo du -xh --max-depth=2 / | sort -rh | head"

section "실패한 서비스"
failed=$(systemctl --failed --no-legend --plain 2>/dev/null)
if [ -n "$failed" ]; then printf '%s\n' "$failed"; else echo "없음"; fi

section "CPU 상위 프로세스 5개"
ps -eo pid,user,pcpu,pmem,etime,comm --sort=-pcpu | head -6

section "메모리 상위 프로세스 5개"
ps -eo pid,user,pcpu,pmem,rss,comm --sort=-rss | head -6

section "네트워크"
ip -brief addr 2>/dev/null || ip addr
echo "기본 경로: $(ip route show default 2>/dev/null || echo '없음')"
if command -v getent >/dev/null 2>&1; then
  if getent hosts deb.debian.org >/dev/null 2>&1 || getent hosts mirror.rockylinux.org >/dev/null 2>&1 \
     || getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    echo "DNS 조회: 정상"
  else
    echo "DNS 조회: 실패 — /etc/resolv.conf 확인 필요"
  fi
fi

section "SSH 서비스"
sshd_state=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || echo unknown)
echo "sshd: $sshd_state"

section "최근 OOM/오류 신호 (root가 아니면 비어 있을 수 있음)"
oom=$(dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -5)
if [ -n "$oom" ]; then printf '%s\n' "$oom"; else echo "커널 오류 로그 없음(또는 권한 없음)"; fi

echo
echo "끝 — 이 출력 전체를 지원 문의에 붙여 주세요."
