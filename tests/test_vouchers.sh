#!/usr/bin/env bash
# Testes de vouchers. Uso: bash tests/test_vouchers.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/harness.sh
env_up vouchers 3410 8410 || exit 1
trap 'env_down vouchers' EXIT

t_login tadmin; t_login toper; t_login tview
t_post tadmin plans.php plans.php 'action=save&name=basico&down=10M&up=2M' >/dev/null
t_post tadmin plans.php plans.php 'action=save&name=premium&down=50M&up=10M' >/dev/null

# --- papéis
ok "viewer 403 página" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/vouchers.php)" 403
ok "viewer 403 impressão" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/vouchers_print.php?batch=1)" 403
ok "viewer não gera" "$(t_post toper vouchers.php vouchers.php 'x=1' >/dev/null; curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview -d 'action=generate&qty=1' $T_WEB/vouchers.php)" 403
ok "sem login 302" "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/vouchers.php)" 302
ok "operator vê página" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper $T_WEB/vouchers.php)" 200
ok "POST sem csrf 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d 'action=generate&qty=1&len=8&plan=basico' $T_WEB/vouchers.php)" 400

# --- validação
n0() { ok "$1" "$(q "SELECT COUNT(*) FROM panel_voucher_batches")" 0; }
G='len=8&plan=basico'
t_post toper vouchers.php vouchers.php "action=generate&qty=0&$G" >/dev/null; n0 "qty 0 rejeitada"
t_post toper vouchers.php vouchers.php "action=generate&qty=1001&$G" >/dev/null; n0 "qty 1001 rejeitada"
t_post toper vouchers.php vouchers.php "action=generate&qty=abc&$G" >/dev/null; n0 "qty texto rejeitada"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&prefix=AB-1&$G" >/dev/null; n0 "prefixo inválido"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&prefix=ABCDEFG&$G" >/dev/null; n0 "prefixo longo"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&len=5&plan=basico" >/dev/null; n0 "tamanho 5"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&len=13&plan=basico" >/dev/null; n0 "tamanho 13"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&len=8&plan=nao_existe" >/dev/null; n0 "plano inexistente"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&len=8&plan=x'%20OR%201=1--" >/dev/null; n0 "plano malicioso"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&$G&expires=2020-01-01" >/dev/null; n0 "data passada"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&$G&expires=xx" >/dev/null; n0 "data inválida"
t_post toper vouchers.php vouchers.php "action=generate&qty=2&$G&minutes=0" >/dev/null; n0 "minutos 0"
ok "nenhum usuário criado nas rejeições" "$(q "SELECT COUNT(*) FROM radcheck")" 0

# --- lote de 20 com prefixo
ok "gera lote 20 -> 302" "$(t_post toper vouchers.php vouchers.php "action=generate&qty=20&prefix=wf&$G&expires=2030-12-31&label=Loja%3Cscript%3E&notes=n1")" 302
ok "20 vouchers" "$(q "SELECT COUNT(*) FROM panel_vouchers WHERE batch_id=1")" 20
ok "20 usuários radcheck senha" "$(q "SELECT COUNT(*) FROM radcheck WHERE attribute='Password.Cleartext' AND username LIKE 'WF%'")" 20
ok "formato do usuário WF+8" "$(q "SELECT COUNT(*) FROM panel_vouchers WHERE username REGEXP '^WF[A-HJKMNP-Z2-9]{8}\$'")" 20
ok "unicidade" "$(q "SELECT COUNT(DISTINCT username) FROM panel_vouchers")" 20
ok "plano aplicado" "$(q "SELECT COUNT(*) FROM radusergroup WHERE groupname='basico' AND username LIKE 'WF%'")" 20
ok "expiração" "$(q "SELECT COUNT(DISTINCT value) FROM radcheck WHERE attribute='Expiration' AND username LIKE 'WF%'")" 1
ok "senha diferente do usuário" "$(q "SELECT COUNT(*) FROM radcheck c WHERE attribute='Password.Cleartext' AND value=username")" 0

