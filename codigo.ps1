<#
.SYNOPSIS
    Engine de Geração Dinâmica de Infraestrutura CloudFormation.
    Suporta inclusão/exclusão condicional de recursos (Flags 'Enabled').
#>

Param(
    [string]$ArchitectureConfigFile = "architecture-spec.json",
    [string]$OutputFile = "cloudformation-dynamic-output.yaml"
)

if (-not (Test-Path $ArchitectureConfigFile)) {
    Write-Error "Arquivo de especificação '$ArchitectureConfigFile' não encontrado."
    exit 1
}

$spec = Get-Content -Raw -Path $ArchitectureConfigFile | ConvertFrom-Json

# Estrutura Base
$cfnTemplate = [ordered]@{
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = $spec.Description
    Parameters               = [ordered]@{}
    Conditions               = [ordered]@{}
    Resources                = [ordered]@{}
    Outputs                  = [ordered]@{}
}

# 1. Carrega Parâmetros Globais
foreach ($param in $spec.Parameters.PSObject.Properties) {
    $cfnTemplate.Parameters[$param.Name] = $param.Value
}

# 2. Geração Dinâmica de Condições e Flags (Enable/Disable Features)
if ($spec.Features) {
    foreach ($feature in $spec.Features.PSObject.Properties) {
        # Adiciona o Parâmetro de Ativação (ex: EnableNatGateway = "true")
        $paramName = "Enable$($feature.Name)"
        $cfnTemplate.Parameters[$paramName] = [ordered]@{
            Type          = "String"
            Default       = if ($feature.Value) { "true" } else { "false" }
            AllowedValues = @("true", "false")
            Description   = "Habilita ou desabilita o recurso $($feature.Name)"
        }
        
        # Cria a condição no CloudFormation
        $condName = "Create$($feature.Name)"
        $cfnTemplate.Conditions[$condName] = @{
            "Fn::Equals" = @("!Ref $paramName", "true")
        }
    }
}

# 3. Componentes da Rede (VPC, IGW, Subnets)
$network = $spec.Network
$azCount = if ($network.AzCount) { [int]$network.AzCount } else { 2 }

