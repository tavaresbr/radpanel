#!/usr/bin/env bash
# Instala o backup diário do RadPanel (cron 03:17, root). Rode como root:  sudo bash bin/install-backup.sh
#
# O que faz:
#   - cria /var/backups/radpanel (root:GRUPO_WEB, 750; os arquivos de backup ficam 600 root, ilegíveis ao PHP;
#     o grupo só permite listar o diretório para a tela Ferramentas mostrar data/arquivo do último backup);
#   - cria /etc/radpanel/backup.cnf (modo 600) se não existir, com uma senha aleatória (nunca impressa);
#   - instala /etc/cron.d/radpanel-backup (todo dia 03:17, root);
#   - com --create-db-user cria/atualiza o usuário MySQL 'radpanel_backup'@'localhost' lendo a senha do .cnf.
#
# Privilégio mínimo do usuário de backup (MariaDB 10.x): SELECT, SHOW VIEW, TRIGGER em radius.* mais
# SELECT em mysql.proc (sem esta, --routines é ignorado em silêncio para rotinas de outro definidor).
# LOCK TABLES não é necessário com --single-transaction; EVENT só com --events (não usado); PROCESS não é usado.
#
# Variáveis: WEB_GROUP (padrão www-data), DB_NAME (radius), BACKUP_DIR, BACKUP_CNF, DESTDIR (prefixo p/ testes).
set -euo pipefail
umask 077

DESTDIR="${DESTDIR:-}"
WEB_GROUP="${WEB_GROUP:-www-data}"
DB_NAME="${DB_NAME:-radius}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/radpanel}"
BACKUP_CNF="${BACKUP_CNF:-/etc/radpanel/backup.cnf}"
CRON_FILE="/etc/cron.d/radpanel-backup"
DB_USER=radpanel_backup
CREATE_USER=0
[ "${1:-}" = "--create-db-user" ] && CREATE_USER=1

[[ "$DB_NAME" =~ ^[A-Za-z0-9_]{1,64}$ ]] || { echo "DB_NAME inválido" >&2; exit 1; }
[[ "$WEB_GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "WEB_GROUP inválido" >&2; exit 1; }
for v in BACKUP_DIR BACKUP_CNF; do
  [[ "${!v}" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "$v inválido" >&2; exit 1; }
done

if [ -z "$DESTDIR" ] && [ "$(id -u)" != "0" ]; then
  echo "Rode como root." >&2; exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/backup.sh"
[ -f "$script" ] || { echo "backup.sh não encontrado em $here" >&2; exit 1; }
if [ -z "$DESTDIR" ]; then
  # O cron roda como root: o script e o diretório não podem ser graváveis por outros (escalada de privilégio).
  for p in "$script" "$here"; do
    [ "$(stat -c '%u' "$p")" = "0" ] || { echo "$p precisa pertencer ao root." >&2; exit 1; }
    perm=$(stat -c '%a' "$p")
    [ $(( 8#$perm & 8#022 )) -eq 0 ] || { echo "$p não pode ser gravável por grupo/outros (modo $perm)." >&2; exit 1; }
  done
fi
chmod 755 "$script" 2>/dev/null || true

# Diretório de backup
install -d -m 750 "$DESTDIR$BACKUP_DIR"
if [ -z "$DESTDIR" ]; then
  if getent group "$WEB_GROUP" >/dev/null; then
    chown root:"$WEB_GROUP" "$BACKUP_DIR"
  else
    chown root:root "$BACKUP_DIR"
    echo "Aviso: grupo '$WEB_GROUP' não existe; a tela Ferramentas não conseguirá listar os backups." >&2
  fi
fi

# Credenciais
install -d -m 750 "$(dirname "$DESTDIR$BACKUP_CNF")"
if [ ! -e "$DESTDIR$BACKUP_CNF" ]; then
  pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
  ( umask 077; printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$pw" >"$DESTDIR$BACKUP_CNF" )
  unset pw
  chmod 600 "$DESTDIR$BACKUP_CNF"
  echo "Criado $BACKUP_CNF (modo 600, senha aleatória; não exibida)."
else
  chmod 600 "$DESTDIR$BACKUP_CNF"
  echo "Mantido $BACKUP_CNF existente."
fi

# Usuário MySQL (opcional; a senha vem do .cnf e passa por stdin, sem aparecer em argv nem na tela)
if [ "$CREATE_USER" = 1 ] && [ -z "$DESTDIR" ]; then
  pw=$(sed -n 's/^password=//p' "$BACKUP_CNF" | head -n1)
  [[ "$pw" =~ ^[A-Za-z0-9]{8,}$ ]] || { echo "Senha do .cnf em formato inesperado; crie o usuário manualmente." >&2; exit 1; }
  mariadb <<SQL
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$pw';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$pw';
GRANT SELECT, SHOW VIEW, TRIGGER ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
GRANT SELECT ON mysql.proc TO '$DB_USER'@'localhost';
SQL
  unset pw
  echo "Usuário MySQL '$DB_USER'@'localhost' criado/atualizado com SELECT, SHOW VIEW, TRIGGER em $DB_NAME e SELECT em mysql.proc."
else
  cat <<MSG
Crie o usuário MySQL de backup (como root do MariaDB), usando a senha que está em $BACKUP_CNF:

  CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '<senha do $BACKUP_CNF>';
  GRANT SELECT, SHOW VIEW, TRIGGER ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
  GRANT SELECT ON mysql.proc TO '$DB_USER'@'localhost';

Ou rode de novo com --create-db-user para fazer isso automaticamente.
MSG
fi

# Cron
install -d -m 755 "$(dirname "$DESTDIR$CRON_FILE")"
{
  echo "# RadPanel: backup diário do banco (gerado por install-backup.sh)"
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "17 3 * * * root BACKUP_DIR=$BACKUP_DIR BACKUP_CNF=$BACKUP_CNF DB_NAME=$DB_NAME $script >/dev/null 2>&1"
} >"$DESTDIR$CRON_FILE"
chmod 644 "$DESTDIR$CRON_FILE"
echo "Cron instalado em $CRON_FILE (03:17, root). Teste agora: sudo $script"
echo "Para a tela Ferramentas, o config.php pode definir 'backup_dir' => '$BACKUP_DIR'."
