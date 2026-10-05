#!/bin/bash
# radclient falso para testes. Registra argv e stdin em fake-radclient.log (ao lado do script)
# e responde conforme o conteúdo de fake-radclient.mode: ack | nak | timeout | weird | hang.
D="$(cd "$(dirname "$0")" && pwd)"
LOG="$D/fake-radclient.log"
mode=$(cat "$D/fake-radclient.mode" 2>/dev/null || echo ack)
{
  echo "=== CALL"
  for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
  secretfile=""
  prev=""
  for a in "$@"; do [ "$prev" = "-S" ] && secretfile="$a"; prev="$a"; done
  if [ -n "$secretfile" ]; then
    echo "SECRETFILE=$secretfile"
    echo "SECRETFILE_MODE=$(stat -c %a "$secretfile" 2>/dev/null)"
    echo "SECRETFILE_CONTENT=$(cat "$secretfile" 2>/dev/null)"
  fi
  echo "ENVCOUNT=$(env | wc -l)"
  echo "--- STDIN"
  cat
  echo "=== END"
} >>"$LOG"
case "$mode" in
  ack)     echo "Received Disconnect-ACK Id 1 from 127.0.0.1:3799 to 127.0.0.1:0 length 20"; exit 0;;
  nak)     echo "Received Disconnect-NAK Id 1 from 127.0.0.1:3799"; exit 1;;
  timeout) echo "radclient: No reply from server for ID 1 socket 3" >&2; exit 1;;
  weird)   echo "segfault-ish" >&2; exit 7;;
  hang)    exec sleep 60;;
esac
exit 99
