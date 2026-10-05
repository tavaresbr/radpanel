#!/usr/bin/env bash
# Testes do assistente "Ativar equipamento" (setup.php). wg, sudo e o helper de reinício são FALSOS: não testa WireGuard/FreeRADIUS reais.
# Uso: bash tests/test_setup.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
source tests/harness.sh
env_up setup 3490 8490 || exit 1
trap 'env_down setup' EXIT

H="$ROOT/bin/panel-wg-peer.sh"
WGD="$T_DIR/wg"; mkdir -p "$WGD"
HS="$T_DIR/handshakes"; : >"$HS"
cat >"$T_DIR/fakewg" <<SH
#!/bin/bash
[ "\${1:-}" = "show" ] && [ "\${3:-}" = "latest-handshakes" ] && { cat "$HS"; exit 0; }
[ "\${1:-}" = "show" ] && exit 0
[ "\${1:-}" = "syncconf" ] && { cat >/dev/null; exit 0; }
exit 0
SH
cat >"$T_DIR/fakewgq" <<'SH'
#!/bin/bash
[ "${1:-}" = "strip" ] && cat "$2"
exit 0
SH
cat >"$T_DIR/fakerestart" <<SH
#!/bin/bash
echo "restart" >>"$T_DIR/restart.log"
echo "Configuração válida; freeradius reiniciado."
SH
cat >"$T_DIR/fakesudo" <<SH
#!/bin/bash
[ "\${1:-}" = "-n" ] || exit 1
shift
export RADPANEL_TEST=1 WG_DIR="$WGD" WG_BIN="$T_DIR/fakewg" WG_QUICK="$T_DIR/fakewgq"
exec "\$@"
SH
chmod +x "$T_DIR/fakewg" "$T_DIR/fakewgq" "$T_DIR/fakerestart" "$T_DIR/fakesudo"
printf '[Interface]\nAddress = 10.99.0.1/24\nListenPort = 51820\nPrivateKey = SEGREDODOSERVIDOR\n' >"$WGD/wg0.base"
SERVERPUB="$(head -c32 /dev/urandom | base64)"; echo "$SERVERPUB" >"$WGD/server.pub"
sed -i "s#'restart_helper' => '[^']*',#'restart_helper' => '$T_DIR/fakerestart', 'wg_helper' => '$H', 'sudo_bin' => '$T_DIR/fakesudo',#" "$T_DIR/config.php"
sleep 3   # o opcache do php -S revalida arquivos a cada 2 s
t_login tadmin; t_login toper; t_login tview

key() { head -c32 /dev/urandom | base64; }
enc() { printf %s "$1" | sed 's/+/%2B/g;s#/#%2F#g;s/=/%3D/g'; }
code() { curl -s -o /dev/null -w '%{http_code}' -b "$T_DIR/jar-$1" "$T_WEB/$2"; }
# Location de um GET autenticado como admin
gloc() { curl -s -b "$T_DIR/jar-tadmin" -c "$T_DIR/jar-tadmin" -o /dev/null -D - "$T_WEB/$1" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}'; }
# Location de um POST com CSRF (página do token, destino, campos)
ploc() { local tok; tok=$(t_tok tadmin "$1"); curl -s -b "$T_DIR/jar-tadmin" -c "$T_DIR/jar-tadmin" -o "$T_DIR/last.html" -D - -d "csrf=$tok&$3" "$T_WEB/$2" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}'; }
page() { t_get tadmin "$1"; }
flashes() { page "$1" | grep -o 'class="flash [a-z]*">[^<]*' | sed 's/.*">//'; }

K1=$(key); K2=$(key)

# ---------- acesso
ok "operator: 403" "$(code toper setup.php)" 403
ok "viewer: 403" "$(code tview setup.php)" 403
ok "anônimo: 302" "$(curl -s -o /dev/null -w '%{http_code}' "$T_WEB/setup.php")" 302
ok "menu do admin: 'Ativar equipamento' é o 1º item" "$(page dashboard.php | grep -o '<nav><a[^>]*href="[^"]*"' | grep -o 'href="[^"]*"')" 'href="setup.php"'
ok "menu do operator não mostra" "$(t_get toper dashboard.php | grep -c 'href="setup.php"')" 0
ok "sem CSRF: 400" "$(curl -s -b "$T_DIR/jar-tadmin" -o /dev/null -w '%{http_code}' -d 'action=start&name=x&mode=wg' "$T_WEB/setup.php")" 400

