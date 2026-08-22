#Requires -Version 7.0

$HasSqliteEngine = Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib')

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Script = Join-Path $script:RepoRoot 'Rename-Domoticz-From-ZwaveJSON.ps1'

    # The -ZwaveJsUser guards run after the database-existence check, so those
    # tests need a path that exists. Nothing ever opens it: the guards reject
    # the run before any query.
    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("inputmode-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    $script:FakeDb = Join-Path $script:WorkDir 'domoticz.db'
    New-Item -ItemType File -Path $script:FakeDb -Force | Out-Null
}

AfterAll {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
        $out | Should -Match 'missing mandatory parameters'
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

    It 'exposes -ZwaveJsUser as a plain string in the live-instance set' {
        # A [Credential()] transformation attribute on -ZwaveJsCredential would
        # accept a username too, but when it cannot prompt it aborts during
        # parameter binding and PowerShell exits 0. Prompting from the script
        # body keeps every failure loud. Keep this a plain string.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$null)
        $userParam = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ZwaveJsUser' }
        $userParam | Should -Not -BeNullOrEmpty
        $attrText = ($userParam.Attributes | ForEach-Object { $_.Extent.Text }) -join ' '
        $attrText | Should -Match "ParameterSetName = 'FromZwaveJs'"
        $attrText | Should -Match '\[string\]|string'
        $attrText | Should -Not -Match 'Credential\(\)'
    }

    It 'rejects -ZwaveJsUser together with -ZwaveJsCredential' -Skip:(-not $HasSqliteEngine) {
        $cred = "(New-Object pscredential('x',(ConvertTo-SecureString 'y' -AsPlainText -Force)))"
        $inner = "& '$script:Script' -ZwaveJsUrl 'http://localhost:1' -DbPath '$script:FakeDb' -ZwaveJsUser admin -ZwaveJsCredential $cred -DryRun; exit `$LASTEXITCODE"
        $out = & pwsh -NoProfile -NonInteractive -Command $inner 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'either -ZwaveJsUser or -ZwaveJsCredential'
    }

    It 'fails loudly, not silently, when -ZwaveJsUser cannot prompt' -Skip:(-not $HasSqliteEngine) {
        # Regression guard for the exit-0 trap: a run that cannot ask for a
        # password must never look like a successful run that renamed nothing.
        $out = & pwsh -NoProfile -File $script:Script -ZwaveJsUrl 'http://localhost:1' `
            -DbPath $script:FakeDb -ZwaveJsUser admin -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'no console to prompt at'
        $out | Should -Match 'Import-CliXml'
    }
}
