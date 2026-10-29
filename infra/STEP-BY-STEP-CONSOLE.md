# Deploy em passos pelo console (site) da AWS - Studio Essencia

Este guia executa o ambiente inteiro **pelo navegador**, usando CloudFormation,
EC2, VPC e Session Manager. Para entender o que cada camada faz, veja
[`ARCHITECTURE.md`](ARCHITECTURE.md) e o resumo em [`README.md`](README.md);
aqui o foco e **onde clicar, o que digitar e o que validar** em cada etapa.

> **Aviso importante:** agora o ambiente inteiro roda 100% no site. A
> aplicacao **publica-se automaticamente**: o `03-cluster.yml` embute o Compose
> e o user-data do manager 1 faz o `docker stack deploy` quando o Swarm fica
> pronto (Passo 5 so verifica). Para republicar, use o payload ja instalado no
> manager 1 (`sudo bash /opt/studio/d.sh <EIP> run` no Session Manager).

Tempos esperados (deploy completo):

| Etapa | Tempo tipico |
|---|---|
| Passo 2 rede | 2-3 min |
| Passo 3 gateways | 5-10 min + Nginx instalar |
| Passo 4 cluster | 10-15 min de stack + nos prontos em ate 25 min |
| Aplicacao (automatica no cluster) | 5-15 min apos o Passo 4 (primeiro pull) |
| Total | ~40-60 min |

---

## Passo 0 - Preparacao

1. **Login:** AWS Academy -> *AWS Console* -> *Amazon Console*.
2. **Regiao:** confirme no seletor superior direito `us-west-2` (lab atual).
   Os templates funcionam em qualquer regiao, mas as notas assumem `us-west-2`.
3. **Key pair:** EC2 -> *Key pairs* -> `studio-essencia-key` deve existir.
   Ela foi preservada no ultimo teardown; nao crie outra.
4. **Seu IP publico:** abra uma aba em `https://checkip.amazonaws.com` e anote
   (ex.: `203.0.113.10`). Esse IP vira `AllowedAdminCidr` e e o **unico** IP
   de onde SSH, RabbitMQ (`:15672`) e WAHA (`:3000`) vao funcionar. Se voce
   trocar de rede (4G, VPN) no meio do deploy, va atualizando a stack da rede.
5. **Arquivos locais que voce vai usar (so os 3 templates):**
   - `C:\Users\Bill Hebert\Downloads\faculdade\Studio-many-IaC-main\infra\01-network.yml`
   - `...\infra\02-gateway.yml`
   - `...\infra\03-cluster.yml`

   O Compose da aplicacao ja esta embutido no `03-cluster.yml` (payload LZMA +
   base64). Se voce editar `infra\swarm\studio-essencia-stack-placement.yml`
   ou `infra\swarm\app-bootstrap\deploy-app.sh`, gere o `03-cluster.yml` novo
   antes de subir: `python infra\scripts\build-app-payload.py` (roda a partir
   da pasta `infra`).
6. **Custo:** mantenha uma aba em *Billing -> Cost Explorer* aberta. Ao
   terminar de usar, faca o Passo 9 completo.

Como criar stack (vale para os Passos 2-4):

1. Servico **CloudFormation** -> *Stacks* -> **Create stack** ->
   *With resources I specify*.
2. Em *Template source*, escolha **Upload a template file** e selecione o `.yml`.
3. *Next*. Em *Specify stack details*, digite **Stack name exatamente como
   indicado** (as proximas stacks importam saidas pelo nome) e preencha os
   parametros.
4. *Next* -> *Configure stack options*: nada a marcar (sem tags/notificacoes
   extras; os templates ja aplicam tags de `Project`). *Next*.
5. *Review*: a caixa de capabilities **nao aparece** (os templates nao criam
   IAM). **Create stack**.
6. Aguarde o status **CREATE_COMPLETE** na aba *Events*. Se rolar back, use o
   Passo 10 (problemas comuns) antes de recriar.

---

## Passo 1 - Anotar valores fixos

| Item | Valor |
|---|---|
| Stack 1 | `studio-network` |
| Stack 2 | `studio-gateway` |
| Stack 3 | `studio-cluster` |
| ProjectName / Environment | `studio-essencia` / `dev` |
| VPC | `10.20.0.0/16` |
| Gateways | `10.20.1.10` (ativo, AZ-A) / `10.20.2.10` (reserva, AZ-B) |
| Managers | `10.20.11.10`, `10.20.12.10`, `10.20.13.10` |
| MySQL / RabbitMQ | `10.20.11.20` / `10.20.12.20` |
| Instancias totais | 9 (limite do Academy com `WorkerCount=2`) |