# ---------- início
B=$(page setup.php)
ok "início: formulário de novo equipamento e lista vazia" "$(echo "$B" | grep -c 'name="mode"')$(echo "$B" | grep -c 'Nenhum ainda')" 21
ok "start sem tipo: volta com aviso" "$(ploc setup.php setup.php 'action=start&name=RB09')" "setup.php?name=RB09&mode=wg"
ok "  aviso" "$(flashes 'setup.php?name=RB09' | grep -c 'Informe')" 1
ok "start com nome hostil: recusa e volta" "$(ploc setup.php setup.php 'action=start&name=a%3Bb&mode=wg')" "setup.php"
ok "  XSS no nome: recusado" "$(ploc setup.php setup.php 'action=start&name=%3Cscript%3E&mode=wg')" "setup.php"
ok "start wg: vai para a etapa 1" "$(ploc setup.php setup.php 'action=start&name=RB09&mode=wg')" "setup.php?name=RB09&mode=wg&step=1"

# ---------- etapa 1: túnel
ok "etapa 3 por URL sem túnel: volta à etapa 1" "$(gloc 'setup.php?name=RB09&mode=wg&step=3')" "setup.php?name=RB09&mode=wg&step=1"
ok "etapa 6 por URL sem nada: volta à etapa 1" "$(gloc 'setup.php?name=RB09&mode=wg&step=6')" "setup.php?name=RB09&mode=wg&step=1"
B=$(page 'setup.php?name=RB09&mode=wg&step=1')
ok "etapa 1: comandos copiáveis e campo da chave" "$(echo "$B" | grep -c '<pre data-copy>')$(echo "$B" | grep -c 'name="pubkey"')" 11
ok "etapa 1: chave inválida volta com aviso" "$(ploc 'setup.php?name=RB09&mode=wg&step=1' setup.php 'action=peer&name=RB09&mode=wg&pubkey=curta')" "setup.php?name=RB09&mode=wg"
ok "  aviso de chave" "$(flashes 'setup.php?name=RB09&mode=wg&step=1' | grep -c 'Chave pública inválida')" 1
ok "adicionar chave: vai à etapa 2" "$(ploc 'setup.php?name=RB09&mode=wg&step=1' setup.php "action=peer&name=RB09&mode=wg&pubkey=$(enc "$K1")")" "setup.php?name=RB09&mode=wg&step=2"
ok "  auditoria setup.peer sem a chave" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='setup.peer' AND target='RB09'")$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%$K1%'")" 10
ok "  repetir é idempotente (mesma chave)" "$(ploc 'setup.php?name=RB09&mode=wg&step=1' setup.php "action=peer&name=RB09&mode=wg&pubkey=$(enc "$K1")")" "setup.php?name=RB09&mode=wg&step=2"
ok "  outro nome com a mesma chave: recusa" "$(ploc setup.php setup.php "action=peer&name=OUTRO&mode=wg&pubkey=$(enc "$K1")")" "setup.php?name=OUTRO&mode=wg"

# ---------- etapa 2: conexão
B=$(page 'setup.php?name=RB09&mode=wg&step=2')
ok "etapa 2: script do túnel com IP 10.99.0.2 e chave do servidor" "$(echo "$B" | grep -c '10.99.0.2/24')$(echo "$B" | grep -c 'endpoint-address=150.230.64.46')" 11
ok "  sem conexão ainda" "$(echo "$B" | grep -c 'ainda sem conexão')" 1
ok "  sem botão 'Continuar' enquanto não conecta" "$(echo "$B" | grep -c '>Continuar<')" 0
ok "etapa 3 por URL sem handshake: volta à etapa 2" "$(gloc 'setup.php?name=RB09&mode=wg&step=3')" "setup.php?name=RB09&mode=wg&step=2"
printf '%s\t%s\n' "$K1" "$(date +%s)" >"$HS"
B=$(page 'setup.php?name=RB09&mode=wg&step=2')
ok "  com handshake recente: conectado + Continuar" "$(echo "$B" | grep -c 'tag good">conectado')$(echo "$B" | grep -c '>Continuar<')" 11
printf '%s\t%s\n' "$K1" "$(( $(date +%s) - 4000 ))" >"$HS"
B=$(page 'setup.php?name=RB09&mode=wg&step=2')
ok "  handshake antigo: 'já conectou' mas não 'conectado'" "$(echo "$B" | grep -c 'já conectou')$(echo "$B" | grep -c 'tag good">conectado')" 10
printf '%s\t%s\n' "$K1" "$(date +%s)" >"$HS"

