<#
.SYNOPSIS
    构建 50 人研发团队的物理隔离仿真实验室 (Air-Gapped Lab Setup)
.DESCRIPTION
    基于 Hyper-V 模拟 TrueNAS, PVE, UPS, Docker集群, 开发机与测试机。
    包含 ISO 自动下载逻辑（需网络）和 虚拟硬件配置。
.NOTES
    存储路径: D:\Lab_Infrastructure (可修改)
#>

# ==========================================
# 1. 全局配置 (可根据实际情况修改)
# ==========================================
$LabRoot = "D:\Lab_Infrastructure"      # 2TB 硬盘的挂载路径
$ISODir  = "$LabRoot\ISOs"              # 镜像存放目录
$VMDir   = "$LabRoot\VMs"               # 虚拟机磁盘目录
$SwitchName = "Lab-Core-Switch-10G"     # 模拟核心交换机

# 虚拟机规格配置 (模拟真实硬件配比)
$Specs = @{
    TrueNAS      = @{ CPU = 4; RAM = 8GB;  BootDisk = 32GB;  DataDisk = 1TB }  # 模拟存储服务器
    OpsServer_PVE= @{ CPU = 8; RAM = 16GB; BootDisk = 128GB; DataDisk = 500GB} # 模拟计算宿主机 (需开启嵌套虚拟化)
    Sim_UPS      = @{ CPU = 1; RAM = 1GB;  BootDisk = 16GB }                   # 模拟 UPS (运行 NUT Server)
    Docker_Node  = @{ CPU = 4; RAM = 8GB;  BootDisk = 64GB }                   # 模拟 Tier 2 测试集群
    Dev_Machine  = @{ CPU = 4; RAM = 8GB;  BootDisk = 128GB }                  # 模拟开发机 (Win11)
    Test_Machine = @{ CPU = 2; RAM = 4GB;  BootDisk = 64GB }                   # 模拟 Tier 4 测试机 (VHDX Boot验证)
}

# 镜像下载链接 (注意：Windows 和 Proxmox 链接可能会随时间变化，建议手动下载替换)
$Images = @{
    "TrueNAS-Scale" = @{ 
        Url = "https://download.truenas.com/TrueNAS-SCALE-Cobia/23.10.1/TrueNAS-SCALE-23.10.1.iso"
        File = "TrueNAS-SCALE.iso" 
    }
    "Proxmox-VE" = @{ 
        Url = "https://enterprise.proxmox.com/iso/proxmox-ve_8.1-1.iso" 
        File = "proxmox-ve.iso" 
    }
    "Ubuntu-Server" = @{ 
        Url = "https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso" 
        File = "ubuntu-server-24.04.iso" 
    }
    # Windows 镜像通常无法直链下载，这里使用空位，后续脚本会提示手动放入
    "Windows-11" = @{ 
        Url = "" 
        File = "Windows11_Dev.iso" 
    }
}

# ==========================================
# 2. 环境初始化
# ==========================================
Write-Host ">>> [Phase 1] 初始化实验室环境..." -ForegroundColor Cyan

# 创建目录
if (!(Test-Path $LabRoot)) { New-Item -Path $LabRoot -ItemType Directory | Out-Null }
if (!(Test-Path $ISODir))  { New-Item -Path $ISODir -ItemType Directory | Out-Null }
if (!(Test-Path $VMDir))   { New-Item -Path $VMDir -ItemType Directory | Out-Null }

