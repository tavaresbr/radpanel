#!/usr/bin/env bash
# Testes de limites (painel + server-config). Uso: bash tests/test_limits.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
source tests/harness.sh
env_up limits 3450 8450 || exit 1
trap 'env_down limits' EXIT

t_login tadmin; t_login toper; t_login tview
P="control.Max"
cnt() { q "SELECT COUNT(*) FROM radcheck WHERE username='$1' AND attribute IN ('control.Max-Daily-Session','control.Max-Monthly-Session','control.Max-All-Session','control.Max-Quota-Daily-Octets','control.Max-Quota-Monthly-Octets','control.Max-Quota-Total-Octets','control.Simultaneous-Use','Calling-Station-Id')"; }
row() { q "SELECT CONCAT(op,'|',value) FROM radcheck WHERE username='$1' AND attribute='$2'"; }
grow() { q "SELECT CONCAT(op,'|',value) FROM radgroupcheck WHERE groupname='$1' AND attribute='$2'"; }
UL() { echo "user_limits.php?u=$1"; }
save() { # papel usuario 'campos'
  t_post "$1" "$(UL $2)" user_limits.php "action=save&username=$2&$3"; }

# ---------------- lib pura
php_t() { php -r 'require "'"$ROOT"'/lib/core.php"; require "'"$ROOT"'/lib/radius_users.php"; require "'"$ROOT"'/lib/limits.php"; '"$1" 2>/dev/null; }
ok "quota 1,5 GB"      "$(php_t 'echo lim_parse_quota("1,5","GB");')" 1610612736
ok "quota 1.25 MB"     "$(php_t 'echo lim_parse_quota("1.25","mb");')" 1310720
ok "quota 10 GB"       "$(php_t 'echo lim_parse_quota("10","GB");')" 10737418240
ok "quota vazia=null"  "$(php_t 'var_dump(lim_parse_quota("","GB"));')" "NULL"
for bad in '-1:GB' 'abc:GB' '0:GB' '1:TB' '1e3:GB' '1.234:GB' '999999999:GB' '5:':; do
  v=${bad%%:*}; u=${bad#*:}
  ok "quota inválida '$bad'" "$(php_t 'try{lim_parse_quota("'$v'","'$u'");echo "aceito";}catch(RuntimeException $e){echo "erro";}')" erro
done
ok "int válido"       "$(php_t 'echo lim_parse_int(" 3600 ",1,86400,"x");')" 3600
for bad in -5 abc 1.5 0 86401 '1;2' '１２'; do
  ok "int inválido '$bad'" "$(php_t 'try{lim_parse_int("'$bad'",1,86400,"x");echo "aceito";}catch(RuntimeException $e){echo "erro";}')" erro
done
ok "mac normaliza :"   "$(php_t 'echo lim_parse_mac("aa:bb:cc:dd:ee:ff");')" "AA-BB-CC-DD-EE-FF"
ok "mac 12 hex"        "$(php_t 'echo lim_parse_mac("aabbccddeeff");')" "AA-BB-CC-DD-EE-FF"
for bad in 'zz:bb:cc:dd:ee:ff' 'aa:bb:cc' '00-00-00-00-00-00' 'FF-FF-FF-FF-FF-FF' "aa:bb:cc:dd:ee:f'"; do
  ok "mac inválido '$bad'" "$(php_t 'try{lim_parse_mac("'"$bad"'");echo "aceito";}catch(RuntimeException $e){echo "erro";}')" erro
done
ok "quota_split GB"    "$(php_t 'echo implode(" ",lim_quota_split(2147483648));')" "2 GB"
ok "quota_split MB"    "$(php_t 'echo implode(" ",lim_quota_split(524288000));')" "500 MB"

# ---------------- plano com limites (admin) + operador não salva
ok "operator não salva plano" "$(t_post toper plans.php plans.php 'action=save&name=gold&daily=10')" 403
ok "admin salva plano com limites" "$(t_post tadmin plans.php plans.php 'action=save&name=gold&down=10M&up=2M&daily=7200&monthly=100000&quota=2&quota_unit=GB&quota_period=monthly&simult=2')" 302
ok "plano daily op '='"   "$(grow gold control.Max-Daily-Session)" "=|7200"
ok "plano monthly"        "$(grow gold control.Max-Monthly-Session)" "=|100000"
ok "plano quota mensal"   "$(grow gold control.Max-Quota-Monthly-Octets)" "=|2147483648"
ok "plano simult"         "$(grow gold control.Simultaneous-Use)" "=|2"
ok "plano sem MAC"        "$(q "SELECT COUNT(*) FROM radgroupcheck WHERE groupname='gold' AND attribute='Calling-Station-Id'")" 0
ok "plano mantém rate"    "$(q "SELECT value FROM radgroupreply WHERE groupname='gold' AND attribute='Mikrotik.Rate-Limit'")" "2M/10M"
ok "plano inválido não grava" "$(t_post tadmin plans.php plans.php 'action=save&name=ruim&daily=-1')" 302
ok "  nada gravado" "$(q "SELECT COUNT(*) FROM radgroupcheck WHERE groupname='ruim'")" 0
t_post tadmin plans.php plans.php 'action=save&name=ruim&quota=5&quota_unit=TB' >/dev/null
ok "  unidade ruim não grava" "$(q "SELECT COUNT(*)+(SELECT COUNT(*) FROM radgroupreply WHERE groupname='ruim') FROM radgroupcheck WHERE groupname='ruim'")" 0
ok "tabela de planos mostra limites" "$(t_get tview plans.php | grep -c 'Simultâneas: 2')" 1
ok "audit plan.save com limites" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='plan.save' AND target='gold' AND detail LIKE '%quota_bytes%2147483648%'")" 1

# ---------------- usuário
t_post toper users.php users.php 'action=create&username=u1&password=senha1234&plan=gold' >/dev/null
t_post toper users.php users.php 'action=create&username=u2&password=senha1234' >/dev/null
ok "link Limites na lista (viewer)" "$(t_get tview users.php | grep -c 'user_limits.php?u=u1')" 1
ok "viewer vê a página"       "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/$(UL u1))" 200
ok "viewer sem formulário"    "$(t_get tview "$(UL u1)" | grep -c 'name="daily"')" 0
ok "operator vê formulário"   "$(t_get toper "$(UL u1)" | grep -c 'name="daily"')" 1
ok "sem login = 302"          "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/$(UL u1))" 302
ok "viewer não grava (403)"   "$(t_post tview users.php user_limits.php 'action=save&username=u1&daily=60')" 403
ok "  nada gravado"           "$(cnt u1)" 0
ok "POST sem csrf = 400"      "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d 'action=save&username=u1&daily=60' $T_WEB/user_limits.php)" 400
ok "  nada gravado"           "$(cnt u1)" 0

ok "operator salva" "$(save toper u1 'daily=3600&monthly=&total=&quota=1.5&quota_unit=GB&quota_period=daily&simult=1&mac=aa:bb:cc:dd:ee:ff')" 302
ok "daily :="           "$(row u1 control.Max-Daily-Session)" ":=|3600"
ok "quota diária :="    "$(row u1 control.Max-Quota-Daily-Octets)" ":=|1610612736"
ok "simult :="          "$(row u1 control.Simultaneous-Use)" ":=|1"
ok "MAC == normalizado" "$(row u1 Calling-Station-Id)" "==|AA-BB-CC-DD-EE-FF"
ok "sem mensal"         "$(cnt u1)" 4
ok "senha preservada"   "$(q "SELECT value FROM radcheck WHERE username='u1' AND attribute='Password.Cleartext'")" senha1234
ok "form preenchido (MAC)" "$(t_get toper "$(UL u1)" | grep -c 'value="AA-BB-CC-DD-EE-FF"')" 1
ok "form preenchido (1,5 GB vira 1536 MB exato)" "$(t_get toper "$(UL u1)" | grep -c 'name="quota" inputmode="decimal" maxlength="12" value="1536"')" 1

ok "troca período p/ mensal 500 MB" "$(save toper u1 'daily=3600&quota=500&quota_unit=MB&quota_period=monthly&simult=1&mac=AA-BB-CC-DD-EE-FF')" 302
ok "quota mensal"        "$(row u1 control.Max-Quota-Monthly-Octets)" ":=|524288000"
ok "quota diária sumiu"  "$(q "SELECT COUNT(*) FROM radcheck WHERE username='u1' AND attribute='control.Max-Quota-Daily-Octets'")" 0

# validação: nada muda
for bad in 'daily=-5' 'daily=abc' 'daily=1.5' 'daily=0' 'daily=86401' 'monthly=2678401' 'total=315360001' 'simult=0' 'simult=101' 'simult=x' \
           'mac=ZZ' 'mac=aa:bb:cc' 'quota=abc' 'quota=-1' 'quota=0' 'quota=5&quota_unit=TB' 'quota=5&quota_period=bogus' \
           "mac=x'%3B%20DROP%20TABLE%20radcheck%3B--" "daily=1%3BDROP" 'daily=%3Cscript%3E'; do
  save toper u1 "daily=3600&quota=500&quota_unit=MB&quota_period=monthly&simult=1&mac=AA-BB-CC-DD-EE-FF" >/dev/null
  save toper u1 "$bad" >/dev/null
  ok "rejeita '$bad' (estado intacto)" "$(row u1 control.Max-Daily-Session)|$(cnt u1)" ":=|3600|4"
done
ok "mensagem de erro amigável" "$(t_get toper "$(UL u1)" >/dev/null; save toper u1 'daily=abc' >/dev/null; t_get toper "$(UL u1)" | grep -c 'apenas números inteiros')" 1
ok "radcheck existe após injeção" "$(q "SELECT COUNT(*)>0 FROM radcheck")" 1

# usuário inexistente / nome malicioso
ok "usuário inexistente = 302" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper "$T_WEB/user_limits.php?u=naoexiste")" 302
ok "u malicioso = 302 e sem eco" "$(curl -s -b $T_DIR/jar-toper "$T_WEB/user_limits.php?u=%3Cscript%3Ealert(1)%3C/script%3E" | grep -c 'alert(1)')" 0
ok "POST usuário inexistente não cria" "$(t_post toper users.php user_limits.php 'action=save&username=naoexiste&daily=60')|$(q "SELECT COUNT(*) FROM radcheck WHERE username='naoexiste'")" "302|0"