# ---------- trocar a chave do roteador (interface recriada no MikroTik)
B=$(page 'setup.php?name=RB09&mode=wg&step=1')
ok "etapa 1 com peer: mostra o formulário de trocar a chave" "$(echo "$B" | grep -c 'value="rekey"')" 1
K3=$(key); K4=$(key)
ok "rekey com chave inválida volta com aviso" "$(ploc setup.php setup.php 'action=rekey&name=RB09&mode=wg&pubkey=curta')" "setup.php?name=RB09&mode=wg"
ok "  aviso" "$(flashes 'setup.php?name=RB09&mode=wg&step=1' | grep -c 'Chave pública inválida')" 1
ok "outro peer RB10 com a chave K4" "$(ploc setup.php setup.php "action=peer&name=RB10&mode=wg&pubkey=$(enc "$K4")")" "setup.php?name=RB10&mode=wg&step=2"
ok "rekey com a chave de OUTRO peer: recusa" "$(ploc setup.php setup.php "action=rekey&name=RB09&mode=wg&pubkey=$(enc "$K4")")" "setup.php?name=RB09&mode=wg"
ok "  aviso de chave em uso" "$(flashes 'setup.php?name=RB09&mode=wg&step=1' | grep -c 'já está em uso')" 1
ok "rekey de peer inexistente: recusa" "$(ploc setup.php setup.php "action=rekey&name=NAOEXISTE&mode=wg&pubkey=$(enc "$K3")")" "setup.php?name=NAOEXISTE&mode=wg"
ok "rekey com chave nova: vai à etapa 2" "$(ploc setup.php setup.php "action=rekey&name=RB09&mode=wg&pubkey=$(enc "$K3")")" "setup.php?name=RB09&mode=wg&step=2"
ok "  helper guarda a chave nova e o MESMO IP" "$(grep -c "PublicKey = $K3" "$WGD/peers.d/RB09.conf")$(grep -c 'AllowedIPs = 10.99.0.2/32' "$WGD/peers.d/RB09.conf")$(grep -c "$K1" "$WGD/peers.d/RB09.conf")" 110
ok "  auditoria setup.rekey sem a chave" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='setup.rekey' AND target='RB09'")$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%$K3%'")" 10
B=$(page 'setup.php?name=RB09&mode=wg&step=2')
ok "  handshake só da chave antiga: ainda sem conexão e com a dica de trocar a chave" "$(echo "$B" | grep -c 'já conectou')$(echo "$B" | grep -c 'ainda sem conexão')$(echo "$B" | grep -c 'Trocar a chave (etapa 1)')" 011
printf '%s\t%s\n' "$K3" "$(date +%s)" >"$HS"
ok "  handshake da chave nova: conectado" "$(page 'setup.php?name=RB09&mode=wg&step=2' | grep -c 'tag good">conectado')" 1
ok "rekey sem CSRF: 400" "$(curl -s -b "$T_DIR/jar-tadmin" -o /dev/null -w '%{http_code}' -d "action=rekey&name=RB09&mode=wg&pubkey=$(enc "$K3")" "$T_WEB/setup.php")" 400

# ---------- etapa 3: cadastro
B=$(page 'setup.php?name=RB09&mode=wg&step=3')
SEC=$(echo "$B" | grep -o 'name="secret"[^>]*value="[A-Za-z0-9]*"' | sed 's/.*value="//;s/"//')
ok "etapa 3: segredo sugerido de 20 caracteres alfanuméricos" "$(echo "$SEC" | grep -cE '^[A-Za-z0-9]{20}$')" 1
ok "  IP do túnel somente leitura" "$(echo "$B" | grep -c 'value="10.99.0.2" readonly')" 1
ok "  dois carregamentos dão segredos diferentes" "$([ "$SEC" != "$(page 'setup.php?name=RB09&mode=wg&step=3' | grep -o 'name="secret"[^>]*value="[A-Za-z0-9]*"' | sed 's/.*value="//;s/"//')" ] && echo ok)" ok
ok "segredo curto: recusa, nada gravado" "$(ploc 'setup.php?name=RB09&mode=wg&step=3' setup.php 'action=register&name=RB09&mode=wg&secret=curto')$(q "SELECT COUNT(*) FROM nas WHERE shortname='RB09'")" "setup.php?name=RB09&mode=wg0"
ok "cadastrar: vai à etapa 4" "$(ploc 'setup.php?name=RB09&mode=wg&step=3' setup.php "action=register&name=RB09&mode=wg&secret=$SEC&ip=203.0.113.9")" "setup.php?name=RB09&mode=wg&step=4"
ok "  nas gravado com o IP DO TÚNEL (ignora o ip do formulário)" "$(q "SELECT nasname FROM nas WHERE shortname='RB09'")" 10.99.0.2
ok "  arquivo clients.d criado" "$(grep -c 'ipaddr = 10.99.0.2' "$T_DIR/raddb/clients.d/RB09.conf")" 1
ok "  auditoria sem o segredo" "$(q "SELECT COUNT(*) FROM panel_audit WHERE detail LIKE '%$SEC%'")" 0
ok "  cadastrar de novo: recusa" "$(ploc 'setup.php?name=RB09&mode=wg&step=3' setup.php "action=register&name=RB09&mode=wg&secret=$SEC")" "setup.php?name=RB09&mode=wg"

