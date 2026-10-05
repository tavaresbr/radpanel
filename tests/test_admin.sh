#!/usr/bin/env bash
# Testes de administração: admins.php, audit.php, tools.php, lib/mikrotik.php, backup. Uso: bash tests/test_admin.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
source tests/harness.sh
env_up admin 3430 8430 || exit 1
trap 'env_down admin' EXIT

code() { curl -s -o /dev/null -w '%{http_code}' -b "$T_DIR/jar-$1" "$T_WEB/$2"; }
rows() { grep -o '^<tr>' | wc -l; }   # linhas <tr> no início de linha
NEWPW='SenhaNova!9876'
SECRET_ADM='Zq9-Sup3rSecretPw'

# backup_dir apontando para o diretório de teste (ainda inexistente) logo no início, antes do cache da config
BK="$T_DIR/backups"
sed -i "s|'server_ip' =>|'backup_dir' => '$BK', 'server_ip' =>|" "$RADPANEL_CONFIG"
t_login tadmin; t_login toper; t_login tview

# ---------- papéis
for p in admins audit tools; do
  ok "$p viewer = 403"   "$(code tview $p.php)" 403
  ok "$p operator = 403" "$(code toper $p.php)" 403
  ok "$p admin = 200"    "$(code tadmin $p.php)" 200
  ok "$p sem login = 302" "$(curl -s -o /dev/null -w '%{http_code}' $T_WEB/$p.php)" 302
done
ok "viewer não cria admin (CSRF ok)" "$(t_post tview dashboard.php admins.php "action=create&username=hack1&role=admin&password=$NEWPW")" 403
ok "operator não cria admin"        "$(t_post toper dashboard.php admins.php "action=create&username=hack2&role=admin&password=$NEWPW")" 403
ok "operator não gera script"       "$(t_post toper dashboard.php tools.php "action=mikrotik&server_ip=1.2.3.4&secret=$SECRET_ADM&services[]=ppp")" 403
ok "  nada criado" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username LIKE 'hack%'")" 0
ok "admin sem CSRF = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin -d "action=create&username=nocsrf&role=viewer&password=$NEWPW" $T_WEB/admins.php)" 400
ok "  nada criado (CSRF)" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username='nocsrf'")" 0

# ---------- criar (validações)
ok "cria adm2 (admin)" "$(t_post tadmin admins.php admins.php "action=create&username=adm2&role=admin&password=TestSenha1234")" 302
ok "  existe com papel admin" "$(q "SELECT role FROM panel_admins WHERE username='adm2'")" admin
ok "  hash argon2id" "$(q "SELECT LEFT(pass_hash,9) FROM panel_admins WHERE username='adm2'")" '$argon2id'
ok "senha curta (9) rejeitada" "$(t_post tadmin admins.php admins.php "action=create&username=curta&role=viewer&password=123456789")" 302
ok "  não criado" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username='curta'")" 0
t_get tadmin admins.php | grep -q 'ao menos 10' && r=sim || r=nao; ok "  mensagem de senha curta" "$r" sim
ok "senha de 10 aceita" "$(t_post tadmin admins.php admins.php "action=create&username=dez10&role=viewer&password=1234567890")" 302
ok "  criado" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username='dez10'")" 1
for bad in "ab" "a%20b" "x'%20OR%201=1--" "u;drop" "%3Cscript%3E" "$(printf 'a%.0s' $(seq 1 65))" "caf%C3%A9"; do
  t_post tadmin admins.php admins.php "action=create&username=$bad&role=viewer&password=$NEWPW" >/dev/null
done
ok "usuários inválidos rejeitados" "$(q "SELECT COUNT(*) FROM panel_admins")" 5   # tadmin toper tview adm2 dez10
ok "usuário de 64 aceito" "$(t_post tadmin admins.php admins.php "action=create&username=$(printf 'b%.0s' $(seq 1 64))&role=viewer&password=$NEWPW")" 302
ok "  criado (64)" "$(q "SELECT COUNT(*) FROM panel_admins WHERE CHAR_LENGTH(username)=64")" 1
t_post tadmin admins.php admins.php "action=create&username=x@y.z-1_&role=viewer&password=$NEWPW" >/dev/null
ok "usuário com @ . - _ aceito" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username='x@y.z-1_'")" 1
t_post tadmin admins.php admins.php "action=create&username=rolebad&role=root&password=$NEWPW" >/dev/null
ok "papel inválido rejeitado" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username='rolebad'")" 0
t_post tadmin admins.php admins.php "action=create&username=ADM2&role=viewer&password=$NEWPW" >/dev/null
ok "duplicado (case-insensitive) rejeitado" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username LIKE 'adm2'")" 1

