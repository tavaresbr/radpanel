#!/usr/bin/env bash
# Ambiente de teste isolado do RadPanel (MariaDB temporário + servidor web embutido do PHP).
#
#   source tests/harness.sh
#   env_up NOME DBPORT WEBPORT     # cria tudo; exporta T_DIR, T_SOCK, T_WEB, RADPANEL_CONFIG
#   ... testes com curl / php / mariadb ...
#   env_down NOME                  # para só os processos desta instância e apaga o diretório
#
# Cada agente usa NOME/portas próprios (ex.: vouchers 3410 8410) para não colidir.
# Usuários criados: tadmin / toper / tview, senha TestSenha1234 (papéis admin/operator/viewer).
# Nunca use "pkill -f": o padrão casa com o próprio shell. Aqui desligamos por pid.

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_SCHEMA="${FORK_SCHEMA:-/home/user/freeradius-server/raddb/mods-config/sql/main/mysql/schema.sql}"
T_PASS='TestSenha1234'

env_up() {
  local name=$1 dbport=$2 webport=$3
  T_DIR="/tmp/claude-0/radpanel-test-$name"
  T_SOCK="$T_DIR/mysql.sock"
  T_WEB="http://127.0.0.1:$webport"
  export T_DIR T_SOCK T_WEB T_DBPORT=$dbport T_WEBPORT=$webport
  rm -rf "$T_DIR"; mkdir -p "$T_DIR/data" "$T_DIR/tmp"
  mariadb-install-db --user=root --datadir="$T_DIR/data" --tmpdir="$T_DIR/tmp" --auth-root-authentication-method=normal \
    >"$T_DIR/install-db.log" 2>&1 || { echo "falha no install-db"; return 1; }
  mariadbd --user=root --datadir="$T_DIR/data" --tmpdir="$T_DIR/tmp" --socket="$T_SOCK" --port="$dbport" \
    --bind-address=127.0.0.1 --pid-file="$T_DIR/mysql.pid" </dev/null >"$T_DIR/mariadb.log" 2>&1 &
  echo $! >"$T_DIR/mysql.shpid"
  local i; for i in $(seq 1 40); do mariadb -S "$T_SOCK" -e 'select 1' >/dev/null 2>&1 && break; sleep 0.5; done
  mariadb -S "$T_SOCK" -e 'select 1' >/dev/null 2>&1 || { echo "mariadb não subiu"; return 1; }

  mariadb -S "$T_SOCK" -e "CREATE DATABASE radius CHARACTER SET utf8mb4;"
  mariadb -S "$T_SOCK" radius <"$FORK_SCHEMA"
  local f
  for f in "$HARNESS_ROOT"/sql/*.sql; do
    case "$(basename "$f")" in grants.*) continue;; esac
    mariadb -S "$T_SOCK" radius <"$f" || { echo "erro em $f"; return 1; }
  done
  mariadb -S "$T_SOCK" -e "CREATE USER 'radpanel'@'127.0.0.1' IDENTIFIED BY 'testdbpass';"
  for f in "$HARNESS_ROOT"/sql/grants.*.sql; do
    sed "s/{{DB_NAME}}/radius/g; s/{{DB_USER}}/radpanel/g; s/'localhost'/'127.0.0.1'/g" "$f" | mariadb -S "$T_SOCK" \
      || { echo "erro em $f"; return 1; }
  done

  cat >"$T_DIR/config.php" <<PHP
<?php return [
  'db_host' => '127.0.0.1', 'db_port' => $dbport, 'db_name' => 'radius',
  'db_user' => 'radpanel', 'db_pass' => 'testdbpass',
  'timezone' => 'America/Sao_Paulo',
  'radius_etc' => '$T_DIR/raddb',
  'radclient' => '$T_DIR/fake-radclient',
  'server_ip' => '150.230.64.46',
  'restart_helper' => '$T_DIR/no-such-helper',
];
PHP
  export RADPANEL_CONFIG="$T_DIR/config.php"
  mkdir -p "$T_DIR/raddb/clients.d"

  local r
  for r in "tadmin admin" "toper operator" "tview viewer"; do
    set -- $r
    local hash; hash=$(php -r 'echo password_hash($argv[1], PASSWORD_ARGON2ID);' "$T_PASS")
    mariadb -S "$T_SOCK" radius -e "INSERT INTO panel_admins (username, pass_hash, role) VALUES ('$1', '$hash', '$2');"
  done

  (cd "$HARNESS_ROOT/public" && RADPANEL_CONFIG="$RADPANEL_CONFIG" exec php -S "127.0.0.1:$webport" \
     </dev/null >"$T_DIR/php.log" 2>&1) &
  echo $! >"$T_DIR/php.shpid"
  for i in $(seq 1 20); do curl -s -o /dev/null "$T_WEB/login.php" && break; sleep 0.3; done
  echo "ambiente $name pronto: web=$T_WEB sock=$T_SOCK"
}

env_down() {
  local name=$1
  local d="/tmp/claude-0/radpanel-test-$name" p f
  for f in php.shpid mysql.pid mysql.shpid; do
    [ -f "$d/$f" ] && { p=$(cat "$d/$f"); kill "$p" 2>/dev/null; }
  done
  sleep 2
  rm -rf "${d:?}"
}

# SQL rápido: q "SELECT ..."
q() { mariadb -S "$T_SOCK" radius -N -e "$1"; }

# Login por papel -> jar de cookies em $T_DIR/jar-ROLE ; uso: t_login tadmin
t_login() {
  local u=$1 jar="$T_DIR/jar-$1" tok
  rm -f "$jar"
  tok=$(curl -s -c "$jar" "$T_WEB/login.php" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//')
  curl -s -b "$jar" -c "$jar" -o /dev/null -d "csrf=$tok&user=$u&pass=$T_PASS" "$T_WEB/login.php"
}

# Token CSRF da sessão: t_tok JAR PAGINA
t_tok() { curl -s -b "$T_DIR/jar-$1" -c "$T_DIR/jar-$1" "$T_WEB/$2" | grep -o 'name="csrf" value="[a-f0-9]*"' | head -1 | sed 's/.*value="//;s/"//'; }

# POST com CSRF: t_post USUARIO PAGINA_QUE_TEM_O_TOKEN PAGINA_DESTINO 'campo=valor&...'  -> imprime o status HTTP
t_post() {
  local tok; tok=$(t_tok "$1" "$2")
  curl -s -b "$T_DIR/jar-$1" -c "$T_DIR/jar-$1" -o "$T_DIR/last.html" -w '%{http_code}' -d "csrf=$tok&$4" "$T_WEB/$3"
}

# GET autenticado: t_get USUARIO PAGINA  -> corpo
t_get() { curl -s -b "$T_DIR/jar-$1" -c "$T_DIR/jar-$1" "$T_WEB/$2"; }

# Contador simples de resultados
PASS_N=0; FAIL_N=0
ok() { # descricao obtido esperado
  if [ "$2" = "$3" ]; then PASS_N=$((PASS_N+1)); echo "PASS $1"; else FAIL_N=$((FAIL_N+1)); echo "FAIL $1 (obtido '$2', esperado '$3')"; fi
}
summary() { echo "== $PASS_N passaram, $FAIL_N falharam"; [ "$FAIL_N" -eq 0 ]; }