# 创建核心交换机 (Internal 类型，模拟内网，宿主机可管理，外网不通)
if (!(Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Host "    正在创建虚拟交换机: $SwitchName (模拟万兆内网)"
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    # 开启巨型帧 (Jumbo Packet) 模拟存储网络优化
    # 注意: 物理网卡支持才生效，这里仅作逻辑模拟
} else {
    Write-Host "    虚拟交换机已存在，跳过。" -ForegroundColor Gray
}

# ==========================================
# 3. 镜像下载逻辑
# ==========================================
Write-Host "`n>>> [Phase 2] 检查并下载系统镜像..." -ForegroundColor Cyan

Function Download-ISO {
    param ($Name, $Info)
    $Path = Join-Path $ISODir $Info.File
    
    if (Test-Path $Path) {
        Write-Host "    [EXIST] $Name 已存在 ($Path)" -ForegroundColor Green
        return $Path
    }

    if ($Info.Url -eq "") {
        Write-Host "    [MANUAL] 请手动下载 $Name 镜像并放置于: $Path" -ForegroundColor Yellow
        return $null
    }

    Write-Host "    [DOWNLOADING] 正在下载 $Name ..." -NoNewline
    try {
        Invoke-WebRequest -Uri $Info.Url -OutFile $Path -UseBasicParsing
        Write-Host " 完成!" -ForegroundColor Green
        return $Path
    } catch {
        Write-Host " 失败! 请检查网络链接。" -ForegroundColor Red
        return $null
    }
}

# 执行下载
$ISOPaths = @{}
foreach ($key in $Images.Keys) {
    $ISOPaths[$key] = Download-ISO -Name $key -Info $Images[$key]
}

# ==========================================
# 4. 虚拟机构建函数
# ==========================================
Function New-LabVM {
    param (
        [string]$Name,
        [int]$CPU,
        [string]$RAM,
        [string]$BootDiskSize,
        [string]$DataDiskSize = $null,
        [string]$IsoPath = $null,
        [bool]$NestedVirt = $false,
        [bool]$SecureBoot = $true
    )

    Write-Host "`n    正在构建: $Name"
    
    # 检查 VM 是否存在
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "    [SKIP] 虚拟机已存在，跳过创建。" -ForegroundColor Yellow
        return
    }

    # 1. 创建 VM
    $VmPath = Join-Path $VMDir $Name
    New-Item -Path $VmPath -ItemType Directory -Force | Out-Null
    
    New-VM -Name $Name -MemoryStartupBytes $RAM -SwitchName $SwitchName -Path $VMDir -Generation 2 | Out-Null

    # 2. 配置 CPU
    Set-VMProcessor -VMName $Name -Count $CPU
    if ($NestedVirt) {
        Write-Host "    -> 开启嵌套虚拟化 (ExposeVirtualizationExtensions)" -ForegroundColor Magenta
        Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
    }

    # 3. 创建并挂载系统盘
    $BootDiskPath = Join-Path $VmPath "$Name-OS.vhdx"
    New-VHD -Path $BootDiskPath -SizeBytes $BootDiskSize -Dynamic | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $BootDiskPath

    # 4. (可选) 创建并挂载数据盘
    if ($DataDiskSize) {
        $DataDiskPath = Join-Path $VmPath "$Name-Data.vhdx"
        Write-Host "    -> 挂载数据盘: $DataDiskSize"
        New-VHD -Path $DataDiskPath -SizeBytes $DataDiskSize -Dynamic | Out-Null
        Add-VMHardDiskDrive -VMName $Name -Path $DataDiskPath
    }

    # 5. 挂载 ISO
    if ($IsoPath -and (Test-Path $IsoPath)) {
        Add-VMDvdDrive -VMName $Name -Path $IsoPath
        # 设置 DVD 为第一启动项
        $dvd = Get-VMDvdDrive -VMName $Name
        Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
    }

    # 6. 安全启动设置 (Linux/TrueNAS 需要关闭 Windows 默认的安全启动或改为 Template)
    if (-not $SecureBoot) {
        Set-VMFirmware -VMName $Name -EnableSecureBoot Off
    } else {
        # 默认 Windows 开启
    }

    Write-Host "    [SUCCESS] $Name 创建完成。" -ForegroundColor Green
}

# ==========================================
# 5. 批量部署架构
# ==========================================
Write-Host "`n>>> [Phase 3] 部署物理层架构虚拟机..." -ForegroundColor Cyan

