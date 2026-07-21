@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Import today's DEM tif into PostGIS Raster.
rem Default target table: public.gis_dem_henan

set "DB_HOST=192.168.110.6"
set "DB_PORT=5432"
set "DB_NAME=ktd_lx_2026gis"
set "DB_USER=zhuoyi"
set "DB_PASSWORD=Ktd@postSQL@2026!@#"

set "DEM_DIR=E:\DEM"
set "SQL_DIR=E:\DEM"
set "SCHEMA_NAME=public"
set "SRID=4326"
set "TILE_SIZE=256x256"

for /f "tokens=1-4 delims=/-. " %%a in ("%date%") do (
    set "A=%%a"
    set "B=%%b"
    set "C=%%c"
    set "D=%%d"
)

echo !A!| findstr /r "^[0-9][0-9][0-9][0-9]$" >nul
if errorlevel 1 (
    set "YY=!B!"
    set "MM=!C!"
    set "DD=!D!"
) else (
    set "YY=!A!"
    set "MM=!B!"
    set "DD=!C!"
)

if "!MM:~1!"=="" set "MM=0!MM!"
if "!DD:~1!"=="" set "DD=0!DD!"
set "TODAY=!YY!!MM!!DD!"

set "TABLE_NAME=gis_dem_henan"
set "SQL_FILE=%SQL_DIR%\!TABLE_NAME!.sql"
set "TIF_FILE="

if exist "%DEM_DIR%\HENAN_4326.tif" set "TIF_FILE=%DEM_DIR%\HENAN_4326.tif"
if not defined TIF_FILE if exist "%DEM_DIR%\!TODAY!.tif" set "TIF_FILE=%DEM_DIR%\!TODAY!.tif"
if not defined TIF_FILE if exist "%DEM_DIR%\DEM_!TODAY!.tif" set "TIF_FILE=%DEM_DIR%\DEM_!TODAY!.tif"
if not defined TIF_FILE if exist "%DEM_DIR%\HENAN_!TODAY!.tif" set "TIF_FILE=%DEM_DIR%\HENAN_!TODAY!.tif"

if not defined TIF_FILE (
    for /f "usebackq delims=" %%f in (`powershell -NoProfile -Command "$today=(Get-Date).Date; Get-ChildItem -LiteralPath '%DEM_DIR%' -Filter '*.tif' -File | Where-Object { $_.LastWriteTime.Date -eq $today } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName"`) do (
        set "TIF_FILE=%%f"
    )
)

if not defined TIF_FILE (
    echo [ERROR] No tif found for today in %DEM_DIR%.
    echo Expected names:
    echo   %DEM_DIR%\HENAN_4326.tif
    echo   %DEM_DIR%\!TODAY!.tif
    echo   %DEM_DIR%\DEM_!TODAY!.tif
    echo   %DEM_DIR%\HENAN_!TODAY!.tif
    echo Or a tif file modified today.
    exit /b 1
)

echo [INFO] Date: !TODAY!
echo [INFO] TIF: !TIF_FILE!
echo [INFO] Target table: %SCHEMA_NAME%.!TABLE_NAME!
echo [INFO] SQL file: !SQL_FILE!

where raster2pgsql >nul 2>nul
if errorlevel 1 (
    echo [ERROR] raster2pgsql not found in PATH.
    exit /b 1
)

where psql >nul 2>nul
if errorlevel 1 (
    echo [ERROR] psql not found in PATH.
    exit /b 1
)

if exist "!SQL_FILE!" del /f /q "!SQL_FILE!"

echo [INFO] Generating SQL...
raster2pgsql -s %SRID% -I -C -M -t %TILE_SIZE% "!TIF_FILE!" %SCHEMA_NAME%.!TABLE_NAME! > "!SQL_FILE!"
if errorlevel 1 (
    echo [ERROR] raster2pgsql failed.
    exit /b 1
)

set "PGPASSWORD=%DB_PASSWORD%"

echo [INFO] Importing SQL into database...
psql -h %DB_HOST% -p %DB_PORT% -U %DB_USER% -d %DB_NAME% -f "!SQL_FILE!"
if errorlevel 1 (
    echo [ERROR] psql import failed.
    exit /b 1
)

echo [INFO] Verifying row count...
psql -h %DB_HOST% -p %DB_PORT% -U %DB_USER% -d %DB_NAME% -c "SELECT COUNT(*) AS tile_count FROM %SCHEMA_NAME%.!TABLE_NAME!;"
if errorlevel 1 (
    echo [ERROR] verification failed.
    exit /b 1
)

echo [OK] DEM imported successfully: %SCHEMA_NAME%.!TABLE_NAME!
endlocal

