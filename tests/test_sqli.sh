#!/usr/bin/env bash
# Injeção de SQL via User-Name / Calling-Station-Id nas consultas %sql() de server-config/policy.d/panel_limits,
# com radiusd 4.0 REAL.  Uso: bash tests/test_sqli.sh   (requer /tmp/claude-0/fr-install)
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
source tests/harness.sh
source tests/fr_env.sh
env_up sqli 3490 8490 || exit 1
trap 'cp -f "$FR_LOG" /tmp/claude-0/sqli-radiusd.log 2>/dev/null; fr_down sqli; env_down sqli' EXIT
fr_up sqli 3490 18490 || exit 1

# aplica o server-config (policy + contadores) no raddb de teste e reinicia
out=$(RADDB="$FR_RADDB" RADIUSD="$FR_INSTALL/sbin/radiusd" BACKUP_ROOT="$FR_DIR/bk" bash bin/apply-server-config.sh 2>&1); rc=$?
ok "apply-server-config no raddb de teste" "$rc" 0
[ "$rc" -ne 0 ] && echo "$out" | tail -15
fr_restart >/dev/null || exit 1

PW=senha1234
MAC=AA-BB-CC-DD-EE-FF
# nomes literais perigosos (inseridos direto no banco, como se alguém os tivesse criado)
NAMES=("a'b" 'x\' "bob' OR '1'='1" '%{User-Name}' 'a"b' 'p%c_d' "z' UNION SELECT 1-- " "w'; DELETE FROM radacct; -- " "k' /*" '%{Calling-Station-Id}' "' OR ''='")
sqlq() { mariadb -S "$T_SOCK" radius -N -e "$1"; }
esc() { python3 -c 'import sys;print(sys.argv[1].replace("\\","\\\\").replace("'"'"'","\\'"'"'"))' "$1"; }
addu() { # nome [simult] [mac]
  local n; n=$(esc "$1")
  sqlq "INSERT INTO radcheck (username,attribute,op,value) VALUES ('$n','Password.Cleartext',':=','$PW')"
  [ -n "${2:-}" ] && sqlq "INSERT INTO radcheck (username,attribute,op,value) VALUES ('$n','control.Simultaneous-Use',':=','$2')"
  [ -n "${3:-}" ] && sqlq "INSERT INTO radcheck (username,attribute,op,value) VALUES ('$n','Calling-Station-Id','==','$3')"
  return 0
}
sess() { # nome n  (n sessões abertas)
  local n i; n=$(esc "$1")
  for i in $(seq 1 "$2"); do
    sqlq "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctupdatetime) VALUES ('s$i','$(date +%s%N)-$i-$RANDOM','$n','1.1.1.1',NOW(),NOW())"
  done
}
# vítima: alice com 5 sessões abertas (limite 10, para ela entrar)
addu alice 10 "$MAC"; sess alice 5
for n in "${NAMES[@]}"; do addu "$n" 1 "$MAC"; done

code() { # saída do radclient -> Accept/Reject/none
  grep -oE 'Received (Access-Accept|Access-Reject)' | head -1 | sed 's/Received //'; }
send() { # usuario senha [Calling-Station-Id]  (usa radclient direto, sem passar o nome por shell/eval)
  local u=$1 p=$2 c=${3-$MAC}
  python3 - "$u" "$p" "$c" <<'PY' | "$FR_RADCLIENT" -x -t 3 -r 1 "127.0.0.1:$FR_AUTHPORT" auth "$FR_SECRET" 2>&1
import sys
def q(s): return '"' + s.replace('\\','\\\\').replace('"','\\"') + '"'
u,p,c = sys.argv[1:4]
print('User-Name = ' + q(u)); print('User-Password = ' + q(p))
if c != '-': print('Calling-Station-Id = ' + q(c))
print('NAS-IP-Address = 127.0.0.1')
PY
}
verdict() { send "$@" | code; }

# A policy padrão filter_username (stock) já rejeita nomes com espaço ou "%{": isso é a 1ª barreira.
# Fase 1 = servidor como em produção (com filter_username); fase 2 = filter_username REMOVIDO, para provar que
# o escape do %sql() em panel_limits, sozinho, impede a injeção.
filtered() { case "$1" in *' '*|*'%{'*) echo Access-Reject;; *) echo Access-Accept;; esac; }

