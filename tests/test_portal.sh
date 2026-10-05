#!/usr/bin/env bash
# Testes do portal do cliente. Uso: bash tests/test_portal.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/harness.sh
env_up portal 3440 8440 || exit 1
ADMIN_WEB="$T_WEB"
P_WEB="http://127.0.0.1:8441"
cleanup() {
  [ -f "$T_DIR/portal.shpid" ] && kill "$(cat "$T_DIR/portal.shpid")" 2>/dev/null
  env_down portal
}
trap cleanup EXIT

# --- usuário MySQL separado do portal (o harness não o cria; o instalador precisa fazê-lo)
mariadb -S "$T_SOCK" -e "CREATE USER 'radportal'@'127.0.0.1' IDENTIFIED BY 'portaldbpass';"
sed "s/{{DB_NAME}}/radius/g; s/{{PORTAL_DB_USER}}/radportal/g; s/'localhost'/'127.0.0.1'/g" portal/grants-portal-user.sql.example \
  | mariadb -S "$T_SOCK" || { echo "erro grants portal"; exit 1; }
cat >"$T_DIR/portal-config.php" <<PHP
<?php return [
  'db_host' => '127.0.0.1', 'db_port' => $T_DBPORT, 'db_name' => 'radius',
  'db_user' => 'radportal', 'db_pass' => 'portaldbpass',
  'timezone' => 'America/Sao_Paulo',
];
PHP
(cd portal/public && RADPANEL_CONFIG="$T_DIR/portal-config.php" exec php -S 127.0.0.1:8441 \
   </dev/null >"$T_DIR/portal-php.log" 2>&1) &
echo $! >"$T_DIR/portal.shpid"
for i in $(seq 1 20); do curl -s -o /dev/null "$P_WEB/login.php" && break; sleep 0.3; done

