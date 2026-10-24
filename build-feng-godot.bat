@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Feng Godot - build engine and native addons

rem Double-click to build the Windows x86_64 editor and native addons.
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

rem Pick up tools installed after this terminal (or Codex) was started.
for /f "delims=" %%I in ('powershell.exe -NoProfile -Command "[Environment]::ExpandEnvironmentVariables([Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User'))"') do set "PATH=%%I;%PATH%"

call :find_python || exit /b 1
call :find_scons || exit /b 1
call :setup_msvc || exit /b 1
call :find_cmake || exit /b 1
call :prepare_dependencies || exit /b 1

echo.
echo [1/4] Building Windows x86_64 editor with D3D12 and AccessKit...
if defined AGILITY_ARG (
    call %PYTHON_CMD% -m SCons platform=windows target=editor arch=x86_64 dev_build=no d3d12=yes accesskit=yes -j%JOBS% "%MESA_ARG%" "%ACCESSKIT_ARG%" "%AGILITY_ARG%"
) else (
    call %PYTHON_CMD% -m SCons platform=windows target=editor arch=x86_64 dev_build=no d3d12=yes accesskit=yes -j%JOBS% "%MESA_ARG%" "%ACCESSKIT_ARG%"
)
if errorlevel 1 exit /b 1
if not exist "%REPO_ROOT%\bin\godot.windows.editor.x86_64.exe" (
    echo [ERROR] Editor executable is missing after SCons completed.
    exit /b 1
)

echo.
echo [2/4] Building Terrain3D native debug addon...
call %PYTHON_CMD% -m SCons -C "%REPO_ROOT%\misc\feng-addons\feng-idweight-terrain\native" platform=windows target=template_debug arch=x86_64 -j%JOBS%
if errorlevel 1 exit /b 1
if not exist "%REPO_ROOT%\misc\feng-addons\feng-idweight-terrain\bin\libfeng-idweight-terrain.windows.debug.x86_64.dll" (
    echo [ERROR] Terrain3D DLL is missing after SCons completed.
    exit /b 1
)

echo.
echo [3/4] Building RenderDoc capture native debug addon...
rem Terrain3D already built the same shared godot-cpp debug library.
call %PYTHON_CMD% -m SCons -C "%REPO_ROOT%\misc\feng-addons\feng-renderdoc-capture\native" platform=windows target=template_debug arch=x86_64 build_library=no -j%JOBS%
if errorlevel 1 exit /b 1
if not exist "%REPO_ROOT%\misc\feng-addons\feng-renderdoc-capture\bin\libfeng-renderdoc-capture.windows.debug.x86_64.dll" (
    echo [ERROR] RenderDoc DLL is missing after SCons completed.
    exit /b 1
)

echo.
echo [4/4] Building NRD native addon...
set "GODOT_CPP=%REPO_ROOT%\misc\feng-addons\feng-idweight-terrain\native\godot-cpp"
set "NRD_NATIVE=%REPO_ROOT%\misc\feng-addons\feng-raytracing\native"
call %PYTHON_CMD% -m SCons -C "%GODOT_CPP%" platform=windows target=template_release arch=x86_64 -j%JOBS%
if errorlevel 1 exit /b 1
cmake -S "%NRD_NATIVE%" -B "%NRD_NATIVE%\_build" "-DGODOT_CPP_ROOT=%GODOT_CPP%" "-DGODOT_CPP_LIBRARY=%GODOT_CPP%\bin\libgodot-cpp.windows.template_release.x86_64.lib"
if errorlevel 1 exit /b 1
cmake --build "%NRD_NATIVE%\_build" --config Release --parallel %JOBS%
if errorlevel 1 exit /b 1
if not exist "%NRD_NATIVE%\..\bin\feng_nrd.dll" (
    echo [ERROR] NRD DLL is missing after CMake completed.
    exit /b 1
)

echo.
echo [DONE] Editor: %REPO_ROOT%\bin\godot.windows.editor.x86_64.exe
echo [DONE] Native debug DLLs: misc\feng-addons\feng-idweight-terrain\bin and misc\feng-addons\feng-renderdoc-capture\bin
echo [DONE] NRD: %NRD_NATIVE%\..\bin\feng_nrd.dll
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
call %PYTHON_CMD% -c "import SCons; assert tuple(int(x) for x in SCons.__version__.split('.')[:3]) >= (4, 10, 1)" >nul 2>nul
if not errorlevel 1 exit /b 0
echo [SETUP] Installing SCons 4.10.1 or newer for the selected Python...
call %PYTHON_CMD% -m pip install --user --upgrade "scons>=4.10.1,<5"
if errorlevel 1 exit /b 1
call %PYTHON_CMD% -m SCons --version
exit /b %ERRORLEVEL%

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

:find_cmake
where cmake >nul 2>nul
if errorlevel 1 if exist "%VS_INSTALL%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" set "PATH=%VS_INSTALL%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%PATH%"
call %PYTHON_CMD% -c "import re, subprocess; version = subprocess.check_output(['cmake', '--version'], text=True); print(version.splitlines()[0]); assert tuple(map(int, re.search(r'(\d+)\.(\d+)\.(\d+)', version).groups())) >= (3, 30, 0)" 2>nul
if not errorlevel 1 exit /b 0
echo [ERROR] CMake 3.30 or newer is required for NRD. Install the Visual Studio C++ CMake tools component or add CMake to PATH.
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
