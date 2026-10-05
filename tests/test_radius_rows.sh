#!/usr/bin/env bash
# Valida com um radiusd 4.0 REAL as linhas SQL gravadas pelo painel (usuários criados via HTTP).
# Uso: bash tests/test_radius_rows.sh     (requer /tmp/claude-0/fr-install compilado; ver tests/FR_FINDINGS.md)
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/harness.sh
source tests/fr_env.sh
# FR_PATCHED=1 bash tests/test_radius_rows.sh  -> usa a libfreeradius-util corrigida (ver FR_FINDINGS.md, achado 1)
env_up rows 3480 8480 || exit 1
cp_log() { cp -f "$FR_LOG" /tmp/claude-0/fr-rows-radiusd.log 2>/dev/null; }
trap 'cp_log; fr_down rows; env_down rows' EXIT
fr_up rows 3480 18120 || exit 1
echo "FR_PATCHED=${FR_PATCHED:-0}"

t_login tadmin

# mostra só os atributos da resposta (sem Message-Authenticator)
reply() { fr_auth "$@" | sed -n '/^Received/,$p' | grep -v 'Message-Authenticator' | tr -s ' \t' ' ' | tr '\n' ';' | sed 's/;$//'; }
attr()  { fr_auth "$@" | grep -E "^\s*$ATTR_RE\s*=" | head -1 | sed 's/.*= *//'; }
info()  { echo "INFO $*"; }

# --- plano e usuários criados PELO PAINEL (HTTP)
ok "plano criado"  "$(t_post tadmin plans.php plans.php 'action=save&name=basico&down=10M&up=2M&timeout=3600&idle=300&interim=120')" 302
ok "u_ok criado (plano, validade 2027-12-31)" "$(t_post tadmin users.php users.php 'action=create&username=u_ok&password=senha1234&plan=basico&expires=2027-12-31')" 302
ok "u_semplano criado" "$(t_post tadmin users.php users.php 'action=create&username=u_semplano&password=senha1234')" 302
info "radcheck u_ok: $(q "SELECT CONCAT(attribute,' ',op,' ',value) FROM radcheck WHERE username='u_ok'" | tr '\n' '|')"
info "radgroupreply basico: $(q "SELECT CONCAT(attribute,' ',op,' ',value) FROM radgroupreply WHERE groupname='basico'" | tr '\n' '|')"
info "radusergroup u_ok: $(q "SELECT CONCAT(groupname,' ',priority) FROM radusergroup WHERE username='u_ok'")"

# (a) senha
echo "--- (a) Password.Cleartext"
ok "(a) senha certa = Accept"  "$(fr_code u_ok senha1234)" Access-Accept
ok "(a) senha errada = Reject" "$(fr_code u_ok senhaerrada)" Access-Reject
ok "(a) usuário inexistente = Reject" "$(fr_code nao_existe x)" Access-Reject
ok "(a) senha de outro usuário (u_semplano) ok" "$(fr_code u_semplano senha1234)" Access-Accept
info "reply Reject: $(reply u_ok senhaerrada)"

# (b) Expiration
echo "--- (b) Expiration"
ok "(b) painel gravou RFC 3339 UTC" "$(q "SELECT value FROM radcheck WHERE username='u_ok' AND attribute='Expiration'")" "2028-01-01T02:59:59Z"
ok "(b) futuro (RFC 3339) = Accept" "$(fr_code u_ok senha1234)" Access-Accept
ok "(b) painel: validade no passado (expires 2020-01-01)" "$(t_post tadmin users.php users.php 'action=expires&username=u_ok&expires=2020-01-01')" 302
info "gravado: $(q "SELECT value FROM radcheck WHERE username='u_ok' AND attribute='Expiration'")"
ok "(b) passado (RFC 3339) = Reject" "$(fr_code u_ok senha1234)" Access-Reject
info "reply: $(reply u_ok senha1234)"
ok "(b) painel: validade futura de novo" "$(t_post tadmin users.php users.php 'action=expires&username=u_ok&expires=2027-12-31')" 302
ok "(b) futuro = Accept" "$(fr_code u_ok senha1234)" Access-Accept
# formatos legados (o painel NÃO grava estes; testados direto no SQL)
setexp() { q "UPDATE radcheck SET value='$1' WHERE username='u_ok' AND attribute='Expiration'"; }
for v in "Dec 31 2027 23:59:59" "Dec 31 2020 23:59:59" "2027-12-31" "2027-12-31T23:59:59-03:00" "2027-12-31 23:59:59" "1893455999" "2027-12-31T23:59:59"; do
  setexp "$v"; c=$(fr_code u_ok senha1234)
  info "Expiration='$v' -> ${c:-SEM RESPOSTA}"
