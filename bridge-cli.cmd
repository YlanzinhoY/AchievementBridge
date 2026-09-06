@echo off
setlocal

set "VENV_PY=%~dp0.venv\Scripts\python.exe"
if exist "%VENV_PY%" (
  "%VENV_PY%" -c "import typer, rich, velopack" >nul 2>nul
  if not errorlevel 1 goto run
)

where py >nul 2>nul
if errorlevel 1 (
  where python >nul 2>nul
  if errorlevel 1 (
    echo Python 3.10 ou mais recente nao foi encontrado.
    echo Instale o Python e execute este arquivo novamente.
    exit /b 1
  )
  set "PYTHON_CMD=python"
) else (
  set "PYTHON_CMD=py -3"
)

echo Preparando a interface do Achievement Bridge...
if not exist "%VENV_PY%" (
  %PYTHON_CMD% -m venv "%~dp0.venv"
  if errorlevel 1 exit /b %errorlevel%
)
"%VENV_PY%" -m pip install --disable-pip-version-check -r "%~dp0requirements-cli.txt"
if errorlevel 1 (
  echo Nao foi possivel instalar as dependencias da interface.
  exit /b %errorlevel%
)

:run
set "API_EXE=%~dp0zig-out\bin\achievement-bridge-api.exe"
if not exist "%API_EXE%" (
  where go >nul 2>nul
  if errorlevel 1 (
    echo O gateway do Achievement Bridge nao foi encontrado.
    echo Instale Go 1.26 ou gere os binarios pelo instalador do projeto.
    exit /b 1
  )
  echo Compilando o gateway local do Achievement Bridge...
  if not exist "%~dp0zig-out\bin" mkdir "%~dp0zig-out\bin"
  pushd "%~dp0api"
  go build -o "%API_EXE%" ".\cmd\achievement-bridge-api"
  if errorlevel 1 goto api_build_failed
  popd
)
"%VENV_PY%" "%~dp0achievement_bridge_cli.py" %*
exit /b %errorlevel%

:api_build_failed
popd
exit /b 1
