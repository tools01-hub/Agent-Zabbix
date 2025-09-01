# Zabbix Agent2 Install & Config Script for Windows Server
# Tested: Server 2012r2, 2016, 2019, 2022
# Save as: install_zabbix_agent2.ps1
# Run as: Administrator

$LogFile = "C:\Windows\Temp\install_zabbix.log"
Start-Transcript -Path $LogFile -Append

Write-Host "==== Starting Zabbix Agent2 Installation $(Get-Date) ===="

# Pre-requisitos
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator!"
    Stop-Transcript
    exit 1
}

# Checagem de espaco em disco na C:\
$minDiskMB = 100
$drive = Get-PSDrive -Name C
$freeMB = [int]($drive.Free/1MB)
Write-Host "Available space on C:\ : $freeMB MB"
if ($freeMB -lt $minDiskMB) {
    Write-Error "Insufficient disk space. At least ${minDiskMB}MB required."
    Stop-Transcript
    exit 1
}

# Detectar servidor Zabbix ativo
$ZabbixServers = @(
    "zbxdc1.claranet.com.br",
    "zbxdc2.claranet.com.br",
    "zbxdc3.claranet.com.br"
)
$ZabbixPort = 10051
$ListenPort = $ZabbixPort - 1
$ZabbixServer = $null

Write-Host "Procurando servidor Zabbix ativo na porta $ZabbixPort..."
foreach ($srv in $ZabbixServers) {
    try {
        $conn = Test-NetConnection -ComputerName $srv -Port $ZabbixPort -WarningAction SilentlyContinue
        if ($conn.TcpTestSucceeded) {
            Write-Host "Servidor ativo encontrado: $srv"
            $ZabbixServer = $srv
            break
        } else {
            Write-Host "Sem resposta de $srv"
        }
    } catch {
        Write-Host "Falha ao testar conexao com $srv"
    }
}
if (-not $ZabbixServer) {
    Write-Error "Nenhum servidor Zabbix ativo encontrado na porta $ZabbixPort. Abortando instalacao."
    Stop-Transcript
    exit 1
}

# Baixar e instalar Zabbix Agent2
$arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "x86" }
$LatestVersion = "7.0.16"
$DownloadUrl = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/$LatestVersion/zabbix_agent2-$LatestVersion-windows-$arch-openssl.msi"
$MsiPath = "$env:TEMP\zabbix_agent2.msi"

Write-Host "Baixando Zabbix Agent2 ($arch) versão $LatestVersion ..."

# Forçar uso de TLS 1.2 (necessário para baixar do CDN do Zabbix)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Invoke-WebRequest -Uri $DownloadUrl -OutFile $MsiPath -UseBasicParsing

# Parar servico se ja existe
if (Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue) {
    Write-Host "Zabbix Agent2 ja esta instalado. Parando servico para atualizar/configurar..."
    Stop-Service 'Zabbix Agent 2' -Force
}

Write-Host "Instalando Zabbix Agent2..."
Start-Process msiexec.exe -Wait -ArgumentList "/i `"$MsiPath`" /qn SERVER=`"$ZabbixServer`" SERVERACTIVE=`"$ZabbixServer`""

# Backup configuracao se ja existe
$ZbxConfPath = "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf"
if (Test-Path $ZbxConfPath) {
    $backup = "${ZbxConfPath}.$((Get-Date).ToString('yyyyMMddHHmmss')).bak"
    Copy-Item $ZbxConfPath $backup
    Write-Host "Backup do arquivo $ZbxConfPath criado em $backup"
}

# Escrever nova configuracao
$conf = @"
ServerActive=${ZabbixServer}:$ZabbixPort
Server=$ZabbixServer
HostnameItem=system.hostname
LogType=file
LogFile=C:\Program Files\Zabbix Agent 2\zabbix_agent2.log
LogFileSize=0
DebugLevel=3
ListenPort=$ListenPort
HostMetadata=windows
RefreshActiveChecks=300
BufferSend=60
BufferSize=1000
EnablePersistentBuffer=0
Timeout=30
Include=C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\*.conf
UnsafeUserParameters=1
Plugins.Log.MaxLinesPerSecond=7
AllowKey=system.run[*]
Plugins.SystemRun.LogRemoteCommands=1
Include=C:\Program Files\Zabbix Agent 2\zabbix_agent2.d\plugins.d\*.conf
"@
$conf | Set-Content -Encoding ASCII $ZbxConfPath

Write-Host "Arquivo de configuracao atualizado: $ZbxConfPath"

# Habilitar servico para iniciar com o Windows
Set-Service -Name 'Zabbix Agent 2' -StartupType Automatic

# Iniciar servico
Start-Service 'Zabbix Agent 2'

# Esperar 20 segundos com o servico ativo
Write-Host "Aguardando 20 segundos com o servico ativo para garantir inicializacao e registro no Zabbix..."
Start-Sleep -Seconds 20

# Reiniciar servico para finalizar o processo de instalacao/configuracao
Restart-Service 'Zabbix Agent 2'
Write-Host "Servico Zabbix Agent 2 reiniciado para concluir a instalacao/configuracao."

# Validar se servico esta rodando apos o restart
Start-Sleep -Seconds 2
$svc = Get-Service -Name 'Zabbix Agent 2'
if ($svc.Status -eq 'Running') {
    Write-Host "Zabbix Agent2 esta ativo e rodando apos o restart."
} else {
    Write-Error "Zabbix Agent2 nao esta rodando apos o restart."
    Stop-Transcript
    exit 1
}

Write-Host "==== Instalacao do Zabbix Agent2 concluida com sucesso em $(Get-Date) ===="

Remove-Item $MsiPath -Force

Stop-Transcript