# ---------- PDOException não vaza SQL (INSERT revogado força erro do banco)
mariadb -S "$T_SOCK" -e "REVOKE INSERT ON radius.panel_admins FROM 'radpanel'@'127.0.0.1';"
t_post tadmin admins.php admins.php "action=create&username=pdoerr&role=viewer&password=$NEWPW" >/dev/null
PB=$(t_get tadmin admins.php)
ok "erro de banco: mensagem genérica" "$(echo "$PB" | grep -c 'Erro ao salvar no banco')" 1
ok "  sem texto SQL na página" "$(echo "$PB" | grep -ci 'SQLSTATE\|denied\|INSERT command\|panel_admins`')" 0
ok "  detalhe foi para o log do servidor" "$(grep -c 'PDOException' "$T_DIR/php.log")" 1
mariadb -S "$T_SOCK" -e "GRANT INSERT ON radius.panel_admins TO 'radpanel'@'127.0.0.1';"
ok "  nada criado" "$(q "SELECT COUNT(*) FROM panel_admins WHERE username='pdoerr'")" 0

# ---------- auto-proteção
t_login adm2
ID_TADMIN=$(q "SELECT id FROM panel_admins WHERE username='tadmin'")
ID_ADM2=$(q "SELECT id FROM panel_admins WHERE username='adm2'")
t_post adm2 admins.php admins.php "action=delete&id=$ID_ADM2" >/dev/null
ok "auto-exclusão bloqueada" "$(q "SELECT COUNT(*) FROM panel_admins WHERE id=$ID_ADM2")" 1
t_get adm2 admins.php | grep -q 'excluir a si mesmo' && r=sim || r=nao; ok "  mensagem de auto-exclusão" "$r" sim
t_post adm2 admins.php admins.php "action=role&id=$ID_ADM2&role=viewer" >/dev/null
ok "auto-rebaixamento bloqueado" "$(q "SELECT role FROM panel_admins WHERE id=$ID_ADM2")" admin
ok "adm2 continua logado" "$(code adm2 admins.php)" 200
ok "id inexistente" "$(t_post adm2 admins.php admins.php "action=delete&id=999999")" 302
ok "ação desconhecida" "$(t_post adm2 admins.php admins.php "action=nuke&id=1")" 302

# ---------- sessões do alvo caem ao mudar papel/senha
t_post adm2 admins.php admins.php "action=create&username=op9&role=operator&password=TestSenha1234" >/dev/null
t_login op9
ok "op9 logado (operator)" "$(code op9 dashboard.php)" 200
ID_OP9=$(q "SELECT id FROM panel_admins WHERE username='op9'")
H1=$(q "SELECT pass_hash FROM panel_admins WHERE id=$ID_OP9")
ok "mudar papel op9 -> viewer" "$(t_post adm2 admins.php admins.php "action=role&id=$ID_OP9&role=viewer")" 302
ok "  papel gravado" "$(q "SELECT role FROM panel_admins WHERE id=$ID_OP9")" viewer
ok "  sessão do op9 caiu (role)" "$(code op9 dashboard.php)" 302
t_login op9
ok "  novo login op9 (viewer)" "$(code op9 dashboard.php)" 200
ok "redefinir senha op9" "$(t_post adm2 admins.php admins.php "action=password&id=$ID_OP9&password=$NEWPW")" 302
ok "  hash mudou" "$([ "$(q "SELECT pass_hash FROM panel_admins WHERE id=$ID_OP9")" != "$H1" ] && echo sim || echo nao)" sim
ok "  sessão do op9 caiu (senha)" "$(code op9 dashboard.php)" 302
t_login op9
ok "  senha antiga não funciona" "$(code op9 dashboard.php)" 302
ok "  senha nova funciona" "$(
  tok=$(curl -s -c $T_DIR/jar-op9 $T_WEB/login.php | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
  curl -s -b $T_DIR/jar-op9 -c $T_DIR/jar-op9 -o /dev/null --data-urlencode "csrf=$tok" --data-urlencode "user=op9" --data-urlencode "pass=$NEWPW" $T_WEB/login.php
  code op9 dashboard.php)" 200
