#!/bin/bash
# Payload embutido no 03-cluster.yml (tar nao; arquivo unico, LZMA+base64).
# O builder scripts/build-app-payload.py injeta o Compose na linha marcada
# #__COMPOSE__ e grava o blob na linha AppPayload: do template.
#
# Executado pelo user data do manager-1 apos o Swarm criar. Sem o segundo
# argumento, apenas descompacta o Compose e re-executa a si mesmo em background
# (setsid), para nao segurar o cloud-init. O trabalho real fica em
# /var/log/studio-app-deploy.log.
#
# Republicacao manual (ex.: apos editar a imagem tag latest):
#   sudo bash /opt/studio/d.sh <EIP> run
set -u
EIP="${1:?informe o EIP}"
DIR=/opt/studio
mkdir -p "$DIR"

cat > "$DIR/compose.yml" <<'COMPOSEEOF'
#__COMPOSE__
COMPOSEEOF

if [ "${2:-}" = "run" ]; then
  exec >>/var/log/studio-app-deploy.log 2>&1
  echo "Deploy da aplicacao iniciado em $(date -Is)"

  READY=0
  ROLES=0
  for attempt in $(seq 1 120); do
    READY=$(docker node ls 2>/dev/null | grep -c ' Ready' || true)
    ROLES=$(docker node ls -q 2>/dev/null \
      | xargs -n1 docker node inspect --format '{{index .Spec.Labels "role"}}' 2>/dev/null \
      | grep -cE '^(app|database|rabbitmq)$' || true)
    if [ "$READY" -ge 7 ] && [ "$ROLES" -ge 4 ]; then
      break
    fi
    sleep 15
  done
  if [ "$READY" -lt 7 ] || [ "$ROLES" -lt 4 ]; then
    echo "TIMEOUT aguardando nos/labels (ready=$READY roles=$ROLES)"
    exit 1
  fi

  export API_BASE_URL="http://$EIP:8080"
  export CORS_ALLOWED_ORIGINS="http://$EIP,http://$EIP:8080"
  docker stack deploy --with-registry-auth --prune --compose-file "$DIR/compose.yml" studio-essencia

  RUNNING=0
  for attempt in $(seq 1 100); do
    RUNNING=$(docker stack services studio-essencia --format '{{.Replicas}}' 2>/dev/null \
      | grep -c '^1/1' || true)
    if [ "$RUNNING" -ge 6 ]; then
      echo "Deploy concluido: 6/6 servicos em 1/1"
      exit 0
    fi
    sleep 15
  done
  echo "TIMEOUT: nem todos os servicos ficaram 1/1 (run=$RUNNING)"
  docker stack services studio-essencia
  exit 1
fi

setsid bash "$0" "$EIP" run </dev/null >/dev/null 2>&1 &
echo "Publicacao iniciada em background; log em /var/log/studio-app-deploy.log"