# ---------- etapa 4: aplicar
ok "etapa 5 por URL antes de aplicar: volta à etapa 4" "$(gloc 'setup.php?name=RB09&mode=wg&step=5')" "setup.php?name=RB09&mode=wg&step=4"
B=$(page 'setup.php?name=RB09&mode=wg&step=4')
ok "etapa 4: arquivo gravado, ainda não aplicado" "$(echo "$B" | grep -c 'gravado')$(echo "$B" | grep -c 'ainda não')" 11
: >"$T_DIR/restart.log"
ok "aplicar: volta à etapa 4" "$(ploc 'setup.php?name=RB09&mode=wg&step=4' setup.php 'action=apply&name=RB09&mode=wg')" "setup.php?name=RB09&mode=wg&step=4"
ok "  helper de reinício chamado 1x" "$(wc -l <"$T_DIR/restart.log")" 1
ok "  auditoria nas.apply" "$(q "SELECT COUNT(*) FROM panel_audit WHERE action='nas.apply'")" 1
B=$(page 'setup.php?name=RB09&mode=wg&step=4')
ok "  agora 'feito' e com Continuar" "$(echo "$B" | grep -c 'tag good">feito')$(echo "$B" | grep -c '>Continuar<')" 11

# ---------- etapa 5: script do RADIUS
B=$(page 'setup.php?name=RB09&mode=wg&step=5')
ok "etapa 5: script via túnel (10.99.0.1) com src-address e segredo" "$(echo "$B" | grep -c "address=10.99.0.1 src-address=10.99.0.2 secret=&quot;$SEC&quot;")" 1
ok "  copiável" "$(echo "$B" | grep -c '<pre data-copy>')" 1
ok "  /radius incoming" "$(echo "$B" | grep -c 'radius incoming set accept=yes port=3799')" 1

# ---------- etapa 6: ativação
B=$(page 'setup.php?name=RB09&mode=wg&step=6')
ok "etapa 6: aguardando primeira sessão" "$(echo "$B" | grep -c 'aguardando')$(echo "$B" | grep -c 'equipamento ativo')" 10
ok "  sem o segredo na página" "$(echo "$B" | grep -c "$SEC")" 0
ok "  lista mostra etapa 5 de 6" "$(page setup.php | grep -c 'etapa 5 de 6')" 1
mariadb -S "$T_SOCK" radius -e "INSERT INTO radacct (acctsessionid, acctuniqueid, username, nasipaddress, acctstarttime, acctupdatetime) VALUES ('s1','u-setup','teste','10.99.0.2',NOW(),NOW())"
B=$(page 'setup.php?name=RB09&mode=wg&step=6')
ok "com sessão do IP do roteador: equipamento ativo" "$(echo "$B" | grep -c 'tag good">equipamento ativo')" 1
ok "  lista mostra 'ativo'" "$(page setup.php | grep -c 'tag good">ativo')" 1
mariadb -S "$T_SOCK" radius -e "DELETE FROM radacct WHERE acctuniqueid='u-setup'; INSERT INTO radacct (acctsessionid, acctuniqueid, username, nasipaddress, acctstarttime, acctupdatetime) VALUES ('s2','u-outro','teste','198.51.100.77',NOW(),NOW())"
ok "sessão de OUTRO IP não ativa" "$(page 'setup.php?name=RB09&mode=wg&step=6' | grep -c 'tag good">equipamento ativo')" 0

