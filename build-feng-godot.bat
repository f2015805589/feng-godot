@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Feng Godot - build engine and native addons

rem Double-click to build the Windows x86_64 editor and both native debug addons.
rem From a terminal, use --no-pause to return immediately with the build exit code.
rem Set FENG_BUILD_JOBS to override the safe default of 8 parallel jobs.
set "PAUSE_ON_EXIT=1"
if /i "%~1"=="--no-pause" set "PAUSE_ON_EXIT=0"
if not "%~1"=="" if /i not "%~1"=="--no-pause" (
    echo Usage: build-feng-godot.bat [--no-pause]
    exit /b 2
)

pushd "%~dp0" || exit /b 1
set "REPO_ROOT=%CD%"
set "JOBS=8"
if defined FENG_BUILD_JOBS set "JOBS=%FENG_BUILD_JOBS%"
call :build_all
set "BUILD_RESULT=%ERRORLEVEL%"
popd
if "%PAUSE_ON_EXIT%"=="1" pause
exit /b %BUILD_RESULT%

:build_all
if not exist "%REPO_ROOT%\SConstruct" (
    echo [ERROR] SConstruct not found in %REPO_ROOT%.
    exit /b 1
)
echo [INFO] Repository: %REPO_ROOT%
echo [INFO] Parallel jobs: %JOBS%

call :find_python || exit /b 1
call :find_scons || exit /b 1
call :setup_msvc || exit /b 1
call :prepare_dependencies || exit /b 1

echo.
echo [1/3] Building Windows x86_64 editor with D3D12 and AccessKit...
if defined AGILITY_ARG (
    call scons platform=windows target=editor arch=x86_64 dev_build=no d3d12=yes accesskit=yes -j%JOBS% "%MESA_ARG%" "%ACCESSKIT_ARG%" "%AGILITY_ARG%"
) else (
    call scons platform=windows target=editor arch=x86_64 dev_build=no d3d12=yes accesskit=yes -j%JOBS% "%MESA_ARG%" "%ACCESSKIT_ARG%"
)
if errorlevel 1 exit /b 1
if not exist "%REPO_ROOT%\bin\godot.windows.editor.x86_64.exe" (
    echo [ERROR] Editor executable is missing after SCons completed.
    exit /b 1
)

echo.
echo [2/3] Building Terrain3D native debug addon...
call scons -C "%REPO_ROOT%\misc\feng-addons\feng-idweight-terrain\native" platform=windows target=template_debug arch=x86_64 -j%JOBS%
if errorlevel 1 exit /b 1
if not exist "%REPO_ROOT%\misc\feng-addons\feng-idweight-terrain\bin\libfeng-idweight-terrain.windows.debug.x86_64.dll" (
    echo [ERROR] Terrain3D DLL is missing after SCons completed.
    exit /b 1
)

echo.
echo [3/3] Building RenderDoc capture native debug addon...
call scons -C "%REPO_ROOT%\misc\feng-addons\feng-renderdoc-capture\native" platform=windows target=template_debug arch=x86_64 -j%JOBS%
if errorlevel 1 exit /b 1
if not exist "%REPO_ROOT%\misc\feng-addons\feng-renderdoc-capture\bin\libfeng-renderdoc-capture.windows.debug.x86_64.dll" (
    echo [ERROR] RenderDoc DLL is missing after SCons completed.
    exit /b 1
)

echo.
echo [DONE] Editor: %REPO_ROOT%\bin\godot.windows.editor.x86_64.exe
echo [DONE] Native debug DLLs: misc\feng-addons\feng-idweight-terrain\bin and misc\feng-addons\feng-renderdoc-capture\bin
echo [INFO] GDScript addons use their source files directly. Restart open editors to reload rebuilt DLLs.
exit /b 0

