param([switch]$PassThru,[string]$Root)
# Program file check: finds files damaged in transfer (lost UTF-8 BOM, NBSP indentation, cut
# lines, wrong line endings) and names the file and the cause.
#
# THIS FILE IS ASCII ONLY ON PURPOSE. A transfer that strips the BOM from every script would
# also break a checker that contains Chinese text, exactly when it is needed. Chinese messages
# are therefore written as \uXXXX escapes inside T '...'; the English meaning is in the comment
# beside each one. To change a message, write the new text and escape every non-ASCII character.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\check_files.ps1
#         exit code 0 = no errors (warnings allowed), 1 = at least one error.
#         -PassThru returns the findings as objects (file, level, message) and prints nothing.
# Read-only: it never changes, repairs or deletes a file.
$ErrorActionPreference='Stop'
function T([string]$escaped){return [regex]::Unescape($escaped)}
if(-not $Root){$Root=Split-Path -Parent $PSScriptRoot}
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$found=New-Object System.Collections.ArrayList
function Add-Finding([string]$file,[string]$level,[string]$message){[void]$found.Add([pscustomobject]@{file=$file;level=$level;message=$message})}
function Get-LineOf([string]$text,[int]$index){return ([regex]::Matches($text.Substring(0,$index),"`n")).Count+1}

# Files the running system needs. Keep in step with CLAUDE.md section 3.
$required=@('e3_monitor_native.ps1','teams_delivery.ps1','work_control.ps1','numeric_monitor.ps1',
    'teams_self_test.ps1','teams_self_test.js','teams_cdp\Delivery.ps1','teams_cdp\receiver-snapshot.js',
    'teams_cdp\receiver-switch.js','teams_receiver.ps1','teams_receiver_commands.ps1','teams_receiver_queries.ps1','teams_receiver_capture.ps1',
    'teams_receiver_watchdog.ps1','calibrator.html','work_control.js','config.json')
foreach($name in $required){
    # "file is missing"
    if(-not (Test-Path -LiteralPath (Join-Path $Root $name))){Add-Finding $name 'error' (T '\u627e\u4e0d\u5230\u9019\u500b\u6a94\u6848')}
}