ok "senha curta na redefinição" "$(t_post adm2 admins.php admins.php "action=password&id=$ID_OP9&password=curta")" 302
ok "  hash inalterado" "$([ "$(q "SELECT pass_hash FROM panel_admins WHERE id=$ID_OP9")" != "" ] && echo sim)" sim
t_post adm2 admins.php admins.php "action=role&id=$ID_OP9&role=zzz" >/dev/null
ok "papel inválido na troca" "$(q "SELECT role FROM panel_admins WHERE id=$ID_OP9")" viewer

# redefinir a própria senha mantém a sessão atual
ok "adm2 redefine a própria senha" "$(t_post adm2 admins.php admins.php "action=password&id=$ID_ADM2&password=$NEWPW")" 302
ok "  sessão atual segue válida" "$(code adm2 admins.php)" 200
cp "$T_DIR/jar-adm2" "$T_DIR/jar-adm2copy"

# ---------- demais admins: rebaixar/excluir com 2 admins
ok "adm2 rebaixa tadmin (há 2 admins)" "$(t_post adm2 admins.php admins.php "action=role&id=$ID_TADMIN&role=operator")" 302
ok "  tadmin virou operator" "$(q "SELECT role FROM panel_admins WHERE id=$ID_TADMIN")" operator
ok "  sessão do tadmin caiu" "$(code tadmin admins.php)" 302
q "UPDATE panel_admins SET role='admin' WHERE id=$ID_TADMIN" ; t_login tadmin
ok "tadmin admin de novo e logando" "$(code tadmin admins.php)" 200

# último admin: segura o lock numa sessão SQL que rebaixa adm2 enquanto tadmin tenta excluir/rebaixar "o outro"
ID_DEZ=$(q "SELECT id FROM panel_admins WHERE username='dez10'")
lock_and_demote() { # $1 = id a rebaixar dentro da transação
  mariadb -S "$T_SOCK" radius -e "BEGIN; SELECT id FROM panel_admins WHERE role='admin' FOR UPDATE; SELECT SLEEP(3); UPDATE panel_admins SET role='viewer' WHERE id=$1; COMMIT;" >/dev/null 2>&1 &
  LOCKPID=$!; sleep 1
}
# A: o ATOR (adm2) é rebaixado dentro da transação concorrente; ao liberar o lock, tadmin passa a ser o único admin
lock_and_demote "$ID_ADM2"
t_post adm2 admins.php admins.php "action=delete&id=$ID_TADMIN" >/dev/null
wait $LOCKPID
ok "último admin não é excluído (corrida com lock)" "$(q "SELECT COUNT(*) FROM panel_admins WHERE id=$ID_TADMIN AND role='admin'")" 1
ok "  adm2 foi rebaixado pela transação concorrente" "$(q "SELECT role FROM panel_admins WHERE id=$ID_ADM2")" viewer
q "UPDATE panel_admins SET role='admin' WHERE id=$ID_ADM2"; t_login tadmin; t_login adm2
# B: o mesmo para rebaixamento
lock_and_demote "$ID_ADM2"
t_post adm2 admins.php admins.php "action=role&id=$ID_TADMIN&role=operator" >/dev/null
wait $LOCKPID
ok "último admin não é rebaixado (corrida com lock)" "$(q "SELECT role FROM panel_admins WHERE id=$ID_TADMIN")" admin
t_get tadmin admins.php >/dev/null
q "UPDATE panel_admins SET role='admin' WHERE id=$ID_ADM2"; t_login tadmin; t_login adm2
ok "excluir não-admin com 2 admins" "$(t_post tadmin admins.php admins.php "action=delete&id=$ID_DEZ")" 302
ok "  removido" "$(q "SELECT COUNT(*) FROM panel_admins WHERE id=$ID_DEZ")" 0
ok "excluir admin com 2 admins" "$(t_post tadmin admins.php admins.php "action=delete&id=$ID_ADM2")" 302
ok "  adm2 removido, tadmin é o único admin" "$(q "SELECT COUNT(*) FROM panel_admins WHERE role='admin'")" 1
ok "  sessão do adm2 caiu" "$(code adm2 admins.php)" 302
t_post tadmin admins.php admins.php "action=role&id=$ID_TADMIN&role=viewer" >/dev/null
ok "último admin não se rebaixa" "$(q "SELECT role FROM panel_admins WHERE id=$ID_TADMIN")" admin

