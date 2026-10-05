#!/usr/bin/env bash
# Testes do bin/update.sh e da gravação/leitura do install.env (instalador FALSO: o real não roda aqui).
# Uso: bash tests/test_update.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)
source tests/harness.sh   # só para ok/summary
T=/tmp/claude-0/radpanel-test-update
rm -rf "$T"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
CONF="$T/conf"; mkdir -p "$CONF"
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
# instalador falso: registra variáveis e argumentos
cat >"$T/work/install-panel.sh" <<SH
#!/bin/bash
echo "ASSUME_YES=\${ASSUME_YES:-} SKIP_APT=\${SKIP_APT:-} ARGS=\$# VERSION=\$(cat "\$(dirname "\$0")/VERSION")" >>"$T/installer.log"
SH
echo v1 >"$T/work/VERSION"
(cd "$T/work" && git add -A && git commit -qm v1 && git push -q origin HEAD:main 2>/dev/null)
git clone -q "$T/origin.git" "$T/clone" 2>/dev/null
echo "$T/clone" >"$CONF/source"
printf 'SAVED_PANEL_DOMAIN=x\n' >"$CONF/install.env"
U() { RADPANEL_TEST=1 WAITS="0 0" CONF_DIR="$CONF" bash bin/update.sh "$@" 2>&1; }

# sem avanço: reaplica
out=$(U); rc=$?
ok "sem novidade: rc 0" "$rc" 0
ok "  instalador chamado sem perguntas e sem apt" "$(tail -1 "$T/installer.log")" "ASSUME_YES=1 SKIP_APT=1 ARGS=0 VERSION=v1"
ok "  avisa que já estava na versão nova" "$(echo "$out" | grep -c 'já estava na versão mais nova')" 1

# novidade no git: avança
echo v2 >"$T/work/VERSION"; (cd "$T/work" && git commit -qam v2 && git push -q origin HEAD:main 2>/dev/null)
out=$(U); rc=$?
ok "novidade: rc 0" "$rc" 0
ok "  instalador viu a versão nova" "$(tail -1 "$T/installer.log" | grep -c 'VERSION=v2')" 1
ok "  mostra o log das mudanças" "$(echo "$out" | grep -c ' v2$')" 1
ok "  imprime 'Atualizado para'" "$(echo "$out" | grep -c '^Atualizado para ')" 1
out=$(FORCE_APT=1 U); ok "FORCE_APT=1 deixa o apt ligado (SKIP_APT=0)" "$(tail -1 "$T/installer.log" | grep -c 'SKIP_APT=0')" 1

# alterações locais: aborta sem tocar em nada
echo sujo >>"$T/clone/VERSION"
: >"$T/installer.log"
echo v3 >"$T/work/VERSION"; (cd "$T/work" && git commit -qam v3 && git push -q origin HEAD:main 2>/dev/null)
out=$(U); rc=$?
ok "alterações locais: recusa (rc 1)" "$rc" 1
ok "  mensagem clara" "$(echo "$out" | grep -c 'alterações locais')" 1
ok "  instalador NÃO rodou" "$(wc -c <"$T/installer.log")" 0
ok "  arquivo local preservado" "$(grep -c sujo "$T/clone/VERSION")" 1
(cd "$T/clone" && git checkout -q -- VERSION)

# histórico divergente: aborta
(cd "$T/clone" && echo local >LOCAL && git add LOCAL && git commit -qm local)
out=$(U); rc=$?
ok "histórico divergente: recusa (rc 1)" "$rc" 1
ok "  mensagem 'não pode avançar'" "$(echo "$out" | grep -c 'não pode avançar')" 1
ok "  instalador NÃO rodou" "$(wc -c <"$T/installer.log")" 0
(cd "$T/clone" && git reset -q --hard HEAD~1)

