# Studio Essencia - Infraestrutura alvo

Esta pasta implementa a arquitetura alvo descrita em
[`ARCHITECTURE.md`](ARCHITECTURE.md):

- VPC privada com tres Availability Zones.
- Um unico Elastic IP publico, anunciado pelo gateway ativo.
- Dois gateways EC2 em sub-redes publicas, um ativo e um reserva, executando
  Nginx e NAT.
- Tres managers do Docker Swarm, um por AZ, com IPs privados fixos.
- `N` workers de aplicacao em Auto Scaling Group, sem IP publico.
- MySQL e RabbitMQ em workers dedicados, com volumes EBS proprios.
- Servicos de aplicacao presos a `node.role == worker` e
  `node.labels.role == app`.
- A aplicacao e publicada automaticamente: o Compose vai embutido no template
  do cluster e o manager 1 roda o `docker stack deploy` quando o Swarm fica
  pronto (re-publicacao manual continua disponivel).

> **Estado do laboratorio (2026-10-29):** o ambiente AWS foi removido para
> interromper o consumo. Nao ha stacks, instancias running, volumes, snapshots
> nem Elastic IP do projeto. A key pair `studio-essencia-key` e o arquivo SSH
> local foram mantidos porque nao geram custo e aceleram o redeploy; o
> `HostName` do gateway no arquivo SSH foi neutralizado para `192.0.2.1` ate o
> proximo deploy.
>
> **Backup:** o teardown padrao exclui volumes e snapshots. Neste momento nao
> existe backup do projeto na AWS. Se os dados forem necessarios no futuro, crie
> e teste os snapshots antes de rodar o teardown.
>
> **Limite do laboratorio:** o AWS Academy permite no maximo **9 instancias
> running**. A configuracao validada usa `N=2` workers: 3 managers + 2 workers +
> 2 nos de dados + 2 gateways = 9 instancias. Com `N=3` seriam 10 e a decima
> seria terminada automaticamente pelo laboratorio. Por isso o template limita
> `WorkerCount` e `WorkerMaxSize` a 2.
>
> **Custo minimo:** os defaults usam `t3.micro` nos gateways e managers,
> `t3.small` nos workers e nos de dados. O volume raiz de 8 GiB foi testado e
> **nao e suficiente para o WAHA**: a extracao da imagem enche o disco e a task
> falha. Por isso o default de `RootVolumeSize` e **20 GiB**; `DataVolumeSize`
> e 8 GiB. Se o backend ou o WAHA sofrerem OOM, aumente apenas
> `WorkerInstanceType` para `t3.medium`.
>
> **Ultima execucao validada (historico):** Swarm com 3 managers, 2 workers, 2
> nos de dados e 2 gateways; stack da aplicacao com todos os servicos em `1/1`;
> frontend 200, backend 401 (esperado sem credenciais), RabbitMQ, WAHA e
> `/nginx-health` 200; dados do MySQL e das filas do RabbitMQ preservados;
> failover e failback do gateway revalidados. O ambiente foi destruido depois
> dessa validacao; esses resultados nao descrevem recursos ativos.

## Como subir

O fluxo recomendado e pelo **console da AWS**, criando os tres templates nesta
ordem: `01-network.yml` → `02-gateway.yml` → `03-cluster.yml`. Cada passo, com
parametros, validacoes e outputs, esta descrito em
[`STEP-BY-STEP-CONSOLE.md`](STEP-BY-STEP-CONSOLE.md). A aplicacao nao exige
nenhum passo extra: o Compose esta embutido no template do cluster e e
publicado sozinho pelo manager 1 quando o Swarm fica pronto.

O deploy cria um novo Elastic IP; ele pode ser diferente do endereco anterior,
entao atualize integracoes externas que apontavam para o IP antigo.

Para remover tudo (incluindo volumes e snapshots do projeto) e parar o consumo:

```powershell
.\infra\scripts\destroy-all.ps1 -Force
```

Sem `-Force`, o script pede a confirmacao `DELETE`. Use `-KeepVolumes` ou
`-KeepSnapshots` para preservar esses recursos. A key pair nao e removida.

