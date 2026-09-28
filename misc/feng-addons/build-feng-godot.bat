@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
title Feng Godot 一键编译

rem ============================================================
rem  Feng Godot 一键编译（引擎 + 内建模块/插件）
rem
rem  本脚本位于 misc\feng-addons\，自动定位仓库根目录：
rem    1. 检查 Python / SCons（缺 SCons 时用 pip 自动安装）
rem    2. 检查 MSVC + Windows SDK（缺失时尝试用 winget 自动安装
rem       Visual Studio 2022 Build Tools）
rem    3. 检查 D3D12 依赖（Mesa NIR / Agility SDK / PIX）和
rem       AccessKit，缺失时运行官方 install_*_windows.py 自动下载
rem    4. scons 编译 editor，产物输出到仓库 bin\ 目录
rem
rem  用法：双击运行，或在命令行里追加 scons 参数覆盖，例如：
rem       build-feng-godot.bat target=template_release
rem       build-feng-godot.bat d3d12=no
rem ============================================================

rem ---- 定位仓库根目录（本文件在 misc\feng-addons\ 下）----
pushd "%~dp0..\.." || (echo [错误] 无法定位仓库根目录。& exit /b 1)
set "REPO_ROOT=%CD%"
echo [信息] 仓库根目录: %REPO_ROOT%

rem ---- 1. Python ----
set "PY="
where py >nul 2>nul && py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY (
	where python >nul 2>nul && python -c "import sys" >nul 2>nul && set "PY=python"
)
if not defined PY (
	echo [错误] 未找到 Python。请先安装 Python 3.8+，或运行：
	echo         winget install -e --id Python.Python.3.12
	exit /b 1
)
echo [信息] Python: %PY%

rem ---- 2. SCons ----
where scons >nul 2>nul
if errorlevel 1 (
	echo [检查] 未找到 scons，正在用 pip 自动安装...
	%PY% -m pip install --user --upgrade scons || (
		echo [错误] scons 安装失败。请检查网络后重试。
		exit /b 1
	)
	rem 用户级 pip 安装后 Scripts 目录可能不在 PATH，补到本次会话 PATH。
	call :add_user_scripts_dir
	where scons >nul 2>nul || (
		echo [错误] 已安装 scons 但不在 PATH，请重开终端或手动加入 Scripts 目录。
		exit /b 1
	)
)
echo [信息] SCons 就绪。

rem ---- 3. MSVC + Windows SDK ----
call :detect_vs
if not defined VS_INSTALL (
	echo [检查] 未找到带 C++ 工作负载的 Visual Studio / Build Tools。
	where winget >nul 2>nul
	if errorlevel 1 (
		echo [错误] 系统没有 winget，无法自动安装编译器。
		echo         请手动安装 Visual Studio 2022 Build Tools（勾选“使用 C++ 的桌面开发”工作负载）：
		echo         https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022
		exit /b 1
	)
	echo [检查] 正在通过 winget 安装 Visual Studio 2022 Build Tools（数 GB，需要一些时间）...
	winget install -e --id Microsoft.VisualStudio.2022.BuildTools --silent --accept-package-agreements --accept-source-agreements --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended" || (
		echo [错误] Build Tools 自动安装失败，请手动安装后重试。
		exit /b 1
	)
	call :detect_vs
)
if not defined VS_INSTALL (
	echo [错误] 仍未检测到 MSVC 工具链，请手动安装 Build Tools。
	exit /b 1
)
echo [信息] Visual Studio: %VS_INSTALL%
if not exist "%VS_INSTALL%\Common7\Tools\VsDevCmd.bat" (
	echo [错误] 未找到 VsDevCmd.bat。
	exit /b 1
)
call "%VS_INSTALL%\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul

rem ---- 4. 引擎构建依赖（D3D12 / AccessKit，缺则自动下载到 build_deps）----
rem SCons 默认依赖目录：%LOCALAPPDATA%\Godot\build_deps
if defined LOCALAPPDATA (
	set "BUILD_DEPS=%LOCALAPPDATA%\Godot\build_deps"
) else (
	set "BUILD_DEPS=%REPO_ROOT%\bin\build_deps"
)
if not exist "%BUILD_DEPS%\mesa" (
	echo [检查] 缺少 D3D12 依赖（Mesa NIR / Agility SDK / PIX），正在自动下载...
	%PY% "%REPO_ROOT%\misc\scripts\install_d3d12_sdk_windows.py" || (
		echo [错误] D3D12 依赖安装失败（需要网络）。可在编译参数追加 d3d12=no 跳过。
		exit /b 1
	)
) else (
	echo [信息] D3D12 依赖已就绪。
)
if not exist "%BUILD_DEPS%\accesskit" (
	echo [检查] 缺少 AccessKit，正在自动下载...
	%PY% "%REPO_ROOT%\misc\scripts\install_accesskit.py" || (
		echo [错误] AccessKit 安装失败（需要网络）。可在编译参数追加 accesskit=no 跳过。
		exit /b 1
	)
) else (
	echo [信息] AccessKit 已就绪。
)

rem ---- 5. 编译 ----
rem 默认编辑器 dev 构建；feng_godottracy / feng_renderdoc 等引擎模块默认随引擎编译，
rem feng-addons 下的 GDScript 插件无需编译，随编辑器直接使用。
if not defined NUMBER_OF_PROCESSORS set "NUMBER_OF_PROCESSORS=4"
echo.
echo [构建] scons platform=windows target=editor dev_build=yes -j%NUMBER_OF_PROCESSORS% %*
echo.
call scons platform=windows target=editor dev_build=yes -j%NUMBER_OF_PROCESSORS% %* || (
	echo.
	echo [错误] 编译失败，请查看上方 scons 输出。
	exit /b 1
)

echo.
echo [完成] 编译成功，产物在 %REPO_ROOT%\bin\ 目录下：
dir /b "%REPO_ROOT%\bin\godot.windows.*.exe" 2>nul
exit /b 0

rem ============================================================
rem  子例程：括号里的命令含 ")"，必须放在代码块之外。
rem ============================================================

:add_user_scripts_dir
rem 把 pip --user 的 Scripts 目录加入本次会话 PATH（python -m site --user-base 无括号，for 命令安全）。
for /f "delims=" %%i in ('%PY% -m site --user-base') do (
	if exist "%%i\Scripts\scons.bat" set "PATH=%%i\Scripts;!PATH!"
)
exit /b 0

:detect_vs
rem 用 vswhere 定位带 MSVC C++ 工作负载的最新 VS/Build Tools 安装。
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VS_INSTALL="
if not exist "%VSWHERE%" exit /b 0
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS_INSTALL=%%i"
exit /b 0
