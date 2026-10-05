#!/usr/bin/env bash
# Testes da base: papéis, auditoria, login, usuários, planos, NAS. Uso: bash tests/test_core.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/harness.sh
env_up core 3400 8400 || exit 1
trap 'env_down core' EXIT

t_login tadmin; t_login toper; t_login tview

# --- acesso por papel
ok "dashboard viewer"      "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/dashboard.php)" 200
ok "nas viewer = 403"      "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/nas.php)" 403
ok "nas operator = 403"    "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper $T_WEB/nas.php)" 403
ok "nas admin"             "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $T_WEB/nas.php)" 200
ok "sem login = 302"       "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/users.php)" 302

# --- viewer não escreve (mesmo com CSRF válido)
ok "viewer não cria usuário" "$(t_post tview users.php users.php 'action=create&username=v1&password=senha1234')" 403
ok "  nada gravado" "$(q "SELECT COUNT(*) FROM radcheck WHERE username='v1'")" 0
# --- operator cria; não mexe em planos
ok "operator cria usuário"  "$(t_post toper users.php users.php 'action=create&username=op1&password=senha1234&expires=2027-12-31')" 302
ok "  Password.Cleartext" "$(q "SELECT value FROM radcheck WHERE username='op1' AND attribute='Password.Cleartext'")" senha1234
ok "  Expiration RFC3339 UTC" "$(q "SELECT value FROM radcheck WHERE username='op1' AND attribute='Expiration'")" "2028-01-01T02:59:59Z"
ok "operator não salva plano" "$(t_post toper plans.php plans.php 'action=save&name=x&down=1M&up=1M')" 403
ok "admin salva plano" "$(t_post tadmin plans.php plans.php 'action=save&name=basico&down=10M&up=2M&timeout=3600&idle=300&interim=300')" 302
ok "  rate" "$(q "SELECT value FROM radgroupreply WHERE groupname='basico' AND attribute='Mikrotik.Rate-Limit'")" "2M/10M"

# --- bloquear/desbloquear (inclui bloqueio duplo)
t_post toper users.php users.php 'action=plan&username=op1&plan=basico' >/dev/null
t_post toper users.php users.php 'action=block&username=op1' >/dev/null
t_post toper users.php users.php 'action=block&username=op1' >/dev/null
ok "bloqueado"    "$(q "SELECT value FROM radcheck WHERE username='op1' AND attribute='Expiration'")" "2000-01-01T00:00:00Z"
t_post toper users.php users.php 'action=unblock&username=op1' >/dev/null
ok "desbloqueio restaura validade (bloqueio duplo não corrompe)" "$(q "SELECT value FROM radcheck WHERE username='op1' AND attribute='Expiration'")" "2028-01-01T02:59:59Z"
ok "plano mantido" "$(q "SELECT groupname FROM radusergroup WHERE username='op1'")" basico

# --- validação e injeção
t_post toper users.php users.php "action=create&username=x'%20OR%201=1--&password=senha1234" >/dev/null
ok "nome malicioso rejeitado" "$(q "SELECT COUNT(*) FROM radcheck WHERE username LIKE 'x%'")" 0
t_post toper users.php users.php 'action=create&username=op1&password=outrasenha' >/dev/null
ok "duplicado não cria 2ª senha" "$(q "SELECT COUNT(*) FROM radcheck WHERE username='op1' AND attribute='Password.Cleartext'")" 1
ok "delete inexistente não quebra" "$(t_post toper users.php users.php 'action=delete&username=naoexiste')" 302

# --- CSRF
ok "POST sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-toper -d 'action=create&username=zz&password=senha1234' $T_WEB/users.php)" 400

# --- NAS: segredo oculto, revelar por POST + auditoria, escape
ok "nas add" "$(t_post tadmin nas.php nas.php 'action=add&nasname=203.0.113.10&shortname=loja1&secret=Seg%22redo%7DForte1&description=Loja')" 302
ok "segredo oculto por padrão" "$(t_get tadmin nas.php | grep -c 'redo}Forte1')" 0
ok "GET ?reveal não revela" "$(t_get tadmin 'nas.php?reveal=1' | grep -c 'redo}Forte1')" 0
t_post tadmin nas.php nas.php 'action=reveal' >/dev/null
ok "revelar por POST mostra com escape" "$(grep -cF 'secret = &quot;Seg\&quot;redo}Forte1&quot;' $T_DIR/last.html)" 1
ok "revelação auditada" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='nas.reveal'")" 1

# --- auditoria sem segredos
ok "audit create" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='user.create' AND target='op1'")" 1
ok "audit sem senha" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%senha1234%' OR detail LIKE '%SegRedo%'")" 0