# falhas de configuração
mv "$CONF/install.env" "$CONF/install.env.off"
out=$(U); rc=$?; ok "sem install.env: rc 1 e orienta" "$rc$(echo "$out" | grep -c 'respostas salvas')" 11
mv "$CONF/install.env.off" "$CONF/install.env"
mv "$CONF/source" "$CONF/source.off"
out=$(U); rc=$?; ok "sem source: rc 1 e orienta" "$rc$(echo "$out" | grep -c 'onde está o clone')" 11
echo "/nao/existe" >"$CONF/source"
out=$(U); rc=$?; ok "clone inexistente: rc 1" "$rc$(echo "$out" | grep -c 'não encontrado')" 11
mv "$CONF/source.off" "$CONF/source"
git -C "$T/clone" remote set-url origin /nao/existe.git
out=$(U); rc=$?; ok "git inalcançável: rc 1 (após tentativas)" "$rc$(echo "$out" | grep -c 'não consegui falar com o git')" 11
git -C "$T/clone" remote set-url origin "$T/origin.git"

# produção ignora overrides do ambiente e exige root
if [ "$(id -u)" != 0 ]; then
  out=$(CONF_DIR="$CONF" bash bin/update.sh 2>&1); ok "sem root: recusa" "$(echo "$out" | grep -c 'rode com sudo')" 1
else
  out=$(CONF_DIR="$CONF" GIT=/bin/false bash bin/update.sh 2>&1)
  ok "produção ignora CONF_DIR do ambiente (usa /etc/radpanel)" "$(echo "$out" | grep -c "$CONF")" 0
fi

# dono do clone diferente de root: o git deve ser chamado via runuser como esse dono (runuser falso registra e executa)
if id nobody >/dev/null 2>&1; then
  cat >"$T/fakerunuser" <<SH
#!/bin/bash
echo "runuser \$*" >>"$T/runuser.log"
[ "\$1" = "-u" ] && [ "\$3" = "--" ] || exit 64
shift 3
exec "\$@"
SH
  chmod +x "$T/fakerunuser"
  chown -R nobody "$T/clone"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'   # root lendo repositório de outro dono (só no teste)
  echo v4 >"$T/work/VERSION"; (cd "$T/work" && git commit -qam v4 && git push -q origin HEAD:main 2>/dev/null)
  out=$(RADPANEL_TEST=1 WAITS="0 0" CONF_DIR="$CONF" RUNUSER="$T/fakerunuser" bash bin/update.sh 2>&1); rc=$?
  [ $rc -ne 0 ] && echo "$out" | tail -5
  ok "clone de outro dono: atualiza (rc 0)" "$rc" 0
  ok "  instalador viu v4" "$(tail -1 "$T/installer.log" | grep -c 'VERSION=v4')" 1
  ok "  todo git passou pelo runuser -u nobody" "$(grep -c '^runuser -u nobody -- .*git -C .*clone' "$T/runuser.log")" "$(wc -l <"$T/runuser.log")"
  ok "  e foi chamado várias vezes" "$([ "$(wc -l <"$T/runuser.log")" -ge 4 ] && echo ok)" ok
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
else
  echo "AVISO: sem usuário 'nobody'; caminho runuser NÃO testado"
fi