# --- impressão: uma única vez
loc=$(curl -s -D - -o /dev/null -b $T_DIR/jar-toper $T_WEB/vouchers.php | head -1)
p1=$(t_get toper 'vouchers_print.php?batch=1')
ok "1ª visita: 20 cartões" "$(echo "$p1" | grep -c 'class="vcard"')" 20
u=$(q "SELECT username FROM panel_vouchers LIMIT 1"); pw=$(q "SELECT value FROM radcheck WHERE username='$u' AND attribute='Password.Cleartext'")
ok "1ª visita mostra senha" "$(echo "$p1" | grep -c "$pw")" 1
ok "layout sem menu" "$(echo "$p1" | grep -c '<nav>')" 0
ok "rótulo escapado" "$(echo "$p1" | grep -c '<script>Loja')" 0
ok "data-print e vouchers.js" "$(echo "$p1" | grep -c 'data-print')$(echo "$p1" | grep -c 'vouchers.js')" 11
p2=$(t_get toper 'vouchers_print.php?batch=1')
ok "2ª visita: sem cartões" "$(echo "$p2" | grep -c 'class="vcard"')" 0
ok "2ª visita: sem senha" "$(echo "$p2" | grep -c "$pw")" 0
ok "lista não mostra senha" "$(t_get toper vouchers.php | grep -c "$pw")" 0
ok "impressão de lote inexistente ok" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper "$T_WEB/vouchers_print.php?batch=999")" 200

# --- lista: qtd/usados
ok "lista mostra lote" "$(t_get toper vouchers.php | grep -c '<td>#1</td>')" 1

# --- usar 3 vouchers (radacct) e revogar só os não usados
for u in $(q "SELECT username FROM panel_vouchers ORDER BY username LIMIT 3"); do
  q "INSERT INTO radacct (acctsessionid, acctuniqueid, username, acctstarttime) VALUES ('s','$u','$u',NOW())"
done
ok "usados = 3 na lista" "$(t_get toper vouchers.php | grep -A5 '<td>#1</td>' | grep -c '<td>3</td>')" 1
ok "revogar sem csrf 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d 'action=revoke&batch=1' $T_WEB/vouchers.php)" 400
ok "viewer não revoga" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview -d 'action=revoke&batch=1' $T_WEB/vouchers.php)" 403
ok "revoga (302)" "$(t_post toper vouchers.php vouchers.php 'action=revoke&batch=1')" 302
ok "flash 17 removidos" "$(t_get toper vouchers.php | grep -c '17 voucher(s) removido(s), 3 usado(s)')" 1
ok "sobraram 3 vouchers" "$(q "SELECT COUNT(*) FROM panel_vouchers")" 3
ok "sobraram 3 usuários radcheck" "$(q "SELECT COUNT(DISTINCT username) FROM radcheck")" 3
ok "radusergroup limpo" "$(q "SELECT COUNT(*) FROM radusergroup")" 3
ok "os 3 mantidos são os usados" "$(q "SELECT COUNT(*) FROM panel_vouchers v JOIN radacct a ON a.username=v.username")" 3
ok "revogar lote inexistente não quebra" "$(t_post toper vouchers.php vouchers.php 'action=revoke&batch=999')" 302
ok "revoga incluindo usados" "$(t_post toper vouchers.php vouchers.php 'action=revoke&batch=1&with_used=1')" 302
ok "tudo removido" "$(q "SELECT COUNT(*) FROM panel_vouchers")$(q "SELECT COUNT(*) FROM radcheck")" 00

# --- Expire-After + plano premium
ok "lote com minutos" "$(t_post toper vouchers.php vouchers.php 'action=generate&qty=3&len=6&plan=premium&minutes=90')" 302
ok "Expire-After = 5400 s" "$(q "SELECT COUNT(*) FROM radcheck WHERE attribute='control.Expire-After' AND value='5400'")" 3
t_get toper 'vouchers_print.php?batch=2' >/dev/null

