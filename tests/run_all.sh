#!/usr/bin/env bash
# Roda todas as suítes do RadPanel (em ondas paralelas, cada uma com banco/portas próprios)
# e imprime um resumo. Uso: bash tests/run_all.sh  [suite ...]
# Suítes que usam o radiusd compilado precisam de /tmp/claude-0/fr-install (veja tests/fr_env.sh).
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
OUT=/tmp/claude-0/runall
rm -rf "$OUT"; mkdir -p "$OUT"

ALL=(core vouchers reports portal customers coa_clients admin limits radius_rows sqli wireguard update perms setup)
SUITES=("$@"); [ ${#SUITES[@]} -eq 0 ] && SUITES=("${ALL[@]}")

run() {
  local s=$1 t=900
  case "$s" in radius_rows) FR_PATCHED=1 timeout $t bash "tests/test_$s.sh" >"$OUT/$s.out" 2>&1 </dev/null ;;
               *) timeout $t bash "tests/test_$s.sh" >"$OUT/$s.out" 2>&1 </dev/null ;; esac
  echo $? >"$OUT/$s.rc"
}

# Duas ondas de até 5 suítes simultâneas (portas distintas por suíte).
pids=(); n=0
for s in "${SUITES[@]}"; do
  run "$s" & pids+=($!); n=$((n+1))
  if [ $((n % 5)) -eq 0 ]; then wait "${pids[@]}"; pids=(); fi
done
[ ${#pids[@]} -gt 0 ] && wait "${pids[@]}"

fail=0
printf '\n%-14s %-6s %s\n' SUITE RC RESUMO
for s in "${SUITES[@]}"; do
  rc=$(cat "$OUT/$s.rc" 2>/dev/null || echo '?')
  sum=$(grep -E '^== [0-9]+ passaram' "$OUT/$s.out" | tail -1)
  [ -z "$sum" ] && sum=$(grep -E 'PASS|FAIL' "$OUT/$s.out" | tail -1)
  nf=$(grep -c '^FAIL' "$OUT/$s.out")
  printf '%-14s %-6s %s (FAIL=%s)\n' "$s" "$rc" "$sum" "$nf"
  { [ "$rc" != 0 ] || [ "$nf" != 0 ]; } && fail=1
done
echo; [ $fail -eq 0 ] && echo "TUDO OK" || echo "HÁ FALHAS (veja $OUT/<suite>.out)"
exit $fail