# esvaziar remove
ok "esvaziar" "$(save toper u1 'daily=&monthly=&total=&quota=&quota_unit=GB&quota_period=monthly&simult=&mac=')" 302
ok "  todas as linhas de limite removidas" "$(cnt u1)" 0
ok "  senha continua" "$(q "SELECT COUNT(*) FROM radcheck WHERE username='u1' AND attribute='Password.Cleartext'")" 1

# plano x usuário na exibição
b=$(t_get toper "$(UL u1)")
ok "herda do plano (tempo diário)" "$(echo "$b" | grep -c '7200.*</span> (plano)\|2h 00m 00s</span> (plano)')" 1
save toper u1 'daily=600&quota_unit=GB&quota_period=monthly' >/dev/null
b=$(t_get toper "$(UL u1)")
ok "usuário prevalece (tempo diário)" "$(echo "$b" | grep -c '0h 10m 00s</span> (usuário)')" 1
ok "plano continua valendo p/ mensal" "$(echo "$b" | grep -c '27h 46m 40s</span> (plano)')" 1
ok "radgroupcheck do plano intacto" "$(grow gold control.Max-Daily-Session)" "=|7200"
ok "operador do plano '=' (não sobrescreve ':=' do usuário)" "$(q "SELECT DISTINCT op FROM radgroupcheck WHERE groupname='gold'")" "="

