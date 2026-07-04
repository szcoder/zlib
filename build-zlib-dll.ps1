#Requires -Version 5.1
<#
.SYNOPSIS
    Build a Release version of zlib1.dll (Windows x64) using Zig cc.

.DESCRIPTION
    Uses zig cc (LLVM clang) as the C compiler to build the zlib shared library
    zlib1.dll. The build includes:
      - All zlib 1.3.2 source files
      - win32/zlib_set_timer_resolution.c (DllMain that sets 2ms timer resolution
        on DLL load via NtSetTimerResolution)
    Linking uses win32/zlib.def for exported symbols and produces an import
    library libz.dll.a. The resource file win32/zlib1.rc is compiled if
    windres or rc.exe is available; otherwise it is skipped (the DLL still
    works, only without embedded version info).

.PARAMETER ZigPath
    Full path to zig.exe. Default: D:\zig-x86_64-windows-0.16.0\zig.exe

.PARAMETER OutDir
    Output directory for build artifacts. Default: <script dir>\build\release

.PARAMETER SkipResource
    Skip compiling zlib1.rc even if windres / rc.exe is found.

.EXAMPLE
    .\build-zlib-dll.ps1
    Build a Release zlib1.dll with default settings.

.EXAMPLE
    .\build-zlib-dll.ps1 -ZigPath C:\zig\zig.exe -OutDir .\out

.NOTES
    Artifacts:
      - zlib1.dll      Shared library (Release, -O3)
      - libz.dll.a     Import library (for linker)
