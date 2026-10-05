#!/usr/bin/env bash
# Ambiente de teste do radiusd (FreeRADIUS 4.0 compilado em /tmp/claude-0/fr-install) ligado ao MariaDB do harness.
#
#   source tests/harness.sh; source tests/fr_env.sh
#   env_up NOME DBPORT WEBPORT          # MariaDB (tcp 127.0.0.1:DBPORT) + painel
#   fr_up NOME DBPORT AUTHPORT          # radiusd: auth AUTHPORT, acct AUTHPORT+1 (udp, 127.0.0.1)
#   $FR_RADCLIENT ...                   # ver fr_auth / fr_acct abaixo
#   fr_down NOME
#
# Exporta: FR_RADCLIENT FR_AUTHPORT FR_ACCTPORT FR_RADDB FR_LOG FR_DIR FR_SECRET
# O banco 'radius' e o usuário 'radpanel'/'testdbpass' vêm do env_up do harness.
# Nunca usa "pkill -f": mata só pelo pid gravado.

FR_INSTALL="${FR_INSTALL:-/tmp/claude-0/fr-install}"
FR_SECRET=testing123

fr_up() {
  local name=$1 sqlport=$2 authport=$3
  local acctport=$((authport + 1))
  FR_DIR="/tmp/claude-0/fr-test-$name"
  FR_RADDB="$FR_DIR/raddb"
  FR_LOG="$FR_DIR/radiusd.log"
  FR_AUTHPORT=$authport FR_ACCTPORT=$acctport
  FR_RADCLIENT="$FR_INSTALL/bin/radclient"
  export FR_DIR FR_RADDB FR_LOG FR_AUTHPORT FR_ACCTPORT FR_RADCLIENT FR_SECRET FR_INSTALL

  [ -x "$FR_INSTALL/sbin/radiusd" ] || { echo "radiusd não instalado em $FR_INSTALL"; return 1; }
  [ "$authport" = 1812 ] || [ "$authport" = 1813 ] && { echo "porta padrão proibida"; return 1; }
  rm -rf "$FR_DIR"; mkdir -p "$FR_DIR/var/log/radius/radacct" "$FR_DIR/var/run" "$FR_DIR/var/lib"
  cp -a "$FR_INSTALL/etc/raddb" "$FR_RADDB"
  local r="$FR_RADDB"

  # radiusd.conf: tudo (confdir, logs, pid) dentro do diretório de teste
  sed -i "s|^confdir = .*|confdir = $r|; s|^localstatedir = .*|localstatedir = $FR_DIR/var|" "$r/radiusd.conf"

  # Usuário de banco do radiusd. O 'radpanel' do harness tem grants mínimos (sem INSERT em radacct/radpostauth etc.),
  # como em produção o radiusd usa um usuário próprio. Mesma senha. Requer $T_SOCK (env_up).
  if [ -n "${T_SOCK:-}" ]; then
    mariadb -S "$T_SOCK" -e "CREATE USER IF NOT EXISTS 'radiusd'@'127.0.0.1' IDENTIFIED BY 'testdbpass';
      CREATE USER IF NOT EXISTS 'radiusd'@'localhost' IDENTIFIED BY 'testdbpass';
      GRANT SELECT,INSERT,UPDATE,DELETE ON radius.* TO 'radiusd'@'127.0.0.1';
      GRANT SELECT,INSERT,UPDATE,DELETE ON radius.* TO 'radiusd'@'localhost';" || return 1
  fi
  # módulo sql -> MariaDB do harness
  sed -i -e 's|dialect = "sqlite"|dialect = "mysql"|' \
         -e "s|^##\tserver = .*|\tserver = \"127.0.0.1\"|" \
         -e "s|^##\tport = .*|\tport = $sqlport|" \
         -e 's|^##\tlogin = .*|\tlogin = "radiusd"|' \
         -e 's|^##\tpassword = .*|\tpassword = "testdbpass"|' "$r/mods-available/sql"
  ln -sf ../mods-available/sql "$r/mods-enabled/sql"
  # sqlcounter fica disponível (instâncias em mods-available/sqlcounter), não habilitado por padrão.

  # portas alternativas (auth/acct); somente loopback
  sed -i -e "s|port = 1812|port = $authport|g" -e "s|port = 1813|port = $acctport|g" \
         -e 's|ipaddr = \*|ipaddr = 127.0.0.1|g' "$r/sites-available/default"
  # cliente de teste (secret testing123 em 127.0.0.1) já existe em clients.conf; troca o segredo p/ garantir
  sed -i "0,/secret = testing123/s//secret = $FR_SECRET/" "$r/clients.conf"

  # EAP/inner-tunnel/proxy: não são necessários; evita exigir certificados.
  rm -f "$r/sites-enabled/inner-tunnel" "$r/sites-enabled/proxy" "$r/mods-enabled/eap" "$r/mods-enabled/eap_inner" \
        "$r/mods-enabled/cache_eap"
  # a política 'default' referencia o módulo eap em recv Access-Request/send/authenticate: tira as linhas.
  python3 - "$r/sites-available/default" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# recv Access-Request: bloco "eap { ... }"
s = re.sub(r'\n\teap \{\n\t\tok = return\n\t\tupdated = return\n\t\}\n', '\n', s)
# authenticate eap { eap }
s = re.sub(r'\nauthenticate eap \{\n\teap\n\}\n', '\n', s)
# linhas soltas "eap" (send Access-Accept / Access-Reject)
s = re.sub(r'(?m)^\teap\n', '', s)
open(p, 'w').write(s)
PY

  if ! "$FR_INSTALL/sbin/radiusd" -C -d "$r" -l "$FR_DIR/check.log" >"$FR_DIR/check.out" 2>&1; then
    echo "configuração inválida (veja $FR_DIR/check.out e check.log)"; tail -20 "$FR_DIR/check.out" "$FR_DIR/check.log"; return 1
  fi

  _fr_start || return 1
}