# --- lote de 1000 (tempo, unicidade)
s=$(date +%s)
ok "lote 1000 -> 302" "$(t_post toper vouchers.php vouchers.php "action=generate&qty=1000&prefix=BIG&len=6&plan=basico")" 302
el=$(( $(date +%s) - s )); echo "tempo lote 1000: ${el}s"
ok "1000 em menos de 90s" "$([ $el -lt 90 ] && echo sim || echo nao)" sim
ok "1000 vouchers lote 3" "$(q "SELECT COUNT(*) FROM panel_vouchers WHERE batch_id=3")" 1000
ok "1000 únicos" "$(q "SELECT COUNT(DISTINCT username) FROM radcheck WHERE username LIKE 'BIG%' AND attribute='Password.Cleartext'")" 1000
ok "impressão 1000 cartões" "$(t_get toper 'vouchers_print.php?batch=3' | grep -c 'class="vcard"')" 1000
ok "lista com 1000 lotes carrega" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper $T_WEB/vouchers.php)" 200

# --- atomicidade: falha no meio desfaz tudo (força colisão impossível: código de 6 + alfabeto... simula com trigger)
mariadb -S "$T_SOCK" radius --delimiter='//' -e "CREATE TRIGGER boom BEFORE INSERT ON panel_vouchers FOR EACH ROW BEGIN IF NEW.username LIKE 'ZZ%' AND (SELECT COUNT(*) FROM panel_vouchers WHERE batch_id=NEW.batch_id) >= 4 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='boom'; END IF; END//"
b0=$(q "SELECT COUNT(*) FROM panel_voucher_batches"); r0=$(q "SELECT COUNT(*) FROM radcheck")
ok "falha no meio -> 302 com erro" "$(t_post toper vouchers.php vouchers.php 'action=generate&qty=10&prefix=ZZ&len=8&plan=basico')" 302
ok "  lotes inalterados" "$(q "SELECT COUNT(*) FROM panel_voucher_batches")" "$b0"
ok "  radcheck inalterado (atômico)" "$(q "SELECT COUNT(*) FROM radcheck")" "$r0"
ok "  mensagem genérica sem SQL" "$(t_get toper vouchers.php | grep -ci 'SQLSTATE\|boom')" 0
mariadb -S "$T_SOCK" radius -e "DROP TRIGGER boom"

# --- auditoria sem códigos
ok "audit voucher.batch (3 lotes)" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='voucher.batch'")" 3
ok "sem user.create por voucher" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='user.create'")" 0
ok "audit voucher.revoke" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='voucher.revoke'")" 2
codes=$(q "SELECT GROUP_CONCAT(username SEPARATOR '|') FROM (SELECT username FROM panel_vouchers LIMIT 200) t")
ok "audit sem nenhum código" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail REGEXP '$codes'")" 0
ok "audit sem senhas" "$(q "SELECT COUNT(*) FROM panel_audit a JOIN radcheck c ON c.attribute='Password.Cleartext' AND c.username LIKE 'BIG%' AND a.detail LIKE CONCAT('%',c.value,'%') AND a.action LIKE 'voucher%'")" 0

# --- CSP / sem inline
for pg in vouchers.php; do
  b=$(t_get toper $pg); ok "sem inline em $pg" "$(echo "$b" | grep -cE 'style="|onclick=|<script>[^<]|javascript:')" 0
done
t_post toper vouchers.php vouchers.php 'action=generate&qty=2&len=6&plan=basico&label=x' >/dev/null
b=$(t_get toper "vouchers_print.php?batch=4"); ok "sem inline na impressão" "$(echo "$b" | grep -cE 'style="|onclick=|<script>[^<]|javascript:')" 0
ok "no-store na impressão" "$(curl -s -D - -o /dev/null -b $T_DIR/jar-toper "$T_WEB/vouchers_print.php?batch=4" | grep -ci 'cache-control: no-store')" 1
ok "sem erro PHP" "$(t_get toper vouchers.php | grep -ci -E 'fatal error|parse error|warning:|exception')" 0
summary