done
# passado em formato legado deve rejeitar se o formato é entendido
setexp "Dec 31 2020 23:59:59"; legacy_past=$(fr_code u_ok senha1234)
setexp "Dec 31 2027 23:59:59"; legacy_future=$(fr_code u_ok senha1234)
info "formato antigo: futuro=$legacy_future passado=$legacy_past"
info "log (formato antigo): $(grep -iE 'expir|Dec 31' "$FR_LOG" | tail -3 | tr '\n' '|')"
setexp "2028-01-01T02:59:59Z"

# (c) bloqueio
echo "--- (c) bloqueio"
ok "(c) bloquear pelo painel" "$(t_post tadmin users.php users.php 'action=block&username=u_ok')" 302
info "gravado: $(q "SELECT value FROM radcheck WHERE username='u_ok' AND attribute='Expiration'")"
ok "(c) bloqueado = Reject" "$(fr_code u_ok senha1234)" Access-Reject
info "reply: $(reply u_ok senha1234)"
ok "(c) desbloquear pelo painel" "$(t_post tadmin users.php users.php 'action=unblock&username=u_ok')" 302
ok "(c) desbloqueado = Accept" "$(fr_code u_ok senha1234)" Access-Accept

# (d) plano
echo "--- (d) atributos do plano na resposta"
R=$(fr_auth u_ok senha1234)
info "reply: $(reply u_ok senha1234)"
for a in 'Session-Timeout' 'Idle-Timeout' 'Acct-Interim-Interval' 'Rate-Limit'; do
  echo "$R" | grep -qE "^\s*($a)\s*=" && ok "(d) $a presente" 1 1 || ok "(d) $a presente" 0 1
done
ok "(d) Rate-Limit valor"  "$(echo "$R" | grep -E 'Rate-Limit' | sed 's/.*= *//' | tr -d '"')" "2M/10M"
ok "(d) Idle-Timeout"      "$(echo "$R" | grep -E '^\s*Idle-Timeout' | sed 's/.*= *//')" 300
ok "(d) Acct-Interim-Interval" "$(echo "$R" | grep -E '^\s*Acct-Interim-Interval' | sed 's/.*= *//')" 120
ok "(d) usuário sem plano: sem atributos de plano" "$(fr_auth u_semplano senha1234 | grep -cE 'Idle-Timeout|Rate-Limit|Acct-Interim')" 0

