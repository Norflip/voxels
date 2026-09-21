@rem build.bat (Windows)
@echo off

setlocal
set BUILD_DIR=build
set FLAGS=-debug -keep-executable -strict-style
set EXE_NAME=main.exe
if not exist %BUILD_DIR% (
    mkdir %BUILD_DIR%
)

echo [build] building %EXE_NAME% [%FLAGS%]
odin build src -out:%BUILD_DIR%/%EXE_NAME% %FLAGS%

if %ERRORLEVEL% neq 0 (
    echo [build] compilation failed with error code %ERRORLEVEL%.
    exit /b %ERRORLEVEL%
)

pushd %BUILD_DIR%
%EXE_NAME%
popd