---

## Passo 2 - Stack de rede (`studio-network`)

**O que cria:** VPC, 2 sub-redes publicas (gateways), 3 privadas (uma AZ cada),
Internet Gateway, route tables e os 6 security groups. **Nenhuma instancia,
nenhum EIP.**

Template `01-network.yml`. Parametros:

| Parametro | O que digitar |
|---|---|
| `ProjectName` | `studio-essencia` |
| `Environment` | `dev` |
| `VpcCidr` | `10.20.0.0/16` (default) |
| `PublicSubnet1Cidr` / `PublicSubnet2Cidr` | defaults `10.20.1.0/24` / `10.20.2.0/24` |
| `PrivateSubnet1/2/3Cidr` | defaults `10.20.11/12/13.0/24` |
| `AllowedWebCidr` | `0.0.0.0/0` (default) - portas publicas 80/443/8080 |
| `AllowedAdminCidr` | **`SEU_IP/32`** (sem default, obrigatorio) |

Validacao (2-3 min depois de `CREATE_COMPLETE`):

- VPC -> *Your VPCs*: uma VPC `10.20.0.0/16` com tag `Project=studio-essencia`.
- CloudFormation -> `studio-network` -> aba **Exports**: lista
  `studio-network-VpcId`, `...-PublicSubnet1Id`, `...-PrivateRouteTable1Id`,
  `...-ClusterSecurityGroupId` etc. (sao essas saidas que as proximas stacks
  importam).
- EC2 -> Instances: **nenhuma** instancia do projeto ainda.

---

## Passo 3 - Stack dos gateways (`studio-gateway`)

**O que cria:** 2 instancias `t3.micro` (ativo AZ-A / reserva AZ-B), o **EIP
unico** associado ao ativo, rotas `0.0.0.0/0` das 3 sub-redes privadas
(NAT via gateway), Nginx + NAT + agente de failover via user-data.

Template `02-gateway.yml`. Parametros:

| Parametro | O que digitar |
|---|---|
| `NetworkStackName` | `studio-network` |
| `ProjectName` / `Environment` | `studio-essencia` / `dev` |
| `KeyName` | `studio-essencia-key` |
| `GatewayInstanceType` | `t3.micro` (default) |
| `GatewayRootVolumeSize` | `8` (default) |
| `Gateway1PrivateIp` / `Gateway2PrivateIp` | defaults `10.20.1.10` / `10.20.2.10` |
| `Manager1/2/3PrivateIp` | defaults `10.20.11.10` / `10.20.12.10` / `10.20.13.10` |
| `CheckIntervalSeconds` / `FailureThreshold` / `ArmedAfterChecks` | defaults `15` / `4` / `3` |
| `ImageId` | deixe o default (parametro publico SSM do Ubuntu 24.04) |

**Anote da aba Outputs** (guarde para os proximos passos):

- `PublicIp` - o EIP; chamado aqui de `<EIP>`.
- `NginxHealthUrl`, `EipAllocationId`, `ActiveGatewayInstanceId`,
  `StandbyGatewayInstanceId`, URLs de frontend/backend/RabbitMQ/WAHA.

Validacao:

1. Status `CREATE_COMPLETE` (~5-8 min).
2. Aguarde o user-data terminar (instala Nginx): abra
   `http://<EIP>/nginx-health` no navegador (do SEU IP) e aguarde responder
   `ok`. Pode levar 2-5 min apos a stack concluir; se der connection refused,
   espere e tente de novo.
3. As portas `:80` e `:8080` do app podem dar 502 - ainda nao ha managers; e
   normal. O `nginx-health` e o que prova que o gateway esta de pe.

> **Antes de seguir, o NAT precisa estar funcionando:** as rotas das 3
> sub-redes privadas (VPC -> Route tables, tag `Project=studio-essencia`) tem
> target `studio-essencia-dev-gateway-active`. Sem isso, o Passo 4 nao
> consegue instalar Docker nos nos privados.

---

## Passo 4 - Stack do cluster (`studio-cluster`)

