#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Script = Join-Path $script:RepoRoot 'Rename-Domoticz-From-ZwaveJSON.ps1'
}

Describe 'Input mode parameter sets' {
    It 'rejects passing both -JsonFile and -ZwaveJsUrl' {
        $out = & pwsh -NoProfile -NonInteractive -File $script:Script -JsonFile 'x.json' -ZwaveJsUrl 'http://h:8091' -DbPath 'd.db' -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'Parameter set cannot be resolved|AmbiguousParameterSet'
    }

    It 'rejects passing neither -JsonFile nor -ZwaveJsUrl' {
        $out = & pwsh -NoProfile -NonInteractive -File $script:Script -DbPath 'd.db' -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'exposes the new parameters and keeps JsonFile validated + positional' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        $names = $params.Name.VariablePath.UserPath
        $names | Should -Contain 'ZwaveJsUrl'
        $names | Should -Contain 'ZwaveJsToken'
        $names | Should -Contain 'SkipCertificateCheck'

        $jsonParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'JsonFile' }
        $attrText = ($jsonParam.Attributes | ForEach-Object { $_.Extent.Text }) -join ' '
        $attrText | Should -Match 'ValidateNotNullOrEmpty'
        $attrText | Should -Match 'Position'
    }
}
