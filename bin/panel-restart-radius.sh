#!/bin/bash
# Valida a configuração do FreeRADIUS e só então reinicia o serviço.
# Chamado pelo painel via: sudo -n /opt/radpanel/bin/panel-restart-radius.sh (sem argumentos).
# Saída curta; exit 0 = reiniciado, 1 = configuração inválida (NÃO reiniciou), 2 = falha ao reiniciar.
# Variáveis RADIUS_SBIN / SYSTEMCTL existem para teste; sob sudo com env_reset elas não chegam aqui.
# Segurança: a validação (radiusd -CX) lê arquivos que o usuário do Apache pode escrever (clients.d), então em
# produção roda como o usuário SEM privilégios do serviço (RUN_USER=freerad), nunca como root. Só o reinício é root.
set -u
if [ "${1:-}" != "" ]; then echo "argumentos não são aceitos"; exit 64; fi
if [ "${RADPANEL_TEST:-}" != "1" ]; then
  # Em produção ignora qualquer override de ambiente.
  RADIUS_SBIN=/opt/freeradius/sbin
  SYSTEMCTL=/usr/bin/systemctl
  RUN_USER=freerad
  RUNUSER=/usr/sbin/runuser
  [ "$(id -u)" = "0" ] || { echo "precisa rodar como root (via sudo)"; exit 64; }
  id "$RUN_USER" >/dev/null 2>&1 || { echo "usuário do serviço '$RUN_USER' não existe; não validei nem reiniciei"; exit 64; }
  [ -x "$RUNUSER" ] || { echo "runuser não encontrado; não validei nem reiniciei"; exit 64; }
else
  RUN_USER=""
  RUNUSER=""
fi
RADIUS_SBIN="${RADIUS_SBIN:-/opt/freeradius/sbin}"
SYSTEMCTL="${SYSTEMCTL:-/usr/bin/systemctl}"
ENV_BIN=/usr/bin/env
HEAD_BIN=/usr/bin/head
CUT_BIN=/usr/bin/cut

if [ -n "$RUN_USER" ]; then
  out=$("$RUNUSER" -u "$RUN_USER" -- "$ENV_BIN" -i PATH=/usr/bin:/bin LC_ALL=C "$RADIUS_SBIN/radiusd" -CX 2>&1)
else
  out=$("$ENV_BIN" -i PATH=/usr/bin:/bin LC_ALL=C "$RADIUS_SBIN/radiusd" -CX 2>&1)
fi
rc=$?
if [ $rc -ne 0 ]; then
  echo "Configuração INVÁLIDA; o serviço NÃO foi reiniciado."
  printf '%s\n' "$out" | "$HEAD_BIN" -n 5 | "$CUT_BIN" -c1-200
  exit 1
fi
rout=$("$ENV_BIN" -i PATH=/usr/bin:/bin LC_ALL=C "$SYSTEMCTL" restart freeradius 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
  echo "Falha ao reiniciar o freeradius (veja: journalctl -u freeradius)."
  printf '%s\n' "$rout" | "$HEAD_BIN" -n 3 | "$CUT_BIN" -c1-200
  exit 2
fi
echo "Configuração válida; freeradius reiniciado."
exit 0
