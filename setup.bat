@echo off
cd /d "%~dp0"
echo ====================================
echo AMT-Whisperer Setup Script
echo ====================================

echo Checking for Python...
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo Python is not installed or not in PATH.
    pause
    exit /b
)

echo Creating virtual environment (.venv)...
if not exist ".venv" (
    python -m venv .venv
)

echo Activating virtual environment and installing requirements...
call .venv\Scripts\activate
pip install --upgrade pip
pip install -r requirements.txt

echo.
echo Setup Complete!
echo You can now run start.bat to launch the system.
pause