PM() { mariadb -h127.0.0.1 -P"$T_DBPORT" -u radportal -pportaldbpass radius "$@"; }
ptok() { curl -s -b "$1" -c "$1" "$P_WEB/$2" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//'; }
# p_login JAR USER PASS -> status HTTP
p_login() { local t; t=$(ptok "$1" login.php)
  curl -s -b "$1" -c "$1" -o "$T_DIR/plast.html" -w '%{http_code}' --data-urlencode "csrf=$t" --data-urlencode "user=$2" --data-urlencode "pass=$3" "$P_WEB/login.php"; }
# p_post JAR PAGINA_TOKEN DESTINO 'campos' -> status
p_post() { local t; t=$(ptok "$1" "$2")
  curl -s -b "$1" -c "$1" -o "$T_DIR/plast.html" -w '%{http_code}' -d "csrf=$t&$4" "$P_WEB/$3"; }
pget() { curl -s -b "$1" -c "$1" "$P_WEB/$2"; }
pcode() { curl -s -o /dev/null -w '%{http_code}' -b "$1" "$P_WEB/$2"; }
clear_att() { q "DELETE FROM panel_login_attempts"; }

# --- dados
q "INSERT INTO radcheck (username,attribute,op,value) VALUES
 ('alice','Password.Cleartext',':=','AlicePass123'),('alice','Expiration',':=','2037-06-15T12:00:00Z'),
 ('bob','Password.Cleartext',':=','BobPass12345'),('bob','Expiration',':=','2000-01-01T00:00:00Z'),
 ('carol','Password.Cleartext',':=','CarolPass123'),('carol','Expiration',':=','2020-06-15T12:00:00Z'),
 ('Alice2','Password.Cleartext',':=','Alice2Pass99'),
 ('alice','Auth-Type',':=','Accept'),('alice','control.Max-Daily-Session',':=','3600')"
q "INSERT INTO radusergroup (username,groupname,priority) VALUES ('alice','basico',1),('bob','premium',1)"
q "INSERT INTO radgroupreply (groupname,attribute,op,value) VALUES ('basico','Mikrotik.Rate-Limit',':=','2M/10M'),('premium','Mikrotik.Rate-Limit',':=','9M/99M')"
q "INSERT INTO panel_user_meta (username,blocked,prev_expiration) VALUES ('bob',1,'2037-01-01T00:00:00Z')"
q "INSERT INTO radacct (acctsessionid,acctuniqueid,username,nasipaddress,acctstarttime,acctstoptime,acctsessiontime,acctinputoctets,acctoutputoctets) VALUES
 ('a1','a1','alice','10.0.0.1',NOW()-INTERVAL 1 HOUR,NOW()-INTERVAL 30 MINUTE,1800,5242880,10485760),
 ('b1','b1','bob','10.0.0.1',NOW()-INTERVAL 1 HOUR,NOW()-INTERVAL 20 MINUTE,2400,123456789,987654321)"
q "UPDATE radacct SET acctstarttime=DATE_FORMAT(NOW(),'%Y-%m-%d 00:05:00') WHERE acctsessionid='a1' AND DATE(NOW())=DATE(DATE_FORMAT(NOW(),'%Y-%m-%d 00:05:00')) AND NOW() > DATE_FORMAT(NOW(),'%Y-%m-%d 00:10:00')"

# ===== privilégio mínimo do usuário MySQL radportal
ok "radportal: SELECT * FROM radcheck negado" "$(PM -e 'SELECT * FROM radcheck' 2>&1 | grep -c 'denied')" 1
ok "radportal: UPDATE radcheck negado"        "$(PM -e "UPDATE radcheck SET value='x'" 2>&1 | grep -c 'denied')" 1
ok "radportal: INSERT radcheck negado"        "$(PM -e "INSERT INTO radcheck (username,attribute,value) VALUES ('z','a','b')" 2>&1 | grep -c 'denied')" 1
ok "radportal: DELETE radcheck negado"        "$(PM -e "DELETE FROM radcheck" 2>&1 | grep -c 'denied')" 1
ok "radportal: radreply negado"               "$(PM -e 'SELECT * FROM radreply' 2>&1 | grep -c 'denied')" 1
ok "radportal: panel_admins negado"           "$(PM -e 'SELECT * FROM panel_admins' 2>&1 | grep -c 'denied')" 1
ok "radportal: panel_audit negado"            "$(PM -e 'SELECT * FROM panel_audit' 2>&1 | grep -c 'denied')" 1
ok "radportal: nas negado"                    "$(PM -e 'SELECT * FROM nas' 2>&1 | grep -c 'denied')" 1
ok "radportal: UPDATE panel_user_meta negado" "$(PM -e "UPDATE panel_user_meta SET blocked=0" 2>&1 | grep -c 'denied')" 1
ok "radportal: INSERT radacct negado"         "$(PM -e "INSERT INTO radacct (acctsessionid,acctuniqueid) VALUES ('x','x')" 2>&1 | grep -c 'denied')" 1
ok "radportal: UPDATE panel_login_attempts negado" "$(PM -e "UPDATE panel_login_attempts SET ip='x'" 2>&1 | grep -c 'denied')" 1
ok "radportal: SELECT radacct ok"             "$(PM -N -e 'SELECT COUNT(*) FROM radacct' 2>&1)" 2
ok "radportal: SELECT radusergroup ok"        "$(PM -N -e 'SELECT COUNT(*) FROM radusergroup' 2>&1)" 2
ok "radportal: SELECT radgroupreply ok"       "$(PM -N -e 'SELECT COUNT(*) FROM radgroupreply' 2>&1)" 2
ok "radportal: SELECT view ok (só Password.Cleartext)" "$(PM -N -e 'SELECT COUNT(*) FROM portal_user_auth' 2>&1)" 4
ok "radportal: view sem Auth-Type/outros atributos" "$(PM -N -e "SELECT COUNT(*) FROM portal_user_auth WHERE password='Accept' OR password='3600'" 2>&1)" 0
ok "radportal: view expõe só 3 colunas" "$(PM -N -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='radius' AND table_name='portal_user_auth'" 2>&1)" 3
ok "view SQL SECURITY DEFINER" "$(q "SELECT security_type FROM information_schema.views WHERE table_name='portal_user_auth'")" DEFINER
ok "procedure SQL SECURITY DEFINER" "$(q "SELECT security_type FROM information_schema.routines WHERE routine_name='portal_set_password'")" DEFINER
ok "radportal: INSERT/DELETE panel_login_attempts ok" "$(PM -N -e "INSERT INTO panel_login_attempts (ip,username,realm) VALUES ('9.9.9.9','t','zz'); DELETE FROM panel_login_attempts WHERE realm='zz'; SELECT 'ok'" 2>&1)" ok