# (re)inicia o radiusd com o raddb já preparado em $FR_RADDB (usado por fr_up e por fr_restart)
_fr_start() {
  local r="$FR_RADDB" i
  # FR_PATCHED=1: usa a libfreeradius-util.so corrigida (data em itens de check do SQL; ver FR_FINDINGS.md)
  local ld="${LD_LIBRARY_PATH:-}"
  [ "${FR_PATCHED:-0}" = 1 ] && ld="${FR_PATCHED_LIB:-/tmp/claude-0/fr-patched-lib}${ld:+:$ld}"
  LD_LIBRARY_PATH="$ld" "$FR_INSTALL/sbin/radiusd" -f -P -xx -d "$r" -l "$FR_LOG" </dev/null >"$FR_DIR/stdout.log" 2>&1 &
  echo $! >"$FR_DIR/radiusd.shpid"
  for i in $(seq 1 40); do
    if echo "Message-Authenticator = 0x00" | "$FR_RADCLIENT" -t 1 -r 1 -x "127.0.0.1:$FR_AUTHPORT" status "$FR_SECRET" >/dev/null 2>&1; then
      echo "radiusd pronto: auth=$FR_AUTHPORT acct=$FR_ACCTPORT log=$FR_LOG"; return 0
    fi
    kill -0 "$(cat "$FR_DIR/radiusd.shpid")" 2>/dev/null || { echo "radiusd morreu"; tail -30 "$FR_LOG" "$FR_DIR/stdout.log"; return 1; }
    sleep 0.5
  done
  echo "radiusd não respondeu ao Status-Server"; tail -30 "$FR_LOG" "$FR_DIR/stdout.log"; return 1
}

# fr_restart: para o radiusd (por pid) e sobe de novo com o raddb atual (após editar $FR_RADDB)
fr_restart() {
  local p; p=$(cat "$FR_DIR/radiusd.shpid"); kill "$p" 2>/dev/null
  local i; for i in 1 2 3 4 5 6 7 8; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  _fr_start
}

fr_down() {
  local name=$1
  local d="/tmp/claude-0/fr-test-$name" p
  if [ -f "$d/radiusd.shpid" ]; then
    p=$(cat "$d/radiusd.shpid"); kill "$p" 2>/dev/null
    local i; for i in 1 2 3 4 5 6 7 8; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  fi
  [ -n "${FR_KEEP:-}" ] || rm -rf "${d:?}"
}

# Access-Request PAP: fr_auth USUARIO SENHA [atributos extras ...]  -> imprime a saída completa do radclient
fr_auth() {
  local u=$1 p=$2; shift 2
  { printf 'User-Name = "%s"\nUser-Password = "%s"\n' "$u" "$p"; local a; for a in "$@"; do printf '%s\n' "$a"; done; } \
    | "$FR_RADCLIENT" -x -t 3 -r 1 "127.0.0.1:$FR_AUTHPORT" auth "$FR_SECRET" 2>&1
}
# só o código: Access-Accept / Access-Reject / (vazio)
fr_code() { fr_auth "$@" | grep -oE 'Received (Access-Accept|Access-Reject|Access-Challenge)' | head -1 | sed 's/Received //'; }

# Accounting: fr_acct TIPO USUARIO SESSAO [atributos extras ...]   (TIPO Start|Interim-Update|Stop)
fr_acct() {
  local t=$1 u=$2 s=$3; shift 3
  { printf 'Acct-Status-Type = %s\nUser-Name = "%s"\nAcct-Session-Id = "%s"\nNAS-IP-Address = 127.0.0.1\nNAS-Port = 1\n' "$t" "$u" "$s"
    local a; for a in "$@"; do printf '%s\n' "$a"; done; } \
    | "$FR_RADCLIENT" -x -t 3 -r 1 "127.0.0.1:$FR_ACCTPORT" acct "$FR_SECRET" 2>&1
}
