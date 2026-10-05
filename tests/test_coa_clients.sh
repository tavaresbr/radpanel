#!/usr/bin/env bash
# Testes de Disconnect (CoA) e clients.d. Uso: bash tests/test_coa_clients.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
source tests/harness.sh
env_up coa 3460 8460 || exit 1
trap 'env_down coa' EXIT

cp tests/fake-radclient.sh "$T_DIR/fake-radclient"; chmod +x "$T_DIR/fake-radclient"
LOG="$T_DIR/fake-radclient.log"; MODE="$T_DIR/fake-radclient.mode"
mode() { echo "$1" >"$MODE"; : >"$LOG"; }
ncalls() { grep -c '^=== CALL' "$LOG" 2>/dev/null || true; }
t_login tadmin; t_login toper; t_login tview

SQL() { mariadb -S "$T_SOCK" radius -e "$1"; }
SQL "INSERT INTO nas (nasname, shortname, type, secret, description) VALUES ('198.51.100.7','mk1','other','Segredo-NAS-123','x')"
addsess() { # id user nas sid framed
  SQL "INSERT INTO radacct (acctsessionid, acctuniqueid, username, nasipaddress, framedipaddress, acctstarttime, acctupdatetime) VALUES ('$3','$1','$2','$4','$5',NOW(),NOW())"
}
addsess u1 alice 'sess-001' 198.51.100.7 10.0.0.5
RID=$(q "SELECT radacctid FROM radacct WHERE acctuniqueid='u1'")

# --- ACK
mode ack
ok "operator derruba (302)" "$(t_post toper sessions.php sessions.php "action=disconnect&id=$RID")" 302
ok "  radclient chamado 1x" "$(ncalls)" 1
EXPECT_ARGV=$'ARG[-S]\nARG[%s]\nARG[-r]\nARG[1]\nARG[-t]\nARG[3]\nARG[198.51.100.7:3799]\nARG[disconnect]'
got=$(grep '^ARG\[' "$LOG" | sed "2s#.*#ARG[%s]#")
ok "  argv exato (sem segredo, usa -S)" "$got" "$(printf '%s' "$EXPECT_ARGV" | sed 's/$//')"
ok "  segredo não está em argv" "$(grep '^ARG' "$LOG" | grep -c 'Segredo-NAS-123')" 0
ok "  arquivo do segredo 600" "$(grep SECRETFILE_MODE "$LOG" | cut -d= -f2)" 600
ok "  arquivo do segredo com o segredo do banco" "$(grep SECRETFILE_CONTENT "$LOG" | cut -d= -f2-)" "Segredo-NAS-123"
sf=$(grep '^SECRETFILE=' "$LOG" | cut -d= -f2-)
ok "  arquivo temporário removido" "$([ -e "$sf" ] && echo existe || echo removido)" removido
ok "  stdin" "$(sed -n '/^--- STDIN/,/^=== END/p' "$LOG" | grep -v '^---\|^===' | tr '\n' '|')" 'User-Name = "alice"|Acct-Session-Id = "sess-001"|NAS-IP-Address = 198.51.100.7|Framed-IP-Address = 10.0.0.5|'
ok "  auditado" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='session.disconnect' AND target='alice' AND detail LIKE '%ack%'")" 1
ok "  auditoria sem segredo" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%Segredo-NAS%'")" 0
ok "  flash de sucesso" "$(t_get toper sessions.php | grep -c 'derrubada')" 1

# --- NAK / timeout / exit estranho / hang
mode nak;     t_post toper sessions.php sessions.php "action=disconnect&id=$RID" >/dev/null
ok "NAK mensagem" "$(t_get toper sessions.php | grep -c 'recusou')" 1
ok "  audit nak" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='session.disconnect' AND detail LIKE '%nak%'")" 1
mode timeout; t_post toper sessions.php sessions.php "action=disconnect&id=$RID" >/dev/null
ok "timeout mensagem" "$(t_get toper sessions.php | grep -c 'não respondeu')" 1
mode weird;   t_post toper sessions.php sessions.php "action=disconnect&id=$RID" >/dev/null
ok "exit estranho: erro" "$(t_get toper sessions.php | grep -c 'código 7')" 1
sf=$(grep '^SECRETFILE=' "$LOG" | tail -1 | cut -d= -f2-)
ok "  tmp removido após falha" "$([ -e "$sf" ] && echo existe || echo removido)" removido
mode hang
s=$(date +%s); t_post toper sessions.php sessions.php "action=disconnect&id=$RID" >/dev/null; e=$(date +%s)
ok "hang: derrubado por timeout (<20s)" "$([ $((e-s)) -lt 20 ] && echo sim || echo nao)" sim
ok "  mensagem timeout" "$(t_get toper sessions.php | grep -c 'não respondeu a tempo')" 1
sf=$(grep '^SECRETFILE=' "$LOG" | tail -1 | cut -d= -f2-)
ok "  tmp removido após hang" "$([ -e "$sf" ] && echo existe || echo removido)" removido
ok "  nenhum fake-radclient sleep sobrando" "$(pgrep -fc '^sleep 60$' || true)" 0