# consumo exibido
q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctupdatetime,acctsessiontime,acctinputoctets,acctoutputoctets)
   VALUES ('a','u-a','u2','10.0.0.1',NOW(),NOW(),600,1048576,1048576),
          ('b','u-b','u2','10.0.0.1',NOW(),NOW(),120,0,0)"
q "UPDATE radacct SET acctstoptime=NOW() WHERE acctuniqueid='u-a'"
save toper u2 'daily=3600&quota=10&quota_unit=MB&quota_period=daily&simult=3' >/dev/null
b=$(t_get toper "$(UL u2)")
ok "consumo de tempo (12 min, diário/mensal/total)" "$(echo "$b" | grep -c '0h 12m 00s')" 3
ok "consumo de dados (2,00 MB)" "$(echo "$b" | grep -c '2,00 MB')" 1
ok "sessões abertas = 1"        "$(echo "$b" | grep -c '1 aberta')" 1
ok "barras de progresso (tempo diário + franquia)" "$(echo "$b" | grep -c '<progress')" 2
ok "sem erro PHP" "$(echo "$b" | grep -ci -E 'fatal error|parse error|warning:|exception')" 0

# auditoria
ok "audit user.limits"          "$(q "SELECT COUNT(*)>=3 FROM panel_audit WHERE action='user.limits' AND target='u1'")" 1
ok "audit com mac normalizado"  "$(q "SELECT COUNT(*)>=1 FROM panel_audit WHERE action='user.limits' AND detail LIKE '%AA-BB-CC-DD-EE-FF%'")" 1
ok "audit sem senha"            "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%senha1234%'")" 0

