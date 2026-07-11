#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the SignMind dev stack: Python gRPC inference server + Go API gateway.

.DESCRIPTION
    Starts both services in the current console (interleaved logs) and shuts
    both down together on Ctrl+C or if either one exits. Paths are resolved
    relative to this script, so it works from any working directory.

    Data flow:  Flutter client --WS--> Go backend --gRPC--> Python inference

.PARAMETER HttpAddr
    Listen address for the Go backend's WebSocket/HTTP API. Default ':8080'.

.PARAMETER AiHost
    Host the Go backend dials for the Python gRPC service. Default '127.0.0.1'.

.PARAMETER AiPort
    Port the Python inference server binds and the backend dials. Default 50051.

.EXAMPLE
    .\dev.ps1
    .\dev.ps1 -HttpAddr ':9090' -AiPort 50055
#>
[CmdletBinding()]
param(
    [string]$HttpAddr = ':8080',
    [string]$AiHost   = '127.0.0.1',
    [int]$AiPort      = 50051
)

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$aiDir   = Join-Path $root 'Inference_backend'
$beDir   = Join-Path $root 'Backend'
$aiAddr  = "$($AiHost):$($AiPort)"

# Prefer the project-local x64 venv if present, else python on PATH.
$venvPy = Join-Path $aiDir '.venv-x64\Scripts\python.exe'
$python = if (Test-Path $venvPy) { $venvPy } else { 'python' }

function Write-Step($msg) { Write-Host "[dev] $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "[dev] $msg" -ForegroundColor Yellow }

# --- Preflight -------------------------------------------------------------
if (-not (Get-Command 'go' -ErrorAction SilentlyContinue)) {
    throw "'go' not found on PATH. Install Go 1.22+ and retry."
}
if ($python -eq 'python' -and -not (Get-Command 'python' -ErrorAction SilentlyContinue)) {
    throw "No python found: neither $venvPy nor 'python' on PATH."
}

# Without a model the inference server still starts (UploadModel can restore
# one), but StreamInference rejects frames until artifacts exist. Warn early.
$modelFile = Join-Path $aiDir 'TSL_Output\tsl_lstm_f32.tflite'
if (-not (Test-Path $modelFile)) {
    Write-Warn2 "Model not found: Inference_backend/TSL_Output/tsl_lstm_f32.tflite"
    Write-Warn2 "StreamInference will reject frames until you copy the model or upload one. Starting anyway."
}

Write-Step "python  : $python"
Write-Step "AI gRPC : $aiAddr"
Write-Step "Backend : http://localhost$($HttpAddr)  (stream: ws://localhost$($HttpAddr)/api/v1/stream)"
Write-Step "Press Ctrl+C to stop both."
Write-Host ''

# Env consumed by backend/internal/config.
$env:SIGNMIND_HTTP_ADDR = $HttpAddr
$env:SIGNMIND_AI_ADDR   = $aiAddr

$procs = @()

function Stop-All {
    foreach ($p in $script:procs) {
        if ($p -and -not $p.HasExited) {
            # /T kills the process tree (go run spawns the compiled binary as a
            # child); PID-targeted, never by image name.
            taskkill /PID $p.Id /T /F 2>$null | Out-Null
        }
    }
}

try {
    Write-Step "starting Python inference server..."
    # The server binds SIGNMIND_AI_ADDR (set above, inherited by the child).
    $py = Start-Process -FilePath $python `
        -ArgumentList '-m', 'inference.server' `
        -WorkingDirectory $aiDir -NoNewWindow -PassThru
    $procs += $py

    Write-Step "starting Go backend (first run compiles, give it a moment)..."
    $go = Start-Process -FilePath 'go' `
        -ArgumentList 'run', './cmd/server' `
        -WorkingDirectory $beDir -NoNewWindow -PassThru
    $procs += $go

    # Block until either service exits; then tear the other down.
    while ($true) {
        Start-Sleep -Milliseconds 500
        if ($py.HasExited) { Write-Warn2 "Python server exited (code $($py.ExitCode)); stopping backend."; break }
        if ($go.HasExited) { Write-Warn2 "Go backend exited (code $($go.ExitCode)); stopping inference server."; break }
    }
}
finally {
    Write-Host ''
    Write-Step "shutting down..."
    Stop-All
    Remove-Item Env:\SIGNMIND_HTTP_ADDR -ErrorAction SilentlyContinue
    Remove-Item Env:\SIGNMIND_AI_ADDR   -ErrorAction SilentlyContinue
    Write-Step "stopped."
}