**O que cria:** 3 managers (`t3.micro`, um por AZ, IPs fixos), Auto Scaling
Group com 2 workers (`t3.small`), nos dedicados MySQL e RabbitMQ (`t3.small`)
com 2 volumes EBS de 8 GiB (`DeletionPolicy: Retain`), e os user-data que
inicializam o Swarm, distribuem tokens (porta 8081 interna), montam o EBS em
`/data`, aplicam as labels `role=app/database/rabbitmq/manager` e **publicam a
aplicacao automaticamente** quando o cluster fica pronto (ver Passo 5).

Template `03-cluster.yml`. Parametros:

| Parametro | O que digitar |
|---|---|
| `NetworkStackName` | `studio-network` |
| `GatewayStackName` | `studio-gateway` (default; de onde o EIP e importado) |
| `ProjectName` / `Environment` | `studio-essencia` / `dev` |
| `KeyName` | `studio-essencia-key` |
| `ManagerInstanceType` | `t3.micro` |
| `WorkerInstanceType` | `t3.small` |
| `DataInstanceType` | `t3.small` |
| `WorkerCount` | `2` (nao aumente: 9 e o limite do Academy) |
| `WorkerMaxSize` | `2` |
| `RootVolumeSize` | `20` (obrigatorio: 8 nao comporta a imagem do WAHA) |
| `DataVolumeSize` | `8` (volumes novos comecam vazios) |
| `Manager1/2/3PrivateIp` | defaults |
| `MySqlPrivateIp` / `RabbitMqPrivateIp` | defaults `10.20.11.20` / `10.20.12.20` |
| `MySqlDataVolumeId` / `RabbitMqDataVolumeId` | **deixe vazios** para ambiente novo com dados novos. Para reutilizar volumes existentes, cole os `vol-...` (MySQL na AZ-A, RabbitMQ na AZ-B) |
| `ImageId` | default |

A stack fica `CREATE_COMPLETE` em ~10-15 min (o ASG espera as instancias
ficarem in-service). Os nos do Swarm podem demorar ate ~25 min para aparecer
`Ready` (apt/Docker descem pelo NAT com retry).

**Anote da aba Outputs:** `MySqlVolumeId` e `RabbitMqVolumeId` (os volumes
retidos), alem dos InstanceIds dos managers e do nome do ASG.

Validacao pelo site:

1. EC2 -> *Instances*: **9 instancias running** do projeto
   (2 gateway, 3 manager, 2 app-worker, mysql, rabbitmq).
2. Selecione a instancia `studio-essencia-dev-manager-1` -> **Connect** -> aba
   **Session Manager** -> *Start session*.
3. Na sessao (o user do Session Manager precisa de sudo):

```bash
sudo docker info --format '{{.Swarm.LocalNodeState}}'      # active
sudo docker node ls
```

Esperado: 7 nos `Ready` - `manager-1` (Leader), `manager-2`, `manager-3`,
2x `app-worker-i-...`, `mysql-data`, `rabbitmq-data`.

4. Confirme as labels:

```bash
sudo docker node ls -q | xargs -n1 sudo docker node inspect \
  --format '{{.Description.Hostname}} -> {{.Spec.Labels.role}}'
```

Esperado: `role=manager` (3x), `role=app` (2x), `role=database`,
`role=rabbitmq`. O labeler roda a cada 30s: se aparecer sem label, aguarde um
ciclo.

> Session Manager sem a aba/erro de agente: confirme que o instance profile
> `LabInstanceProfile` permite SSM (no lab ele permitia `Run Command`). As
> validacoes podem ser feitas via SSH local ao gateway (`ssh ubuntu@<EIP>`);
> a publicacao da aplicacao nao depende do Session Manager de todo (roda sozinha
> pelo user-data). Para republicar manualmente, use o comando do Passo 5.

---

## Passo 5 - Aplicacao: publicacao automatica (so verificar)

Nao ha upload nem comando manual no fluxo normal. O `03-cluster.yml` embute o
Compose (linha `AppPayload:`, payload LZMA + base64) e o user-data do manager 1
executa sozinho: espera os 7 nos `Ready` com labels, monta
`API_BASE_URL=http://<EIP>:8080` e `CORS_ALLOWED_ORIGINS` com o EIP importado
da stack `studio-gateway` e roda `docker stack deploy --prune`.

A stack `studio-cluster` fica `CREATE_COMPLETE` **antes** de a aplicacao
terminar; aguarde 5-15 min (primeiro pull; WAHA e a maior) e confira na mesma
sessao do Session Manager do Passo 4:

```bash
sudo docker stack services studio-essencia
sudo tail -n 40 /var/log/studio-app-deploy.log
```