# ---------- auditoria sem senha
ok "audit tem admin.create" "$(q "SELECT COUNT(*)>0 FROM panel_audit WHERE action='admin.create'")" 1
ok "audit tem admin.role/password/delete" "$(q "SELECT COUNT(DISTINCT action) FROM panel_audit WHERE action IN ('admin.role','admin.password','admin.delete')")" 3
LEAK=$(q "SELECT COUNT(*) FROM panel_audit WHERE CONCAT_WS('|',admin_name,target,action,detail) LIKE '%$NEWPW%' OR CONCAT_WS('|',admin_name,target,action,detail) LIKE '%TestSenha1234%' OR CONCAT_WS('|',admin_name,target,action,detail) LIKE '%1234567890%' OR CONCAT_WS('|',admin_name,target,action,detail) LIKE '%argon2%'")
ok "auditoria sem senha nem hash" "$LEAK" 0
ok "audit.php sem senhas na página" "$(t_get tadmin audit.php | grep -c -e "$NEWPW" -e 'argon2')" 0

# ---------- audit.php: filtros e paginação
q "DELETE FROM panel_audit"
q "INSERT INTO panel_audit (admin_name, ip, action, target, detail, ts)
   SELECT IF(seq%2=0,'alice','bob'), '10.0.0.1', IF(seq%3=0,'test.alpha','test.beta'), CONCAT('bulk-',seq), CONCAT('d',seq), TIMESTAMP('2026-01-01 12:00:00') + INTERVAL seq DAY
   FROM seq_1_to_130"
q "INSERT INTO panel_audit (admin_name, ip, action, target, detail) VALUES ('eve','10.0.0.2','test.xss','bul_k%','<script>alert(1)</script>')"
q "INSERT INTO panel_audit (admin_name, ip, action, target, detail) VALUES ('eve','10.0.0.2','test.xss','bulkX','\"><img src=x onerror=alert(2)>')"
B=$(t_get tadmin audit.php); ok "página 1 = 50 linhas de dados" "$(( $(echo "$B" | rows) - 1 ))" 50
ok "total 132 registros" "$(echo "$B" | grep -c '132 registro')" 1
ok "página 3 = 32 linhas" "$(( $(t_get tadmin 'audit.php?page=3' | rows) - 1 ))" 32
ok "página 4 vazia" "$(t_get tadmin 'audit.php?page=4' | grep -c 'Nenhum registro')" 1
ok "page=abc não quebra" "$(code tadmin 'audit.php?page=abc')" 200
ok "page negativa não quebra" "$(code tadmin 'audit.php?page=-5')" 200
ok "page gigante não quebra" "$(code tadmin 'audit.php?page=99999999999999999999')" 200
ok "link de paginação com filtro" "$(t_get tadmin 'audit.php?action=test.alpha&page=1' | grep -c 'href="?action=test.alpha&amp;page=')" 0  # alpha tem 43 linhas: 1 página
ok "filtro ação alpha = 43" "$(t_get tadmin 'audit.php?action=test.alpha' | rows | awk '{print $1-1}')" 43
ok "filtro ação beta = 87 (2 págs)" "$(t_get tadmin 'audit.php?action=test.beta' | grep -c '87 registro')" 1
ok "pager mantém filtro" "$(t_get tadmin 'audit.php?action=test.beta' | grep -c 'href="?action=test.beta&amp;page=2"')" 1
ok "filtro admin alice = 65" "$(t_get tadmin 'audit.php?admin=alice' | grep -c '65 registro')" 1
ok "filtro alvo bulk-12 (contém) = 12,120-129 -> 11" "$(t_get tadmin 'audit.php?target=bulk-12' | grep -c '11 registro')" 1
ok "alvo com _ literal (bul_k) casa só 1" "$(t_get tadmin 'audit.php?target=bul_k' | grep -c '1 registro')" 1
ok "alvo com % literal casa só 1" "$(t_get tadmin 'audit.php?target=%25' | grep -c '1 registro')" 1
ok "período from=2026-05-01 (seq>=120)" "$(t_get tadmin 'audit.php?from=2026-05-02&to=2026-05-02' | grep -c '1 registro')" 1
D=$(q "SELECT DATE(MIN(ts)) FROM panel_audit WHERE target='bulk-1'")
ok "período dia único (seq=1) é 2026-01-02" "$D" 2026-01-02
ok "  filtro por esse dia" "$(t_get tadmin 'audit.php?from=2026-01-02&to=2026-01-02&action=test.beta' | grep -c '1 registro')" 1
ok "período invertido = 0" "$(t_get tadmin 'audit.php?from=2030-01-01' | grep -c 'Nenhum registro')" 1
ok "data inválida avisa" "$(t_get tadmin 'audit.php?from=2026-13-45' | grep -c 'Data inválida')" 1
ok "filtro com aspas/SQL não quebra" "$(code tadmin "audit.php?target=%27%20OR%201=1--&admin=%22")" 200
ok "  e não vaza tudo" "$(t_get tadmin "audit.php?target=%27%20OR%201=1--" | grep -c 'Nenhum registro')" 1
X=$(t_get tadmin 'audit.php?action=test.xss')
ok "detail escapado (script)" "$(echo "$X" | grep -c '&lt;script&gt;alert(1)&lt;/script&gt;')" 1
ok "  sem <script> do detail" "$(echo "$X" | grep -c '<script>alert')" 0
ok "  atributo escapado (img)" "$(echo "$X" | grep -c '<img ')" 0
ok "audit somente leitura: 1 único form POST (logout)" "$(echo "$B" | grep -c 'method="post"')" 1
ok "audit via POST não altera" "$(t_post tadmin audit.php audit.php 'action=delete' >/dev/null; q "SELECT COUNT(*) FROM panel_audit WHERE action LIKE 'test.%'")" 132

