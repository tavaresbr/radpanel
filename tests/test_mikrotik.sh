#!/usr/bin/env bash
# Testes do gerador de script MikroTik (lib/mikrotik.php) e da página Ferramentas (public/tools.php).
# NÃO testa RouterOS real: só o texto gerado e a página.
# Uso: bash tests/test_mikrotik.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
source tests/harness.sh
env_up mt 3490 8490 || exit 1
trap 'env_down mt' EXIT

cat >"$T_DIR/mt.php" <<'PHP'
<?php
require $argv[1] . '/lib/mikrotik.php';
$fail = 0; $n = 0;
function t(string $d, bool $c) { global $fail, $n; $n++; if (!$c) { $fail++; echo "FALHA $d\n"; } }
$b = ['server_ip' => '10.99.0.1', 'secret' => 'Abc123-def456', 'name' => 'loja-1', 'services' => ['hotspot', 'ppp'], 'auth_port' => '1812',
  'acct_port' => '1813', 'accounting' => true, 'interim' => '5', 'incoming' => true, 'coa_port' => '3799', 'hotspot_profile' => '', 'src_address' => ''];
$s = mikrotik_script($b);
t('remove anterior (idempotente)', str_contains($s, '/radius remove [ find comment="RadPanel-loja-1" ]'));
t('radius add com called-id', str_contains($s, 'timeout=3s called-id=loja-1 comment="RadPanel-loja-1"'));
t('incoming', str_contains($s, '/radius incoming set accept=yes port=3799'));
t('firewall padrão ligado', str_contains($s, '/ip firewall filter add chain=input protocol=udp src-address=10.99.0.1 dst-port=3799 action=accept comment="RadPanel-loja-1 coa"'));
t('firewall com fallback sem place-before', str_contains($s, 'place-before=0 } on-error={ /ip firewall filter add'));
t('mac format no hotspot', str_contains($s, 'radius-mac-format=XX-XX-XX-XX-XX-XX'));
t('ppp aaa', str_contains($s, '/ppp aaa set use-radius=yes accounting=yes interim-update=5m'));
t('rollback comentado', str_contains($s, "# /radius remove [ find comment=\"RadPanel-loja-1\" ]") && str_contains($s, '# /ppp aaa set use-radius=no'));
t('rollback do firewall', str_contains($s, '# /ip firewall filter remove [ find comment="RadPanel-loja-1 coa" ]'));
t('log', str_contains($s, ':log info "RadPanel-loja-1 aplicado"'));
$p = $b; $p['firewall'] = false; $x = mikrotik_script($p);
t('sem firewall: só comentário', !str_contains($x, '/ip firewall filter add') && str_contains($x, '# CoA/Disconnect: libere UDP 3799 vindo de 10.99.0.1'));
$p = $b; $p['server_ip'] = 'radius.exemplo.com.br'; $x = mikrotik_script($p);
t('host DNS: sem regra de firewall', !str_contains($x, '/ip firewall filter add') && str_contains($x, '# CoA/Disconnect'));
$p = $b; $p['incoming'] = false; $x = mikrotik_script($p);
t('sem incoming: sem firewall nem incoming', !str_contains($x, 'firewall') && !str_contains($x, '/radius incoming'));
$p = $b; $p['services'] = ['ppp']; $x = mikrotik_script($p);
t('só ppp: sem hotspot', !str_contains($x, 'hotspot'));
$p = $b; $p['hotspot_profile'] = 'perfil-1'; $x = mikrotik_script($p);
t('perfil nomeado', str_contains($x, '[ find name="perfil-1" ] use-radius=yes'));
// linhas de comando: nada de substituição/encadeamento perigoso
foreach (explode("\n", trim($s)) as $l) {
  if ($l === '' || $l[0] === '#') { t("comentário sem crase/\$: $l", !preg_match('/[`$]/', $l)); continue; }
  t("sem crase, \$ ou barra invertida: $l", !preg_match('/[`$\\\\]/', $l));
}
// entradas hostis seguem recusadas
foreach (['secret' => ['a"b;cdefgh', "abcdefgh\n/system reset", 'abc def gh', 'ab$(id)cdefgh'], 'name' => ['a"b', 'a b', "a\nb", 'x;y'],
          'server_ip' => ['1.2.3.4;x', 'a b', '$(id)'], 'hotspot_profile' => ['a"b', 'x;y']] as $k => $vals) {
  foreach ($vals as $v) {
    $p = $b; $p[$k] = $v; $ok = false;
    try { mikrotik_script($p); } catch (RuntimeException $e) { $ok = true; }
    t("recusa $k " . json_encode($v), $ok);
  }
}
echo $fail ? "$fail de $n falharam\n" : "tudo ok ($n)\n";
exit($fail ? 1 : 0);
PHP
R=$(php "$T_DIR/mt.php" "$ROOT" 2>&1); echo "$R"
ok "lib/mikrotik.php: unitários" "$(echo "$R" | tail -1 | grep -c '^tudo ok')" 1