:find_python
set "PYTHON_CMD="
where py >nul 2>nul
if not errorlevel 1 (
    py -3 -c "import sys" >nul 2>nul
    if not errorlevel 1 set "PYTHON_CMD=py -3"
)
if not defined PYTHON_CMD (
    where python >nul 2>nul
    if not errorlevel 1 (
        python -c "import sys" >nul 2>nul
        if not errorlevel 1 set "PYTHON_CMD=python"
    )
)
if defined PYTHON_CMD exit /b 0
echo [ERROR] Python 3 is required. Install it and run this script again.
exit /b 1

:find_scons
where scons >nul 2>nul
if not errorlevel 1 exit /b 0
echo [SETUP] Installing SCons for the current Python user...
call %PYTHON_CMD% -m pip install --user scons
if errorlevel 1 exit /b 1
for /f "delims=" %%I in ('%PYTHON_CMD% -m site --user-base') do set "PATH=%%I\Scripts;%PATH%"
where scons >nul 2>nul
if not errorlevel 1 exit /b 0
echo [ERROR] SCons was installed but scons.exe is not on PATH.
exit /b 1

:setup_msvc
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VS_INSTALL="
if exist "%VSWHERE%" for /f "usebackq delims=" %%I in (`"%VSWHERE%" -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_INSTALL=%%I"
if defined VS_INSTALL if exist "%VS_INSTALL%\Common7\Tools\VsDevCmd.bat" (
    call "%VS_INSTALL%\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul
    if not errorlevel 1 exit /b 0
)
echo [ERROR] MSVC C++ Build Tools are unavailable. Install the Visual Studio Desktop development with C++ workload.
exit /b 1

:prepare_dependencies
set "REPO_DEPS=%REPO_ROOT%\bin\build_deps"
set "LOCAL_DEPS=%LOCALAPPDATA%\Godot\build_deps"
set "MESA_ARG="
set "ACCESSKIT_ARG="
set "AGILITY_ARG="

if exist "%REPO_DEPS%\mesa-x86_64-msvc" set "MESA_ARG=mesa_libs=%REPO_DEPS%\mesa"
if not defined MESA_ARG if exist "%LOCAL_DEPS%\mesa-x86_64-msvc" set "MESA_ARG=mesa_libs=%LOCAL_DEPS%\mesa"
if not defined MESA_ARG (
    echo [SETUP] Downloading Godot D3D12 build dependencies...
    call %PYTHON_CMD% "%REPO_ROOT%\misc\scripts\install_d3d12_sdk_windows.py"
    if errorlevel 1 exit /b 1
    if exist "%LOCAL_DEPS%\mesa-x86_64-msvc" set "MESA_ARG=mesa_libs=%LOCAL_DEPS%\mesa"
)
if not defined MESA_ARG (
    echo [ERROR] D3D12 Mesa dependencies are missing.
    exit /b 1
)

if exist "%REPO_DEPS%\accesskit\include" set "ACCESSKIT_ARG=accesskit_sdk_path=%REPO_DEPS%\accesskit"
if not defined ACCESSKIT_ARG if exist "%LOCAL_DEPS%\accesskit\include" set "ACCESSKIT_ARG=accesskit_sdk_path=%LOCAL_DEPS%\accesskit"
if not defined ACCESSKIT_ARG (
    echo [SETUP] Downloading Godot AccessKit build dependencies...
    call %PYTHON_CMD% "%REPO_ROOT%\misc\scripts\install_accesskit.py"
    if errorlevel 1 exit /b 1
    if exist "%LOCAL_DEPS%\accesskit\include" set "ACCESSKIT_ARG=accesskit_sdk_path=%LOCAL_DEPS%\accesskit"
)
if not defined ACCESSKIT_ARG (
    echo [ERROR] AccessKit dependencies are missing.
    exit /b 1
)

if exist "%REPO_DEPS%\agility_sdk" set "AGILITY_ARG=agility_sdk_path=%REPO_DEPS%\agility_sdk"
if not defined AGILITY_ARG if exist "%LOCAL_DEPS%\agility_sdk" set "AGILITY_ARG=agility_sdk_path=%LOCAL_DEPS%\agility_sdk"
exit /b 0