As secoes manuais abaixo ficam como referencia e diagnostico. Para entender
cada camada antes de subir, veja [`ARCHITECTURE.md`](ARCHITECTURE.md) e o guia
do console.

## Arquitetura

```text
Internet
   |
   v
Elastic IP unico
   |
   v
Gateway ativo (AZ-A)  --failover-->  Gateway reserva (AZ-B)
Nginx :80/:8080/:15672/:3000          Nginx pronto, sem SG publico
NAT 0.0.0.0/0 -> cluster
   |
   +--> Manager 1 10.20.11.10 (AZ-A)
   +--> Manager 2 10.20.12.10 (AZ-B)
   +--> Manager 3 10.20.13.10 (AZ-C)
   |       |
   |       +--> ingress Swarm --> workers role=app
   |
   +--> MySQL    10.20.11.20 (worker role=database)
   +--> RabbitMQ 10.20.12.20 (worker role=rabbitmq)
```

O Nginx usa os tres IPs fixos dos managers como upstream. Os managers
participam do ingress routing mesh, mas nao executam tarefas de aplicacao.

## Stacks

| Arquivo | Funcao |
|---|---|
| `01-network.yml` | VPC, duas sub-redes publicas, tres privadas, route tables e security groups |
| `02-gateway.yml` | Dois gateways Nginx/NAT, um EIP (exportado), rotas privadas e agente de failover |
| `03-cluster.yml` | Tres managers, workers, MySQL/RabbitMQ, EBS, labels e **publicacao automatica da aplicacao** (payload embutido) |
| `swarm/studio-essencia-stack-placement.yml` | Compose fonte; embutido no cluster via builder |
| `swarm/app-bootstrap/deploy-app.sh` | Script que o manager 1 executa para publicar sozinho (fonte do payload) |
| `scripts/build-app-payload.py` | Reempacota compose + script no `03-cluster.yml` (LZMA+base64) |
| `scripts/switch-gateway.ps1` | Failback ou failover manual entre gateways |
| `scripts/destroy-all.ps1` | Remove stacks, instancias, EIPs e, por padrao, volumes e snapshots |
| `STEP-BY-STEP-CONSOLE.md` | Deploy em passos feito inteiramente pelo site (console) da AWS |
| `diagrams/` | Diagramas Mermaid da topologia, requisicao e failover |
| `ARCHITECTURE.md` | Justificativas, riscos e criterios da arquitetura |

## Pre-requisitos

- AWS CLI configurada na conta academica (v1 ou v2).
- Key Pair existente na regiao. O mesmo par e usado nos gateways e nos nos.
- `LabInstanceProfile` disponivel. Ele e usado por gateways, managers, workers,
  MySQL e RabbitMQ.
- Permissoes de EC2, Auto Scaling, EBS, CloudFormation e Elastic IP.
- O agente de failover usa o instance profile para chamar as APIs EC2. Se o
  laboratorio bloquear `ec2:AssociateAddress`, `ec2:ReplaceRoute` ou
  `ec2:ModifyInstanceAttribute`, o failover automatico nao funciona; use o
  script manual em `scripts/switch-gateway.ps1`.

Valide as credenciais:

```powershell
aws sts get-caller-identity
```

## 1. Variaveis

Execute a partir de `infra`:

```powershell
Set-Location "C:\Users\Bill Hebert\Downloads\faculdade\Studio-many-IaC-main\infra"

$Region = "us-west-2"
$KeyName = "studio-essencia-key"
$MyIp = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com").Trim()
$MyIp
```

`us-west-2` e a regiao do laboratorio atual; os templates sao agnosticos de
regiao. Use `$MyIp/32` em `AllowedAdminCidr`. Ela libera SSH no gateway,
SSH/SFTP via ProxyCommand nos nos privados, RabbitMQ e WAHA.

## 2. Validar os templates

```powershell
aws cloudformation validate-template `
  --template-body file://01-network.yml --region $Region