# ===== stored procedure
SNAP="SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,username,attribute,op,value) ORDER BY id)) FROM radcheck"
S0=$(q "$SNAP")
PM -N -e "CALL portal_set_password('alice','errada','NovaSenha123')" >/dev/null 2>&1
ok "proc: old errada não altera nada" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('bob','AlicePass123','NovaSenha123')" >/dev/null 2>&1
ok "proc: outro usuário com a senha de outro não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('alice'' OR ''1''=''1','AlicePass123','NovaSenha123')" >/dev/null 2>&1
ok "proc: injeção no usuário não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('%','AlicePass123','NovaSenha123')" >/dev/null 2>&1
ok "proc: curinga no usuário não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('ALICE','AlicePass123','NovaSenha123')" >/dev/null 2>&1
ok "proc: usuário com caixa diferente não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('alice','alicepass123','NovaSenha123')" >/dev/null 2>&1
ok "proc: old com caixa diferente não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('alice','AlicePass123','curta')" >/dev/null 2>&1
ok "proc: nova curta não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('alice','AlicePass123','AlicePass123')" >/dev/null 2>&1
ok "proc: nova igual à atual não altera" "$(q "$SNAP")" "$S0"
PM -N -e "CALL portal_set_password('bob','BobPass12345','NovaSenha123')" >/dev/null 2>&1
ok "proc: bloqueado não altera" "$(q "$SNAP")" "$S0"
ok "proc: devolve changed=0 em falha" "$(PM -N -e "CALL portal_set_password('alice','errada','NovaSenha123')" 2>&1)" 0
ok "proc: sucesso devolve 1" "$(PM -N -e "CALL portal_set_password('alice','AlicePass123','TrocaDireta99')" 2>&1)" 1
ok "proc: só a linha de senha da alice mudou" "$(q "SELECT GROUP_CONCAT(CONCAT_WS('|',username,attribute,op,value) ORDER BY id) FROM radcheck WHERE username='alice'")" \
  "alice|Password.Cleartext|:=|TrocaDireta99,alice|Expiration|:=|2037-06-15T12:00:00Z,alice|Auth-Type|:=|Accept,alice|control.Max-Daily-Session|:=|3600"
ok "proc: demais usuários intactos" "$(q "SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,username,attribute,op,value) ORDER BY id)) FROM radcheck WHERE username<>'alice'")" \
  "$(q "SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',id,username,attribute,op,value) ORDER BY id)) FROM radcheck WHERE username<>'alice'")"
ok "proc: bob intacto" "$(q "SELECT value FROM radcheck WHERE username='bob' AND attribute='Password.Cleartext'")" BobPass12345
PM -N -e "CALL portal_set_password('alice','TrocaDireta99','AlicePass123')" >/dev/null 2>&1