# Página Ferramentas
t_login tadmin; t_login toper
ok "operador não acessa tools.php" "$(curl -s -o /dev/null -w '%{http_code}' -b "$T_DIR/jar-toper" "$T_WEB/tools.php" | grep -c '^200$')" 0
q "INSERT INTO nas (nasname, shortname, type, secret) VALUES ('10.99.0.2', 'loja-x', 'other', 'Segredo-Forte-1')"
B=$(t_get tadmin tools.php)
ok "form: botão de gerar segredo e Avançado" "$(echo "$B" | grep -c 'data-gensecret="mt-secret"')$(echo "$B" | grep -c '<summary>Avançado')" 11
ok "form: checkbox de firewall" "$(echo "$B" | grep -c 'name="firewall"')" 1
ok "tools.js e tools.css referenciados" "$(echo "$B" | grep -c 'src="tools.js"')$(echo "$B" | grep -c 'tools.css')" 11
ok "tools.js servido" "$(curl -s "$T_WEB/tools.js" | grep -q 'getRandomValues' && echo 1)" 1
POST='action=mikrotik&server_ip=10.99.0.1&name=loja-x&services%5B%5D=hotspot&incoming=1&firewall=1&accounting=1&auth_port=1812&acct_port=1813&interim=5&coa_port=3799&src_address=10.99.0.2'
ok "gera com segredo igual ao cadastro" "$(t_post tadmin tools.php tools.php "$POST&secret=Segredo-Forte-1")" 200
P=$(cat "$T_DIR/last.html")
ok "  script presente" "$(echo "$P" | grep -c 'called-id=loja-x')" 1
ok "  botão Baixar" "$(echo "$P" | grep -c 'data-download="pre\[data-copy\]"')" 1
ok "  conferência: cadastrado e segredo ok" "$(echo "$P" | grep -c 'Equipamento cadastrado')$(echo "$P" | grep -c 'é o mesmo do cadastro')" 11
ok "  conferência: sem accounting ainda" "$(echo "$P" | grep -c 'Nenhum accounting recebido')" 1
ok "  segredo não volta ao formulário" "$(echo "$P" | grep -c 'id="mt-secret"[^>]*value=')" 0
q "INSERT INTO radacct (acctsessionid, acctuniqueid, username, nasipaddress, acctstarttime, acctupdatetime) VALUES ('s1','u1','a','10.99.0.2', NOW(), NOW())"
t_post tadmin tools.php tools.php "$POST&secret=Segredo-Forte-1" >/dev/null
ok "  conferência: último accounting há N" "$(grep -c 'Último accounting há' "$T_DIR/last.html")" 1
t_post tadmin tools.php tools.php "$POST&secret=Outro-Segredo-9" >/dev/null
ok "segredo diferente do cadastro é avisado" "$(grep -c 'NÃO é o do cadastro' "$T_DIR/last.html")" 1
t_post tadmin tools.php tools.php "${POST/loja-x/inexistente}&secret=Segredo-Forte-1" >/dev/null
ok "equipamento não cadastrado é avisado" "$(grep -c 'Nenhum equipamento cadastrado' "$T_DIR/last.html")" 1
ok "auditoria sem segredo" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%Segredo-Forte-1%' OR detail LIKE '%Outro-Segredo-9%'")" 0
ok "HTML sem style/onclick/script inline" "$(grep -cE 'style="|onclick=|<script>[^<]' "$T_DIR/last.html")" 0
ok "segredo hostil: erro, sem script" "$(t_post tadmin tools.php tools.php "$POST&secret=abc%22%3Bdef12")$(grep -c 'called-id' "$T_DIR/last.html")" 2000
ok "sem erro PHP nos logs" "$(grep -ci 'fatal\|warning\|notice\|deprecated' "$T_DIR/php.log")" 0
summary