# CSP / inline
for pg in "$(UL u1)" users.php plans.php; do
  ok "sem style/onclick/script inline em $pg" "$(t_get toper "$pg" | grep -cE 'style="|onclick=|<script>[^<]|javascript:|data:')" 0
done
ok "CSP presente" "$(curl -s -D - -o /dev/null -b $T_DIR/jar-toper "$T_WEB/$(UL u1)" | grep -ci "content-security-policy")" 1
ok "referencia limits.css" "$(t_get toper "$(UL u1)" | grep -c 'limits.css')" 1

# PDOException não vaza texto SQL
q "CREATE TRIGGER t_boom BEFORE INSERT ON radcheck FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='SEGREDO-SQL-xyz'"
save toper u2 'daily=100' >/dev/null
b=$(t_get toper "$(UL u2)")
ok "erro de banco: mensagem genérica" "$(echo "$b" | grep -c 'Erro ao salvar no banco')" 1
ok "erro de banco: sem texto SQL"     "$(echo "$b" | grep -ciE 'SQLSTATE|SEGREDO|trigger')" 0
t_post tadmin plans.php plans.php 'action=save&name=gold2&daily=100' >/dev/null  # plano não insere em radcheck; força em radgroupcheck abaixo
q "DROP TRIGGER t_boom"
q "CREATE TRIGGER t_boom2 BEFORE INSERT ON radgroupcheck FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='SEGREDO-SQL-plano'"
t_post tadmin plans.php plans.php 'action=save&name=gold3&daily=100' >/dev/null
b=$(t_get tadmin plans.php)
ok "plano: mensagem genérica sem SQL" "$(echo "$b" | grep -c 'Erro ao salvar no banco')|$(echo "$b" | grep -ciE 'SQLSTATE|SEGREDO')" "1|0"
q "DROP TRIGGER t_boom2"

# ---------------- consultas dos contadores (SQL real em MariaDB)
P0=2000000000
q "DELETE FROM radacct"
q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctsessiontime,acctinputoctets,acctoutputoctets) VALUES
 ('1','q1','cu','1.1.1.1',FROM_UNIXTIME($((P0+100))),600,1000,2000),
 ('2','q2','cu','1.1.1.1',FROM_UNIXTIME($((P0-300))),1000,10,20),
 ('3','q3','cu','1.1.1.1',FROM_UNIXTIME($((P0-5000))),100,5,5),
 ('4','q4','outro','1.1.1.1',FROM_UNIXTIME($((P0+100))),9999,9999,9999)"
runq() { # arquivo conf, atributo-start
  python3 - "$1" "$2" "$P0" <<'PY' | mariadb -S "$T_SOCK" radius -N
import re,sys
t=open(sys.argv[1]).read()
t=t[t.index('"')+1:t.rindex('"')].replace('\\\n',' ')
t=t.replace('%{User-Name}','cu')
if sys.argv[2]!='-': t=t.replace('%{'+sys.argv[2]+'}',sys.argv[3])
print(t+';')
PY
}
C=server-config/mods-config/sql/counter/mysql
ok "SQL panel_daily (overlap)"    "$(runq $C/panel_daily.conf control.Panel-Daily-Start)" 1300
ok "SQL panel_monthly"            "$(runq $C/panel_monthly.conf control.Panel-Monthly-Start)" 1300
ok "SQL panel_total"              "$(runq $C/panel_total.conf -)" 1700
ok "SQL panel_quota_day"          "$(runq $C/panel_quota_day.conf control.Panel-QuotaDay-Start)" 3000
ok "SQL panel_quota_month"        "$(runq $C/panel_quota_month.conf control.Panel-QuotaMonth-Start)" 3000
ok "SQL panel_quota_total"        "$(runq $C/panel_quota_total.conf -)" 3040
ok "SQL usuário sem consumo = 0"  "$(runq $C/panel_total.conf - | sed 's/^/x/' >/dev/null; sed "s/'cu'/'zz'/" /dev/null; python3 - <<'PY' | mariadb -S "$T_SOCK" radius -N
t=open('server-config/mods-config/sql/counter/mysql/panel_quota_total.conf').read()
t=t[t.index('"')+1:t.rindex('"')].replace('\\\n',' ').replace('%{User-Name}','zz'); print(t+';')
PY
)" 0
ok "lib_usage coincide c/ SQL (total)" "$(php_t '$p=db();' 2>/dev/null; php -r 'require "'"$ROOT"'/lib/core.php"; require "'"$ROOT"'/lib/radius_users.php"; require "'"$ROOT"'/lib/limits.php"; $u=lim_usage(db(),"cu"); echo $u["time"]["total"],"|",$u["bytes"]["total"];' 2>/dev/null)" "1700|3040"
# consistência de nomes: attrs do server-config == chaves da lib
ok "check_names do server == chaves da lib" "$(grep -h 'check_name' server-config/mods-available/panel_counters | sed 's/.*= //' | sort | tr '\n' ' ')" \
   "$(php_t 'foreach(array_merge([LIM_KEY_DAILY,LIM_KEY_MONTHLY,LIM_KEY_TOTAL],array_values(LIM_QUOTA_KEYS)) as $k){echo $k,"\n";}' | sort | tr '\n' ' ')"