# ===== login
clear_att
J=$T_DIR/pj-alice; rm -f $J
ok "sem login = 302" "$(pcode /dev/null dashboard.php)" 302
ok "login alice ok (302)" "$(p_login $J alice AlicePass123)" 302
ok "cookie radportal, HttpOnly, SameSite" "$(grep -c 'radportal' $J)" 1
ok "alice vê dashboard" "$(pcode $J dashboard.php)" 200
D=$(pget $J dashboard.php)
ok "mostra plano" "$(echo "$D" | grep -c '>basico<')" 1
ok "mostra velocidade do plano" "$(echo "$D" | grep -c '2M/10M')" 1
ok "estado ativo" "$(echo "$D" | grep -c 'tag good')" 1
ok "validade formatada" "$(echo "$D" | grep -c '15/06/2037 09:00')" 1
ok "consumo mês e hoje (15,00 MB)" "$(echo "$D" | grep -c '15,00 MB')" 2
ok "sessão listada (download 10,00 MB)" "$(echo "$D" | grep -c '10,00 MB')" 1
ok "não mostra senha" "$(echo "$D" | grep -c -E 'AlicePass123|BobPass12345|CarolPass123')" 0
ok "não mostra dados do bob" "$(echo "$D" | grep -c -E 'premium|9M/99M|117,74 MB|941,9')" 0

# --- isolamento entre clientes (manipulação de parâmetros)
for qs in 'username=bob' 'user=bob' 'u=bob' 'username=bob&user=bob' 'username[]=bob'; do
  b=$(pget $J "dashboard.php?$qs")
  ok "parâmetro ?$qs ignorado" "$(echo "$b" | grep -c -E 'premium|117,74 MB|Olá, bob')" 0
done
b=$(curl -s -b $J -c $J -d 'username=bob&user=bob' "$P_WEB/dashboard.php")
ok "POST user=bob ignorado" "$(echo "$b" | grep -c -E 'premium|117,74 MB|Olá, bob')" 0
ok "ainda é a alice" "$(echo "$b" | grep -c 'Olá, alice')" 1
ok "alice (case) não confunde com Alice2/ALICE" "$(echo "$D" | grep -c 'Alice2')" 0
ok "login 'ALICE' (caixa) negado" "$(p_login $T_DIR/pj-x ALICE AlicePass123)" 200

# --- enumeração: mesma mensagem e corpo; tempo parecido
clear_att
rm -f $T_DIR/pj-e1 $T_DIR/pj-e2 $T_DIR/pj-e3
p_login $T_DIR/pj-e1 naoexiste QualquerCoisa1 >/dev/null; cp $T_DIR/plast.html $T_DIR/e1.html
p_login $T_DIR/pj-e2 alice SenhaErrada123 >/dev/null; cp $T_DIR/plast.html $T_DIR/e2.html
p_login $T_DIR/pj-e3 bob SenhaErrada123 >/dev/null; cp $T_DIR/plast.html $T_DIR/e3.html
n() { sed 's/value="[a-f0-9]*"//' "$1" | md5sum; }
ok "inexistente = senha errada (corpo idêntico)" "$(n $T_DIR/e1.html)" "$(n $T_DIR/e2.html)"
ok "bloqueado c/ senha errada = mesma resposta" "$(n $T_DIR/e2.html)" "$(n $T_DIR/e3.html)"
ok "mensagem genérica" "$(grep -c 'Usuário ou senha inválidos' $T_DIR/e1.html)" 1
clear_att
tm() { local s e tot=0 i; for i in 1 2 3 4; do rm -f $T_DIR/pj-t; t=$(ptok $T_DIR/pj-t login.php)
  r=$(curl -s -b $T_DIR/pj-t -c $T_DIR/pj-t -o /dev/null -w '%{time_total}' --data-urlencode "csrf=$t" --data-urlencode "user=$1$i" --data-urlencode "pass=Errada$i" "$P_WEB/login.php"); tot=$(echo "$tot + $r" | bc -l); done; echo "$tot"; }
T1=$(tm naoexiste); T2=$(tm alice)
clear_att
ok "tempo parecido (diferença média < 50 ms)" "$(echo "d=($T1-$T2)/4; if (d<0) d=-d; d<0.05" | bc -l)" 1