aws cloudformation validate-template `
  --template-body file://02-gateway.yml --region $Region

aws cloudformation validate-template `
  --template-body file://03-cluster.yml --region $Region
```

## 3. Rede

```powershell
aws cloudformation deploy `
  --stack-name studio-network `
  --template-file 01-network.yml `
  --parameter-overrides `
    ProjectName=studio-essencia `
    Environment=dev `
    AllowedWebCidr=0.0.0.0/0 `
    AllowedAdminCidr="$MyIp/32" `
  --region $Region
```

A stack de rede nao cria o EIP nem as rotas default privadas. Isso e feito pela
stack dos gateways.

## 4. Gateways

```powershell
aws cloudformation deploy `
  --stack-name studio-gateway `
  --template-file 02-gateway.yml `
  --parameter-overrides `
    NetworkStackName=studio-network `
    ProjectName=studio-essencia `
    Environment=dev `
    KeyName=$KeyName `
    GatewayInstanceType=t3.micro `
    GatewayRootVolumeSize=8 `
    Manager1PrivateIp=10.20.11.10 `
    Manager2PrivateIp=10.20.12.10 `
    Manager3PrivateIp=10.20.13.10 `
  --region $Region
```

O gateway ativo fica na AZ-A e recebe o EIP. O reserva fica na AZ-B, com o mesmo
Nginx/NAT, mas sem o security group de aplicacao. O agente do reserva monitora o
ativo e promove a reserva quando necessario.

O EIP e o unico endpoint web divulgado. Para o bootstrap, as duas instancias
gateway recebem IPv4 publico automatico; na reserva, esse IP nao abre 80, 8080,
15672 nem 3000; apenas SSH de management fica disponivel. Se voce exigir
literalmente nenhum IPv4 automatico, use uma AMI pre-configurada e remova o IP
automatico depois do bootstrap.

Saidas:

```powershell
aws cloudformation describe-stacks `
  --stack-name studio-gateway `
  --region $Region `
  --query "Stacks[0].Outputs" `
  --output table
```

Guarde `PublicIp`, `NginxHealthUrl`, `EipAllocationId`,
`ActiveGatewayInstanceId` e `StandbyGatewayInstanceId`.

Antes do cluster, valide:

```powershell
$GatewayIp = aws cloudformation describe-stacks `
  --stack-name studio-gateway `
  --region $Region `
  --query "Stacks[0].Outputs[?OutputKey=='PublicIp'].OutputValue" `
  --output text

Invoke-RestMethod "http://$GatewayIp/nginx-health"
```

O retorno esperado e `ok`. O Nginx pode responder 502 nas portas da aplicacao
enquanto os managers ainda nao existem; o health acima testa o processo.

## 5. Cluster

Alternativa pela AWS CLI, a partir de `infra`:

```powershell
aws cloudformation deploy `
  --stack-name studio-cluster `
  --template-file 03-cluster.yml `
  --parameter-overrides `
    NetworkStackName=studio-network `
    GatewayStackName=studio-gateway `
    ProjectName=studio-essencia `
    Environment=dev `
    KeyName=$KeyName `
    ManagerInstanceType=t3.micro `
    WorkerInstanceType=t3.small `
    DataInstanceType=t3.small `
    WorkerCount=2 `
    WorkerMaxSize=2 `
    RootVolumeSize=20 `
    DataVolumeSize=8 `
    Manager1PrivateIp=10.20.11.10 `
    Manager2PrivateIp=10.20.12.10 `
    Manager3PrivateIp=10.20.13.10 `
    MySqlPrivateIp=10.20.11.20 `
    RabbitMqPrivateIp=10.20.12.20 `
  --region $Region