Esperado: 6 servicos `1/1` (mysql, rabbitmq, waha, backend, actions-service,
front) e a linha `Deploy concluido: 6/6 servicos em 1/1` no log.

Se algum servico ficar `Pending`: `sudo docker service ps <servico>` e volte ao
Passo 4 (labels). Se a stack nao existir de todo, o log acima tem o motivo
(timeout de nos, deploy falho etc.).

Para **republicar** depois (imagens `:latest` novas ou troco de EIP), a copia
do payload ja fica no manager 1:

```bash
sudo bash /opt/studio/d.sh <EIP> run
```

A publicacao da aplicacao e automatica e nao depende de navegador, S3 nem
Session Manager: o Compose esta embutido no `03-cluster.yml` (linha
`AppPayload:`). Para **republicar** depois (imagens `:latest` novas ou troco de
EIP), use no Session Manager do manager 1:

```bash
sudo bash /opt/studio/d.sh <EIP> run
```

Se voce editar o Compose localmente, **reempacote o template** antes do proximo
deploy do cluster (a partir de `infra`): `python scripts\build-app-payload.py`.

---

## Passo 6 - Validar acessos (navegador, do seu IP)

| URL | Esperado |
|---|---|
| `http://<EIP>/` | frontend 200 |
| `http://<EIP>:8080/swagger-ui.html` | Swagger 200 |
| `http://<EIP>:8080/` | 401 - **esperado** sem credenciais |
| `http://<EIP>/nginx-health` | `ok` |
| `http://<EIP>:15672` | RabbitMQ UI; login `admin` / `admin` |
| `http://<EIP>:3000` | WAHA dashboard (sem senha no lab) |

`15672` e `3000` so abrem do IP liberado em `AllowedAdminCidr` (seu IP do
Passo 0). Nao abra por 4G/VPN diferente e chame de falha.

---

## Passo 7 - Snapshot EBS dos dados (faca agora, todo deploy)

Sem isto, a stack nao tem backup: volume perdido = dados perdidos. A rotina
logica (mysqldump + definicoes do RabbitMQ) continua pendente de implementacao.

1. EC2 -> *Volumes* -> filtre tag `Project = studio-essencia`: os 2 volumes de
   dados (`8 GiB`, tags `Role=mysql-data` e `Role=rabbitmq-data`). **Anote os
   `vol-...`** - sao os IDs para `MySqlDataVolumeId`/`RabbitMqDataVolumeId` em
   um redeploy futuro.
2. Selecione -> *Actions* -> **Create snapshot** -> descricao
   `studio-essencia mysql backup AAAA-MM-DD` (e outra pro rabbitmq).
3. EC2 -> *Snapshots*: aguarde progresso 100% (estado `completed`).
4. Custos: snapshot cobra GB-mes. Quando criar outro, apague os antigos sem
   uso.

Restaurar pelo site: *Snapshots* -> acao **Create volume from snapshot** ->
**mesma AZ do no** (MySQL: AZ-A/`us-west-2a`; RabbitMQ: AZ-B/`us-west-2b`),
tamanho **>=** o do snapshot -> criar a stack do cluster passando os IDs em
`MySqlDataVolumeId`/`RabbitMqDataVolumeId`. O user-data detecta o filesystem
existente (`blkid`) e **reutiliza sem formatar**.

---

## Passo 8 - (Opcional) Testar failover pelo site

1. EC2 -> Instances -> a `ActiveGatewayInstanceId` (Outputs do Passo 3) ->
   *Instance state* -> **Stop instance**.
2. Aguarde ~60-90s (agente: 4 falhas x 15s + promocao).
3. No mesmo navegador (mesmo EIP): `http://<EIP>/nginx-health` -> `ok`, e o
   frontend continua. O agente moveu EIP, SG de aplicacao e as 3 rotas
   privadas.
4. Confirme no site: EC2 -> *Elastic IPs* -> associacao agora e na instancia
   da reserva; VPC -> Route tables privadas -> target virou o gateway reserva.
5. Para voltar: **Start instance** no gateway original, aguarde `running` +
   `nginx-health` ok, e entao faca o **failback** - que so existe via script
   local: `.\scripts\switch-gateway.ps1 -Target active -GatewayStackName
   studio-gateway -NetworkStackName studio-network -Region us-west-2`. Se nao
   for rodar o script, pode deixar no reserva - o ambiente funciona igual.