# --- sem NAS cadastrado
mode ack
addsess u2 bob 'sess-002' 192.0.2.99 ''
RID2=$(q "SELECT radacctid FROM radacct WHERE acctuniqueid='u2'")
t_post toper sessions.php sessions.php "action=disconnect&id=$RID2" >/dev/null
ok "NAS não cadastrado: erro claro" "$(t_get toper sessions.php | grep -c 'não está cadastrado')" 1
ok "  radclient não chamado" "$(ncalls)" 0
ok "id inexistente" "$(t_post toper sessions.php sessions.php 'action=disconnect&id=99999')" 302

# --- papéis / CSRF
ok "viewer POST = 403" "$(t_post tview sessions.php sessions.php "action=disconnect&id=$RID")" 403
ok "viewer não vê botões" "$(t_get tview sessions.php | grep -c 'Derrubar')" 0
ok "operator vê botões" "$(t_get toper sessions.php | grep -o 'Derrubar' | wc -l)" 8
ok "POST sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d "action=disconnect&id=$RID" $T_WEB/sessions.php)" 400
ok "  radclient não chamado" "$(ncalls)" 0
ok "botão tem data-confirm" "$(t_get toper sessions.php | grep -o 'data-confirm="Derrubar' | wc -l)" 4

# --- injeção (valores maliciosos direto no banco -> lib)
lib() { # user nas sid framed
  RADPANEL_CONFIG="$RADPANEL_CONFIG" php -r '
    $_SERVER["REQUEST_METHOD"]="GET"; $_SERVER["REMOTE_ADDR"]="127.0.0.1";
    require "'"$ROOT"'/lib/bootstrap.php"; require "'"$ROOT"'/lib/coa.php";
    $r = coa_disconnect(db(), $argv[1], $argv[2], $argv[3], $argv[4]); echo $r["status"];' -- "$@" 2>/dev/null
}
mode ack
bad=("a;id" 'a$(id)' "a'b" $'a\nUser-Name = root' 'a"b' 'a b')
for v in "${bad[@]}"; do
  ok "username malicioso rejeitado: $(printf %q "$v")" "$(lib "$v" 198.51.100.7 sess-1 '')" error
done
for v in '198.51.100.7;id' '$(id)' $'198.51.100.7\n1' "1.2.3.4'" '198.51.100.7 -x'; do
  ok "NAS ip malicioso rejeitado: $(printf %q "$v")" "$(lib alice "$v" sess-1 '')" error
done
for v in 's;id' 's$(id)' $'s\nFoo = 1' "s'q" 's"q' 's s' "$(printf 'x%.0s' $(seq 1 65))" ''; do
  ok "session id malicioso rejeitado: $(printf %q "$v")" "$(lib alice 198.51.100.7 "$v" '')" error
done
for v in '10.0.0.1;id' $'10.0.0.1\nX=1' 'abc'; do
  ok "framed ip malicioso rejeitado: $(printf %q "$v")" "$(lib alice 198.51.100.7 sess-1 "$v")" error
done
ok "nenhuma chamada ao radclient nas rejeições" "$(ncalls)" 0
# segredo malicioso no banco
for sec in $'abc\nUser-Name=x' 'ab;id' 'a b cde' 'a"b$(id)'; do
  SQL "UPDATE nas SET secret='$(printf %s "$sec" | sed "s/'/''/g")' WHERE nasname='198.51.100.7'"
  r=$(lib alice 198.51.100.7 sess-1 '')
  case "$sec" in 'a"b$(id)'|'ab;id') exp=ack;; *) exp=error;; esac
  ok "segredo no banco: $(printf %q "$sec") -> $exp" "$r" "$exp"
done
# segredo com aspas/$ chega literal no arquivo (sem shell)
ok "segredo com aspas e \$() literal" "$(grep SECRETFILE_CONTENT "$LOG" | tail -1 | cut -d= -f2-)" 'a"b$(id)'
SQL "UPDATE nas SET secret='Segredo-NAS-123' WHERE nasname='198.51.100.7'"
# injeção válida mas bizarra: IPv6
SQL "INSERT INTO nas (nasname, shortname, type, secret) VALUES ('2001:db8::1','v6','other','Segredo6-abcd')"
: >"$LOG"; lib alice 2001:db8::1 sess-6 '' >/dev/null
ok "IPv6 alvo entre colchetes" "$(grep -c 'ARG\[\[2001:db8::1\]:3799\]' "$LOG")" 1
# radclient inexistente
sed -i "s#'radclient' => '[^']*'#'radclient' => '/nao/existe'#" "$T_DIR/config.php"
ok "radclient ausente: erro" "$(lib alice 198.51.100.7 sess-1 '')" error
sed -i "s#'radclient' => '[^']*'#'radclient' => '$T_DIR/fake-radclient'#" "$T_DIR/config.php"
ok "sem arquivos coa* sobrando em /tmp" "$(ls "$(php -r 'echo sys_get_temp_dir();')" 2>/dev/null | grep -c '^coa')" 0

