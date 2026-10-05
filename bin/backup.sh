#!/usr/bin/env bash
# Backup diário do banco do RadPanel/FreeRADIUS (mysqldump --single-transaction --routines).
#
# Saída:   $BACKUP_DIR/radius-YYYYmmdd-HHMM.sql.gz  (modo 600; dono root quando rodado como root)
# Credenciais: arquivo [client] user/password em $BACKUP_CNF (modo 600). A senha nunca vai na linha de comando.
# Variáveis de ambiente (todas opcionais):
#   BACKUP_DIR   (padrão /var/backups/radpanel)     BACKUP_CNF  (padrão /etc/radpanel/backup.cnf)
#   DB_NAME      (padrão radius)                    KEEP        (padrão 14 arquivos)
#
# Privilégios mínimos do usuário MySQL de backup (ver install-backup.sh):
#   GRANT SELECT, SHOW VIEW, TRIGGER ON radius.*  +  GRANT SELECT ON mysql.proc (MariaDB; sem isso as rotinas
#   de outro definidor não saem no dump, sem erro) — suficiente para --single-transaction --routines
#   (LOCK TABLES só seria necessário sem --single-transaction; EVENT só com --events; PROCESS não é usado).
set -euo pipefail
umask 077

BACKUP_DIR="${BACKUP_DIR:-/var/backups/radpanel}"
BACKUP_CNF="${BACKUP_CNF:-/etc/radpanel/backup.cnf}"
DB_NAME="${DB_NAME:-radius}"
KEEP="${KEEP:-14}"
MIN_FREE_MB="${MIN_FREE_MB:-200}"
TAG=radpanel-backup

log() {
  # $1 = prioridade (user.info / user.err), resto = mensagem
  local prio=$1; shift
  logger -t "$TAG" -p "$prio" -- "$*" 2>/dev/null || true
  echo "$TAG: $*" >&2
}
die() { log user.err "ERRO: $*"; exit 1; }

[[ "$DB_NAME" =~ ^[A-Za-z0-9_]{1,64}$ ]] || die "DB_NAME inválido"
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || die "KEEP inválido"
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die "MIN_FREE_MB inválido"
command -v mysqldump >/dev/null 2>&1 || die "mysqldump não encontrado"

[ -f "$BACKUP_CNF" ] || die "arquivo de credenciais ausente: $BACKUP_CNF"
cnf_mode=$(stat -c '%a' "$BACKUP_CNF")
[ "$cnf_mode" = "600" ] || die "$BACKUP_CNF deve ter modo 600 (atual $cnf_mode)"
if [ "$(id -u)" = "0" ]; then
  [ "$(stat -c '%u' "$BACKUP_CNF")" = "0" ] || die "$BACKUP_CNF deve pertencer ao root"
fi

mkdir -p "$BACKUP_DIR"
[ -w "$BACKUP_DIR" ] || die "sem permissão de escrita em $BACKUP_DIR"

# Evita execuções simultâneas.
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || die "outro backup está em andamento"

free_mb=$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')
[ "${free_mb:-0}" -ge "$MIN_FREE_MB" ] || die "espaço livre insuficiente: ${free_mb:-?} MB < ${MIN_FREE_MB} MB"

stamp=$(date +%Y%m%d-%H%M)
final="$BACKUP_DIR/radius-$stamp.sql.gz"
tmp=$(mktemp "$BACKUP_DIR/.radius-$stamp.XXXXXX.part")
trap 'rm -f "$tmp"' EXIT

log user.info "iniciando backup de $DB_NAME"
# --defaults-extra-file precisa ser o primeiro argumento.
mysqldump --defaults-extra-file="$BACKUP_CNF" --single-transaction --routines --triggers \
  --default-character-set=utf8mb4 --databases "$DB_NAME" | gzip -9 >"$tmp"
gzip -t "$tmp" || die "arquivo gerado está corrompido"
[ "$(stat -c '%s' "$tmp")" -gt 200 ] || die "arquivo gerado é pequeno demais"

chmod 600 "$tmp"
[ "$(id -u)" = "0" ] && chown root:root "$tmp"
mv -f "$tmp" "$final"
trap - EXIT

# Retenção: mantém os KEEP mais recentes (o nome contém a data, então ordem lexicográfica = cronológica).
mapfile -t all < <(printf '%s\n' "$BACKUP_DIR"/radius-*.sql.gz | sort)
if [ "${#all[@]}" -gt "$KEEP" ]; then
  for old in "${all[@]:0:${#all[@]}-KEEP}"; do
    rm -f -- "$old"
    log user.info "removido backup antigo $(basename "$old")"
  done
fi

log user.info "backup concluído: $(basename "$final") ($(stat -c '%s' "$final") bytes)"