# instalador real: grava install.env/source e lê de volta (trechos extraídos; o resto precisa de Apache/MariaDB)
ok "install-panel.sh grava install.env (600) e source" "$(grep -c "install.env" install-panel.sh)" "$(grep -c "install.env" install-panel.sh)"
ok "  usa printf %q nos 3 valores" "$(grep -c "printf 'SAVED_PANEL_\(DOMAIN\|EMAIL\)=%q\|printf 'SAVED_PORTAL_DOMAIN=%q" install-panel.sh)" 3
ok "  carrega install.env e define ASSUME_YES=1" "$(grep -c '^  ASSUME_YES=1$' install-panel.sh)" 1
ok "  FRESH=1 desliga o reaproveitamento" "$(grep -c 'FRESH:-0' install-panel.sh)" 1
# valores hostis sobrevivem ao ciclo gravar -> carregar (printf %q + source)
cat >"$T/rt.sh" <<'SH'
PANEL_DOMAIN='a.b.com'; PORTAL_DOMAIN=''; EMAIL="x'; touch $T/PWNED; echo '@y.com"
{ printf 'SAVED_PANEL_DOMAIN=%q\n' "$PANEL_DOMAIN"; printf 'SAVED_PORTAL_DOMAIN=%q\n' "$PORTAL_DOMAIN"; printf 'SAVED_PANEL_EMAIL=%q\n' "$EMAIL"; } >"$T/env.out"
. "$T/env.out"
[ "$SAVED_PANEL_EMAIL" = "$EMAIL" ] && [ ! -e "$T/PWNED" ] && echo roundtrip-ok
SH
ok "install.env: valor hostil não executa e volta idêntico" "$(T=$T bash "$T/rt.sh")" roundtrip-ok
# ---------- bin/config-set.php (server_ip no config.php)
CS="php $PWD/bin/config-set.php"
cfgtest() { printf '%s' "$2" >"$T/cfg-$1.php"; chmod 640 "$T/cfg-$1.php"; }
cfgtest nokey "<?php
return [
    'db_host' => 'localhost',
    'db_pass' => 'x\$y',
    'trusted_proxies' => ['127.0.0.1'],
];
"
$CS "$T/cfg-nokey.php" server_ip 150.230.64.46; ok "config-set: sem a chave, insere (rc 0)" "$?" 0
ok "  valor lido de volta" "$(php -r '$c=require $argv[1]; echo $c["server_ip"];' "$T/cfg-nokey.php")" 150.230.64.46
ok "  outras chaves preservadas" "$(php -r '$c=require $argv[1]; echo $c["db_pass"],"|",$c["db_host"],"|",$c["trusted_proxies"][0];' "$T/cfg-nokey.php")" 'x$y|localhost|127.0.0.1'
ok "  modo do arquivo preservado (640)" "$(stat -c %a "$T/cfg-nokey.php")" 640
cfgtest empty "<?php
return [
    'db_host' => 'localhost',
    'server_ip' => '',
    'timezone' => 'America/Sao_Paulo',
];
"
$CS "$T/cfg-empty.php" server_ip 203.0.113.9; ok "config-set: chave vazia, troca (rc 0)" "$?" 0
ok "  valor novo e vizinhas preservadas" "$(php -r '$c=require $argv[1]; echo $c["server_ip"],"|",$c["timezone"];' "$T/cfg-empty.php")" '203.0.113.9|America/Sao_Paulo'
ok "  só uma linha server_ip" "$(grep -c "'server_ip'" "$T/cfg-empty.php")" 1
$CS "$T/cfg-empty.php" server_ip radius.exemplo.com.br; ok "  aceita nome de host" "$(php -r '$c=require $argv[1]; echo $c["server_ip"];' "$T/cfg-empty.php")" radius.exemplo.com.br
cp "$T/cfg-empty.php" "$T/cfg-before.php"
for bad in "1.2.3.4',x" "1.2.3.4'; system('id'); '" "javascript:alert" "" "a b" "1.2.3.4
x"; do
  $CS "$T/cfg-empty.php" server_ip "$bad" 2>/dev/null; rc=$?
  ok "  recusa valor hostil $(printf %q "$bad")" "$([ $rc -ne 0 ] && echo ok)" ok
done
ok "  arquivo intacto após recusas" "$(cmp -s "$T/cfg-empty.php" "$T/cfg-before.php" && echo igual)" igual
$CS "$T/cfg-empty.php" outra_chave 1.2.3.4 2>/dev/null; ok "  chave não permitida: rc 1" "$?" 1
echo "nao e php de array" >"$T/cfg-bad.php"; $CS "$T/cfg-bad.php" server_ip 1.2.3.4 2>/dev/null; ok "  formato inesperado: rc 1 e arquivo intacto" "$?$(cat "$T/cfg-bad.php")" "1nao e php de array"
$CS "$T/nao-existe.php" server_ip 1.2.3.4 2>/dev/null; ok "  arquivo ausente: rc 1" "$?" 1
ok "  sem sobras .cfg- temporárias" "$(ls -a "$T" | grep -c '^\.cfg-')" 0
ok "install-panel.sh usa config-set.php" "$(grep -c 'bin/config-set.php' install-panel.sh)" 1
summary