# --- derrubar todas do usuário
SQL "DELETE FROM radacct"
addsess a1 carol s-a 198.51.100.7 10.0.0.1; addsess a2 carol s-b 198.51.100.7 10.0.0.2; addsess a3 dave s-c 198.51.100.7 10.0.0.3
mode ack
ok "derrubar todas (302)" "$(t_post toper sessions.php sessions.php 'action=disconnect_user&username=carol')" 302
ok "  2 chamadas (só da carol)" "$(ncalls)" 2
ok "  nenhuma para dave" "$(grep -c 's-c' "$LOG")" 0
ok "  usuário inválido -> 302 sem chamadas" "$(t_post toper sessions.php sessions.php 'action=disconnect_user&username=a;b')" 302
ok "  ainda 2 chamadas" "$(ncalls)" 2
ok "viewer disconnect_user = 403" "$(t_post tview sessions.php sessions.php 'action=disconnect_user&username=carol')" 403

# ===== clients.d
CD="$T_DIR/raddb/clients.d"
ok "nas viewer/operator ainda 403" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper $T_WEB/nas.php)" 403
ok "nas add (segredo com aspas/barra)" "$(t_post tadmin nas.php nas.php 'action=add&nasname=203.0.113.10&shortname=loja1&secret=Seg%22re%5Cdo%7DForte1&description=Loja')" 302
ok "arquivo criado" "$([ -f "$CD/loja1.conf" ] && echo sim || echo nao)" sim
ok "  modo 0640" "$(stat -c %a "$CD/loja1.conf")" 640
ok "  conteúdo: secret escapado" "$(grep -cF 'secret = "Seg\"re\\do}Forte1"' "$CD/loja1.conf")" 1
ok "  conteúdo: ipaddr" "$(grep -cF 'ipaddr = 203.0.113.10' "$CD/loja1.conf")" 1
ok "  sem temporários sobrando" "$(ls -A "$CD" | grep -c '^\.tmp')" 0
cp "$CD/loja1.conf" "$T_DIR/loja1.before"
ok "idempotência: apply regrava igual" "$(t_post tadmin nas.php nas.php 'action=apply')" 302
cmp -s "$CD/loja1.conf" "$T_DIR/loja1.before" && r=igual || r=diferente
ok "  arquivo idêntico" "$r" igual
ok "  modo 0640 mantido" "$(stat -c %a "$CD/loja1.conf")" 640
ok "nome inválido (../x) rejeitado" "$(t_post tadmin nas.php nas.php 'action=add&nasname=203.0.113.11&shortname=..%2Fx&secret=SegredoForte1')" 302
ok "  nada criado" "$(q "SELECT COUNT(*) FROM nas WHERE nasname='203.0.113.11'")" 0
t_post tadmin nas.php nas.php 'action=add&nasname=203.0.113.12&shortname=.oculto&secret=SegredoForte1' >/dev/null
ok "nome com ponto inicial rejeitado" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='.oculto'")" 0
ok "  nenhum arquivo fora de clients.d" "$(ls "$T_DIR/raddb" | grep -c 'conf')" 0
ok "operator não aplica (403)" "$(t_post toper nas.php nas.php 'action=apply')" 403
ok "mostra trecho só por POST" "$(t_get tadmin nas.php | grep -c 'Forte1')" 0
t_post tadmin nas.php nas.php 'action=apply' >/dev/null
ok "apply sem helper: erro amigável" "$(t_get tadmin nas.php | grep -c 'Helper de reinício')" 1
ok "página tem data-confirm de reinício" "$(t_get tadmin nas.php | grep -c 'data-confirm="Reiniciar')" 1
ok "nas delete remove arquivo" "$(t_post tadmin nas.php nas.php "action=delete&id=$(q "SELECT id FROM nas WHERE shortname='loja1'")")" 302
ok "  arquivo apagado" "$([ -e "$CD/loja1.conf" ] && echo existe || echo removido)" removido
ok "  delete repetido não quebra" "$(t_post tadmin nas.php nas.php 'action=delete&id=99999')" 302
ok "auditoria nas.add sem segredo" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%Forte1%'")" 0
for p in nas sessions; do
  b=$(t_get tadmin $p.php); ok "$p sem erro PHP" "$(echo "$b" | grep -ci -E 'fatal error|parse error|warning:|exception')" 0
  ok "$p sem style/onclick/script inline" "$(echo "$b" | grep -cE 'style="|onclick=|<script>[^<]')" 0