# (e) Session-Timeout
echo "--- (e) Session-Timeout: plano x usuário x Expiration"
st() { fr_auth "$@" | grep -E '^\s*Session-Timeout' | sed 's/.*= *//' | tr '\n' ','; }
setexp "2028-01-01T02:59:59Z"
info "plano 3600 + Expiration 2028 (longe): Session-Timeout=$(st u_ok senha1234)"
soon=$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ); setexp "$soon"
info "plano 3600 + Expiration em 30 min ($soon): Session-Timeout=$(st u_ok senha1234)"
soon2=$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ); setexp "$soon2"
info "plano 3600 + Expiration em 3 h: Session-Timeout=$(st u_ok senha1234)"
st_semplano=$(q "SELECT 1"); setexp "2028-01-01T02:59:59Z"
q "UPDATE radcheck SET value='$soon' WHERE username='u_semplano' AND attribute='Expiration'; INSERT INTO radcheck (username,attribute,op,value) SELECT 'u_semplano','Expiration',':=','$soon' WHERE NOT EXISTS (SELECT 1 FROM radcheck WHERE username='u_semplano' AND attribute='Expiration')"
info "sem plano + Expiration em 30 min: Session-Timeout=$(st u_semplano senha1234)"
q "INSERT INTO radreply (username,attribute,op,value) VALUES ('u_ok','Session-Timeout',':=','600')"
info "radreply u_ok Session-Timeout := 600 (plano 3600, Expiration longe): Session-Timeout=$(st u_ok senha1234)"
q "UPDATE radreply SET op='=' WHERE username='u_ok' AND attribute='Session-Timeout'"
info "radreply u_ok Session-Timeout = 600: Session-Timeout=$(st u_ok senha1234)"
q "UPDATE radreply SET value='99999',op=':=' WHERE username='u_ok' AND attribute='Session-Timeout'"
info "radreply u_ok Session-Timeout := 99999 (> plano): Session-Timeout=$(st u_ok senha1234)"
ok "(e) radreply do usuário := NÃO vale: o := do plano (radgroupreply) sobrescreve (DIVERGÊNCIA, ver FR_FINDINGS.md)" "$(st u_ok senha1234)" "3600,"
# se o plano usasse op '=' (só define se ainda não existe), o valor do usuário prevaleceria:
q "UPDATE radgroupreply SET op='=' WHERE groupname='basico' AND attribute='Session-Timeout'"
q "UPDATE radreply SET value='600' WHERE username='u_ok' AND attribute='Session-Timeout'"
ok "(e) com plano op '=' e radreply := 600 -> usuário prevalece" "$(st u_ok senha1234)" "600,"
q "DELETE FROM radreply WHERE username='u_ok'"
ok "(e) com plano op '=' sem radreply -> plano" "$(st u_ok senha1234)" "3600,"
q "UPDATE radgroupreply SET op=':=' WHERE groupname='basico'"