```

A arquitetura completa tem `N + 7` instancias: `N` workers de aplicacao, 3
managers, 2 gateways, 1 MySQL e 1 RabbitMQ. A stack do cluster cria `N + 5`
(workers, managers, MySQL e RabbitMQ); os 2 gateways vem da stack anterior.
No AWS Academy, use **`N=2`**: sao 9 instancias running. `N=3` exigiria 10;
para caber em 9 seria preciso parar o gateway reserva (perdendo o failover) ou
outro papel. Lambda apenas automatiza start/stop; ela nao cria capacidade nem
resolve o limite de 9 running.

O root de 8 GiB nao acomoda a imagem do WAHA; o default atual e 20 GiB. Para
reaproveitar volumes de dados retidos (por exemplo, apos remover a stack do
cluster), informe os IDs dos volumes existentes:

```powershell
    MySqlDataVolumeId=vol-... `
    RabbitMqDataVolumeId=vol-... `
```

Os volumes precisam estar na AZ-A e AZ-B, respectivamente, e ter o filesystem
com a label `studio-data`. Com esses parametros, o template anexa os volumes
existentes em vez de criar volumes novos. EBS pode crescer in-place, mas nao
encolher; monitore o espaco de imagens Docker e os logs no disco raiz.

Nao atualize uma stack em execucao apenas para mudar `RootVolumeSize`: uma
atualizacao pode substituir managers/nos de dados e criar instancias temporarias
acima do limite de 9. Na ultima execucao, os volumes dos workers foram
expandidos in-place para 20 GiB; uma mudanca global deve ser feita recriando a
stack com backup ou aplicando `modify-volume` + `growpart`/`resize2fs`.

Os managers usam IPs fixos porque o Nginx aponta para eles. Os workers de
aplicacao usam o Auto Scaling Group nas tres sub-redes privadas. MySQL e
RabbitMQ sao instancias unicas; nao sao alta disponibilidade.

O `docker swarm init` fixa o pool overlay em `172.30.0.0/16` (`/24` por rede)
para nao colidir com a VPC `10.20.0.0/16`.

**Publicacao automatica da aplicacao:** o `03-cluster.yml` embute o Compose e o
script `swarm/app-bootstrap/deploy-app.sh` (tar de um arquivo -> LZMA -> base64
na linha `AppPayload:` do template). O user-data do manager 1 decodifica o
payload em `/opt/studio/d.sh` e o executa em background: ele espera os 7 nos
`Ready` e as 4 labels de papel, exporta `API_BASE_URL`/`CORS_ALLOWED_ORIGINS`
com o EIP importado da stack `studio-gateway` (output `PublicIp`, exportado como
`${AWS::StackName}-PublicIp`) e roda `docker stack deploy`. A stack do cluster
conclui antes disso; o progresso fica em `/var/log/studio-app-deploy.log` no
manager 1. Se voce editar o Compose ou o `deploy-app.sh`, rode
`python scripts\build-app-payload.py` (a partir de `infra`) antes de criar ou
atualizar a stack do cluster; o script recusa payloads que estourarem os 16 KiB
de user-data do EC2.

Saidas uteis:

```powershell
aws cloudformation describe-stacks `
  --stack-name studio-cluster `
  --region $Region `
  --query "Stacks[0].Outputs" `
  --output table
```

## 6. Acesso administrativo

Nao ha IP publico nos managers nem nos workers. Use o gateway como
`ProxyCommand`. O `ssh -J` do OpenSSH no Windows tem um bug com IP literal
entre colchetes; o formato abaixo e o que funciona no laboratorio:

```powershell
$GatewayIp = aws cloudformation describe-stacks `
  --stack-name studio-gateway `
  --region $Region `
  --query "Stacks[0].Outputs[?OutputKey=='PublicIp'].OutputValue" `
  --output text

ssh -F "C:\Users\<voce>\.ssh\studio-config" studio-manager-1
```

Exemplo de `C:\Users\<voce>\.ssh\studio-config` (substitua o EIP e o caminho da
chave):

```text
Host studio-gateway
    HostName <EIP>
    User ubuntu
    IdentityFile C:\Users\<voce>\.ssh\studio-essencia-key.pem

Host studio-manager-1
    HostName 10.20.11.10
    User ubuntu
    IdentityFile C:\Users\<voce>\.ssh\studio-essencia-key.pem
    ProxyCommand ssh -W %h:%p studio-gateway