# --- bloqueado e expirado
clear_att
JB=$T_DIR/pj-bob; rm -f $JB
ok "bob (bloqueado) entra" "$(p_login $JB bob BobPass12345)" 302
B=$(pget $JB dashboard.php)
ok "bloqueado: mensagem de atendimento" "$(echo "$B" | grep -c 'Conta bloqueada. Procure o atendimento')" 1
ok "bloqueado: etiqueta Bloqueado" "$(echo "$B" | grep -c '>Bloqueado<')" 1
ok "bloqueado: sem link de trocar senha" "$(echo "$B" | grep -c 'Alterar senha</a></p>')" 0
ok "bloqueado: password.php redireciona" "$(pcode $JB password.php)" 302
ok "bloqueado: POST troca de senha não altera" "$(p_post $JB dashboard.php password.php 'old=BobPass12345&new=NovaSenha123&confirm=NovaSenha123')" 302
ok "  senha do bob intacta" "$(q "SELECT value FROM radcheck WHERE username='bob' AND attribute='Password.Cleartext'")" BobPass12345
ok "bloqueado não vaza senha" "$(echo "$B" | grep -c 'BobPass12345')" 0
JC=$T_DIR/pj-carol; rm -f $JC
ok "carol (expirada) entra" "$(p_login $JC carol CarolPass123)" 302
C=$(pget $JC dashboard.php)
ok "expirado: mostra data de expiração" "$(echo "$C" | grep -c '15/06/2020 09:00')" 2
ok "expirado: etiqueta Expirado" "$(echo "$C" | grep -c '>Expirado<')" 1
ok "expirado sem plano/sessões: estados vazios" "$(echo "$C" | grep -c 'Nenhuma conexão registrada')" 1

# --- CSRF
ok "login POST sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -d 'user=alice&pass=AlicePass123' $P_WEB/login.php)" 400
ok "troca senha sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $J -d 'old=AlicePass123&new=NovaSenha123&confirm=NovaSenha123' $P_WEB/password.php)" 400
ok "  senha não mudou" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" AlicePass123
ok "troca senha csrf inválido = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $J -d 'csrf=zzz&old=AlicePass123&new=NovaSenha123&confirm=NovaSenha123' $P_WEB/password.php)" 400
ok "logout GET = 405 (não sai)" "$(pcode $J logout.php)" 405
ok "  ainda logado" "$(pcode $J dashboard.php)" 200
ok "logout POST sem csrf = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $J -X POST $P_WEB/logout.php)" 400