# 5.1 TrueNAS (存储层) - 关闭安全启动，因为是 Debian/Linux
New-LabVM -Name "Lab-Storage-TrueNAS" `
          -CPU $Specs.TrueNAS.CPU -RAM $Specs.TrueNAS.RAM `
          -BootDiskSize $Specs.TrueNAS.BootDisk -DataDiskSize $Specs.TrueNAS.DataDisk `
          -IsoPath $ISOPaths["TrueNAS-Scale"] `
          -SecureBoot $false

# 5.2 Ops Server (PVE) (计算层) - 必须开启嵌套虚拟化，关闭安全启动
New-LabVM -Name "Lab-Ops-ProxmoxVE" `
          -CPU $Specs.OpsServer_PVE.CPU -RAM $Specs.OpsServer_PVE.RAM `
          -BootDiskSize $Specs.OpsServer_PVE.BootDisk -DataDiskSize $Specs.OpsServer_PVE.DataDisk `
          -IsoPath $ISOPaths["Proxmox-VE"] `
          -NestedVirt $true `
          -SecureBoot $false

# 5.3 Simulated UPS (电力层) - 用 Ubuntu 模拟，装 NUT
New-LabVM -Name "Lab-Power-UPS" `
          -CPU $Specs.Sim_UPS.CPU -RAM $Specs.Sim_UPS.RAM `
          -BootDiskSize $Specs.Sim_UPS.BootDisk `
          -IsoPath $ISOPaths["Ubuntu-Server"] `
          -SecureBoot $false

# 5.4 Docker Cluster (测试层 Tier 2)
New-LabVM -Name "Lab-Test-DockerNode" `
          -CPU $Specs.Docker_Node.CPU -RAM $Specs.Docker_Node.RAM `
          -BootDiskSize $Specs.Docker_Node.BootDisk `
          -IsoPath $ISOPaths["Ubuntu-Server"] `
          -SecureBoot $false

# 5.5 开发机 (终端层 Tier 1) - Windows
New-LabVM -Name "Lab-Client-Dev01" `
          -CPU $Specs.Dev_Machine.CPU -RAM $Specs.Dev_Machine.RAM `
          -BootDiskSize $Specs.Dev_Machine.BootDisk `
          -IsoPath $ISOPaths["Windows-11"] `
          -SecureBoot $true

# 5.6 测试机 (Tier 4) - 用于验证 VHDX 启动 (这里模拟为一台普通 VM)
New-LabVM -Name "Lab-Client-Test01" `
          -CPU $Specs.Test_Machine.CPU -RAM $Specs.Test_Machine.RAM `
          -BootDiskSize $Specs.Test_Machine.BootDisk `
          -IsoPath $ISOPaths["Windows-11"] `
          -SecureBoot $true

# ==========================================
# 6. 结束指引
# ==========================================
Write-Host "`n======================================================="
Write-Host " 实验室架构部署脚本执行完毕！" -ForegroundColor Cyan
Write-Host "======================================================="
Write-Host "接下来的手动步骤："
Write-Host "1. 如果脚本提示手动下载 Windows/Proxmox 镜像，请下载并放入: $ISODir"
Write-Host "   然后在 Hyper-V 管理器中手动挂载 ISO 到对应 VM。"
Write-Host "2. 启动 'Lab-Storage-TrueNAS'，按照屏幕提示安装系统。"
Write-Host "   (安装后 Web 访问 IP 需在宿主机配置 NAT 或通过虚拟机连接)"
Write-Host "3. 启动 'Lab-Ops-ProxmoxVE'，安装 PVE 环境。"
Write-Host "   (验证：在 PVE 里的虚拟机能否启动，测试嵌套虚拟化)"
Write-Host "4. 你的 '核心交换机' 是 Hyper-V 的 '$SwitchName'。"
Write-Host "   请确保所有 VM 的 IP 地址手动配置在同一网段 (如 192.168.30.x)。"
Write-Host "======================================================="