# --- login: limite por (ip,usuário), não trava outro admin; sessão invalida com mudança
for i in 1 2 3 4 5 6; do
  t=$(curl -s -c $T_DIR/jx "$T_WEB/login.php" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
  curl -s -b $T_DIR/jx -c $T_DIR/jx -o /dev/null -d "csrf=$t&user=toper&pass=errada$i" "$T_WEB/login.php"
done
t=$(curl -s -c $T_DIR/jx "$T_WEB/login.php" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
ok "toper bloqueado após 5 falhas (mesmo com senha certa)" "$(curl -s -b $T_DIR/jx -c $T_DIR/jx -o /dev/null -w '%{http_code}' -d "csrf=$t&user=toper&pass=$T_PASS" $T_WEB/login.php)" 200
t=$(curl -s -c $T_DIR/jy "$T_WEB/login.php" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
ok "outro usuário (tadmin) ainda entra do mesmo IP" "$(curl -s -b $T_DIR/jy -c $T_DIR/jy -o /dev/null -w '%{http_code}' -d "csrf=$t&user=tadmin&pass=$T_PASS" $T_WEB/login.php)" 302

# admin rebaixado perde acesso na hora (sem esperar a sessão expirar)
mariadb -S "$T_SOCK" radius -e "UPDATE panel_admins SET role='viewer' WHERE username='tadmin'"
ok "admin rebaixado: sessão invalidada na hora (302 p/ login)" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $T_WEB/nas.php)" 302
mariadb -S "$T_SOCK" radius -e "DELETE FROM panel_admins WHERE username='tview'"
ok "admin apagado: sessão morre" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tview $T_WEB/dashboard.php)" 302

# --- cabeçalhos
h=$(curl -s -D - -o /dev/null -b $T_DIR/jar-toper $T_WEB/dashboard.php)
ok "CSP base-uri" "$(echo "$h" | grep -ci "base-uri 'none'")" 1
ok "no-store" "$(echo "$h" | grep -ci 'cache-control: no-store')" 1

# ===== Correções da revisão de segurança =====
mariadb -S "$T_SOCK" radius -e "UPDATE panel_admins SET role='admin' WHERE username='tadmin'"
t_login tadmin
sleep 1; mariadb -S "$T_SOCK" radius -e "DELETE FROM panel_login_attempts"

# validade de usuário BLOQUEADO não pode desbloquear
t_post toper users.php users.php 'action=create&username=blk1&password=senha1234&expires=2027-06-30' >/dev/null
t_post toper users.php users.php 'action=block&username=blk1' >/dev/null
ok "blk1 bloqueado" "$(q "SELECT value FROM radcheck WHERE username='blk1' AND attribute='Expiration'")" "2000-01-01T00:00:00Z"
t_post toper users.php users.php 'action=expires&username=blk1&expires=2029-01-15' >/dev/null
ok "mudar validade de bloqueado NÃO desbloqueia" "$(q "SELECT value FROM radcheck WHERE username='blk1' AND attribute='Expiration'")" "2000-01-01T00:00:00Z"
ok "  nova validade guardada para o desbloqueio" "$(q "SELECT prev_expiration FROM panel_user_meta WHERE username='blk1'")" "2029-01-16T02:59:59Z"
t_post toper users.php users.php 'action=unblock&username=blk1' >/dev/null
ok "  ao desbloquear vale a validade nova" "$(q "SELECT value FROM radcheck WHERE username='blk1' AND attribute='Expiration'")" "2029-01-16T02:59:59Z"
t_post toper users.php users.php 'action=expires&username=blk1&expires=2028-03-10' >/dev/null
ok "validade de usuário ativo muda normalmente" "$(q "SELECT value FROM radcheck WHERE username='blk1' AND attribute='Expiration'")" "2028-03-11T02:59:59Z"

# excluir usuário também limpa a marcação de voucher (não revoga um usuário recriado)
q "INSERT INTO panel_voucher_batches (label, plan, qty, created_by) VALUES ('t','',1,'x')" 2>/dev/null
B=$(q "SELECT MAX(id) FROM panel_voucher_batches"); [ "$B" = "NULL" ] && B=1
q "INSERT INTO panel_vouchers (batch_id, username) VALUES ($B, 'blk1')"
t_post toper users.php users.php 'action=delete&username=blk1' >/dev/null
ok "excluir usuário remove a marca de voucher" "$(q "SELECT COUNT(*) FROM panel_vouchers WHERE username='blk1'")" 0

# NAS: redes largas e segredos com expansão são recusados
for n in "0.0.0.0/0" "10.0.0.0/8" "192.168.0.0/16" "::/0" "0.0.0.0"; do
  t_post tadmin nas.php nas.php "action=add&nasname=$(printf %s "$n" | sed 's#/#%2F#g')&shortname=wide&secret=SegredoForte1" >/dev/null
  ok "NAS $n recusado" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='wide'")" 0
done
ok "NAS /24 aceito" "$(t_post tadmin nas.php nas.php 'action=add&nasname=198.51.100.0%2F24&shortname=rede24&secret=SegredoForte1')" 302
ok "  gravado" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='rede24'")" 1
t_post tadmin nas.php nas.php 'action=add&nasname=198.51.100.9&shortname=exp1&secret=abc%24%7Bdef%7Dghi' >/dev/null
ok "segredo com \${ recusado" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='exp1'")" 0
t_post tadmin nas.php nas.php 'action=add&nasname=198.51.100.10&shortname=exp2&secret=abc%25%7Bdef%7Dghi' >/dev/null
ok "segredo com %{ recusado" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='exp2'")" 0

# NAS: se o arquivo clients.d não puder ser removido, o cadastro é mantido
CDIR="$T_DIR/raddb/clients.d"; mkdir -p "$CDIR"
t_post tadmin nas.php nas.php 'action=add&nasname=198.51.100.20&shortname=trava&secret=SegredoForte1' >/dev/null
NID=$(q "SELECT id FROM nas WHERE shortname='trava'")
if [ -f "$CDIR/trava.conf" ]; then
  chattr +i "$CDIR/trava.conf" 2>/dev/null && IMM=1 || IMM=0
  if [ "$IMM" = 1 ]; then
    t_post tadmin nas.php nas.php "action=delete&id=$NID" >/dev/null
    ok "arquivo imutável: cadastro mantido" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='trava'")" 1
    chattr -i "$CDIR/trava.conf"
  else
    echo "SKIP chattr indisponível neste sistema de arquivos"
  fi
fi
t_post tadmin nas.php nas.php "action=delete&id=$NID" >/dev/null
ok "remoção normal apaga cadastro e arquivo" "$(q "SELECT COUNT(*) FROM nas WHERE shortname='trava'")$(ls "$CDIR" | grep -c '^trava.conf$')" "00"

# plano: não exclui com usuários; ao excluir apaga o preço
t_post tadmin plans.php plans.php 'action=save&name=pl_del&down=1M&up=1M' >/dev/null
q "INSERT INTO panel_plan_prices (groupname, price, period_days) VALUES ('pl_del', 10.00, 30)" 2>/dev/null
t_post toper users.php users.php 'action=create&username=pl_u&password=senha1234&plan=pl_del' >/dev/null
t_post tadmin plans.php plans.php 'action=delete&name=pl_del' >/dev/null
ok "plano com usuário não é excluído" "$(q "SELECT COUNT(*) FROM radgroupreply WHERE groupname='pl_del'")" 1
t_post toper users.php users.php 'action=plan&username=pl_u&plan=' >/dev/null
t_post tadmin plans.php plans.php 'action=delete&name=pl_del' >/dev/null
ok "plano sem usuários é excluído" "$(q "SELECT COUNT(*) FROM radgroupreply WHERE groupname='pl_del'")" 0
ok "  e o preço órfão também" "$(q "SELECT COUNT(*) FROM panel_plan_prices WHERE groupname='pl_del'")" 0

# login: auditoria não grava texto cru, e não cresce durante o bloqueio
mariadb -S "$T_SOCK" radius -e "DELETE FROM panel_login_attempts; DELETE FROM panel_audit WHERE action='login.fail'"
lf() { local t; t=$(curl -s -c $T_DIR/jz "$T_WEB/login.php" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//'); curl -s -b $T_DIR/jz -c $T_DIR/jz -o /dev/null --data-urlencode "user=$1" -d "csrf=$t&pass=x" "$T_WEB/login.php"; }
lf 'MinhaSenhaSecreta!! com espaço'
ok "login.fail com texto cru: nome não vai para a auditoria" "$(q "SELECT COUNT(*) FROM panel_audit WHERE target LIKE '%MinhaSenhaSecreta%' OR detail LIKE '%MinhaSenhaSecreta%'")" 0
ok "  registrado como (nome inválido)" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='login.fail' AND target LIKE '(nome inv%'")" 1
for i in 1 2 3 4 5 6 7 8; do lf alvo; done
ok "falhas durante o bloqueio não enchem a auditoria (5 gravadas, não 8)" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='login.fail' AND target='alvo'")" 5

# grants: o usuário do painel não lê radpostauth.pass nem faz UPDATE em radcheck
q "INSERT INTO radpostauth (username, pass, reply) VALUES ('zed', 'senhaDigitadaSecreta', 'Access-Reject')"
PQ() { mariadb -h127.0.0.1 -P "$T_DBPORT" -u radpanel -ptestdbpass radius -N -e "$1" 2>&1; }
ok "painel NÃO lê radpostauth.pass" "$(PQ 'SELECT pass FROM radpostauth' | grep -c -i 'denied')" 1
ok "painel lê radpostauth.username" "$(PQ "SELECT username FROM radpostauth WHERE reply LIKE 'Access-Reject%'" | grep -c zed)" 1
ok "painel NÃO faz UPDATE em radcheck" "$(PQ "UPDATE radcheck SET value='x' WHERE username='zz'" | grep -c -i 'denied')" 1
ok "painel NÃO altera panel_audit" "$(PQ "UPDATE panel_audit SET action='x'" | grep -c -i 'denied')" 1

# --- páginas carregam sem erro PHP
for p in dashboard users plans sessions; do
  b=$(t_get toper $p.php); ok "página $p sem erro PHP" "$(echo "$b" | grep -ci -E 'fatal error|parse error|warning:|exception')" 0
done
summary