BAD=("bob' OR '2'='2" "alice'--" "alice'/*" "x'UNION SELECT 1,2,3-- " "x';DROP TABLE radacct;-- " "x\\'OR 1=1-- " "x')OR('1'='1" 'alice"OR"1"="1' "x%'" "alice' AND '1'='1" "%{sql:SELECT 1}" "alice%')--")
MACBAD=("$MAC' OR '1'='1" "$MAC'; DROP TABLE radcheck; -- " "' UNION SELECT 'x' -- " "$MAC\\" "$MAC\"" "%{User-Name}" "AA-BB-CC-DD-EE-FF' -- " "x%y_z" "$MAC'OR'1'='1")
phase() { # rótulo  expectativa-de-nomes: "filtro" ou "livre"
  local L=$1 mode=$2 n c e
  ok "[$L] alice (limite 10, 5 abertas) aceita" "$(verdict alice $PW)" Access-Accept
  # usuários cujo nome literal contém metacaracteres: 0 sessões próprias => aceitos; com sessão própria => rejeitados
  for n in "${NAMES[@]}"; do
    e=Access-Accept; [ "$mode" = filtro ] && e=$(filtered "$n")
    ok "[$L] nome literal [$n] (0 sessões próprias; alice tem 5)" "$(verdict "$n" $PW)" "$e"
  done
  for n in "${NAMES[@]}"; do sess "$n" 1; done
  for n in "${NAMES[@]}"; do
    e=Access-Reject
    ok "[$L] nome literal [$n] com 1 sessão própria (limite 1)" "$(verdict "$n" $PW)" "$e"
  done
  sqlq "DELETE FROM radacct WHERE acctsessionid='s1' AND username<>'alice' AND acctuniqueid LIKE '%-1-%'" # (limpa as sessões extras)
  # User-Name malicioso inexistente
  for n in "${BAD[@]}"; do
    ok "[$L] inexistente [$n] rejeitado" "$(verdict "$n" $PW)" Access-Reject
  done
  ok "[$L] tabelas ainda existem" "$(sqlq "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='radius' AND table_name IN ('radacct','radcheck')")" 2
  ok "[$L] radcheck intacto" "$(sqlq "SELECT COUNT(*) FROM radcheck")" "$RC0"
  # Calling-Station-Id malicioso, usuário legítimo com MAC fixo
  for c in "${MACBAD[@]}"; do
    ok "[$L] alice com CSI malicioso [$c] rejeitada" "$(verdict alice $PW "$c")" Access-Reject
  done
  ok "[$L] alice sem CSI rejeitada" "$(verdict alice $PW -)" Access-Reject
  ok "[$L] alice com MAC certo (minúsculo/':') aceita" "$(verdict alice $PW aa:bb:cc:dd:ee:ff)" Access-Accept
  ok "[$L] usuário sem MAC fixo, CSI malicioso: aceito (CSI não vai a SQL)" "$(verdict nomac $PW "$MAC' OR '1'='1")" Access-Accept
  ok "[$L] radcheck intacto após CSI" "$(sqlq "SELECT COUNT(*) FROM radcheck")" "$RC0"
}
addu nomac 1
RC0=$(sqlq "SELECT COUNT(*) FROM radcheck")
phase fase1-com-filter filtro

# fase 2: remove a chamada filter_username do site (só no raddb de teste)
sed -i 's/^\([ \t]*\)filter_username[ \t]*$/\1# filter_username (removido no teste)/' "$FR_RADDB/sites-available/default"
ok "filter_username removido do site de teste" "$(grep -c '^[ 	]*filter_username[ 	]*$' "$FR_RADDB/sites-available/default")" 0
fr_restart >/dev/null || exit 1
sqlq "DELETE FROM radacct WHERE username<>'alice'"
phase fase2-sem-filter livre
ok "[fase2] radacct de alice intacto (5 sessões)" "$(sqlq "SELECT COUNT(*) FROM radacct WHERE username='alice'")" 5

# ---- contadores (sqlcounter usa %{User-Name} nas consultas): limite diário com nome perigoso
n="bob' OR '1'='1"; ne=$(esc "$n")
sqlq "INSERT INTO radcheck (username,attribute,op,value) VALUES ('$ne','control.Max-Daily-Session',':=','1000')"
sqlq "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctstoptime,acctsessiontime) VALUES ('c1','cnt-alice','alice','1.1.1.1',NOW(),NOW(),999999)"
sqlq "DELETE FROM radacct WHERE username='$ne'"
r=$(send "$n" $PW)
ok "contador: sessão de alice (999999 s) não conta p/ bob'-injeção (Session-Timeout 1000)" "$(echo "$r" | grep -c 'Session-Timeout = 1000')" 1
ok "contador: Access-Accept" "$(echo "$r" | code)" Access-Accept

# ---- log do radiusd: nenhum erro de SQL / sintaxe
sleep 1
ok "log: sem erro de sintaxe SQL" "$(grep -ciE 'You have an error in your SQL|syntax|SQLSTATE|Failed executing|sql_box_escape' "$FR_LOG")" 0
grep -iE 'error in your SQL|syntax|SQLSTATE' "$FR_LOG" | head -5
ok "radiusd vivo ao final" "$(kill -0 "$(cat "$FR_DIR/radiusd.shpid")" 2>/dev/null && echo sim)" sim

summary