# --- troca de senha
ok "senha atual errada" "$(p_post $J password.php password.php 'old=errada123&new=NovaSenha123&confirm=NovaSenha123')" 302
ok "  mensagem" "$(pget $J password.php | grep -c 'Senha atual incorreta')" 1
ok "  senha não mudou" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" AlicePass123
p_post $J password.php password.php 'old=AlicePass123&new=curta&confirm=curta' >/dev/null
ok "nova curta rejeitada" "$(pget $J password.php | grep -c 'pelo menos 8')" 1
ok "  senha não mudou" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" AlicePass123
p_post $J password.php password.php 'old=AlicePass123&new=NovaSenha123&confirm=Diferente1234' >/dev/null
ok "confirmação diferente rejeitada" "$(pget $J password.php | grep -c 'confirmação não confere')" 1
p_post $J password.php password.php 'old=AlicePass123&new=AlicePass123&confirm=AlicePass123' >/dev/null
ok "nova igual à atual rejeitada" "$(pget $J password.php | grep -c 'diferente da atual')" 1
ok "  senha não mudou" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" AlicePass123
# manipulação: tentar trocar a senha do bob enviando username=bob
p_post $J password.php password.php 'username=bob&user=bob&u=bob&old=BobPass12345&new=Hackeada12345&confirm=Hackeada12345' >/dev/null
ok "troca com user=bob e senha do bob não altera o bob" "$(q "SELECT value FROM radcheck WHERE username='bob' AND attribute='Password.Cleartext'")" BobPass12345
ok "  nem a alice" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" AlicePass123
ok "troca de senha com '; e <script> na nova senha" "$(p_post $J password.php password.php "old=AlicePass123&new=%27%3B+DROP+TABLE+radcheck%3B--%3Cscript%3E&confirm=%27%3B+DROP+TABLE+radcheck%3B--%3Cscript%3E")" 302
ok "  gravada literalmente" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" "'; DROP TABLE radcheck;--<script>"
ok "  radcheck existe" "$(q "SELECT COUNT(*)>0 FROM radcheck")" 1
ok "  sessão continua válida após trocar" "$(pcode $J dashboard.php)" 200
ok "  login com a senha nova" "$(p_login $T_DIR/pj-a2 alice "'; DROP TABLE radcheck;--<script>")" 302
q "UPDATE radcheck SET value='AlicePass123' WHERE username='alice' AND attribute='Password.Cleartext'"
ok "senha trocada fora invalida a sessão aberta" "$(pcode $J dashboard.php)" 302
p_login $J alice AlicePass123 >/dev/null
ok "troca válida" "$(p_post $J password.php password.php 'old=AlicePass123&new=NovaSenha123&confirm=NovaSenha123')" 302
ok "  senha mudou" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" NovaSenha123
ok "  outros atributos intactos" "$(q "SELECT COUNT(*) FROM radcheck WHERE username='alice'")" 4
ok "  sessão atual continua" "$(pcode $J dashboard.php)" 200
ok "  senha antiga não entra mais" "$(p_login $T_DIR/pj-old alice AlicePass123)" 200
ok "  senha nova entra" "$(p_login $T_DIR/pj-new alice NovaSenha123)" 302
ok "senha trocada: senha só aparece na tela? (nunca)" "$(pget $J dashboard.php | grep -c NovaSenha123)" 0
ok "senha trocada: nem em password.php" "$(pget $J password.php | grep -c NovaSenha123)" 0
q "UPDATE radcheck SET value='AlicePass123' WHERE username='alice' AND attribute='Password.Cleartext'"

