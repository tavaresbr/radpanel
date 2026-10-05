#!/usr/bin/env bash
# Testes do túnel WireGuard (helper, gerador de script, página). Usa wg/sudo falsos: NÃO testa WireGuard real.
# Uso: bash tests/test_wireguard.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
source tests/harness.sh
env_up wg 3480 8480 || exit 1
trap 'env_down wg' EXIT

H="$ROOT/bin/panel-wg-peer.sh"
WGD="$T_DIR/wg"; mkdir -p "$WGD"
# wg e wg-quick falsos (registram as chamadas)
cat >"$T_DIR/fakewg" <<SH
#!/bin/bash
echo "wg \$*" >>"$T_DIR/wg.log"
[ "\${1:-}" = "show" ] && exit 0
[ "\${1:-}" = "syncconf" ] && { cat >>"$T_DIR/wg.sync"; exit 0; }
exit 0
SH
cat >"$T_DIR/fakewgq" <<SH
#!/bin/bash
echo "wg-quick \$*" >>"$T_DIR/wg.log"
[ "\${1:-}" = "strip" ] && [ -e "$T_DIR/failstrip" ] && { echo "falha simulada"; exit 1; }
[ "\${1:-}" = "strip" ] && cat "\$2"
exit 0
SH
chmod +x "$T_DIR/fakewg" "$T_DIR/fakewgq"
# sudo falso: exige -n, remove-o e roda o helper em modo teste
cat >"$T_DIR/fakesudo" <<SH
#!/bin/bash
echo "sudo \$*" >>"$T_DIR/sudo.log"
[ "\${1:-}" = "-n" ] || exit 1
shift
export RADPANEL_TEST=1 WG_DIR="$WGD" WG_BIN="$T_DIR/fakewg" WG_QUICK="$T_DIR/fakewgq"
exec "\$@"
SH
chmod +x "$T_DIR/fakesudo"
hp() { RADPANEL_TEST=1 WG_DIR="$WGD" WG_BIN="$T_DIR/fakewg" WG_QUICK="$T_DIR/fakewgq" bash "$H" "$@"; }
key() { head -c32 /dev/urandom | base64; }
K1=$(key); K2=$(key); K3=$(key); K4=$(key)

# ---------- helper
out=$(hp list 2>&1); rc=$?
ok "helper sem wg0.base recusa (rc 1)" "$rc" 1
printf '[Interface]\nAddress = 10.99.0.1/24\nListenPort = 51820\nPrivateKey = SEGREDODOSERVIDOR\n' >"$WGD/wg0.base"
echo "SERVERPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" >"$WGD/server.pub"
ok "list vazio" "$(hp list)" ""
ok "add a -> 10.99.0.2" "$(hp add loja-a "$K1")" "OK 10.99.0.2"
ok "add b -> 10.99.0.3" "$(hp add loja-b "$K2")" "OK 10.99.0.3"
ok "add a de novo (mesma chave) é idempotente" "$(hp add loja-a "$K1")" "OK 10.99.0.2"
out=$(hp add loja-a "$K3"); rc=$?; ok "mesmo nome, outra chave: recusa" "$rc" 1
out=$(hp add loja-z "$K1"); rc=$?; ok "mesma chave, outro nome: recusa" "$rc" 1
for bad in 'x;y' '../etc' '.oculto' '-n' 'a b' ''; do
  out=$(hp add "$bad" "$K3" 2>&1); rc=$?
  ok "nome hostil '$bad' recusado" "$([ $rc -ne 0 ] && echo ok)" ok
done
for badk in 'curta' "${K3}x" "$(echo "$K3" | tr '=' 'A')" 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=' "${K3:0:20}\$(id)${K3:30}"; do
  out=$(hp add loja-c "$badk" 2>&1); rc=$?
  ok "chave inválida recusada ($badk)" "$([ $rc -ne 0 ] && echo ok)" ok