# (g) itens de checagem que outras telas do painel gravam (limites / MAC): o servidor entende a SINTAXE?
echo "--- (g) itens control.* e MAC no radcheck (só sintaxe/leitura; contadores exigem server-config)"
perr() { grep -c 'cannot be parsed' "$FR_LOG"; }
lim_try() { # attr valor
  q "DELETE FROM radcheck WHERE username='u_ok' AND attribute LIKE 'control.%'"
  q "INSERT INTO radcheck (username,attribute,op,value) VALUES ('u_ok','$1',':=','$2')"
  local e0 e1 c; e0=$(perr); c=$(fr_code u_ok senha1234); e1=$(perr)
  echo "${c:-SEM RESPOSTA} (erros de parse novos: $((e1-e0)))"
}
LIMS="control.Max-Daily-Session=3600 control.Max-Monthly-Session=2000000 control.Max-All-Session=99999 control.Simultaneous-Use=1 control.Max-Quota-Daily-Octets=1073741824 control.Max-Quota-Monthly-Octets=1073741824 control.Max-Quota-Total-Octets=1073741824"
for kv in $LIMS; do info "SEM módulo sqlcounter: ${kv%%=*} := ${kv#*=} -> $(lim_try "${kv%%=*}" "${kv#*=}")"; done
ln -sf ../mods-available/sqlcounter "$FR_RADDB/mods-enabled/sqlcounter"
fr_restart >/dev/null || { echo "radiusd não subiu com sqlcounter"; tail -20 "$FR_DIR/stdout.log"; }
for kv in $LIMS; do info "COM módulo sqlcounter habilitado (só define os atributos; não está ligado ao site): ${kv%%=*} -> $(lim_try "${kv%%=*}" "${kv#*=}")"; done
q "DELETE FROM radcheck WHERE username='u_ok' AND attribute LIKE 'control.%'"
rm -f "$FR_RADDB/mods-enabled/sqlcounter"; fr_restart >/dev/null
q "INSERT INTO radcheck (username,attribute,op,value) VALUES ('u_ok','Calling-Station-Id','==','AA-BB-CC-DD-EE-FF')"
info "MAC igual: $(fr_code u_ok senha1234 'Calling-Station-Id = "AA-BB-CC-DD-EE-FF"')  MAC diferente: $(fr_code u_ok senha1234 'Calling-Station-Id = "11-22-33-44-55-66"')  sem MAC: $(fr_code u_ok senha1234)"
q "DELETE FROM radcheck WHERE username='u_ok' AND attribute='Calling-Station-Id'"

# (f) accounting
echo "--- (f) accounting"
SID=sess-0001
fr_acct Start u_ok $SID 'Framed-IP-Address = 10.0.0.5' 'Calling-Station-Id = "AA-BB-CC-DD-EE-FF"' | grep -E '^Received' | sed 's/^/INFO start: /'
ok "(f) Start grava linha" "$(q "SELECT COUNT(*) FROM radacct WHERE username='u_ok' AND acctsessionid='$SID'")" 1
ok "(f)   online (acctstoptime NULL)" "$(q "SELECT COUNT(*) FROM radacct WHERE acctsessionid='$SID' AND acctstoptime IS NULL")" 1
fr_acct Interim-Update u_ok $SID 'Framed-IP-Address = 10.0.0.5' 'Calling-Station-Id = "AA-BB-CC-DD-EE-FF"' 'Acct-Session-Time = 60' 'Acct-Input-Octets = 1000' 'Acct-Output-Octets = 5000' | grep -E '^Received' | sed 's/^/INFO interim: /'
ok "(f) Interim atualiza (continua 1 linha)" "$(q "SELECT COUNT(*) FROM radacct WHERE acctsessionid='$SID'")" 1
ok "(f)   octets Interim in/out" "$(q "SELECT CONCAT(acctinputoctets,'/',acctoutputoctets,'/',acctsessiontime) FROM radacct WHERE acctsessionid='$SID'")" "1000/5000/60"
ok "(f) sessions.php online mostra u_ok" "$(t_get tadmin 'sessions.php?tab=online' | grep -c 'u_ok')" 1
ok "(f)   mostra IP 10.0.0.5"  "$(t_get tadmin 'sessions.php?tab=online' | grep -c '10.0.0.5')" 1
fr_acct Stop u_ok $SID 'Framed-IP-Address = 10.0.0.5' 'Calling-Station-Id = "AA-BB-CC-DD-EE-FF"' 'Acct-Session-Time = 120' 'Acct-Input-Octets = 2000' 'Acct-Output-Octets = 9000' 'Acct-Terminate-Cause = User-Request' | grep -E '^Received' | sed 's/^/INFO stop: /'
ok "(f) Stop grava fim" "$(q "SELECT COUNT(*) FROM radacct WHERE acctsessionid='$SID' AND acctstoptime IS NOT NULL")" 1
ok "(f)   octets finais" "$(q "SELECT CONCAT(acctinputoctets,'/',acctoutputoctets,'/',acctsessiontime,'/',acctterminatecause) FROM radacct WHERE acctsessionid='$SID'")" "2000/9000/120/User-Request"
ok "(f) sessions.php online não mostra mais" "$(t_get tadmin 'sessions.php?tab=online' | grep -c 'u_ok')" 0
ok "(f) sessions.php histórico mostra" "$(t_get tadmin "sessions.php?tab=history&from=2020-01-01&to=2030-01-01" | grep -c 'u_ok')" 1
ok "(f) sessions.php consumo mostra" "$(t_get tadmin "sessions.php?tab=usage&from=2020-01-01&to=2030-01-01" | grep -c 'u_ok')" 1
info "radacct: $(q "SELECT username,nasipaddress,framedipaddress,callingstationid,acctinputoctets,acctoutputoctets,acctstarttime,acctstoptime FROM radacct" | tr '\t' ' ')"
info "radpostauth: $(q "SELECT COUNT(*) FROM radpostauth")"
info "erros no log: $(grep -ciE 'ERROR' "$FR_LOG")"
grep -iE 'ERROR' "$FR_LOG" | sort | uniq -c | head -10 | sed 's/^/INFO log: /'
summary