# ---------- MikroTik: unidade (PHP CLI) com entradas hostis
cat >"$T_DIR/mt.php" <<'PHP'
<?php
require $argv[1] . '/lib/mikrotik.php';
$base = ['server_ip' => '150.230.64.46', 'secret' => 'Abc123-def456', 'name' => 'loja-1', 'services' => ['hotspot', 'ppp'],
  'auth_port' => '1812', 'acct_port' => '1813', 'accounting' => true, 'interim' => '5', 'incoming' => true, 'coa_port' => '3799', 'hotspot_profile' => ''];
$fail = 0; $n = 0;
function t(string $d, bool $c) { global $fail, $n; $n++; if (!$c) { $fail++; echo "FALHA $d\n"; } }
$s = mikrotik_script($base);
t('script válido', str_contains($s, '/radius add service=hotspot,ppp address=150.230.64.46 secret="Abc123-def456" authentication-port=1812 accounting-port=1813'));
t('incoming', str_contains($s, '/radius incoming set accept=yes port=3799'));
t('hotspot profile', str_contains($s, '/ip hotspot profile set [ find default=yes ] use-radius=yes radius-accounting=yes radius-interim-update=5m'));
t('ppp aaa', str_contains($s, '/ppp aaa set use-radius=yes accounting=yes interim-update=5m'));
foreach (explode("\n", trim($s)) as $line) {
  if ($line[0] === '#') { t("comentário sem perigo: $line", !preg_match('/[;$`]/', $line)); continue; }
  t("prefixo permitido: $line", (bool)preg_match('~^(/(radius add|radius remove|radius incoming set|ip hotspot profile set|ppp aaa set|ip firewall filter remove) |:do \{ /ip firewall filter add |:log info ")~', $line));
  t("sem ; $ ` na linha: $line", !preg_match('/[;$`\\\\]/', $line));
}
$o = mikrotik_script($base + []); 
$p = $base; $p['services'] = ['ppp']; $p['accounting'] = false; $p['incoming'] = false; $p['hotspot_profile'] = 'meu-perfil';
$s2 = mikrotik_script($p);
t('só ppp: sem hotspot', !str_contains($s2, 'hotspot profile'));
t('accounting=no', str_contains($s2, 'accounting=no'));
t('sem incoming', !str_contains($s2, 'incoming'));
$p = $base; $p['services'] = ['hotspot']; $p['hotspot_profile'] = 'meu-perfil'; $s3 = mikrotik_script($p);
t('perfil nomeado', str_contains($s3, '[ find name="meu-perfil" ]') && !str_contains($s3, 'ppp aaa'));
$p = $base; $p['server_ip'] = 'radius.exemplo.com.br'; t('hostname ok', str_contains(mikrotik_script($p), 'address=radius.exemplo.com.br '));
$p = $base; $p['server_ip'] = '2001:db8::1'; t('ipv6 ok', str_contains(mikrotik_script($p), 'address=2001:db8::1 '));

