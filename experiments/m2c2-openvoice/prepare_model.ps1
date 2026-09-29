$ErrorActionPreference = 'Stop'

$modelRevision = 'b0f10347769c88bb6df26e268d4b84bc7237fdeb'
$upstreamRevision = '3a72f7931fce14857c34a15b2d83ffbcaa755e16'
$converterRepository = 'mlboydaisuke/OpenVoice-V2-CoreML'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$destination = Join-Path $repositoryRoot 'local-models\OpenVoiceV2'
$files = @(
    @{ path = 'OpenVoice_SpeakerEncoder.mlpackage/Manifest.json'; size = 617; sha256 = '' },
    @{ path = 'OpenVoice_SpeakerEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel'; size = 25281; sha256 = 'b2eadb91cb59157aa4d4958bc6becee86758faf273de240b2b7a4969971fe7e5' },
    @{ path = 'OpenVoice_SpeakerEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin'; size = 1627840; sha256 = '6b50c4ca00b72862f7cd974f9bef7d1dd36d2a86adc0b6b626116fb26b5cc6de' },
    @{ path = 'OpenVoice_VoiceConverter.mlpackage/Manifest.json'; size = 617; sha256 = '' },
    @{ path = 'OpenVoice_VoiceConverter.mlpackage/Data/com.apple.CoreML/model.mlmodel'; size = 482492; sha256 = 'c7ca229e9fe7f8508884512f6c1100c1fa38fd15bb5e7b9b2641246733cf8fc0' },
    @{ path = 'OpenVoice_VoiceConverter.mlpackage/Data/com.apple.CoreML/weights/weight.bin'; size = 63887808; sha256 = 'bc5c2c0952a4146a74ae7c4dce9ccda8c294af8b41ee4dbadc7d47077d8104ea' }
)

New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($file in $files) {
    $target = Join-Path $destination $file.path
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    $relative = [System.Uri]::EscapeDataString($file.path).Replace('%2F', '/')
    $uri = "https://huggingface.co/$converterRepository/resolve/$modelRevision/$relative`?download=true"
    Invoke-WebRequest -Uri $uri -OutFile $target
    $actualSize = (Get-Item -LiteralPath $target).Length
    $actualHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSize -ne $file.size -or ($file.sha256 -and $actualHash -ne $file.sha256)) {
        throw "Pinned asset verification failed: $($file.path) ($actualSize bytes, $actualHash)"
    }
    $file.sha256 = $actualHash
}

$manifest = [ordered]@{
    format_version = 1
    pack_id = 'openvoice-v2-coreml'
    source_repository = 'myshell-ai/OpenVoice'
    source_revision = $upstreamRevision
    converter_repository = $converterRepository
    converter_revision = $modelRevision
    license = 'MIT'
    compute_units = 'cpuAndGPU'
    files = @($files | ForEach-Object { [ordered]@{ path = $_.path; bytes = $_.size; sha256 = $_.sha256 } })
}
$manifestPath = Join-Path $destination 'manifest.json'
$json = $manifest | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($manifestPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Write-Output "Verified OpenVoice V2 Core ML pack at $destination"
Write-Output "Weight payload bytes: $((($files | Measure-Object -Property size -Sum).Sum))"
