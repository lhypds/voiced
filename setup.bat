@echo off
rem Installs what building and running the voiced service on Windows needs, skipping what is
rem already there:
rem   - Visual Studio Build Tools with the C++ tools, the linker Rust uses (several GB)
rem   - Rust, through rustup
rem   - Claude Code, for Run mode, if you want it
rem Uses winget, part of Windows 10 and 11 (App Installer in the Microsoft Store).
rem Then run install.bat.

rem Delayed expansion: the Build Tools path has "(x86)" in it, which would end a ( ) block.
setlocal EnableDelayedExpansion
where winget >nul 2>nul || (
    echo winget is missing: install App Installer from the Microsoft Store, then run setup.bat again.
    exit /b 1
)

echo == C++ build tools
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCTOOLS="
if exist "%VSWHERE%" (
    for /f "usebackq delims=" %%i in (`"%VSWHERE%" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VCTOOLS=%%i"
)
if defined VCTOOLS (
    echo Already installed: !VCTOOLS!
) else (
    echo Installing Visual Studio Build Tools with the C++ tools. This takes a while.
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if errorlevel 1 (
        echo The C++ build tools did not install.
        exit /b 1
    )
)

echo == Rust
where cargo >nul 2>nul || set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"
where cargo >nul 2>nul && (
    echo Already installed.
) || (
    winget install --id Rustlang.Rustup -e --accept-package-agreements --accept-source-agreements
    if errorlevel 1 (
        echo Rust did not install.
        exit /b 1
    )
)
"%USERPROFILE%\.cargo\bin\rustup.exe" default stable-msvc >nul 2>nul
where cargo >nul 2>nul || (
    echo Rust is installed but cargo was not found. Open a new window and run setup.bat again.
    exit /b 1
)

echo == Claude Code
where claude >nul 2>nul || set "PATH=%USERPROFILE%\.local\bin;%PATH%"
where claude >nul 2>nul && (
    echo Already installed.
) || (
    choice /C YN /M "Run mode carries sentences out with Claude Code. Install it"
    if not errorlevel 2 powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex"
)

echo.
echo Ready. Run install.bat to build and start the voiced service.
endlocal