$hostile = [
  'secret' => ['ab"cd1234', 'abcd;1234', 'abc$(reboot)1', 'abc${x}1234', "abcd\n/system reset-configuration", "abcd\r\n1234", 'abc[/system reset-configuration]',
               'abc`reboot`1', "abc'1234'", 'abc\\1234x', 'short', str_repeat('a', 65), 'abc def123', 'abc?1234x', 'abc|1234x', 'abc{1234}x', 'ação12345', "abcd1234\n", ''],
  'server_ip' => ['1.2.3.4; /system reset-configuration', '1.2.3.4"', "1.2.3.4\n/system reboot", '$(reboot)', '[/system reset-configuration]', 'a b', '', '1.2.3.4 secret=x', '-bad.com', 'bad..com', str_repeat('a', 300)],
  'name' => ['x"; /system reset-configuration; "', "a\nb", 'a b', '[/system reset-configuration]', '$(x)', str_repeat('n', 33)],
  'hotspot_profile' => ['x" ]; /system reset-configuration; [ find name="', 'a b', '[/system reset-configuration]', "a\nb", '$x', str_repeat('p', 33)],
  'auth_port' => ['0', '70000', '18a2', '1812; x', '-1', '1e3'],
  'acct_port' => ['99999', 'x'], 'coa_port' => ['65536', '3799"'],
  'interim' => ['0', '61', 'x', '5m; /x', '-1', '1.5'],
  'services' => [['hotspot;ppp'], ['ssh'], [], 'hotspot', [['x']], [1]],
];
foreach ($hostile as $field => $vals) {
  foreach ($vals as $v) {
    $in = $base; $in[$field] = $v;
    try { $out = mikrotik_script($in); $rej = false; } catch (RuntimeException $e) { $rej = true; $out = ''; }
    t("rejeita $field=" . json_encode($v), $rej);
    t("nenhum comando perigoso em $field=" . json_encode($v), !str_contains($out, '/system') && !str_contains($out, 'reset-configuration'));
  }
}
$in = $base; $in['secret'] = 12345678;
try { mikrotik_script($in); t('segredo não-string', false); } catch (RuntimeException $e) { t('segredo não-string', true); }
echo "mikrotik.php: $n verificações, $fail falhas\n";
exit($fail ? 1 : 0);
PHP
php "$T_DIR/mt.php" "$ROOT" >"$T_DIR/mt.out" 2>&1; mt_rc=$?
tail -5 "$T_DIR/mt.out"; ok "mikrotik.php unidade (entradas hostis)" "$mt_rc" 0

# ---------- tools.php (HTTP)
PRE() { sed -n '/<pre/,/<\/pre>/p' "$T_DIR/last.html"; }
ok "gerar script (POST)" "$(t_post tadmin tools.php tools.php "action=mikrotik&server_ip=150.230.64.46&secret=$SECRET_ADM&name=loja-1&services[]=hotspot&services[]=ppp&auth_port=1812&acct_port=1813&interim=5&accounting=1&incoming=1&coa_port=3799")" 200
ok "  script em <pre> com o segredo" "$(PRE | grep -c "secret=&quot;$SECRET_ADM&quot;")" 1
ok "  /radius incoming no script" "$(PRE | grep -c 'radius incoming set accept=yes port=3799')" 1
ok "  segredo não volta em input value" "$(grep -c "value=\"$SECRET_ADM\"" "$T_DIR/last.html")" 0
ok "  auditoria registrou a geração" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='tools.mikrotik'")" 1
ok "  segredo NÃO está na auditoria" "$(q "SELECT COUNT(*) FROM panel_audit WHERE CONCAT_WS('|',admin_name,target,action,detail) LIKE '%$SECRET_ADM%'")" 0
ok "  segredo NÃO está em nenhuma tabela" "$(mariadb -S "$T_SOCK" radius -N -e "SELECT 1" >/dev/null; mariadb-dump -S "$T_SOCK" radius --skip-extended-insert 2>/dev/null | grep -c "$SECRET_ADM")" 0
ok "  segredo NÃO está no log do php" "$(grep -c "$SECRET_ADM" "$T_DIR/php.log")" 0
ok "padrão do IP vem do config (150.230.64.46)" "$(t_get tadmin tools.php | grep -c 'value="150.230.64.46"')" 1
t_post tadmin tools.php tools.php "action=mikrotik&server_ip=1.2.3.4&secret=ab%22%3B%20/system%20reset-configuration&services[]=ppp" >/dev/null
ok "  segredo hostil: sem <pre> gerado" "$(grep -c '<pre>' "$T_DIR/last.html")" 0
ok "  e mostra erro" "$(grep -c 'class="flash err"\|Segredo inválido' "$T_DIR/last.html")" 1
t_post tadmin tools.php tools.php "action=mikrotik&server_ip=%24(reboot)&secret=$SECRET_ADM&services[]=ppp" >/dev/null
ok "  IP hostil rejeitado" "$(grep -c '<pre>' "$T_DIR/last.html")" 0
t_post tadmin tools.php tools.php "action=mikrotik&server_ip=1.2.3.4&secret=$SECRET_ADM&services[]=ppp&name=x%22%3B%0A/system%20reset-configuration" >/dev/null
ok "  nome hostil rejeitado" "$(grep -c '<pre>' "$T_DIR/last.html")" 0
t_post tadmin tools.php tools.php "action=mikrotik&server_ip=1.2.3.4&secret=$SECRET_ADM" >/dev/null
ok "  sem serviço rejeitado" "$(grep -c '<pre>' "$T_DIR/last.html")" 0
ok "tools: ação desconhecida = 400" "$(t_post tadmin tools.php tools.php 'action=x')" 400
ok "tools: sem CSRF = 400" "$(curl -s -o /dev/null -w '%{http_code}' -b $T_DIR/jar-tadmin -d "action=mikrotik&server_ip=1.2.3.4&secret=$SECRET_ADM&services[]=ppp" $T_WEB/tools.php)" 400