# VPC Base
$cfnTemplate.Resources["VPC"] = [ordered]@{
    Type       = "AWS::EC2::VPC"
    Properties = [ordered]@{
        CidrBlock           = $network.VpcCidr
        EnableDnsSupport    = $true
        EnableDnsHostnames  = $true
        Tags                = @(@{ Key = "Name"; Value = "!Sub `"${ProjectName}-vpc`"" })
    }
}

# Internet Gateway (Opcional - controlado pela feature 'InternetAccess')
$isIgwEnabled = ($null -eq $spec.Features.InternetAccess) -or ($spec.Features.InternetAccess -eq $true)
$igwResource = [ordered]@{
    Type       = "AWS::EC2::InternetGateway"
    Properties = [ordered]@{
        Tags = @(@{ Key = "Name"; Value = "!Sub `"${ProjectName}-igw`"" })
    }
}
if ($spec.Features.InternetAccess -ne $null) {
    $igwResource["Condition"] = "CreateInternetAccess"
}
$cfnTemplate.Resources["InternetGateway"] = $igwResource

$cfnTemplate.Resources["VPCGatewayAttachment"] = [ordered]@{
    Type       = "AWS::EC2::VPCGatewayAttachment"
    Condition  = if ($spec.Features.InternetAccess -ne $null) { "CreateInternetAccess" } else { $null }
    Properties = [ordered]@{
        VpcId             = "!Ref VPC"
        InternetGatewayId = "!Ref InternetGateway"
    }
} | Where-Object { $_.Value -ne $null -or $_.Key -ne "Condition" }

# Subnets Públicas e Privadas
$publicSubnetRefs  = @()
$privateSubnetRefs = @()

for ($azIndex = 0; $azIndex -lt $azCount; $azIndex++) {
    $azNumber = $azIndex + 1
    
    # Subnet Pública
    if ($network.PublicSubnetCidrs -and $azIndex -lt $network.PublicSubnetCidrs.Count) {
        $pubSubnetName = "PublicSubnetAZ$azNumber"
        $publicSubnetRefs += $pubSubnetName
        
        $cfnTemplate.Resources[$pubSubnetName] = [ordered]@{
            Type       = "AWS::EC2::Subnet"
            Properties = [ordered]@{
                VpcId               = "!Ref VPC"
                CidrBlock           = $network.PublicSubnetCidrs[$azIndex]
                AvailabilityZone    = "!Select [ $azIndex, !GetAZs '' ]"
                MapPublicIpOnLaunch = $true
                Tags                = @(@{ Key = "Name"; Value = "!Sub `"${ProjectName}-public-az$azNumber`"" })
            }
        }
    }

    # Subnet Privada
    if ($network.PrivateSubnetCidrs -and $azIndex -lt $network.PrivateSubnetCidrs.Count) {
        $privSubnetName = "PrivateSubnetAZ$azNumber"
        $privateSubnetRefs += $privSubnetName

        $cfnTemplate.Resources[$privSubnetName] = [ordered]@{
            Type       = "AWS::EC2::Subnet"
            Properties = [ordered]@{
                VpcId               = "!Ref VPC"
                CidrBlock           = $network.PrivateSubnetCidrs[$azIndex]
                AvailabilityZone    = "!Select [ $azIndex, !GetAZs '' ]"
                MapPublicIpOnLaunch = $false
                Tags                = @(@{ Key = "Name"; Value = "!Sub `"${ProjectName}-private-az$azNumber`"" })
            }
        }
    }
}

# 4. Security Groups Condicionais
foreach ($sg in $spec.SecurityGroups) {
    # Pula a criação do SG se a propriedade 'Enabled' for explicitamente 'false'
    if ($sg.PSObject.Properties["Enabled"] -and $sg.Enabled -eq $false) {
        continue
    }

    $ingressRules = @()
    foreach ($rule in $sg.Rules) {
        $ingressRules += [ordered]@{
            IpProtocol  = $rule.Protocol
            FromPort    = $rule.Port
            ToPort      = $rule.Port
            CidrIp      = $rule.CidrIp
        }
    }

    $sgResource = [ordered]@{
        Type       = "AWS::EC2::SecurityGroup"
        Properties = [ordered]@{
            GroupDescription = $sg.Description
            VpcId            = "!Ref VPC"
            SecurityGroupIngress = $ingressRules
            Tags             = @(@{ Key = "Name"; Value = "!Sub `"${ProjectName}-$($sg.Name)`"" })
        }
    }

    if ($sg.ConditionName) {
        $sgResource["Condition"] = $sg.ConditionName
    }

    $cfnTemplate.Resources[$sg.Name] = $sgResource
}

# 5. Grupos de Nós / Servidores Condicionais
foreach ($nodeGroup in $spec.NodeGroups) {
    # Se o grupo inteiro estiver desativado no JSON, ele não é gerado no template
    if ($nodeGroup.PSObject.Properties["Enabled"] -and $nodeGroup.Enabled -eq $false) {
        continue
    }

    $count  = $nodeGroup.Count
    $prefix = $nodeGroup.NamePrefix
    
    for ($i = 1; $i -le $count; $i++) {
        $resourceName = "$prefix$i"
        
        $targetAZIndex = ($i - 1) % $azCount
        $selectedSubnet = if ($nodeGroup.SubnetType -eq "Public") {
            $publicSubnetRefs[$targetAZIndex]
        } else {
            $privateSubnetRefs[$targetAZIndex]
        }
        
        # UserData e BaseData Files
        $userDataScript = "#!/bin/bash`nset -e`n"
        if ($nodeGroup.BaseDataFiles) {
            foreach ($file in $nodeGroup.BaseDataFiles) {
                $filePath = $file.Path
                $fileContent = $file.Content -join "`n"
                
                $userDataScript += "mkdir -p \$(dirname '$filePath')`n"
                $userDataScript += "cat << 'EOF' > $filePath`n$fileContent`nEOF`n"
                
                if ($file.Permissions) {
                    $userDataScript += "chmod $($file.Permissions)$filePath`n"
                }
            }
        }
        
        if ($nodeGroup.BootstrapCommand) {
            $userDataScript += "$($nodeGroup.BootstrapCommand)`n"
        }

        $instanceResource = [ordered]@{
            Type       = "AWS::EC2::Instance"
            Properties = [ordered]@{
                ImageId          = "!Ref ImageId"
                InstanceType     = "!Ref InstanceType"
                SubnetId         = "!Ref $selectedSubnet"
                SecurityGroupIds = @("!Ref $($nodeGroup.SecurityGroupRef)")
                UserData         = @{ "Fn::Base64" = $userDataScript }
                Tags             = @(
                    @{ Key = "Name"; Value = "!Sub `"${ProjectName}-$prefix-$i`"" }
                )
            }
        }

        # Vincula Condição nativa do CloudFormation se especificado no JSON
        if ($nodeGroup.ConditionFeature) {$instanceResource["Condition"] = "Create$($nodeGroup.ConditionFeature)"
        }

        if ($nodeGroup.DependsOnNode) {
            $instanceResource["DependsOn"] = $nodeGroup.DependsOnNode
        }

        $cfnTemplate.Resources[$resourceName] =$instanceResource
    }
}

# 6. Serializador YAML
function ConvertTo-CfnYaml ($obj, $depth = 0) {$indent = "  " * $depth$yaml = ""

    if ($obj -is [System.Collections.IDictionary]) {
        foreach ($key in $obj.Keys) {$val = $obj[$key]
            # Omite entradas com valor nulo
            if ($null -eq$val) { continue }

            if ($val -is [System.Collections.IDictionary] -or $val -is [PSCustomObject]) {$yaml += "$indent$key:`n"
                $yaml += ConvertTo-CfnYaml -obj $val -depth ($depth + 1)
            } elseif ($val -is [System.Collections.IList] -or $val -is [Array]) {
                $yaml += "$indent$key:`n"
                foreach ($item in$val) {
                    if ($item -is [System.Collections.IDictionary] -or$item -is [PSCustomObject]) {
                        $yaml += "$indent  - `n"
                        $yaml += ConvertTo-CfnYaml -obj $item -depth ($depth + 2)
                    } else {
                        $yaml += "$indent  - $item`n"
                    }
                }
            } else {
                $strVal = "$val"
                if ($strVal.StartsWith("!")) {
                    $yaml += "$indent$key:$strVal`n"
                } else {
                    $yaml += "$indent$key: `"$strVal`"`n"
                }
            }
        }
    }
    return $yaml
}

$yamlOutput = ConvertTo-CfnYaml -obj$cfnTemplate
Set-Content -Path $OutputFile -Value$yamlOutput -Encoding UTF8
Write-Host "Template gerado com regras condicionais ativas em: $OutputFile" -ForegroundColor Green