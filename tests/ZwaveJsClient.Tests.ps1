#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'modules/ZwaveJsClient/ZwaveJsClient.psd1') -Force -ErrorAction Stop
}

Describe 'ConvertFrom-EngineIoOpen' {
    It 'parses sid and timings from an engine.io open packet' {
        InModuleScope ZwaveJsClient {
            $open = ConvertFrom-EngineIoOpen -Body '0{"sid":"abc123","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}'
            $open.Sid | Should -Be 'abc123'
            $open.PingInterval | Should -Be 25000
            $open.PingTimeout | Should -Be 20000
        }
    }

    It 'defaults missing timings' {
        InModuleScope ZwaveJsClient {
            $open = ConvertFrom-EngineIoOpen -Body '0{"sid":"x"}'
            $open.Sid | Should -Be 'x'
            $open.PingInterval | Should -Be 25000
        }
    }

    It 'throws when the packet is not an open packet' {
        InModuleScope ZwaveJsClient { { ConvertFrom-EngineIoOpen -Body '42["INITED",{}]' } | Should -Throw }
    }

    It 'throws when sid is missing' {
        InModuleScope ZwaveJsClient { { ConvertFrom-EngineIoOpen -Body '0{"pingInterval":25000}' } | Should -Throw }
    }
}