# ===== rate limit
clear_att
for i in 1 2 3 4 5 6; do p_login $T_DIR/pj-rl alice "errada$i" >/dev/null; done
ok "5 falhas (ip,usuário): 6ª não grava mais" "$(q "SELECT COUNT(*) FROM panel_login_attempts WHERE realm='portal' AND username='alice'")" 5
ok "alice bloqueada mesmo com senha certa" "$(p_login $T_DIR/pj-rl alice AlicePass123)" 200
ok "  mesma mensagem genérica" "$(grep -c 'Usuário ou senha inválidos' $T_DIR/plast.html)" 1
ok "carol (outro usuário, mesmo ip) ainda entra" "$(p_login $T_DIR/pj-rl2 carol CarolPass123)" 302
ok "tentativas gravadas com realm=portal" "$(q "SELECT COUNT(*) FROM panel_login_attempts WHERE realm<>'portal'")" 0
# admin não é afetado: mesmo usuário 'alice' é irrelevante; testa que admin entra e que tentativas admin não contam no portal
T_WEB="$ADMIN_WEB"
ok "admin loga normalmente durante o bloqueio do portal" "$(t_login tadmin; curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $ADMIN_WEB/dashboard.php)" 200
# inverso: falhas no admin (realm admin) não bloqueiam portal
clear_att
for i in 1 2 3 4 5 6; do
  t=$(curl -s -c $T_DIR/jx "$ADMIN_WEB/login.php" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
  curl -s -b $T_DIR/jx -c $T_DIR/jx -o /dev/null -d "csrf=$t&user=alice&pass=errada$i" "$ADMIN_WEB/login.php"
done
ok "falhas no admin gravam realm=admin" "$(q "SELECT COUNT(*) FROM panel_login_attempts WHERE realm='admin'")" 5
ok "falhas no admin não bloqueiam alice no portal" "$(p_login $T_DIR/pj-rl3 alice AlicePass123)" 302
# limite por ip (30)
clear_att
for i in $(seq 1 30); do q "INSERT INTO panel_login_attempts (ip,username,realm) VALUES ('127.0.0.1','u$i','portal')"; done
ok "30 falhas por ip: nem o usuário certo entra" "$(p_login $T_DIR/pj-ip alice AlicePass123)" 200
ok "  limite por ip não afeta o admin" "$(t_login tadmin; curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $ADMIN_WEB/dashboard.php)" 200
clear_att
# troca de senha: tentativas de senha atual também contam
JR=$T_DIR/pj-rl4; p_login $JR alice AlicePass123 >/dev/null
for i in 1 2 3 4 5; do p_post $JR password.php password.php "old=errada$i&new=NovaSenha123&confirm=NovaSenha123" >/dev/null; done
ok "5 senhas atuais erradas: 6ª, mesmo certa, é recusada" "$(p_post $JR password.php password.php 'old=AlicePass123&new=NovaSenha123&confirm=NovaSenha123')" 302
ok "  senha não mudou" "$(q "SELECT value FROM radcheck WHERE username='alice' AND attribute='Password.Cleartext'")" AlicePass123
clear_att

# ===== isolamento de sessão admin x portal
ok "admin loga" "$(t_login tadmin; curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $ADMIN_WEB/dashboard.php)" 200
AID=$(grep -P '\tradpanel\t' $T_DIR/jar-tadmin | awk '{print $7}')
ok "cookie do admin tem nome radpanel (id obtido)" "$([ -n "$AID" ] && echo 1 || echo 0)" 1
ok "id da sessão admin enviado como radportal: portal recusa" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$AID" $P_WEB/dashboard.php)" 302
ok "cookie radpanel enviado ao portal é ignorado" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radpanel=$AID" $P_WEB/dashboard.php)" 302
ok "  admin continua logado depois" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin $ADMIN_WEB/dashboard.php)" 200
rm -f $J
ok "portal logado: cookie radportal"  "$(p_login $J alice AlicePass123)" 302
PID=$(grep -P '\tradportal\t' $J | awk '{print $7}')
ok "id da sessão do portal enviado como radpanel: admin recusa" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radpanel=$PID" $ADMIN_WEB/dashboard.php)" 302
ok "  admin recusa também users.php" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radpanel=$PID" $ADMIN_WEB/users.php)" 302
rm -f $J; p_login $J alice AlicePass123 >/dev/null
PID=$(grep -P '\tradportal\t' $J | awk '{print $7}')
ok "  cliente não ganha acesso ao portal com cookie do admin" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$PID" $P_WEB/dashboard.php)" 200
# o portal se recusa a usar sessão com marcas de admin (injetadas no arquivo da sessão)
SD=$(php -r 'echo session_save_path() ?: sys_get_temp_dir();')
if [ -f "$SD/sess_$PID" ]; then
  cp "$SD/sess_$PID" "$T_DIR/sess.bak"
  printf '%s' 'admin_id|i:1;admin_stamp|s:3:"abc";' >> "$SD/sess_$PID"
  ok "sessão com marca de admin: portal recusa" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$PID" $P_WEB/dashboard.php)" 302
else echo "SKIP sessão com marca de admin (arquivo de sessão não encontrado em $SD)"; fi

# ===== login regenera sessão (fixation)
JF=$T_DIR/pj-fix; rm -f $JF
ptok $JF login.php >/dev/null
BEFORE=$(grep -P '\tradportal\t' $JF | awk '{print $7}')
p_login $JF alice AlicePass123 >/dev/null
AFTER=$(grep -P '\tradportal\t' $JF | awk '{print $7}')
ok "session id muda no login" "$([ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ] && echo 1 || echo 0)" 1
ok "id antigo não vale mais" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$BEFORE" $P_WEB/dashboard.php)" 302
ok "id fixado pelo atacante (inexistente) não vira sessão" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Cookie: radportal=attackerfixedid1234567890abcdef' $P_WEB/dashboard.php)" 302