```

Apos criar a stack do gateway, atualize o `HostName` do bloco `studio-gateway`
no seu arquivo local com o novo EIP (aba Outputs da stack). Enquanto o
laboratorio estiver destruido, o arquivo usa `192.0.2.1` de proposito para nao
tentar conexoes com um EIP liberado.

Dentro do manager 1:

```bash
docker node ls
docker info --format '{{.Swarm.LocalNodeState}}'
systemctl status swarm-token.service --no-pager
systemctl status swarm-labeler.service --no-pager
```

Os managers devem aparecer com `ManagerStatus: Leader` ou `Reachable`. O
labeler aplica automaticamente:

- `role=manager` nos managers;
- `role=app` nos workers de aplicacao;
- `role=database` no MySQL;
- `role=rabbitmq` no RabbitMQ.

Nao rotule manualmente os nos; os hostnames `manager-*`, `app-worker-*`,
`mysql-data` e `rabbitmq-data` sao usados pelo labeler.

## 7. Aplicacao: automatica (com re-publicacao manual)

Nao ha o que publicar manualmente no fluxo normal: a stack `studio-cluster`
ja embute o Compose e o manager 1 publica o stack sozinho quando o Swarm fica
pronto (ver secao 5). Acompanhe:

```powershell
ssh -F "$HOME\.ssh\studio-config" studio-manager-1 `
  "sudo tail -n 40 /var/log/studio-app-deploy.log"
ssh -F "$HOME\.ssh\studio-config" studio-manager-1 `
  "sudo docker stack services studio-essencia"
```

Re-publicacao manual (novo pull das imagens `:latest`, ou mudar `API_BASE_URL`
depois de um troco de EIP). O payload ja fica no manager 1 em `/opt/studio/d.sh`:

```powershell
ssh -F "$HOME\.ssh\studio-config" studio-manager-1 `
  "sudo bash /opt/studio/d.sh <EIP> run"
```

A confirmacao do header e pela AWS CLI ou console. Para que a **proxima criacao** da stack use o Compose novo, apos editar

Acompanhe:

```bash
docker stack services studio-essencia
docker service ps studio-essencia_studio-essencia-backend
docker service ps studio-essencia_mysql
docker service ps studio-essencia_rabbitmq
```

Se um servico ficar `Pending`, confira os labels:

```bash
docker node ls
docker node inspect <ID> --format '{{json .Spec.Labels}}'
```

## 8. Acessar

Use sempre o mesmo EIP:

- Frontend: `http://<EIP>/`
- Swagger/API: `http://<EIP>:8080/swagger-ui.html`
- RabbitMQ: `http://<EIP>:15672` (`admin` / `admin`)
- WAHA: `http://<EIP>:3000`
- Health do Nginx: `http://<EIP>/nginx-health`

RabbitMQ e WAHA sao liberados apenas para `AllowedAdminCidr`.

## 9. Failover e failback

O agente no gateway reserva verifica a porta 80 do gateway ativo. Depois de
ficar armado, ele promove a reserva quando o ativo falha:

1. desassocia o EIP do ativo;
2. associa o EIP a reserva;
3. anexa o security group publico a reserva e remove do ativo;
4. substitui `0.0.0.0/0` nas tres route tables privadas;
5. permanece em espera, sem failback automatico; o retorno e manual.

Teste controlado (derrubar o gateway ativo):

```powershell
$ActiveId = aws cloudformation describe-stacks `
  --stack-name studio-gateway `
  --region $Region `
  --query "Stacks[0].Outputs[?OutputKey=='ActiveGatewayInstanceId'].OutputValue" `
  --output text

aws ec2 stop-instances --instance-ids $ActiveId --region $Region
```

A deteccao leva aproximadamente 1 minuto com os valores padrao. O failover foi
validado no laboratorio: o EIP passou para a reserva em menos de 1 minuto e o
frontend continuou em 200. As rotas privadas sao atualizadas pelo agente, mas o
EC2 pode levar alguns segundos para refletir a mudanca; confirme com
`aws ec2 describe-route-tables` antes de concluir. Valide:

```powershell
Invoke-RestMethod "http://$GatewayIp/nginx-health"
```