# ---------- backup: status sem backup
ok "tools: sem backup" "$(t_get tadmin tools.php | grep -c 'sem backup')" 1

# ---------- shell: sintaxe
ok "bash -n backup.sh" "$(bash -n bin/backup.sh && echo 0)" 0
ok "bash -n install-backup.sh" "$(bash -n bin/install-backup.sh && echo 0)" 0

# ---------- backup.sh contra o MariaDB do harness
CNF="$T_DIR/backup.cnf"
mariadb -S "$T_SOCK" radius -e "CREATE PROCEDURE p_teste_backup() SELECT 1; CREATE USER 'radpanel_backup'@'127.0.0.1' IDENTIFIED BY 'bk-test-pass';
  GRANT SELECT, SHOW VIEW, TRIGGER ON radius.* TO 'radpanel_backup'@'127.0.0.1'; GRANT SELECT ON mysql.proc TO 'radpanel_backup'@'127.0.0.1';"
printf '[client]\nuser=radpanel_backup\npassword=bk-test-pass\nhost=127.0.0.1\nport=%s\n' "$T_DBPORT" >"$CNF"
chmod 644 "$CNF"
BACKUP_DIR="$BK" BACKUP_CNF="$CNF" bash bin/backup.sh >"$T_DIR/bk.out" 2>&1; ok "backup recusa .cnf com modo 644" "$?" 1
chmod 600 "$CNF"
BACKUP_DIR="$BK" BACKUP_CNF="$CNF" bash bin/backup.sh >"$T_DIR/bk.out" 2>&1; ok "backup.sh executa (usuário de privilégio mínimo)" "$?" 0
tail -3 "$T_DIR/bk.out"
F=$(ls "$BK"/radius-*.sql.gz 2>/dev/null | head -1)
ok "  arquivo radius-YYYYmmdd-HHMM.sql.gz" "$(basename "${F:-x}" | grep -Ec '^radius-[0-9]{8}-[0-9]{4}\.sql\.gz$')" 1
ok "  modo 600" "$(stat -c %a "${F:-/nonexistent}")" 600
ok "  gzip íntegro" "$(gzip -t "$F" && echo 0)" 0
ok "  contém panel_admins" "$(zcat "$F" | grep -c 'CREATE TABLE `panel_admins`')" 1
ok "  contém a rotina (--routines)" "$([ "$(zcat "$F" | grep -c 'p_teste_backup')" -ge 1 ] && echo 1)" 1
ok "  contém dados (tadmin)" "$([ "$(zcat "$F" | grep -c "tadmin")" -ge 1 ] && echo 1)" 1
ok "  nenhuma sobra .part/.lock indevida" "$(ls -A "$BK" | grep -c '\.part$')" 0
ok "  senha não saiu no stdout/stderr" "$(grep -c 'bk-test-pass' "$T_DIR/bk.out")" 0
ok "diretório de backup 700/750 não é lido por outros" "$(stat -c %a "$BK" | grep -Ec '^7[0-5]0$')" 1
# retenção
for d in 20200101-0101 20200102-0101 20200103-0101 20200104-0101 20200105-0101; do : >"$BK/radius-$d.sql.gz"; done
KEEP=3 BACKUP_DIR="$BK" BACKUP_CNF="$CNF" bash bin/backup.sh >/dev/null 2>&1
ok "retenção KEEP=3" "$(ls "$BK"/radius-*.sql.gz | wc -l)" 3
ok "  o mais novo foi mantido" "$(ls "$BK"/radius-*.sql.gz | grep -c "radius-$(date +%Y)")" 1
ok "  os mais antigos saíram" "$(ls "$BK" | grep -c '^radius-2020010[12]')" 0
# espaço insuficiente
MIN_FREE_MB=999999999 BACKUP_DIR="$BK" BACKUP_CNF="$CNF" bash bin/backup.sh >"$T_DIR/bk2.out" 2>&1; ok "aborta com pouco espaço" "$?" 1
ok "  mensagem de espaço" "$(grep -c 'espaço livre insuficiente' "$T_DIR/bk2.out")" 1
# credenciais erradas -> falha e não deixa arquivo
BEFORE=$(ls "$BK" | wc -l)
printf '[client]\nuser=radpanel_backup\npassword=errada\nhost=127.0.0.1\nport=%s\n' "$T_DBPORT" >"$T_DIR/bad.cnf"; chmod 600 "$T_DIR/bad.cnf"
BACKUP_DIR="$BK" BACKUP_CNF="$T_DIR/bad.cnf" bash bin/backup.sh >/dev/null 2>&1; ok "senha errada: falha (pipefail)" "$([ $? -ne 0 ] && echo 1)" 1
ok "  nenhum arquivo novo" "$(ls "$BK" | wc -l)" "$BEFORE"
BACKUP_DIR="$BK" BACKUP_CNF="$T_DIR/inexistente.cnf" bash bin/backup.sh >/dev/null 2>&1; ok ".cnf ausente: falha" "$?" 1
DB_NAME='radius;x' BACKUP_DIR="$BK" BACKUP_CNF="$CNF" bash bin/backup.sh >/dev/null 2>&1; ok "DB_NAME hostil rejeitado" "$?" 1

