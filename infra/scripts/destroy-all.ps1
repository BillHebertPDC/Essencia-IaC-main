[CmdletBinding()]
param(
    [string]$Region = "us-west-2",
    [string]$ProjectName = "studio-essencia",
    [switch]$Force,
    [switch]$KeepVolumes,
    [switch]$KeepSnapshots
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-Aws {
    if (Get-Command aws -ErrorAction SilentlyContinue) {
        return
    }

    $candidates = @(
        (Join-Path $env:APPDATA "Python\Python314\Scripts\aws.cmd"),
        (Join-Path $env:ProgramFiles "Amazon\AWSCLIV2\aws.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $env:Path = (Split-Path $candidate) + ";" + $env:Path
            if (Get-Command aws -ErrorAction SilentlyContinue) {
                return
            }
        }
    }

    throw "AWS CLI nao encontrado."
}

function Invoke-Aws {
    param([string[]]$Arguments)

    & aws @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Falha no AWS CLI: aws " + ($Arguments -join " "))
    }
}

function Get-Ids {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -eq "None") {
        return @()
    }

    return @($Text -split "\s+" | Where-Object { $_ })
}

function Test-StackExists {
    param([string]$StackName)

    $status = & aws cloudformation list-stacks `
        --region $Region `
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED DELETE_FAILED `
        --query "StackSummaries[?StackName=='$StackName'].StackStatus | [0]" `
        --output text

    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($status) -and $status -ne "None")
}

Resolve-Aws

if (-not $Force) {
    Write-Host "ATENCAO: este comando remove stacks, instancias, EIPs e, por padrao,"
    Write-Host "volumes EBS e snapshots do projeto '$ProjectName' em $Region."
    $answer = Read-Host "Digite DELETE para confirmar"
    if ($answer -ne "DELETE") {
        throw "Remocao cancelada."
    }
}

Write-Host "Removendo stacks do projeto..."
foreach ($stackName in @("studio-cluster", "studio-gateway", "studio-network")) {
    if (-not (Test-StackExists -StackName $stackName)) {
        Write-Host "  ${stackName}: nao existe"
        continue
    }

    Write-Host "  ${stackName}: deletando..."
    Invoke-Aws -Arguments @(
        "cloudformation", "delete-stack",
        "--stack-name", $stackName,
        "--region", $Region
    )
    Invoke-Aws -Arguments @(
        "cloudformation", "wait", "stack-delete-complete",
        "--stack-name", $stackName,
        "--region", $Region
    )
    Write-Host "  ${stackName}: removida"
}

$instanceText = & aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectName" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query "Reservations[].Instances[].InstanceId" `
    --output text
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao listar instancias do projeto."
}
$instanceIds = @(Get-Ids -Text $instanceText)
if ($instanceIds.Count -gt 0) {
    Write-Host "Encerrando instancias restantes: $($instanceIds -join ', ')"
    Invoke-Aws -Arguments (@(
        "ec2", "terminate-instances",
        "--region", $Region,
        "--instance-ids"
    ) + $instanceIds)
    Invoke-Aws -Arguments (@(
        "ec2", "wait", "instance-terminated",
        "--region", $Region,
        "--instance-ids"
    ) + $instanceIds)
}

$addressJson = & aws ec2 describe-addresses `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectName" `
    --query "Addresses" `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao listar Elastic IPs do projeto."
}
$addresses = @((($addressJson -join "`n") | ConvertFrom-Json) | Where-Object { $null -ne $_ })
foreach ($address in $addresses) {
    $associationProperty = $address.PSObject.Properties["AssociationId"]
    if ($associationProperty -and $associationProperty.Value) {
        Write-Host "Desassociando EIP $($address.PublicIp)..."
        Invoke-Aws -Arguments @(
            "ec2", "disassociate-address",
            "--region", $Region,
            "--association-id", $associationProperty.Value
        )
    }
    Write-Host "Liberando EIP $($address.PublicIp)..."
    Invoke-Aws -Arguments @(
        "ec2", "release-address",
        "--region", $Region,
        "--allocation-id", $address.AllocationId
    )
}

if (-not $KeepVolumes) {
    $volumeText = & aws ec2 describe-volumes `
        --region $Region `
        --filters "Name=tag:Project,Values=$ProjectName" `
        --query "Volumes[].VolumeId" `
        --output text
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao listar volumes do projeto."
    }
    $volumeIds = @(Get-Ids -Text $volumeText)
    foreach ($volumeId in $volumeIds) {
        $state = & aws ec2 describe-volumes `
            --region $Region `
            --volume-ids $volumeId `
            --query "Volumes[0].State" `
            --output text
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao consultar o volume $volumeId."
        }
        if ($state -eq "in-use") {
            Write-Warning "Volume $volumeId ainda esta em uso; ele nao sera excluido."
            continue
        }
        Write-Host "Excluindo volume $volumeId..."
        Invoke-Aws -Arguments @(
            "ec2", "delete-volume",
            "--region", $Region,
            "--volume-id", $volumeId
        )
    }
}

if (-not $KeepSnapshots) {
    $snapshotText = & aws ec2 describe-snapshots `
        --region $Region `
        --owner-ids self `
        --filters "Name=description,Values=*$ProjectName*" `
        --query "Snapshots[].SnapshotId" `
        --output text
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao listar snapshots do projeto."
    }
    $snapshotIds = @(Get-Ids -Text $snapshotText)
    foreach ($snapshotId in $snapshotIds) {
        Write-Host "Excluindo snapshot $snapshotId..."
        Invoke-Aws -Arguments @(
            "ec2", "delete-snapshot",
            "--region", $Region,
            "--snapshot-id", $snapshotId
        )
    }
}

Write-Host ""
Write-Host "Verificacao final:"
$remainingStacks = & aws cloudformation list-stacks `
    --region $Region `
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED ROLLBACK_COMPLETE `
    --query "StackSummaries[?contains(StackName, '$ProjectName')].StackName" `
    --output text
$remainingVolumes = & aws ec2 describe-volumes `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectName" `
    --query "Volumes[].VolumeId" `
    --output text
$remainingInstances = & aws ec2 describe-instances `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectName" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query "Reservations[].Instances[].InstanceId" `
    --output text
$remainingAddresses = & aws ec2 describe-addresses `
    --region $Region `
    --filters "Name=tag:Project,Values=$ProjectName" `
    --query "Addresses[].PublicIp" `
    --output text
$remainingSnapshots = & aws ec2 describe-snapshots `
    --region $Region `
    --owner-ids self `
    --filters "Name=description,Values=*$ProjectName*" `
    --query "Snapshots[].SnapshotId" `
    --output text

Write-Host "  Stacks:    $remainingStacks"
Write-Host "  Instancias: $remainingInstances"
Write-Host "  Volumes:   $remainingVolumes"
Write-Host "  Snapshots: $remainingSnapshots"
Write-Host "  EIPs:      $remainingAddresses"
if ($KeepVolumes) {
    Write-Host "  Volumes foram mantidos por -KeepVolumes."
}
if ($KeepSnapshots) {
    Write-Host "  Snapshots foram mantidos por -KeepSnapshots."
}
Write-Host "Teardown concluido. A key pair e o arquivo SSH local nao foram removidos."