Depois, inicie o gateway original, espere a instancia ficar `running` e faca o
failback manual quando o Nginx estiver saudavel:

```powershell
aws ec2 start-instances --instance-ids $ActiveId --region $Region
aws ec2 wait instance-running --instance-ids $ActiveId --region $Region

.\scripts\switch-gateway.ps1 `
  -Target active `
  -GatewayStackName studio-gateway `
  -NetworkStackName studio-network `
  -Region $Region
```

O script move o EIP para o gateway original, reanexa o SG publico e atualiza as
rotas. Valide `http://$GatewayIp/nginx-health` depois do failback.

O script tambem pode ser usado com `-Target standby` para um failover manual de
emergencia. Nao atualize a stack do gateway enquanto o EIP estiver na reserva:
o CloudFormation pode tentar reaplicar a associacao original do EIP e as rotas.
Se precisar atualizar, faca o failback antes.

## 10. Dados e backup

MySQL e RabbitMQ usam volumes EBS dedicados, com `DeletionPolicy: Retain`.
Os bind mounts sao:

- MySQL: `/data/mysql`
- RabbitMQ: `/data/rabbitmq`

Os volumes continuam existindo quando a stack do cluster e removida. Eles nao
sao backup: se a instancia ou o volume for perdido, os dados podem ser perdidos.
Antes de uso real, configure snapshot EBS, teste a restauracao e defina RPO/RTO.
Na ultima migracao foram criados snapshots EBS dos dois volumes; no teardown de
2026-10-29 os volumes e os snapshots foram excluidos junto com o restante do
projeto. **Nao existe backup atual na AWS.** O procedimento de restauracao
logica (dump/restore do MySQL e definicoes do RabbitMQ) tambem continua
pendente de implementacao e teste como rotina.

Para criar um snapshot manual:

```powershell
aws ec2 create-snapshot --region $Region --volume-id <volume-id> `
  --description "backup manual studio-essencia"
```

Para restaurar, crie um volume na mesma AZ a partir do snapshot, anexe-o ao no
de dados, monte em `/data` e valide MySQL/RabbitMQ antes de liberar a aplicacao.
Um snapshot de 20 GiB nao pode ser restaurado em um volume de 8 GiB.

MySQL e RabbitMQ continuam sendo pontos unicos de falha; uma falha de AZ que
contenha o MySQL derruba o banco.

## 11. Custo, cotas e limite de 9 instancias

- Instancias: `N + 7`; com `N=2`, sao 9 running.
- vCPU aproximado: `14 + 2N` com `t3.micro` e `t3.small`; com `N=2`, 18 vCPU.
- Tipos padrao: `t3.micro` (2 gateways e 3 managers) e `t3.small` (2 workers e
  2 nos de dados).
- Volumes: 20 GiB de root nos nos do cluster (8 GiB falhou no WAHA) e 8 GiB
  nos gateways; 8 GiB de dados para novos volumes MySQL/RabbitMQ.
- Um Elastic IP.
- Sem NLB e sem NAT Gateway.

O limite do AWS Academy e de **9 instancias running**. A configuracao `N=2`
usa exatamente 9 e e a maior capacidade que cabe no laboratorio sem sacrificar
um manager, o gateway reserva ou os nos de dados. `N=3` seriam 10 running; o
laboratorio termina a decima automaticamente (confirmado via CloudTrail).

Lambda/start-stop nao e necessario para `N=2`. Se no futuro o desenho for para
`N=3`, a unica forma de manter 9 running seria parar o gateway reserva (ou outro
papel) e subir um terceiro worker; isso elimina o failover de entrada e piora a
disponibilidade. A Lambda poderia automatizar essa troca, mas nao cria
capacidade. Nao implemente esse caminho sem aceitar explicitamente essa perda e
testar a role/capacidade.

O default de 20 GiB de root e necessario para o WAHA; ainda assim, imagens
Docker, logs e dados podem encher o disco. Monitore `df -h` e aumente
`RootVolumeSize` ou `DataVolumeSize` se necessario (EBS nao encolhe in-place).

Confirme no AWS Academy as cotas de instancias, vCPU, EIP, EBS e a permissao de
criar os recursos. Se a cota nao permitir `N + 7`, reduza `WorkerCount`; nao
remova managers, AZs ou o gateway reserva sem registrar a perda de resiliencia.

## 12. Remocao e teardown

O caminho recomendado, a partir do root do repositorio, e:

```powershell
.\infra\scripts\destroy-all.ps1 -Force
```

O script remove, nesta ordem, `studio-cluster`, `studio-gateway` e
`studio-network`; encerra instancias remanescentes, libera EIPs e, por padrao,
exclui volumes EBS e snapshots identificados pelo projeto. Use `-KeepVolumes`
e/ou `-KeepSnapshots` para preservar esses recursos. Sem `-Force`, ele exige a
confirmacao `DELETE`.

Remocao manual equivalente:

```powershell
aws cloudformation delete-stack --stack-name studio-cluster --region $Region
aws cloudformation wait stack-delete-complete --stack-name studio-cluster --region $Region