done

# --- helper de reinício
H="$ROOT/bin/panel-restart-radius.sh"
ok "bash -n helper" "$(bash -n "$H" && echo ok)" ok
FB="$T_DIR/fakebin"; mkdir -p "$FB"
cat >"$FB/radiusd" <<X
#!/bin/bash
[ "\${1:-}" = "-CX" ] || exit 9
[ -f "$T_DIR/invalid" ] && { echo "Error: bad config line 42"; exit 1; }
echo "Configuration appears to be OK"; exit 0
X
cat >"$FB/systemctl" <<X
#!/bin/bash
echo "\$*" >>"$T_DIR/systemctl.log"; [ -f "$T_DIR/failrestart" ] && { echo "Job failed"; exit 1; }; exit 0
X
chmod +x "$FB/radiusd" "$FB/systemctl"
export FAKE_DIR="$T_DIR"
rm -f "$T_DIR/systemctl.log" "$T_DIR/invalid" "$T_DIR/failrestart"
out=$(RADPANEL_TEST=1 RADIUS_SBIN="$FB" SYSTEMCTL="$FB/systemctl" bash "$H"); rc=$?
ok "helper: ok rc" "$rc" 0
ok "  reiniciou" "$(cat "$T_DIR/systemctl.log")" "restart freeradius"
touch "$T_DIR/invalid"; rm -f "$T_DIR/systemctl.log"
out=$(RADPANEL_TEST=1 RADIUS_SBIN="$FB" SYSTEMCTL="$FB/systemctl" bash "$H"); rc=$?
ok "helper: validação falha rc=1" "$rc" 1
ok "  NÃO reiniciou" "$([ -e "$T_DIR/systemctl.log" ] && echo reiniciou || echo nao)" nao
ok "  mensagem de erro" "$(echo "$out" | grep -c 'INVÁLIDA')" 1
rm -f "$T_DIR/invalid"; touch "$T_DIR/failrestart"
out=$(RADPANEL_TEST=1 RADIUS_SBIN="$FB" SYSTEMCTL="$FB/systemctl" bash "$H"); rc=$?
ok "helper: falha no restart rc=2" "$rc" 2
rm -f "$T_DIR/failrestart"
out=$(RADPANEL_TEST=1 RADIUS_SBIN="$FB" SYSTEMCTL="$FB/systemctl" bash "$H" extra 2>&1); rc=$?
ok "helper: recusa argumentos" "$rc" 64
out=$(RADIUS_SBIN="$FB" SYSTEMCTL="$FB/systemctl" bash "$H" 2>&1); rc=$?
ok "helper: sem RADPANEL_TEST ignora overrides (não usa fake; exige root/caminho real)" "$([ $rc -ne 0 ] || [ ! -e "$T_DIR/systemctl.log" ] && echo ok)" ok
ok "sudoers: só o script, sem args" "$(grep -c 'NOPASSWD: /opt/radpanel/bin/panel-restart-radius.sh ""$' server-config/sudoers.radpanel)" 1

# --- PDOException não vaza SQL
tok=$(t_tok tadmin nas.php)
SQL "RENAME TABLE nas TO nas_x"
curl -s -b $T_DIR/jar-tadmin -c $T_DIR/jar-tadmin -o /dev/null -d "csrf=$tok&action=add&nasname=203.0.113.50&shortname=zz1&secret=SegredoForte1" $T_WEB/nas.php
SQL "RENAME TABLE nas_x TO nas"
b=$(t_get tadmin nas.php)
ok "nas: PDOException vira mensagem genérica" "$(echo "$b" | grep -c 'Erro ao salvar no banco')" 1
ok "  sem texto SQL" "$(echo "$b" | grep -ciE 'SQLSTATE|doesn.t exist|nas_x|radius\.')" 0
tok=$(t_tok toper sessions.php)
SQL "RENAME TABLE radacct TO radacct_x"
curl -s -b $T_DIR/jar-toper -c $T_DIR/jar-toper -o /dev/null -d "csrf=$tok&action=disconnect&id=1" $T_WEB/sessions.php
SQL "RENAME TABLE radacct_x TO radacct"
b=$(t_get toper sessions.php)
ok "sessions: PDOException vira mensagem genérica" "$(echo "$b" | grep -c 'Erro ao salvar no banco')" 1
ok "  sem texto SQL" "$(echo "$b" | grep -ciE 'SQLSTATE|doesn.t exist|radacct_x')" 0

ok "pgrep: sem processo sleep do fake" "$(pgrep -fc '^sleep 60$' || true)" 0
summary
