param(
    [ValidateSet("active", "standby")]
    [string]$Target = "active",

    [string]$GatewayStackName = "studio-gateway",
    [string]$NetworkStackName = "studio-network",
    [string]$Region = "us-west-2"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-StackOutput {
    param(
        [string]$StackName,
        [string]$Key
    )

    $value = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue | [0]" `
        --output text

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value) -or $value -eq "None") {
        throw "Saida $Key nao encontrada na stack $StackName"
    }

    return $value.Trim()
}

$eipAllocationId = Get-StackOutput -StackName $GatewayStackName -Key "EipAllocationId"
$publicIp = Get-StackOutput -StackName $GatewayStackName -Key "PublicIp"
$originalActiveId = Get-StackOutput -StackName $GatewayStackName -Key "ActiveGatewayInstanceId"
$originalStandbyId = Get-StackOutput -StackName $GatewayStackName -Key "StandbyGatewayInstanceId"

$managementSg = Get-StackOutput -StackName $NetworkStackName -Key "GatewayManagementSecurityGroupId"
$natSg = Get-StackOutput -StackName $NetworkStackName -Key "GatewayNatSecurityGroupId"
$appSg = Get-StackOutput -StackName $NetworkStackName -Key "GatewayAppSecurityGroupId"

$routeTables = @(
    (Get-StackOutput -StackName $NetworkStackName -Key "PrivateRouteTable1Id"),
    (Get-StackOutput -StackName $NetworkStackName -Key "PrivateRouteTable2Id"),
    (Get-StackOutput -StackName $NetworkStackName -Key "PrivateRouteTable3Id")
)

if ($Target -eq "active") {
    $targetInstanceId = $originalActiveId
    $otherInstanceId = $originalStandbyId
} else {
    $targetInstanceId = $originalStandbyId
    $otherInstanceId = $originalActiveId
}

Write-Host "Movendo o EIP $eipAllocationId para $TargetInstanceId ($Target)..."

$associationId = aws ec2 describe-addresses `
    --allocation-ids $eipAllocationId `
    --region $Region `
    --query "Addresses[0].AssociationId" `
    --output text

if ($LASTEXITCODE -ne 0) {
    throw "Falha ao consultar a associacao atual do EIP"
}

if ($associationId -and $associationId -ne "None") {
    aws ec2 disassociate-address `
        --association-id $associationId `
        --region $Region | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao desassociar o EIP"
    }
}

aws ec2 associate-address `
    --allocation-id $eipAllocationId `
    --instance-id $targetInstanceId `
    --allow-reassociation `
    --region $Region | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Falha ao associar o EIP ao destino"
}

$targetGroups = @($managementSg, $natSg, $appSg)
$otherGroups = @($managementSg, $natSg)

aws ec2 modify-instance-attribute `
    --instance-id $targetInstanceId `
    --groups $targetGroups `
    --region $Region

if ($LASTEXITCODE -ne 0) {
    throw "Falha ao anexar o security group publico ao destino"
}

aws ec2 modify-instance-attribute `
    --instance-id $otherInstanceId `
    --groups $otherGroups `
    --region $Region

if ($LASTEXITCODE -ne 0) {
    throw "Falha ao remover o security group publico da origem"
}

foreach ($routeTableId in $routeTables) {
    aws ec2 replace-route `
        --route-table-id $routeTableId `
        --destination-cidr-block "0.0.0.0/0" `
        --instance-id $targetInstanceId `
        --region $Region | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao atualizar a rota da tabela $routeTableId"
    }
}

Write-Host "Concluido. EIP e rotas agora apontam para $targetInstanceId ($Target)."
Write-Host "Valide: http://$publicIp/nginx-health"