aws cloudformation delete-stack --stack-name studio-gateway --region $Region
aws cloudformation wait stack-delete-complete --stack-name studio-gateway --region $Region

aws cloudformation delete-stack --stack-name studio-network --region $Region
aws cloudformation wait stack-delete-complete --stack-name studio-network --region $Region
```

A remocao manual das stacks retem os volumes EBS do MySQL e do RabbitMQ. Depois
de confirmar que os dados podem ser descartados, exclua os volumes e snapshots
manualmente no console ou com `aws ec2 delete-volume` /
`aws ec2 delete-snapshot`. No teardown de 2026-10-29, os volumes e os snapshots
do projeto tambem foram excluidos; nao ha recursos ou backup ativos.

## Diagnostico rapido

### Gateway sem NAT

No gateway ativo:

```bash
sudo systemctl status studio-nat.service --no-pager
sudo iptables -t nat -L POSTROUTING -n -v
sudo sysctl net.ipv4.ip_forward
```

### Worker nao entra no Swarm

```bash
sudo cloud-init status --long
sudo tail -n 100 /var/log/cloud-init-output.log
```

No manager:

```bash
systemctl status swarm-token.service --no-pager
curl -i http://10.20.11.10:8081/worker-token
```

### Nginx retorna 502/503

Confira os servicos e os labels:

```bash
docker service ls
docker node ls
docker service ps studio-essencia_studio-essencia-front
```

O Nginx aponta para os managers; o ingress do Swarm precisa estar ativo neles.
Se os servicos estiverem `Pending`, o labeler ainda nao aplicou as labels ou nao
ha worker de aplicacao suficiente.

### CORS bloqueado no navegador

Se o site abre, mas o console mostra "No 'Access-Control-Allow-Origin' header"
chamando a API em `:8080`, o problema e o `Host` reescrito pelo Nginx do gateway.
O bloco `listen 8080` de `/etc/nginx/conf.d/studio.conf` precisa enviar o Host
**com a porta** para o backend; caso contrario o Spring ve a chamada
(origem `http://IP`) como mesma origem do `Host: IP` recebido e nao devolve o
cabecalho CORS.

Nos dois gateways (o template ja foi corrigido em 2026-10-29; em gateways criados
antes disso, faca o hotfix ao vivo):

```bash
sudo sed -i 's/proxy_set_header Host $host;/proxy_set_header Host $http_host;/' /etc/nginx/conf.d/studio.conf
sudo nginx -t && sudo systemctl reload nginx
```

Teste de confirmacao:

```bash
curl -i -H 'Origin: http://<EIP>' 'http://<EIP>:8080/servicos?ativo=true'
```

Deve conter `Access-Control-Allow-Origin: http://<EIP>`.

### Failover nao aconteceu

No gateway reserva:

```bash
sudo systemctl status studio-failover.service --no-pager
sudo journalctl -u studio-failover.service -n 100 --no-pager
```

Se o instance profile nao puder chamar as APIs EC2, use
`scripts/switch-gateway.ps1`.