ok "nenhuma instância stock redefinida" "$(grep -cE '^sqlcounter (dailycounter|monthlycounter|noresetcounter|expire_on_login)' server-config/mods-available/panel_counters)" 0
ok "6 instâncias panel_*" "$(grep -cE '^sqlcounter panel_(daily|monthly|total|quota_day|quota_month|quota_total) ' server-config/mods-available/panel_counters)" 6

# ---------------- apply-server-config.sh
SRCR=/home/user/freeradius-server/raddb
mk() { rm -rf "$1"; mkdir -p "$1"; cp -a $SRCR "$1/raddb"; mkdir -p "$1/raddb/mods-enabled" "$1/raddb/sites-enabled"; ln -s ../sites-available/default "$1/raddb/sites-enabled/default"; }
cat > "$T_DIR/fake-radiusd" <<'FR'
#!/bin/sh
[ -n "$FAKE_FAIL" ] && { echo "Errors reading configuration (fake)"; exit 1; }
d=""; while [ $# -gt 0 ]; do [ "$1" = -d ] && d=$2; shift; done
grep -q panel_limits "$d/sites-enabled/default" && [ -L "$d/mods-enabled/panel_counters" ] && exit 0
exit 2
FR
chmod +x "$T_DIR/fake-radiusd"
A="$T_DIR/a"; mk "$A"; orig_sum=$(sha256sum "$A/raddb/sites-available/default" | cut -d' ' -f1)
out=$(RADDB="$A/raddb" RADIUSD="$T_DIR/fake-radiusd" bash bin/apply-server-config.sh 2>&1); rc=$?
ok "apply: exit 0" "$rc" 0
ok "apply: não reinicia sem --restart" "$(echo "$out" | grep -c 'NÃO reiniciado')" 1
ok "apply: 8 arquivos copiados" "$(ls $A/raddb/mods-available/panel_counters $A/raddb/policy.d/panel_limits $A/raddb/mods-config/sql/counter/mysql/panel_*.conf | wc -l)" 8
ok "apply: link em mods-enabled" "$(readlink $A/raddb/mods-enabled/panel_counters)" "../mods-available/panel_counters"
S="$A/raddb/sites-available/default"
ok "apply: 2 BEGIN" "$(grep -c '# BEGIN radpanel' $S)" 2
ok "apply: 2 END" "$(grep -c '# END radpanel' $S)" 2
ok "apply: ordem prepare < -sql < panel_limits < pap (só no recv Access-Request)" "$(awk '/recv Access-Request/{s=1} s&&/panel_limits_prepare/{a=NR} s&&/^[ \t]*-sql/{b=NR} s&&/^[ \t]*panel_limits[ \t]*$/{c=NR} s&&/^[ \t]*pap[ \t]*$/{d=NR; exit} END{print (a&&b&&c&&d&&a<b&&b<c&&c<d)?"ok":"errado"}' $S)" ok
ok "apply: só duas chamadas no site" "$(grep -c 'panel_limits' $S)" 2
ok "apply: backup datado criado" "$(ls -d $A/radpanel-backups/*/ | wc -l)" 1
sum1=$(sha256sum $S | cut -d' ' -f1)
sleep 1
out=$(RADDB="$A/raddb" RADIUSD="$T_DIR/fake-radiusd" bash bin/apply-server-config.sh 2>&1); rc=$?
ok "apply 2ª vez: exit 0" "$rc" 0
ok "apply 2ª vez: idempotente (site idêntico)" "$(sha256sum $S | cut -d' ' -f1)" "$sum1"
ok "apply 2ª vez: 2º backup" "$(ls -d $A/radpanel-backups/*/ | wc -l)" 2
ok "site ainda tem o resto do original" "$(grep -c 'authenticate pap' $S)" 1

B="$T_DIR/b"; mk "$B"; sb=$(sha256sum "$B/raddb/sites-available/default" | cut -d' ' -f1)
out=$(FAKE_FAIL=1 RADDB="$B/raddb" RADIUSD="$T_DIR/fake-radiusd" bash bin/apply-server-config.sh 2>&1); rc=$?
ok "apply com validação falhando: exit != 0" "$([ $rc -ne 0 ] && echo sim || echo nao)" sim
ok "  restaurou o site" "$(sha256sum $B/raddb/sites-available/default | cut -d' ' -f1)" "$sb"
ok "  removeu arquivos novos" "$(ls $B/raddb/mods-available/panel_counters $B/raddb/policy.d/panel_limits 2>/dev/null | wc -l)" 0
ok "  removeu link" "$([ -e $B/raddb/mods-enabled/panel_counters ] || [ -L $B/raddb/mods-enabled/panel_counters ] && echo existe || echo nao)" nao
ok "  avisou restauração" "$(echo "$out" | grep -c RESTAURANDO)" 1

# site sem 'pap' => falha e restaura
Cc="$T_DIR/c"; mk "$Cc"; sed -i '/^[ \t]*pap[ \t]*$/d' "$Cc/raddb/sites-available/default"; sc=$(sha256sum "$Cc/raddb/sites-available/default" | cut -d' ' -f1)
RADDB="$Cc/raddb" RADIUSD="$T_DIR/fake-radiusd" bash bin/apply-server-config.sh >/dev/null 2>&1; rc=$?
ok "apply sem 'pap': falha e restaura" "$([ $rc -ne 0 ] && echo sim)|$(sha256sum $Cc/raddb/sites-available/default | cut -d' ' -f1)" "sim|$sc"

# ---------------- radiusd real (se compilado): -CX e teste funcional com radclient
RD=/tmp/claude-0/fr-install/sbin/radiusd; RC=/tmp/claude-0/fr-install/bin/radclient
if [ -x "$RD" ] && [ -x "$RC" ]; then
  D="$T_DIR/real"; mkdir -p "$D"; cp -a /tmp/claude-0/fr-install/etc/raddb "$D/raddb"
  (cd "$D/raddb/certs" && make >/dev/null 2>&1)
  RR="$D/raddb"
  ln -s ../mods-available/sql "$RR/mods-enabled/sql"
  sed -i 's/^\tdialect = "sqlite"/\tdialect = "mysql"/; s/^##\tserver = .*/\tserver = "127.0.0.1"/; s/^##\tport = .*/\tport = 3450/; s/^##\tlogin = .*/\tlogin = "fr"/; s/^##\tpassword = .*/\tpassword = "frpass"/' "$RR/mods-available/sql"
  sed -i 's/port = 1812/port = 18450/; s/port = 1813/port = 18451/' "$RR/sites-available/default"
  sed -i 's/port = 18120/port = 18452/' "$RR/sites-available/inner-tunnel"
  q "CREATE USER 'fr'@'127.0.0.1' IDENTIFIED BY 'frpass'; GRANT ALL ON radius.* TO 'fr'@'127.0.0.1'"
  out=$(RADDB="$RR" RADIUSD="$RD" bash bin/apply-server-config.sh 2>&1); rc=$?
  ok "radiusd -CX real aceita a configuração aplicada" "$rc" 0
  [ "$rc" -ne 0 ] && echo "$out" | tail -15
  ok "apply real idempotente (2ª vez)" "$(RADDB="$RR" RADIUSD="$RD" bash bin/apply-server-config.sh >/dev/null 2>&1; echo $?)" 0

  "$RD" -X -d "$RR" >"$T_DIR/radiusd.log" 2>&1 &
  RDPID=$!
  for i in $(seq 1 40); do grep -q 'Ready to process requests' "$T_DIR/radiusd.log" && break; sleep 0.5; done
  ok "radiusd subiu" "$(grep -c 'Ready to process requests' "$T_DIR/radiusd.log")" 1
  auth() { # usuario [attrs extras]
    printf 'User-Name = "%s", User-Password = "senha1234", NAS-IP-Address = 127.0.0.1%s\n' "$1" "${2:+, $2}" |
      timeout 15 "$RC" -x -t 3 -r 1 127.0.0.1:18450 auth testing123 2>&1
  }
  mku() { t_post toper users.php users.php "action=create&username=$1&password=senha1234&plan=${2:-}" >/dev/null; }
  lim() { save toper "$1" "$2" >/dev/null; }

  mku f_free
  ok "RADIUS: usuário sem limites aceito" "$(auth f_free | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS: senha errada rejeitada" "$(printf 'User-Name="f_free",User-Password="x"\n' | timeout 15 $RC -t 3 -r 1 127.0.0.1:18450 auth testing123 2>&1 | grep -c 'Access-Reject' | sed 's/^[1-9][0-9]*$/1/')" 1

  # MAC fixo
  mku f_mac; lim f_mac 'mac=aa:bb:cc:dd:ee:ff&quota_unit=GB'
  ok "RADIUS: MAC certo (minúsculo, com ':') aceito" "$(auth f_mac 'Calling-Station-Id = "aa:bb:cc:dd:ee:ff"' | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS: MAC certo (formato com '-') aceito" "$(auth f_mac 'Calling-Station-Id = "AA-BB-CC-DD-EE-FF"' | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  r=$(auth f_mac 'Calling-Station-Id = "11-22-33-44-55-66"')
  ok "RADIUS: outro MAC rejeitado" "$(echo "$r" | grep -c 'Access-Reject' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS: outro MAC com Reply-Message" "$(echo "$r" | grep -c 'Dispositivo nao autorizado' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS: sem Calling-Station-Id rejeitado" "$(auth f_mac | grep -c 'Access-Reject' | sed 's/^[1-9][0-9]*$/1/')" 1

  # simultâneas
  mku f_sim; lim f_sim 'simult=1&quota_unit=GB'
  ok "RADIUS: simult 1, sem sessões: aceito" "$(auth f_sim | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctupdatetime) VALUES ('s1','f-s1','f_sim','1.1.1.1',NOW(),NOW())"
  r=$(auth f_sim)
  ok "RADIUS: simult 1 com 1 sessão aberta: rejeitado" "$(echo "$r" | grep -c 'Access-Reject' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS:   com Reply-Message" "$(echo "$r" | grep -c 'sessoes simultaneas' | sed 's/^[1-9][0-9]*$/1/')" 1
  q "UPDATE radacct SET acctstoptime=NOW() WHERE acctuniqueid='f-s1'"
  ok "RADIUS: sessão encerrada: aceito" "$(auth f_sim | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  q "UPDATE radacct SET acctstoptime=NULL, acctupdatetime=DATE_SUB(NOW(), INTERVAL 2 DAY) WHERE acctuniqueid='f-s1'"
  ok "RADIUS: sessão 'fantasma' (>24h sem update) não conta" "$(auth f_sim | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  lim f_sim 'simult=2&quota_unit=GB'
  q "UPDATE radacct SET acctupdatetime=NOW() WHERE acctuniqueid='f-s1'"
  ok "RADIUS: simult 2 com 1 aberta: aceito" "$(auth f_sim | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1

  # tempo diário
  mku f_day; lim f_day 'daily=3600&quota_unit=GB'
  ok "RADIUS: diário sem consumo: Session-Timeout 3600" "$(auth f_day | grep -c 'Session-Timeout = 3600' | sed 's/^[1-9][0-9]*$/1/')" 1
  q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctupdatetime,acctstoptime,acctsessiontime) VALUES ('d1','f-d1','f_day','1.1.1.1',NOW(),NOW(),NOW(),3000)"
  ok "RADIUS: diário com 3000 s usados: Session-Timeout 600" "$(auth f_day | grep -c 'Session-Timeout = 600' | sed 's/^[1-9][0-9]*$/1/')" 1
  q "UPDATE radacct SET acctsessiontime=3600 WHERE acctuniqueid='f-d1'"
  r=$(auth f_day)
  ok "RADIUS: diário esgotado: rejeitado" "$(echo "$r" | grep -c 'Access-Reject' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS:   com Reply-Message" "$(echo "$r" | grep -c 'maximum daily usage' | sed 's/^[1-9][0-9]*$/1/')" 1

  # total
  mku f_tot; lim f_tot 'total=1000&quota_unit=GB'
  q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctsessiontime) VALUES ('t1','f-t1','f_tot','1.1.1.1',DATE_SUB(NOW(), INTERVAL 90 DAY),400)"
  ok "RADIUS: total 1000 s, 400 usados (há 90 dias): Session-Timeout 600" "$(auth f_tot | grep -c 'Session-Timeout = 600' | sed 's/^[1-9][0-9]*$/1/')" 1

  # franquia de dados
  mku f_q; lim f_q 'quota=10&quota_unit=MB&quota_period=total'
  q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctinputoctets,acctoutputoctets) VALUES ('q1','f-q1','f_q','1.1.1.1',DATE_SUB(NOW(), INTERVAL 40 DAY),2097152,2097152)"
  r=$(auth f_q)
  ok "RADIUS: franquia 10 MB, 4 MB usados: Mikrotik-Total-Limit 6291456" "$(echo "$r" | grep -c 'Total-Limit = 6291456' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS:   Access-Accept" "$(echo "$r" | grep -c 'Access-Accept' | sed 's/^[1-9][0-9]*$/1/')" 1
  mku f_qg; lim f_qg 'quota=6&quota_unit=GB&quota_period=total'
  q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctinputoctets,acctoutputoctets) VALUES ('q2','f-q2','f_qg','1.1.1.1',NOW(),536870912,536870912)"
  r=$(auth f_qg)
  ok "RADIUS: franquia 6 GB, 1 GB usado: Total-Limit 1073741824 (low)" "$(echo "$r" | grep -c 'Total-Limit = 1073741824' | sed 's/^[1-9][0-9]*$/1/')" 1
  ok "RADIUS:   Total-Limit-Gigawords 1 (restante 5 GB)" "$(echo "$r" | grep -c 'Total-Limit-Gigawords = 1' | sed 's/^[1-9][0-9]*$/1/')" 1
  q "UPDATE radacct SET acctinputoctets=4294967296, acctoutputoctets=2147483648 WHERE acctuniqueid='f-q2'"
  ok "RADIUS: franquia esgotada: rejeitado" "$(auth f_qg | grep -c 'Access-Reject' | sed 's/^[1-9][0-9]*$/1/')" 1
  # franquia diária + mensal: vale a menor
  mku f_qm; lim f_qm 'quota=100&quota_unit=MB&quota_period=monthly'
  q "INSERT INTO radcheck (username,attribute,op,value) VALUES ('f_qm','control.Max-Quota-Daily-Octets',':=','52428800')"
  r=$(auth f_qm)
  ok "RADIUS: diária 50 MB + mensal 100 MB: restante = menor (52428800)" "$(echo "$r" | grep -c 'Total-Limit = 52428800' | sed 's/^[1-9][0-9]*$/1/')" 1

  # plano x usuário
  t_post tadmin plans.php plans.php 'action=save&name=pl1&daily=1000&simult=5' >/dev/null
  mku f_pl pl1
  ok "RADIUS: limite do plano vale (Session-Timeout 1000)" "$(auth f_pl | grep -c 'Session-Timeout = 1000' | sed 's/^[1-9][0-9]*$/1/')" 1
  lim f_pl 'daily=2000&quota_unit=GB'
  ok "RADIUS: limite do usuário prevalece sobre o plano (2000)" "$(auth f_pl | grep -c 'Session-Timeout = 2000' | sed 's/^[1-9][0-9]*$/1/')" 1
  t_post tadmin plans.php plans.php 'action=save&name=pl2&timeout=300&daily=1000' >/dev/null
  mku f_pl2 pl2
  ok "RADIUS: Session-Timeout do plano (300) menor que o contador (1000): vale 300" "$(auth f_pl2 | grep -c 'Session-Timeout = 300' | sed 's/^[1-9][0-9]*$/1/')" 1

  kill "$RDPID" 2>/dev/null; sleep 1; cp "$T_DIR/radiusd.log" /tmp/claude-0/limits-radiusd.log
  ok "radiusd sem erros de unlang na execução" "$(grep -E 'ERROR|Failed' "$T_DIR/radiusd.log" | grep -vE 'pap -|authenticate the user|Maximum|Rejecting user|inner-eap|accounting Failed' | wc -l)" 0
  grep -E 'Failed|ERROR' "$T_DIR/radiusd.log" | head -5
else
  echo "NÃO TESTADO: radiusd/radclient reais ausentes"
fi

summary
