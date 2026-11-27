@echo off
cd /d "%~dp0\web_app"
echo Starting DeviceBridge QR Web App...
start "" http://localhost:3000
node server.js
pause
