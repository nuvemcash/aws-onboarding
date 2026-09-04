#!/usr/bin/env bash
# Decide se uma tag deve ser publicada e se deve virar latest/.
#
# Uso:
#   git tag --list 'v*' | scripts/semver-gate.sh <tag>
#
# Lê a lista de tags candidatas via stdin (uma por linha; a própria tag pode ou
# não estar incluída — o script funde as duas). Falha (exit 1) se <tag> não for
# semver estrita (vX.Y.Z): tag como "vfoo" ou com sufixo pre-release não passa.
# Em sucesso, imprime em stdout (formato pronto para GITHUB_OUTPUT):
#
#   publish=true
#   latest=true|false     (true só quando <tag> é a maior semver entre as
#                          candidatas — tag antiga empurrada depois não pisa
#                          no latest/ de uma versão mais nova já publicada)

set -euo pipefail

TAG="${1:?uso: semver-gate.sh <tag> (lista de tags candidatas via stdin)}"
SEMVER_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

if [[ ! "$TAG" =~ $SEMVER_RE ]]; then
  echo "Tag '$TAG' não é semver estrita (vX.Y.Z) — publicação recusada." >&2
  exit 1
fi

highest="$( { cat -; echo "$TAG"; } | grep -E "$SEMVER_RE" | sort -Vu | tail -n1 )"

echo "publish=true"
if [[ "$TAG" == "$highest" ]]; then
  echo "latest=true"
else
  echo "latest=false"
fi
