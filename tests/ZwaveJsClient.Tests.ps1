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

Describe 'Split-EngineIoPayload' {
    It 'splits multiple packets on the U+001E record separator' {
        InModuleScope ZwaveJsClient {
            $sep = [char]0x1e
            $packets = Split-EngineIoPayload -Body ("40{`"sid`":`"x`"}" + $sep + '42["INITED",{}]')
            $packets.Count | Should -Be 2
            $packets[0] | Should -Be '40{"sid":"x"}'
            $packets[1] | Should -Be '42["INITED",{}]'
        }
    }

    It 'returns a single-element array for one packet' {
        InModuleScope ZwaveJsClient { (Split-EngineIoPayload -Body '42["INITED",{}]').Count | Should -Be 1 }
    }

    It 'returns an empty array for an empty body' {
        InModuleScope ZwaveJsClient { (Split-EngineIoPayload -Body '').Count | Should -Be 0 }
    }
}