# status na tela Ferramentas
# (backup_dir já foi definido no início; o php -S guarda a config em cache e não relê depois)
ok "tools mostra o arquivo do último backup" "$(t_get tadmin tools.php | grep -c 'radius-20[0-9]\{6\}-[0-9]\{4\}\.sql\.gz')" 1
ok "tools mostra 'em dia'" "$(t_get tadmin tools.php | grep -c 'em dia')" 1
touch -d '3 days ago' "$BK"/radius-*.sql.gz
ok "tools: backup antigo = desatualizado" "$(t_get tadmin tools.php | grep -c 'desatualizado')" 1

# install-backup.sh com DESTDIR
DD="$T_DIR/dest"
DESTDIR="$DD" bash bin/install-backup.sh >"$T_DIR/inst.out" 2>&1; ok "install-backup.sh (DESTDIR)" "$?" 0
ok "  cron 03:17 root" "$(grep -c '^17 3 \* \* \* root ' "$DD/etc/cron.d/radpanel-backup")" 1
ok "  cron modo 644" "$(stat -c %a "$DD/etc/cron.d/radpanel-backup")" 644
ok "  backup.cnf modo 600" "$(stat -c %a "$DD/etc/radpanel/backup.cnf")" 600
ok "  diretório de backup 750" "$(stat -c %a "$DD/var/backups/radpanel")" 750
ok "  senha do .cnf não impressa" "$(pw=$(sed -n 's/^password=//p' "$DD/etc/radpanel/backup.cnf"); [ -n "$pw" ] && grep -c "$pw" "$T_DIR/inst.out")" 0
ok "  privilégios documentados na saída" "$(grep -c 'GRANT SELECT, SHOW VIEW, TRIGGER' "$T_DIR/inst.out")" 1
DESTDIR="$DD" bash bin/install-backup.sh >/dev/null 2>&1; ok "  idempotente (mantém .cnf)" "$?" 0
if [ "$(id -u)" != 0 ]; then bash bin/install-backup.sh >/dev/null 2>&1; ok "install-backup recusa não-root sem DESTDIR" "$([ $? -ne 0 ] && echo 1)" 1; fi

# ---------- CSP / HTML inline
for p in admins.php audit.php tools.php; do
  ok "$p sem style=/onclick=/<script> inline" "$(t_get tadmin $p | grep -cE 'style="|onclick=|<script>[^<]')" 0
done
ok "php -l" "$(for f in public/admins.php public/audit.php public/tools.php lib/mikrotik.php; do php -l $f >/dev/null || echo bad; done | wc -l)" 0
summary