#>
[CmdletBinding()]
param(
    [string]$ZigPath = "D:\zig-x86_64-windows-0.16.0\zig.exe",
    [string]$OutDir,
    [switch]$SkipResource
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths and configuration
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SrcDir    = $ScriptDir
if (-not $OutDir) { $OutDir = Join-Path $SrcDir 'build\release' }

# zlib source list (matches OBJS in win32/Makefile.gcc)
$ZlibSrcs = @(
    'adler32.c', 'compress.c', 'crc32.c', 'deflate.c', 'gzclose.c',
    'gzlib.c', 'gzread.c', 'gzwrite.c', 'inflate.c', 'infback.c',
    'inftrees.c', 'inffast.c', 'trees.c', 'uncompr.c', 'zutil.c'
)

$TimerSrc = 'win32\zlib_set_timer_resolution.c'
$DefFile  = 'win32\zlib.def'
$RcFile   = 'win32\zlib1.rc'

# Release flags: -Os optimize for size, -DNDEBUG disable asserts, -Wall warnings.
# Size optimization: -g0 strips all debug info, -fno-ident removes compiler
# identification strings, -fno-asynchronous-unwind-tables drops unwind data
# (not needed in a release DLL). ZLIB_BUILD is intentionally NOT defined
# (matches Makefile.gcc); exports go through the .def file.
$CFlags = @('-Os', '-DNDEBUG', '-Wall', '-g0', '-fno-ident',
            '-fno-asynchronous-unwind-tables', "-I$SrcDir")

$OutDll    = Join-Path $OutDir 'zlib1.dll'
$OutImplib = Join-Path $OutDir 'libz.dll.a'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step($msg) {
    Write-Host ""
    Write-Host ("==> " + $msg) -ForegroundColor Cyan
}

function Write-OK($msg) {
    Write-Host ("    [OK] " + $msg) -ForegroundColor Green
}

function Assert-Tool($path, $name) {
    if (-not (Test-Path $path)) {
        throw "Cannot find $name at: $path`nSpecify the correct path via -ZigPath."
    }
}

function Find-ResourceCompiler {
    # Prefer zig rc (built-in resinator, bundled with Zig, always available)
    if (Test-Path $ZigPath) { return @{ Exe = $ZigPath; Type = 'zig-rc' } }
    # Fallback: system windres (MinGW)
    $wr = Get-Command windres -ErrorAction SilentlyContinue
    if ($wr) { return @{ Exe = $wr.Source; Type = 'windres' } }
    # Fallback: system rc.exe (MSVC)
    $rc = Get-Command rc -ErrorAction SilentlyContinue
    if ($rc) { return @{ Exe = $rc.Source; Type = 'rc' } }
    return $null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "  Build Release zlib1.dll (Zig cc / clang)"       -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "Project dir : $SrcDir"
Write-Host "Output dir  : $OutDir"
Write-Host "Zig path    : $ZigPath"

# 0. Toolchain check
Write-Step "Checking toolchain"
Assert-Tool $ZigPath "zig.exe"
$zigVer = & $ZigPath version
Write-OK "zig $zigVer"
$ccVer = (& $ZigPath cc --version 2>&1 | Select-Object -First 1)
Write-OK $ccVer

# 1. Prepare output directory
Write-Step "Preparing output directory"
$objDir = Join-Path $OutDir 'obj'
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Path $objDir -Force | Out-Null
Write-OK $OutDir

# Work from source root so relative paths (win32\.., ../zlib.h in .rc) resolve
Set-Location $SrcDir

# 2. Compile zlib sources
Write-Step "Compiling zlib sources (-O3 -DNDEBUG)"
$objs = New-Object System.Collections.Generic.List[string]
foreach ($s in $ZlibSrcs) {
    $obj = Join-Path $objDir ([System.IO.Path]::GetFileNameWithoutExtension($s) + '.o')
    & $ZigPath cc @CFlags -c $s -o $obj
    if ($LASTEXITCODE -ne 0) { throw "Compile failed: $s" }
    $objs.Add($obj)
    Write-Host "    $s"
}
Write-OK "$($ZlibSrcs.Count) source files compiled"

# 3. Compile zlib_set_timer_resolution.c (DllMain)
Write-Step "Compiling zlib_set_timer_resolution.c (DllMain / timer resolution)"
$timerObj = Join-Path $objDir 'zlib_set_timer_resolution.o'
& $ZigPath cc @CFlags -c $TimerSrc -o $timerObj
if ($LASTEXITCODE -ne 0) { throw "Compile failed: $TimerSrc" }
$objs.Add($timerObj)
Write-OK $TimerSrc

# 4. Compile resource (optional)
$hasResource = $false
if (-not $SkipResource) {
    Write-Step "Compiling resource zlib1.rc"
    $rcInfo = Find-ResourceCompiler
    if ($rcInfo) {
        try {
            if ($rcInfo.Type -eq 'zig-rc') {
                $resObj = Join-Path $objDir 'zlib1.res'
                & $rcInfo.Exe rc /fo"$resObj" /i "$SrcDir" $RcFile
                if ($LASTEXITCODE -ne 0) { throw "zig rc failed" }
                $objs.Add($resObj)
            } elseif ($rcInfo.Type -eq 'windres') {
                $resObj = Join-Path $objDir 'zlibrc.o'
                & $rcInfo.Exe $RcFile -O coff -o $resObj
                if ($LASTEXITCODE -ne 0) { throw "windres failed" }
                $objs.Add($resObj)
            } else {
                $resObj = Join-Path $objDir 'zlib1.res'
                & $rcInfo.Exe /fo"$resObj" $RcFile
                if ($LASTEXITCODE -ne 0) { throw "rc.exe failed" }
                $objs.Add($resObj)
            }
            $hasResource = $true
            Write-OK "Using $($rcInfo.Type): $($rcInfo.Exe)"
        } catch {
            Write-Host "    [WARN] Resource compile failed, skipping: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    [SKIP] No windres / rc.exe found, skipping resource" -ForegroundColor Yellow
        Write-Host "           (DLL works fine, only missing embedded version info)" -ForegroundColor DarkGray
    }
} else {
    Write-Step "Skipping resource (-SkipResource)"
}

# 5. Link zlib1.dll
Write-Step "Linking zlib1.dll"
$linkArgs = New-Object System.Collections.Generic.List[string]
$linkArgs.Add('-shared')
$linkArgs.Add("-Wl,--out-implib,$OutImplib")
$linkArgs.Add('-Wl,--gc-sections')          # discard unreachable sections
$linkArgs.Add('-Wl,--build-id=none')        # drop the .buildid section
$linkArgs.Add('-Wl,-s')                     # strip symbols from the final image
$linkArgs.Add('-o')
$linkArgs.Add($OutDll)
$linkArgs.Add($DefFile)
foreach ($o in $objs) { $linkArgs.Add($o) }

& $ZigPath cc @linkArgs
if ($LASTEXITCODE -ne 0) { throw "Linking zlib1.dll failed" }
$dllSize = (Get-Item $OutDll).Length
Write-OK "zlib1.dll ($dllSize bytes)"
Write-OK "libz.dll.a"

# 6. Verify artifacts
Write-Step "Verifying artifacts"
if (-not (Test-Path $OutDll))    { throw "zlib1.dll not generated" }
if (-not (Test-Path $OutImplib)) { throw "libz.dll.a not generated" }

$timerBytes = [System.IO.File]::ReadAllBytes($timerObj)
$ascii = [System.Text.Encoding]::ASCII.GetString($timerBytes)
if ($ascii -match 'DllMain') {
    Write-OK "DllMain symbol present in zlib_set_timer_resolution.o"
} else {
    Write-Host "    [WARN] DllMain symbol not found in object file" -ForegroundColor Yellow
}

$dllBytes = [System.IO.File]::ReadAllBytes($OutDll)
$dllAscii = [System.Text.Encoding]::ASCII.GetString($dllBytes)
$exports = @('zlibVersion', 'deflate', 'inflate', 'compress', 'uncompress')
foreach ($e in $exports) {
    if ($dllAscii -match $e) {
        Write-OK "Export: $e"
    } else {
        Write-Host "    [WARN] Export not found in DLL: $e" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  Build succeeded (Release)"                       -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host "  zlib1.dll      : $OutDll"
Write-Host "  libz.dll.a     : $OutImplib"
Write-Host "  Size           : $dllSize bytes"
Write-Host "  Optimization   : -Os -DNDEBUG (size)"
Write-Host "  Resource       : $(if ($hasResource) {'compiled'} else {'skipped'})"
Write-Host "  Object count   : $($objs.Count)"
Write-Host "================================================" -ForegroundColor Green
