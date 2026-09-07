@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
:start_bot
cls
echo ====================================================
echo OrderFlowKawa System (With Autonomous Git Watchdog)
echo ====================================================

call .venv\Scripts\activate

echo [!time!] Launching Out-of-Band Visualizer on port 8501...
start /b python -m streamlit run out_of_band\visualizer.py --server.port 8501

echo [!time!] Launching Main Execution Engine...
start /b python main.py

echo.
echo ====================================================
echo System is running. Watchdog is monitoring Github...
echo DO NOT CLOSE THIS WINDOW.
echo ====================================================

:updater_loop
timeout /t 10 /nobreak >nul
git fetch origin main >nul 2>&1

for /f "tokens=*" %%i in ('git rev-list HEAD...origin/main --count') do set BEHIND=%%i

if "!BEHIND!" NEQ "0" (
    if "!BEHIND!" NEQ "" (
        echo.
        echo ====================================================
        echo [!time!] UPDATE DETECTED! Pulling !BEHIND! commits...
        echo ====================================================
        
        echo Stopping current bot processes...
        wmic process where "name='python.exe' and commandline like '%%visualizer.py%%'" delete >nul 2>&1
        wmic process where "name='python.exe' and commandline like '%%main.py%%'" delete >nul 2>&1
        
        echo Pulling latest code...
        git pull origin main
        
        echo Checking for new dependencies...
        pip install -r requirements.txt
        
        echo Rebooting system...
        timeout /t 3 /nobreak >nul
        goto start_bot
    )
)

goto updater_loop