# ===== logout e timeout ocioso
JL=$T_DIR/pj-lo; p_login $JL alice AlicePass123 >/dev/null
LID=$(grep -P '\tradportal\t' $JL | awk '{print $7}')
ok "logout POST" "$(p_post $JL dashboard.php logout.php 'x=1')" 302
ok "  sessão encerrada" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$LID" $P_WEB/dashboard.php)" 302
p_login $JL alice AlicePass123 >/dev/null
LID=$(grep -P '\tradportal\t' $JL | awk '{print $7}')
if [ -f "$SD/sess_$LID" ]; then
  sed -i 's/s:4:"last";i:[0-9]*;/s:4:"last";i:1;/' "$SD/sess_$LID"
  ok "ocioso > 20 min: sessão expira" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$LID" $P_WEB/dashboard.php)" 302
else echo "SKIP timeout ocioso (arquivo de sessão não encontrado)"; fi
p_login $JL alice AlicePass123 >/dev/null
LID=$(grep -P '\tradportal\t' $JL | awk '{print $7}')
if [ -f "$SD/sess_$LID" ]; then
  sed -i "s/s:4:\"last\";i:[0-9]*;/s:4:\"last\";i:$(( $(date +%s) - 1100 ));/" "$SD/sess_$LID"
  ok "ocioso 18 min: ainda vale" "$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: radportal=$LID" $P_WEB/dashboard.php)" 200
fi

# ===== usuário removido derruba a sessão
JD=$T_DIR/pj-del; p_login $JD carol CarolPass123 >/dev/null
q "DELETE FROM radcheck WHERE username='carol'"
ok "usuário removido: sessão morre" "$(pcode $JD dashboard.php)" 302

# ===== cabeçalhos, CSP, HTML limpo
H=$(curl -s -D - -o /dev/null -b $J $P_WEB/dashboard.php)
ok "CSP default-src 'self'" "$(echo "$H" | grep -ci "content-security-policy: default-src 'self'; style-src 'self'; img-src 'self'")" 1
ok "CSP base-uri none" "$(echo "$H" | grep -ci "base-uri 'none'")" 1
ok "X-Frame-Options" "$(echo "$H" | grep -ci 'x-frame-options: deny')" 1
ok "nosniff" "$(echo "$H" | grep -ci 'x-content-type-options: nosniff')" 1
ok "no-store" "$(echo "$H" | grep -ci 'cache-control: no-store')" 1
ok "cookie HttpOnly+SameSite=Strict" "$(echo "$H" | grep -i 'set-cookie' | grep -ci 'httponly')" "$(echo "$H" | grep -ci 'set-cookie')"
p_login $JB bob BobPass12345 >/dev/null
for pg in login.php dashboard.php password.php; do
  for jj in $J $JB; do
    b=$(pget $jj $pg)
    ok "HTML $pg sem style/onclick/script inline" "$(echo "$b" | grep -c -E 'style="|onclick=|<script|javascript:|data:')" 0
  done
done
b=$(pget /dev/null login.php)
ok "login sem inline" "$(echo "$b" | grep -c -E 'style="|onclick=|<script|javascript:|data:')" 0
ok "texto de recuperação 'procure o atendimento'" "$(echo "$b" | grep -ci 'procure o atendimento')" 1
ok "XSS: usuário <script> é escapado/rejeitado" "$(p_login $T_DIR/pj-xss '<script>alert(1)</script>' x >/dev/null; grep -c '<script>alert' $T_DIR/plast.html)" 0
for p in dashboard password; do
  ok "página $p sem erro PHP" "$(pget $J $p.php | grep -ci -E 'fatal error|parse error|warning:|exception')" 0
done
ok "arquivos fora do docroot (lib) não servidos" "$(curl -s -o /dev/null -w '%{http_code}' $P_WEB/../lib/portal.php)" 404
ok "erros PHP não vazam no log de resposta" "$(grep -ci -E 'fatal|parse error' $T_DIR/portal-php.log)" 0
for f in portal/lib/*.php portal/public/*.php; do ok "php -l $f" "$(php -l $f 2>&1 | grep -c 'No syntax errors')" 1; done
summary