done
ok "nada vazou para peers.d" "$(ls "$WGD/peers.d" | tr '\n' ' ')" "loja-a.conf loja-b.conf "
ok "wg0.conf tem a base e os 2 peers" "$(grep -c '^\[Peer\]' "$WGD/wg0.conf") $(grep -c '^PrivateKey = SEGREDODOSERVIDOR' "$WGD/wg0.conf")" "2 1"
ok "wg0.conf modo 600" "$(stat -c %a "$WGD/wg0.conf")" 600
ok "syncconf foi chamado" "$(grep -c '^wg syncconf wg0' "$T_DIR/wg.log" | awk '{print ($1>0)?"sim":"nao"}')" sim
ok "list mostra 2 linhas" "$(hp list | wc -l)" 2
ok "list formato" "$(hp list | head -1)" "loja-a 10.99.0.2 $K1"
ok "pubkey" "$(hp pubkey)" "SERVERPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
ok "status: sem handshake = 0, com a chave cadastrada" "$(hp status | head -1)" "loja-a 10.99.0.2 0 $K1"
ok "status: 2 linhas" "$(hp status | wc -l)" 2
out=$(hp status extra 2>&1); rc=$?; ok "status com args: rc 64" "$rc" 64
ok "remove a" "$(hp remove loja-a)" OK
ok "wg0.conf sem a" "$(grep -c "$K1" "$WGD/wg0.conf")" 0
ok "novo peer reaproveita IP livre .2" "$(hp add loja-c "$K3")" "OK 10.99.0.2"
K5=$(key); K6=$(key)
ok "rekey troca a chave mantendo o IP" "$(hp rekey loja-c "$K5")" "OK 10.99.0.2"
ok "  wg0.conf sem a chave antiga e com a nova" "$(grep -c "$K3" "$WGD/wg0.conf")$(grep -c "$K5" "$WGD/wg0.conf")" 01
ok "  list mostra a chave nova" "$(hp list | grep -c "loja-c 10.99.0.2 $K5")" 1
ok "  idempotente (mesma chave)" "$(hp rekey loja-c "$K5")" "OK 10.99.0.2"
out=$(hp rekey loja-c "$K2"); rc=$?; ok "  chave de OUTRO peer: recusa" "$rc$(echo "$out" | grep -c 'já está em uso')" 11
out=$(hp rekey fantasma "$K6"); rc=$?; ok "  peer inexistente: recusa" "$rc" 1
for badk in 'curta' "${K6}x" "$(echo "$K6" | tr '=' 'A')" "${K6:0:20}\$(id)${K6:30}"; do
  out=$(hp rekey loja-c "$badk" 2>&1); rc=$?; ok "  chave inválida recusada ($badk)" "$([ $rc -ne 0 ] && echo ok)" ok
