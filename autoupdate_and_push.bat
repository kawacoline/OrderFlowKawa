@echo off
setlocal enabledelayedexpansion

echo ====================================
echo Git Initialization and Autoupdater
echo ====================================

REM Ensure .gitignore is configured
echo Checking .gitignore...
if not exist ".gitignore" (
    echo .venv/ > .gitignore
    echo .env >> .gitignore
    echo state.json >> .gitignore
    echo state.json.lock >> .gitignore
    echo __pycache__/ >> .gitignore
) else (
    findstr /C:"state.json" .gitignore >nul || echo state.json >> .gitignore
    findstr /C:"state.json.lock" .gitignore >nul || echo state.json.lock >> .gitignore
)

REM Initialize Git if not already
if not exist ".git" (
    echo Initializing Git repository...
    git init
    git branch -M main
    git add .
    git commit -m "Initial commit: AMT-Whisperer Architecture"
)

REM Check if remote exists
git remote get-url origin >nul 2>&1
if %errorlevel% neq 0 (
    echo No remote found. Creating private repository OrderFlowKawa using gh CLI...
    gh repo create OrderFlowKawa --private --source=. --remote=origin --push
    if %errorlevel% neq 0 (
        echo Failed to create/push to repository via gh CLI. Ensure you are authenticated via 'gh auth login'.
        pause
        exit /b
    )
    echo Repository successfully created and pushed!
)

echo Starting Autoupdater...
echo This will run in the background and check for updates every 60 seconds.

:updater_loop
git fetch origin main >nul 2>&1

REM Check if we are behind origin/main
for /f "tokens=*" %%i in ('git rev-list HEAD...origin/main --count') do set BEHIND=%%i

if "!BEHIND!" NEQ "0" (
    if "!BEHIND!" NEQ "" (
        echo [!time!] Update detected! Pulling !BEHIND! commits...
        
        REM Kill existing python processes (MT5 loop and visualizer)
        echo Stopping current bot processes...
        wmic process where "name='python.exe' and commandline like '%%visualizer.py%%'" delete >nul 2>&1
        wmic process where "name='python.exe' and commandline like '%%main.py%%'" delete >nul 2>&1
        
        git pull origin main
        
        echo Reinstalling requirements...
        call .venv\Scripts\activate
        pip install -r requirements.txt
        
        echo Restarting bot...
        start cmd /c "start.bat"
    )
)

timeout /t 60 /nobreak >nul
goto updater_loop
