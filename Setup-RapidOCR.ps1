param([string]$Python='python')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$helper=Join-Path $root 'rapidocr-helper'
$runtime=Join-Path $helper '.venv\Scripts\python.exe'
if(!(Test-Path -LiteralPath $runtime)){
 & $Python -m venv (Join-Path $helper '.venv')
 if($LASTEXITCODE -ne 0){throw 'Install Python 3.11+ from python.org, then run this setup again.'}
}
& $runtime -m pip install -r (Join-Path $helper 'requirements.txt')
if($LASTEXITCODE -ne 0){throw 'RapidOCR dependency installation failed'}
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class OcrSetupIni {
 [DllImport("kernel32",CharSet=CharSet.Unicode)]
 public static extern bool WritePrivateProfileString(string section,string key,string value,string path);
}
'@
$ini=Join-Path $root 'OcrBoxes\OCR Boxes.ini'
if(Test-Path -LiteralPath $ini){Copy-Item -LiteralPath $ini -Destination ($ini+'.before-setup-'+(Get-Date -Format yyyyMMddHHmmss))}
foreach($entry in @(@('helper','python',$runtime),@('ocr','engine','rapid'),@('capture','mode','general'))){
 if(![OcrSetupIni]::WritePrivateProfileString($entry[0],$entry[1],$entry[2],$ini)){throw 'Could not write OCR setup setting'}
}
Write-Output 'RapidOCR configured. Start OcrBoxes\OCR Boxes.ahk with AutoHotkey v2.'
