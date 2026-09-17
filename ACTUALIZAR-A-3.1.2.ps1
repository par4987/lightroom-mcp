<#
  ACTUALIZAR-A-3.1.2.ps1
  Actualiza el bridge Lightroom MCP a la v3.1.2 (fix del ciclo de caídas).

  Uso (desde PowerShell):

    powershell -ExecutionPolicy Bypass -File .\ACTUALIZAR-A-3.1.2.ps1

    o indicando dónde está el zip:

    powershell -ExecutionPolicy Bypass -File .\ACTUALIZAR-A-3.1.2.ps1 -ZipPath "C:\Users\pablo\Downloads\pired-lightroom-mcp.zip"

  Si no le pasás -ZipPath, busca el zip más reciente en tu carpeta Descargas.

  Hace todo solo:
    1. Verifica que Claude Desktop esté cerrado (te avisa si no).
    2. Lee la config de Claude Desktop y detecta la carpeta REAL que usa
       (así no hay forma de equivocarse con las carpetas anidadas).
    3. Cierra los procesos node del puente.
    4. Respalda tu dist actual (backup con fecha) y copia el dist v3.1.2.
    5. Limpia el lock viejo.
    6. Verifica la versión instalada.
#>

param([string]$ZipPath = "")

$ErrorActionPreference = 'Stop'
$targetVersion = '3.1.2'

function Say($m)  { Write-Host "[actualizar] $m" }
function Warn($m)  { Write-Host "[aviso] $m" -ForegroundColor Yellow }

# --- 0) Claude Desktop tiene que estar cerrado -------------------------------
$claude = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
if ($claude) {
  Warn 'Claude Desktop está corriendo. Cerralo por completo'
  Warn '(clic derecho en el ícono de la bandeja, junto al reloj -> Quit) y después...'
  Read-Host '   presioná Enter acá para continuar' | Out-Null
  if (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) {
    throw 'Claude Desktop sigue corriendo. Ejecutá este script de nuevo cuando esté cerrado.'
  }
}

# --- 1) Encontrar el zip ------------------------------------------------------
if (-not $ZipPath) {
  $downloads = Join-Path $env:USERPROFILE 'Downloads'
  $cand = Get-ChildItem -Path $downloads -Filter 'pired-lightroom-mcp*.zip' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending
  if ($cand) {
    $ZipPath = $cand[0].FullName
    Say "Usando el zip más reciente de Descargas: $ZipPath"
  }
}
if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath)) {
  throw "No encontré el zip. Pasalo como parámetro: -ZipPath 'C:\ruta\pired-lightroom-mcp.zip'"
}
$ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path

# --- 2) Leer la config de Claude y ubicar el index.js real -------------------
$configFile = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (-not (Test-Path -LiteralPath $configFile)) {
  throw "No encuentro la config de Claude Desktop: $configFile"
}
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
if (-not $config.mcpServers) { throw 'La config de Claude Desktop no tiene sección mcpServers.' }

$entry = $null
$entryName = ''
foreach ($name in @($config.mcpServers.PSObject.Properties.Name)) {
  $s = $config.mcpServers.$name
  $flat = (@($s.command) + @($s.args)) -join ' '
  if ($flat -match 'lightroom') { $entry = $s; $entryName = $name; break }
}
if (-not $entry) { throw "No hay ningún servidor 'lightroom' en la config de Claude." }
Say "Servidor MCP detectado en la config de Claude: '$entryName'"

$indexPath = @($entry.args) | Where-Object { $_ -match '\.js$' } | Select-Object -First 1
if (-not $indexPath) { $indexPath = [string]$entry.command }
$indexPath = ([string]$indexPath).Trim('"').Trim("'")
if (-not (Test-Path -LiteralPath $indexPath)) {
  throw "La ruta de la config no existe: $indexPath (revisá claude_desktop_config.json)"
}
$distDir = Split-Path -Parent $indexPath
Say "Carpeta dist que usa Claude ahora: $distDir"

# --- 3) Cerrar los procesos node del puente ----------------------------------
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_.CommandLine -and $_.CommandLine -match 'lightroom' -and $_.CommandLine -match 'index\.js') {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed++ } catch {}
  }
}
Say "Procesos del puente cerrados: $killed"

# --- 4) Extraer el zip y ubicar el dist nuevo --------------------------------
$temp = Join-Path $env:TEMP ('lrmcp-' + [guid]::NewGuid().ToString('N').Substring(0,8))
Expand-Archive -LiteralPath $ZipPath -DestinationPath $temp -Force

$hit = Get-ChildItem -Path $temp -Recurse -Filter 'index.js' -ErrorAction SilentlyContinue |
       Where-Object { $_.DirectoryName -match 'server[\\/]dist$' } | Select-Object -First 1
if (-not $hit) { throw "Dentro del zip no encontré server\dist. Zip inesperado: $ZipPath" }
$newDist = $hit.DirectoryName

$vf = Join-Path $newDist 'version.js'
if (-not (Test-Path -LiteralPath $vf)) { throw 'El dist del zip no tiene version.js' }
$sel = Select-String -Path $vf -Pattern 'VERSION\s*=\s*"([\d.]+)"'
if (-not $sel) { throw "No pude leer la versión en $vf" }
$zipVersion = $sel.Matches[0].Groups[1].Value
if ($zipVersion -ne $targetVersion) {
  throw "El zip trae la v$zipVersion y necesitás la v$targetVersion. Descargá el zip nuevo de la conversación."
}
Say "El zip trae la v$zipVersion — correcto."

# --- 5) Respaldo y reemplazo --------------------------------------------------
$backup = "$distDir.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
if (Test-Path -LiteralPath $distDir) {
  Move-Item -LiteralPath $distDir -Destination $backup
  Say "Respaldo de tu versión anterior: $backup"
}
Copy-Item -Path $newDist -Destination $distDir -Recurse
Say 'Dist v3.1.2 copiado.'

# --- 6) Limpiar el lock y pedidos de yield -----------------------------------
$lockDir = Join-Path $env:USERPROFILE '.config\lightroom-mcp'
foreach ($f in @('bridge-58763-58764.lock', 'bridge-58763-58764.yield-request')) {
  $p = Join-Path $lockDir $f
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Say "Borrado: $f" }
}

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue

# --- 7) Verificación final ----------------------------------------------------
$sel2 = Select-String -Path (Join-Path $distDir 'version.js') -Pattern 'VERSION\s*=\s*"([\d.]+)"'
if (-not $sel2 -or $sel2.Matches[0].Groups[1].Value -ne $targetVersion) {
  throw 'La verificación final falló: el dist instalado no reporta la versión esperada.'
}

Write-Host ''
Write-Host 'TODO LISTO.' -ForegroundColor Green
Write-Host 'Ahora:'
Write-Host '  1. Abrí Claude Desktop.'
Write-Host '  2. Verificá en el log que aparezca: "Lightroom MCP server v3.1.2 running on stdio"'
$logPath = Join-Path $env:APPDATA 'Claude\logs\mcp-server-lightroom.log'
Write-Host "     Log: $logPath"
Write-Host '  3. Reiniciá Claude un par de veces: ya no debería aparecer'
Write-Host '     "Another Lightroom MCP bridge is already running".'