done
out=$(hp rekey 'a;b' "$K6" 2>&1); rc=$?; ok "  nome hostil recusado" "$([ $rc -ne 0 ] && echo ok)" ok
out=$(hp rekey loja-c 2>&1); rc=$?; ok "  argumentos faltando: rc 64" "$rc" 64
touch "$T_DIR/failstrip"
out=$(hp rekey loja-c "$K6"); rc=$?
ok "  falha ao aplicar: rc 1 e volta à chave anterior" "$rc$(hp list | grep -c "loja-c 10.99.0.2 $K5")$(ls "$WGD/peers.d" | grep -c '\.bak')" 110
rm -f "$T_DIR/failstrip"
ok "  depois da falha, rekey volta a funcionar" "$(hp rekey loja-c "$K6")" "OK 10.99.0.2"
K3=$K6   # a chave atual de loja-c passa a ser K6 (K3 antiga já não vale)
out=$(hp remove inexistente); rc=$?; ok "remove inexistente recusa" "$rc" 1
out=$(hp remove 'a;b' 2>&1); rc=$?; ok "remove nome hostil recusa" "$([ $rc -ne 0 ] && echo ok)" ok
out=$(hp add so-um 2>&1); rc=$?; ok "args faltando: rc 64" "$rc" 64
out=$(hp list extra 2>&1); rc=$?; ok "list com args: rc 64" "$rc" 64
out=$(hp foo 2>&1); rc=$?; ok "comando desconhecido: rc 64" "$rc" 64
# sem RADPANEL_TEST ignora o ambiente: não é root aqui, então deve recusar antes de tocar em qualquer coisa
out=$(WG_DIR="$WGD" bash "$H" list 2>&1); rc=$?
ok "produção ignora WG_DIR (recusa: não é root ou não há /etc/wireguard configurado)" "$([ $rc -ne 0 ] && echo ok)" ok
ok "  e não mexeu em $WGD" "$(ls "$WGD/peers.d" | wc -l)" 2
# esgotar IPs: 253 peers
rm -f "$WGD"/peers.d/*.conf
for i in $(seq 1 252); do printf '[Peer]\n# p%s\nPublicKey = %s\nAllowedIPs = 10.99.0.%s/32\n' "$i" "$(key)" "$((i+1))" >"$WGD/peers.d/p$i.conf"; done
ok "253º cabe (.254)" "$(hp add p253 "$(key)")" "OK 10.99.0.254"
ok "253 peers" "$(hp list | wc -l)" 253
out=$(hp add p254 "$(key)"); rc=$?; ok "254º recusado" "$rc" 1
rm -f "$WGD"/peers.d/*.conf; hp remove x >/dev/null 2>&1; : >"$T_DIR/wg.log"

# sudoers
ok "sudoers: add/rekey/remove/list/pubkey/status só com o helper" "$(grep -c 'NOPASSWD: /opt/radpanel/bin/panel-wg-peer.sh add \*, /opt/radpanel/bin/panel-wg-peer.sh remove \*, /opt/radpanel/bin/panel-wg-peer.sh rekey \*, /opt/radpanel/bin/panel-wg-peer.sh list, /opt/radpanel/bin/panel-wg-peer.sh pubkey, /opt/radpanel/bin/panel-wg-peer.sh status$' server-config/sudoers.radpanel)" 1

# ---------- gerador de script (PHP CLI)
PUBS=$(printf 'A%.0s' $(seq 1 43))=
cat >"$T_DIR/wgmt.php" <<'PHP'
<?php
require $argv[1] . '/lib/mikrotik.php';
$fail = 0; $n = 0;
function t(string $d, bool $c) { global $fail, $n; $n++; if (!$c) { $fail++; echo "FALHA $d\n"; } }
$pub = str_repeat('A', 43) . '=';
$b = ['server_ip' => '150.230.64.46', 'server_pub' => $pub, 'address' => '10.99.0.2', 'name' => 'loja-1'];
$s = mikrotik_wg_script($b);
t('interface', str_contains($s, '/interface wireguard add name=wg-radius listen-port=13231'));
t('peer', str_contains($s, 'public-key="' . $pub . '" endpoint-address=150.230.64.46 endpoint-port=51820 allowed-address=10.99.0.1/32 persistent-keepalive=25s'));
t('ip', str_contains($s, '/ip address add address=10.99.0.2/24 interface=wg-radius'));
t('chave pública do roteador', str_contains($s, ':put [/interface wireguard get wg-radius public-key]'));
t('sem chave privada', !preg_match('/private/i', $s));
t('wg: saída 100% ASCII', !preg_match('/[^\\x00-\\x7F]/', $s));
foreach (explode("\n", trim($s)) as $l) {
  if ($l[0] === '#') { t("comentário sem perigo: $l", !preg_match('/[`$]/', $l)); continue; }
  t("linha permitida: $l", (bool)preg_match('~^(:if \(\[:len \[/(interface wireguard|interface wireguard peers|ip address) find |:put \[/interface wireguard get wg-radius public-key\]$)~', $l));
  t("sem ; ` \\ na linha (fora do bloco :if): $l", !preg_match('/[`\\\\]/', $l));
}
foreach ([['server_ip', "1.2.3.4\nx"], ['server_ip', '1.2.3.4;rm'], ['server_ip', ''], ['server_pub', 'curta'], ['server_pub', $pub . "\n/system reset"],
          ['address', '10.99.0.1'], ['address', '10.99.0.255'], ['address', '10.99.0.0'], ['address', '10.99.1.5'], 
          ['address', '10.99.0.2/24'], ['name', 'a b'], ['name', 'a"b'], ['name', str_repeat('x', 33)], ['wg_port', '0'], ['wg_port', '70000'], ['wg_port', '51820;']] as [$k, $v]) {
  $p = $b; $p[$k] = $v; $ok = false;
  try { mikrotik_wg_script($p); } catch (RuntimeException $e) { $ok = true; }
  t("recusa $k=" . json_encode($v), $ok);
}
$p = $b; $p['address'] = '10.99.0.254'; t('254 ok', str_contains(mikrotik_wg_script($p), '10.99.0.254/24'));
$p = $b; unset($p['name']); t('nome padrão', str_contains(mikrotik_wg_script($p), 'RadPanel-radpanel'));
// src_address no script do RADIUS
$r = ['server_ip' => '10.99.0.1', 'secret' => 'Abc123-def456', 'name' => 'loja-1', 'services' => ['hotspot'], 'auth_port' => '1812', 'acct_port' => '1813',
  'accounting' => true, 'interim' => '5', 'incoming' => true, 'coa_port' => '3799', 'hotspot_profile' => '', 'src_address' => '10.99.0.2'];
t('radius: saída 100% ASCII', !preg_match('/[^\\x00-\\x7F]/', mikrotik_script($r)));
t('src-address no /radius add', str_contains(mikrotik_script($r), 'address=10.99.0.1 src-address=10.99.0.2 secret="'));
$r['src_address'] = ''; t('sem src-address por padrão no /radius add', !preg_match('~^/radius add .*src-address~m', mikrotik_script($r)));
foreach (['10.99.0.2;x', "10.99.0.2\nx", 'abc', '10.99.0.2 secret="x"', '::1'] as $v) {
  $r['src_address'] = $v; $ok = false;
  try { mikrotik_script($r); } catch (RuntimeException $e) { $ok = true; }
  t('recusa src_address ' . json_encode($v), $ok);
}
echo $fail ? "$fail de $n falharam\n" : "tudo ok ($n)\n";
exit($fail ? 1 : 0);
PHP
out=$(php "$T_DIR/wgmt.php" "$ROOT" 2>&1); rc=$?
echo "$out" | grep FALHA
ok "gerador: $(echo "$out" | tail -1)" "$rc" 0

# ---------- página (admin) com sudo/wg falsos
sed "s#'restart_helper' => '[^']*',#'restart_helper' => '$T_DIR/no-such-helper', 'wg_helper' => '$H', 'sudo_bin' => '$T_DIR/fakesudo',#" "$T_DIR/config.php" >"$T_DIR/config.php.new" && mv "$T_DIR/config.php.new" "$T_DIR/config.php"
# o servidor php -S já lê o config a cada requisição (require), então basta trocar o arquivo
sleep 3
t_login tadmin; t_login toper; t_login tview
code() { curl -s -o /dev/null -w '%{http_code}' -b "$T_DIR/jar-$1" "$T_WEB/$2"; }
ok "operator não acessa (403)" "$(code toper wireguard.php)" 403
ok "viewer não acessa (403)" "$(code tview wireguard.php)" 403
ok "sem login redireciona" "$(curl -s -o /dev/null -w '%{http_code}' "$T_WEB/wireguard.php")" 302
ok "menu mostra VPN WireGuard ao admin" "$(t_get tadmin dashboard.php | grep -c 'href="wireguard.php"')" 1
ok "menu não mostra ao operator" "$(t_get toper dashboard.php | grep -c 'href="wireguard.php"')" 0

rm -f "$WGD/server.pub"; rm -f "$WGD"/peers.d/*.conf
B=$(t_get tadmin wireguard.php)
ok "sem server.pub: 'não configurado' e mostra o comando" "$(echo "$B" | grep -c 'não configurado')$(echo "$B" | grep -c 'wg-setup.sh')" 11
SERVERPUB="$(key)"; echo "$SERVERPUB" >"$WGD/server.pub"
B=$(t_get tadmin wireguard.php)
ok "com server.pub: ativo e mostra a chave" "$(echo "$B" | grep -c 'ativo')$(echo "$B" | grep -c "$SERVERPUB")" 11
ok "sem CSRF: 400" "$(curl -s -b "$T_DIR/jar-tadmin" -o /dev/null -w '%{http_code}' -d "action=add&name=x&pubkey=$K1" "$T_WEB/wireguard.php")" 400
: >"$T_DIR/sudo.log"
ok "add por operator: 403" "$(t_post toper dashboard.php wireguard.php "action=add&name=loja-a&pubkey=$(printf %s "$K1" | sed 's/+/%2B/g;s#/#%2F#g;s/=/%3D/g')")" 403
ok "  helper não foi chamado" "$(grep -c 'add' "$T_DIR/sudo.log")" 0
enc() { printf %s "$1" | sed 's/+/%2B/g;s#/#%2F#g;s/=/%3D/g'; }
ok "admin adiciona (200 com script)" "$(t_post tadmin wireguard.php wireguard.php "action=add&name=loja-a&pubkey=$(enc "$K1")")" 200
R=$(cat "$T_DIR/last.html")
ok "  mostra IP 10.99.0.2" "$(echo "$R" | grep -c '10.99.0.2/24')" 1
ok "  script tem a chave pública do servidor" "$(echo "$R" | grep -c "$(printf %s "$SERVERPUB" | sed 's/[+\/]/./g')")" 2
ok "  usa o IP público do config (150.230.64.46)" "$(echo "$R" | grep -c 'endpoint-address=150.230.64.46')" 1
ok "  helper chamado com sudo -n + argv" "$(grep -c "^sudo -n $H add loja-a $K1\$" "$T_DIR/sudo.log")" 1
ok "  auditoria wg.add sem a chave" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='wg.add' AND target='loja-a'")$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%$K1%'")" 10
ok "nome hostil: erro e nada gravado" "$(t_post tadmin wireguard.php wireguard.php "action=add&name=a%3Bb&pubkey=$(enc "$K2")")" 302
ok "  flash de erro" "$(t_get tadmin wireguard.php | grep -c 'Nome inválido')" 1
ok "chave inválida: 302 + flash" "$(t_post tadmin wireguard.php wireguard.php "action=add&name=loja-b&pubkey=curta")$(t_get tadmin wireguard.php | grep -c 'Chave pública inválida')" 3021
ok "chave PRIVADA colada com 44 chars inválidos não passa" "$(t_post tadmin wireguard.php wireguard.php "action=add&name=loja-b&pubkey=%24%28id%29")" 302
ok "lista mostra loja-a" "$(t_get tadmin wireguard.php | grep -c 'loja-a')" 3
# cadastrar como equipamento
ok "register: segredo curto recusado" "$(t_post tadmin wireguard.php wireguard.php 'action=register&name=loja-a&ip=10.99.0.2&secret=curto')$(q "SELECT COUNT(*) FROM nas WHERE nasname='10.99.0.2'")" 3020
ok "register: peer inexistente recusado" "$(t_post tadmin wireguard.php wireguard.php 'action=register&name=fantasma&ip=10.99.0.9&secret=Segredo-Forte-1')$(q "SELECT COUNT(*) FROM nas WHERE nasname='10.99.0.9'")" 3020
ok "register: IP que não é do peer recusado" "$(t_post tadmin wireguard.php wireguard.php 'action=register&name=loja-a&ip=10.99.0.77&secret=Segredo-Forte-1')$(q "SELECT COUNT(*) FROM nas WHERE nasname='10.99.0.77'")" 3020
ok "register ok" "$(t_post tadmin wireguard.php wireguard.php 'action=register&name=loja-a&ip=10.99.0.2&secret=Segredo-Forte-1')$(q "SELECT COUNT(*) FROM nas WHERE nasname='10.99.0.2' AND shortname='loja-a'")" 3021
ok "  clients.d gerado com ipaddr do túnel" "$(grep -c 'ipaddr = 10.99.0.2' "$T_DIR/raddb/clients.d/loja-a.conf")" 1
ok "  auditoria sem segredo" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%Segredo-Forte-1%'")" 0
ok "register de novo: já existe" "$(t_post tadmin wireguard.php wireguard.php 'action=register&name=loja-a&ip=10.99.0.2&secret=Segredo-Forte-2')$(q "SELECT COUNT(*) FROM nas WHERE nasname='10.99.0.2'")" 3021
ok "página mostra 'cadastrado'" "$(t_get tadmin wireguard.php | grep -c 'cadastrado')" 1
ok "remove" "$(t_post tadmin wireguard.php wireguard.php 'action=remove&name=loja-a')" 302
ok "  saiu do helper" "$(hp list | wc -l)" 0
ok "  auditoria wg.remove" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='wg.remove'")" 1
ok "ação desconhecida não derruba (302)" "$(t_post tadmin wireguard.php wireguard.php 'action=zzz')" 302
ok "sem erro PHP nos logs" "$(grep -ci 'fatal\|warning\|notice\|deprecated' "$T_DIR/php.log")" 0
# botão Copiar
B=$(t_get tadmin wireguard.php)
ok "wireguard.php: 2 blocos com data-copy (passo 1 e... conforme estado)" "$([ "$(echo "$B" | grep -c '<pre data-copy>')" -ge 1 ] && echo ok)" ok
ok "tools.php: script gerado é copiável" "$(t_post tadmin tools.php tools.php 'action=mikrotik&server_ip=150.230.64.46&secret=Abc123-def456&name=x&services%5B%5D=hotspot&auth_port=1812&acct_port=1813&interim=5&coa_port=3799' >/dev/null; grep -c '<pre data-copy>' "$T_DIR/last.html")" 1
ok "nas.php: bloco de clients.d NÃO é copiável" "$(t_get tadmin nas.php | grep -c '<pre data-copy')" 0
ok "app.js servido com o tratador" "$(curl -s "$T_WEB/app.js" | grep -c 'pre\[data-copy\]')" 1
ok "CSP sem unsafe-inline" "$(curl -sI "$T_WEB/login.php" | grep -i '^content-security-policy' | grep -c 'unsafe')" 0
out=$(node tests/copy_browser.js "$T_WEB" tadmin "$T_PASS" 2>&1); rc=$?
echo "$out" | grep -E '^(FALHA|OK)' | sed 's/^OK /PASS navegador: /;s/^FALHA /FAIL navegador: /'
if [ $rc -eq 2 ]; then echo "AVISO: Playwright/Chromium indisponível; botão Copiar NÃO testado no navegador"; else ok "navegador real: botão Copiar (rc)" "$rc" 0; fi
# helper ausente: erro amigável, sem vazar caminho
sed -i "s#'wg_helper' => '[^']*'#'wg_helper' => '/nao/existe'#" "$T_DIR/config.php"
sleep 3   # o opcache do php -S revalida arquivos a cada 2 s
B=$(t_get tadmin wireguard.php)
ok "helper ausente: mensagem amigável" "$(echo "$B" | grep -c 'Helper do WireGuard não instalado')" 1
ok "  sem caminho/stack vazado" "$(echo "$B" | grep -c '/nao/existe\|Stack trace')" 0
summary
