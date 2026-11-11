param([switch]$Worker,[string]$Fixture,[string]$CaseName)
# Each case runs in a fresh PowerShell process, as the standalone receiver does.
# Binding is synthetic; all browser/send entry points are forbidden.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if($Worker){
    if('System.Drawing.Bitmap' -as [type]){throw 'Fixture contaminated: Drawing was already loaded'}
    . (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
    $script:E3WorkControlRoot=Join-Path $Fixture 'work'
    $script:E3CdpLogRoot=Join-Path $Fixture 'logs'
    function Get-E3CdpStateRoot {return (Join-Path $Fixture 'state')}
    function Resolve-E3CdpTarget([string]$name,[switch]$Headless){
        return @{route=$name;targetId='FIXTURE';binding=@{accountId='fixture';chatId='48:fixture';label='fixture'}}
    }
    function Enter-E3WorkLock {throw 'UNEXPECTED_TRANSPORT'}
    function Get-E3CdpSession {throw 'UNEXPECTED_TRANSPORT'}
    function Open-E3HeadlessTarget {throw 'UNEXPECTED_TRANSPORT'}
    function Invoke-E3Cdp {throw 'UNEXPECTED_TRANSPORT'}
    $files=@(Join-Path $Fixture 'valid.png');$message='fixture'
    $headless=$false;$reject=$false
    switch($CaseName){
        'visible' {}
        'headless' {$headless=$true}
        'image-only' {$message=''}
        'text-only' {$files=@()}
        'bad-signature' {$files=@(Join-Path $Fixture 'invalid.png');$reject=$true}
        'broken-png' {$files=@(Join-Path $Fixture 'broken.png');$reject=$true}
        'oversize' {$files=@(Join-Path $Fixture 'oversize.png');$reject=$true}
        'mixed-invalid' {$files+=Join-Path $Fixture 'invalid.png';$reject=$true}
        default {throw 'Unknown fixture case'}
    }
    $failure=''
    try{Send-GroupToTeamsCdp 'fixture' $files $message @{cdp_headless=$headless;auto_press_enter=$true} $true}
    catch{$failure=$_.Exception.Message}
    if($failure -match 'Unable to find type|UNEXPECTED_TRANSPORT'){throw $failure}
    if($reject -and -not $failure){throw 'Invalid image was accepted'}
    if(-not $reject -and $failure){throw $failure}
    if($files.Count -and -not ('System.Drawing.Bitmap' -as [type])){throw 'Image preflight did not load Drawing'}
    if(-not $files.Count -and ('System.Drawing.Bitmap' -as [type])){throw 'Text-only preflight unnecessarily loaded Drawing'}
    # Image validation must release file handles, including after rejection.
    foreach($file in $files){$stream=[IO.File]::Open($file,'Open','ReadWrite','None');$stream.Dispose()}
    "PASS $CaseName; no browser or send"
    exit 0
}
$Fixture=Join-Path $env:TEMP ('E3ImagePreflight_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Fixture)
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
foreach($item in @(@{name='valid.png';width=16},@{name='oversize.png';width=4097})){
    $bitmap=[Drawing.Bitmap]::new($item.width,1)
    try{$bitmap.Save((Join-Path $Fixture $item.name),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
[IO.File]::WriteAllBytes((Join-Path $Fixture 'invalid.png'),[byte[]](0,1,2,3,4,5,6,7,8))
[IO.File]::WriteAllBytes((Join-Path $Fixture 'broken.png'),[byte[]](137,80,78,71,13,10,26,10,0))
$cases=@('visible','headless','image-only','text-only','bad-signature','broken-png','oversize','mixed-invalid')
foreach($name in $cases){
    $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Worker -Fixture $Fixture -CaseName $name 2>&1
    $code=$LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $Fixture ($name+'.log')),[string[]]$output,[Text.UTF8Encoding]::new($false))
    if($code -ne 0){throw "FAIL $name (exit $code): $($output -join ' ')"}
    $output|Select-Object -Last 1
}
"CDP_IMAGE_PREFLIGHT_PASS: $($cases.Count) fresh processes; fixture=$Fixture"