# ---------- IP fixo
ok "start fixed: vai à etapa 3" "$(ploc setup.php setup.php 'action=start&name=FX1&mode=fixed')" "setup.php?name=FX1&mode=fixed&step=3"
ok "  etapa 1 por URL no modo fixo: mostra a etapa 3" "$(page 'setup.php?name=FX1&mode=fixed&step=1' | grep -c '3. Cadastrar o equipamento')" 1
B=$(page 'setup.php?name=FX1&mode=fixed&step=3')
ok "  barra sem etapa de túnel e com campo de IP público" "$(echo "$B" | grep -c '1. Túnel')$(echo "$B" | grep -c 'name="ip" required')" 01
ok "  IP da rede do túnel recusado no modo fixo" "$(ploc setup.php setup.php 'action=register&name=FX1&mode=fixed&ip=10.99.0.50&secret=SegredoFixo123456')$(q "SELECT COUNT(*) FROM nas WHERE shortname='FX1'")" "setup.php?name=FX1&mode=fixed0"
ok "  IP inválido/rede larga recusado" "$(ploc setup.php setup.php 'action=register&name=FX1&mode=fixed&ip=0.0.0.0%2F0&secret=SegredoFixo123456')$(q "SELECT COUNT(*) FROM nas WHERE shortname='FX1'")" "setup.php?name=FX1&mode=fixed0"
ok "  cadastrar com IP público" "$(ploc setup.php setup.php 'action=register&name=FX1&mode=fixed&ip=203.0.113.50&secret=SegredoFixo123456')" "setup.php?name=FX1&mode=fixed&step=4"
ok "  peer inexistente: ação peer recusada" "$(ploc setup.php setup.php "action=peer&name=FX1&mode=fixed&pubkey=$(enc "$K2")")" "setup.php?name=FX1&mode=fixed"
ploc setup.php setup.php 'action=apply&name=FX1&mode=fixed' >/dev/null
B=$(page 'setup.php?name=FX1&mode=fixed&step=5')
ok "  script do RADIUS com o IP público do servidor e sem src-address" "$(echo "$B" | grep -c 'address=150.230.64.46 secret=')$(echo "$B" | grep '^/radius add' | grep -c 'src-address')" 10
ok "  lista mostra 2 equipamentos" "$(page setup.php | grep -c '<td>RB09</td>\|<td>FX1</td>')" 2

# ---------- robustez
ok "ação desconhecida volta com aviso" "$(ploc setup.php setup.php 'action=zzz&name=FX1&mode=fixed')" "setup.php?name=FX1&mode=fixed"
ok "ação sem nome: recusa" "$(ploc setup.php setup.php 'action=apply')" "setup.php?mode=wg"
ok "step fora da faixa cai na etapa certa" "$(gloc 'setup.php?name=RB09&mode=wg&step=99')$(code tadmin 'setup.php?name=RB09&mode=wg&step=abc')" "200"
ok "sem erro PHP nos logs" "$(grep -ci 'fatal\|warning\|notice\|deprecated' "$T_DIR/php.log")" 0
ok "segredos nunca em log do PHP" "$(grep -c "$SEC\|SegredoFixo" "$T_DIR/php.log")" 0

# ---------- IP público do servidor vazio: aviso claro com a solução
cp "$T_DIR/config.php" "$T_DIR/config.php.bak"
sed -i "s#'server_ip' => '[^']*'#'server_ip' => ''#" "$T_DIR/config.php"
sleep 3
B=$(page 'setup.php?name=RB09&mode=wg&step=2')
ok "server_ip vazio: etapa 2 avisa e explica o que fazer" "$(echo "$B" | grep -c 'IP público do servidor')$(echo "$B" | grep -c 'update.sh')" 11
mv "$T_DIR/config.php.bak" "$T_DIR/config.php"; touch "$T_DIR/config.php"   # mtime novo: o opcache compara em segundos
sleep 3
B=$(page 'setup.php?name=RB09&mode=wg&step=2')
ok "server_ip preenchido: sem o aviso" "$(echo "$B" | grep -c 'falta configurar')" 0

# ---------- helper de WireGuard quebrado: a lista ainda abre e a etapa mostra o erro sem vazar caminho
sed -i "s#'wg_helper' => '[^']*'#'wg_helper' => '/nao/existe'#" "$T_DIR/config.php"
sleep 3
ok "helper ausente: início ainda abre (200)" "$(code tadmin setup.php)" 200
B=$(page 'setup.php?name=FX1&mode=fixed&step=3')
ok "  sem caminho/stack vazado" "$(echo "$B" | grep -c '/nao/existe\|Stack trace')" 0
sed -i "s#'wg_helper' => '[^']*'#'wg_helper' => '$H'#" "$T_DIR/config.php"
sleep 3

# ---------- navegador real: percurso completo
out=$(T_SOCK="$T_SOCK" HS_FILE="$HS" node tests/setup_browser.js "$T_WEB" tadmin "$T_PASS" 2>&1); rc=$?
echo "$out" | grep -E '^(FALHA|OK)' | sed 's/^OK /PASS navegador: /;s/^FALHA /FAIL navegador: /'
if [ $rc -eq 2 ]; then echo "AVISO: Playwright/Chromium indisponível; percurso NÃO testado no navegador"; else ok "navegador real: percurso do assistente (rc)" "$rc" 0; fi
summary