6. Nunca de *Update* na stack `studio-gateway` com o EIP na reserva.

---

## Passo 9 - Desligar tudo (custo zero)

1. CloudFormation -> deletar **nesta ordem**, aguardando
   `DELETE_COMPLETE` de uma antes da proxima:
   `studio-cluster` -> `studio-gateway` -> `studio-network`.
   (O EIP e liberado junto com a stack do gateway; as instancias e root
   volumes vao abaixo com as stacks.)
2. A stack do cluster **retens os volumes de dados** (`Retain`): EC2 ->
   *Volumes* -> os 2 `vol-...` do Passo 7 -> *Actions* -> **Delete volume**
   (somente se os dados podem ser descartados). Para guarda-los, mantenha e
   anote os IDs.
3. EC2 -> *Snapshots* -> delete os do projeto que nao servem mais.
4. Confirme custo zero do projeto: EC2 -> Instances = 0 running; Elastic IPs
   = 0; CloudFormation = 0 stacks ativas; Volumes/Snapshots = 0; VPC do
   projeto = 0. Instancias `terminated` somem do console e nao cobram.
5. O atalho equivalente no Windows: `.\infra\scripts\destroy-all.ps1 -Force`
   (faz 1-4 de uma vez, mantendo a key pair).

---

## Passo 10 - Problemas comuns (console)

| Sintoma | Causa provavel | Acao |
|---|---|---|
| Rollback na criacao da stack | nome de stack duplicado / export em uso | delete a stack antiga com o mesmo nome e recrie |
| `nginx-health` nunca da `ok` | user-data do gateway ainda rodando ou NAT sem rota | EC2 -> Instances -> gateway -> *Connect* -> *Serial console* ou SSH `ubuntu@<EIP>`; `tail -100 /var/log/cloud-init-output.log` |
| Cluster CREATE_FAILED / nos nunca `Ready` | NAT nao esta pronto; worker nao instala Docker | valide `nginx-health` antes; olhe `/var/log/cloud-init-output.log` de um worker via Session Manager |
| Servico `Pending` | labels ausentes ou menos de 2 workers | Passo 4 (labels) e ASG (instancias running) |
| WAHA nao sobe / erro de espaco | disco cheio | no worker: `df -h`, `sudo docker image prune -a -f`, `sudo docker builder prune -f` |
| 502/503 no frontend | backend sem health ainda | `sudo docker service ps studio-essencia_studio-essencia-backend` |
| 15672/3000 nao abrem | seu IP mudou | CloudFormation -> `studio-network` -> Update -> novo `SEU_IP/32` em `AllowedAdminCidr` |
| Session Manager indisponivel | SSM negado pela escola | use SSH local ao gateway (`ssh ubuntu@<EIP>`), config na secao 6 do README |
| Site 200 mas API com erro de CORS | nginx com `Host $host` removia a porta; Spring nao emitia ACAO | confirme nos dois gateways `proxy_set_header Host $http_host;` em /etc/nginx/conf.d/studio.conf (corrigido no template em 2026-10-29) |
| Aplicacao nao foi publicada | publish automatico falhou ou ainda esta puxando imagens | `sudo tail /var/log/studio-app-deploy.log` no manager-1; republicar com `sudo bash /opt/studio/d.sh <EIP> run` |
| 10a instancia sumiu sozinha | Academy terminou (limite 9) | mantenha `WorkerCount=2`; nao tente subir mais |
| `ExpiredToken` no site | sessao AWS Academy venceu | novo login |

---

## Checklist

1. Regiao `us-west-2`; key pair existe; IP anotado. (Passo 0)
2. `studio-network` CREATE_COMPLETE; exports visiveis. (Passo 2)
3. `studio-gateway` CREATE_COMPLETE; `http://<EIP>/nginx-health` = `ok`; EIP
   anotado. (Passo 3)
4. `studio-cluster` CREATE_COMPLETE; 9 instancias running; Session Manager:
   7 nos Ready + labels. (Passo 4)
5. Publicacao automatica concluida (log `Deploy concluido: 6/6`); 6 servicos
   `1/1`. (Passo 5)
6. Frontend/Swagger 200, backend 401 esperado, Rabbit `admin/admin`, WAHA.
   (Passo 6)
7. Snapshots mysql/rabbit `completed`; volume IDs anotados. (Passo 7)
8. Ao terminar: deletar stacks (cluster->gateway->network), volumes e
   snapshots; conferir 0 recursos. (Passo 9)
