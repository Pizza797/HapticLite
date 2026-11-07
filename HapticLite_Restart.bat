@'
@echo off
taskkill /F /IM pythonw.exe >nul 2>&1
start "" /D "%USERPROFILE%\HapticLite" "%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe" "%USERPROFILE%\HapticLite\app.py"
'@ | Set-Content -Encoding ascii "$([Environment]::GetFolderPath('Desktop'))\Restart HapticLite.bat"