$code=@('.ps1','.js','.json','.bat')
$files=@(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue|Where-Object{
    $_.Extension -in @('.ps1','.js','.json','.bat','.html','.md') -and
    $_.FullName.Substring($Root.Length) -notmatch '\\(\.[^\\]+|logs|captures|edge_profile|sample_images)\\'
})
foreach($file in $files){
    $rel=$file.FullName.Substring($Root.Length+1)
    $ext=$file.Extension.ToLowerInvariant()
    $level=if($ext -in $code){'error'}else{'warn'}
    try{$bytes=[IO.File]::ReadAllBytes($file.FullName)}
    # "cannot be read"
    catch{Add-Finding $rel 'error' ((T '\u7121\u6cd5\u8b80\u53d6\uff1a')+$_.Exception.Message);continue}
    # "file is empty"
    if(-not $bytes.Length){Add-Finding $rel $level (T '\u6a94\u6848\u662f\u7a7a\u7684');continue}
    $bom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text=[Text.Encoding]::UTF8.GetString($bytes)
    if($text.Length -and $text[0] -eq [char]0xFEFF){$text=$text.Substring(1)}
    $nonAscii=$text -match '[^\x00-\x7F]'
    # "not valid UTF-8 (saved in another encoding, or cut in the middle of a character), near line N"
    $bad=$text.IndexOf([char]0xFFFD)
    if($bad -ge 0){Add-Finding $rel $level ((T '\u4e0d\u662f\u6709\u6548\u7684 UTF-8\uff08\u53ef\u80fd\u88ab\u5b58\u6210\u5176\u4ed6\u7de8\u78bc\uff0c\u6216\u5728\u5b57\u5143\u4e2d\u9593\u88ab\u622a\u65b7\uff09\uff0c\u7d04\u5728\u7b2c ')+(Get-LineOf $text $bad)+(T ' \u884c'))}
    # "contains N NBSP (special space) characters, first at line N; the content was probably copied and pasted"
    $nbsp=([regex]::Matches($text,[string][char]0xA0)).Count
    if($nbsp){Add-Finding $rel $level ((T '\u542b ')+$nbsp+(T ' \u500b NBSP \u7279\u6b8a\u7a7a\u767d\uff0c\u7b2c\u4e00\u500b\u5728\u7b2c ')+(Get-LineOf $text $text.IndexOf([char]0xA0))+(T ' \u884c\uff1b\u5167\u5bb9\u53ef\u80fd\u662f\u8907\u88fd\u8cbc\u4e0a\u7684'))}
    # "contains a zero-width character at line N"
    $zero=[regex]::Match($text,'[\u200B\u200C\u200D\u2060\uFEFF]')
    if($zero.Success){Add-Finding $rel $level ((T '\u542b\u96f6\u5bec\u5b57\u5143\uff0c\u5728\u7b2c ')+(Get-LineOf $text $zero.Index)+(T ' \u884c'))}
    switch($ext){
        '.ps1' {
            # "UTF-8 BOM is missing; Windows PowerShell 5.1 would read the Chinese text in the wrong encoding"
            if($nonAscii -and -not $bom){Add-Finding $rel 'error' (T '\u7f3a\u5c11 UTF-8 BOM\uff0cWindows PowerShell 5.1 \u6703\u7528\u932f\u8aa4\u7684\u7de8\u78bc\u8b80\u53d6\u4e2d\u6587')}
            $tokens=$null;$parseErrors=$null
            [void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$parseErrors)
            # "cannot be parsed (N errors), first at line N: <parser message>; the file may be cut off"
            if($parseErrors.Count){Add-Finding $rel 'error' ((T '\u7121\u6cd5\u89e3\u6790\uff08')+$parseErrors.Count+(T ' \u500b\u932f\u8aa4\uff09\uff0c\u7b2c\u4e00\u500b\u5728\u7b2c ')+$parseErrors[0].Extent.StartLineNumber+(T ' \u884c\uff1a')+$parseErrors[0].Message+(T '\uff1b\u6a94\u6848\u53ef\u80fd\u88ab\u622a\u65b7'))}
        }
        '.bat' {
            # "contains non-ASCII characters; batch files must be ASCII only"
            if($nonAscii -or $bom){Add-Finding $rel 'error' (T '\u542b\u975e ASCII \u5b57\u5143\u6216 BOM\uff1b\u6279\u6b21\u6a94\u53ea\u80fd\u7528 ASCII')}
            # "has LF line endings; batch files need CRLF"
            if($text -match "(?<!`r)`n"){Add-Finding $rel 'error' (T '\u63db\u884c\u662f LF\uff1b\u6279\u6b21\u6a94\u9700\u8981 CRLF')}
        }
        '.json' {
            # "is not valid JSON: <message>"
            try{[void]($text|ConvertFrom-Json)}catch{Add-Finding $rel 'error' ((T '\u4e0d\u662f\u6709\u6548\u7684 JSON\uff1a')+$_.Exception.Message)}
        }
        '.html' {
            # "does not end with </html>; the file may be cut off"
            if(-not $text.TrimEnd().EndsWith('</html>',[StringComparison]::OrdinalIgnoreCase)){Add-Finding $rel 'error' (T '\u7d50\u5c3e\u4e0d\u662f </html>\uff1b\u6a94\u6848\u53ef\u80fd\u88ab\u622a\u65b7')}
        }
    }
}
if($PassThru){return $found.ToArray()}
$errors=@($found|Where-Object{$_.level -eq 'error'});$warnings=@($found|Where-Object{$_.level -ne 'error'})
foreach($item in $errors){Write-Host ('[X] '+$item.file+(T '\uff1a')+$item.message) -ForegroundColor Red}
foreach($item in $warnings){Write-Host ('[!] '+$item.file+(T '\uff1a')+$item.message) -ForegroundColor Yellow}
if($errors.Count){
    # "Program file check: N problems that stop the program. Transfer the files again as a zip or an attachment (never copy and paste through Teams, Outlook or a web page)."
    Write-Host ((T '\u7a0b\u5f0f\u6a94\u6aa2\u67e5\uff1a')+$errors.Count+(T ' \u500b\u6703\u8b93\u7a0b\u5f0f\u7121\u6cd5\u57f7\u884c\u7684\u554f\u984c\u3002\u8acb\u7528 zip \u6216\u9644\u4ef6\u91cd\u65b0\u50b3\u6a94\uff08\u4e0d\u8981\u7d93 Teams\u3001Outlook \u6216\u7db2\u9801\u8907\u88fd\u8cbc\u4e0a\uff09\u3002')) -ForegroundColor Red
    exit 1
}
# "Program file check: N files checked, no blocking problem" / ", N warnings"
Write-Host ((T '\u7a0b\u5f0f\u6a94\u6aa2\u67e5\uff1a\u5df2\u6aa2\u67e5 ')+$files.Count+(T ' \u500b\u6a94\u6848\uff0c\u6c92\u6709\u6703\u8b93\u7a0b\u5f0f\u7121\u6cd5\u57f7\u884c\u7684\u554f\u984c')+$(if($warnings.Count){(T '\uff0c\u53e6\u6709 ')+$warnings.Count+(T ' \u500b\u63d0\u9192')}else{''})+(T '\u3002')) -ForegroundColor Green
exit 0
