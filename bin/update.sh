#!/bin/bash
# Atualiza o RadPanel a partir do git com um comando:  sudo /opt/radpanel/bin/update.sh
# Puxa a versão nova do clone (git fetch + avanço simples, como o DONO do clone, nunca como root) e roda o
# instalador sem perguntas (respostas salvas em /etc/radpanel/install.env). Mantém config, banco, admins e certificado.
# FORCE_APT=1 reinstala os pacotes do sistema também. Não é chamado pelo painel web (só pelo administrador).
# CONF_DIR/RUNUSER/GIT/WAITS só valem com RADPANEL_TEST=1 (produção ignora o ambiente).
set -euo pipefail
die() { echo "ERRO: $*" >&2; exit 1; }

if [[ "${RADPANEL_TEST:-}" == "1" ]]; then
  CONF_DIR="${CONF_DIR:-/etc/radpanel}"; RUNUSER="${RUNUSER:-/usr/sbin/runuser}"; GIT="${GIT:-/usr/bin/git}"
  WAITS="${WAITS:-0 2 4 8 16}"
else
  CONF_DIR=/etc/radpanel; RUNUSER=/usr/sbin/runuser; GIT=/usr/bin/git
  WAITS="0 2 4 8 16"
  [[ $EUID -eq 0 ]] || die "rode com sudo: sudo /opt/radpanel/bin/update.sh"
fi
BRANCH=main

[[ -s "$CONF_DIR/source" ]] || die "não sei onde está o clone do git. Rode uma vez: cd ~/radpanel && git pull && sudo bash install-panel.sh"
CLONE="$(head -n1 "$CONF_DIR/source")"
[[ -d "$CLONE/.git" && -f "$CLONE/install-panel.sh" ]] || die "clone '$CLONE' não encontrado ou incompleto."
[[ -f "$CONF_DIR/install.env" ]] || die "faltam as respostas salvas ($CONF_DIR/install.env). Rode uma vez: cd '$CLONE' && git pull && sudo bash install-panel.sh"

OWNER="$(stat -c %U "$CLONE")"
git_as() {
  if [[ "$OWNER" == "root" ]]; then "$GIT" -C "$CLONE" "$@"
  else "$RUNUSER" -u "$OWNER" -- "$GIT" -C "$CLONE" "$@"; fi
}

if [[ -n "$(git_as status --porcelain --untracked-files=no)" ]]; then
  die "há alterações locais não salvas em $CLONE; não vou sobrescrevê-las. Veja: cd '$CLONE' && git status"
fi
before="$(git_as rev-parse HEAD)"

echo "==> Buscando a versão nova no git"
ok=0
for wait in $WAITS; do
  sleep "$wait"
  if git_as fetch origin "$BRANCH"; then ok=1; break; fi
  echo "    falhou; tentando de novo..." >&2
done
[[ $ok -eq 1 ]] || die "não consegui falar com o git (rede?)."
git_as merge --ff-only "origin/$BRANCH" >/dev/null || die "o clone não pode avançar sem conflito (histórico diferente). Nada foi alterado no servidor."
after="$(git_as rev-parse HEAD)"

if [[ "$before" == "$after" ]]; then
  echo "    já estava na versão mais nova ($(git_as rev-parse --short HEAD)); reaplicando mesmo assim."
else
  echo "    mudanças recebidas:"
  git_as log --oneline "$before..$after" | sed 's/^/      /'
fi

echo "==> Aplicando (instalador sem perguntas)"
if [[ "${FORCE_APT:-0}" == "1" ]]; then SKIP_APT=0; else SKIP_APT=1; fi
ASSUME_YES=1 SKIP_APT="$SKIP_APT" bash "$CLONE/install-panel.sh"
echo
echo "Atualizado para $(git_as rev-parse --short HEAD). Se a tela parecer antiga, aperte Ctrl+F5 no navegador."
