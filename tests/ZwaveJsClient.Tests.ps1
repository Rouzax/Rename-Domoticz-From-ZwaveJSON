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

Describe 'ConvertFrom-SocketIoPacket' {
    It 'parses an EVENT packet into event name and args' {
        InModuleScope ZwaveJsClient {
            $p = ConvertFrom-SocketIoPacket -Packet '42["INITED",{"nodes":[{"id":5}]}]'
            $p.EioType | Should -Be '4'
            $p.SioType | Should -Be '2'
            $p.Event | Should -Be 'INITED'
            $p.Args[0].nodes[0].id | Should -Be 5
        }
    }

    It 'parses a CONNECT packet' {
        InModuleScope ZwaveJsClient {
            $p = ConvertFrom-SocketIoPacket -Packet '40{"sid":"nsp-sid"}'
            $p.SioType | Should -Be '0'
            $p.Event | Should -BeNullOrEmpty
            $p.Args[0].sid | Should -Be 'nsp-sid'
        }
    }

    It 'parses a CONNECT_ERROR packet' {
        InModuleScope ZwaveJsClient {
            $p = ConvertFrom-SocketIoPacket -Packet '44{"message":"Authentication failed"}'
            $p.SioType | Should -Be '4'
            $p.Args[0].message | Should -Be 'Authentication failed'
        }
    }

    It 'returns null-ish fields for a ping packet' {
        InModuleScope ZwaveJsClient {
            $p = ConvertFrom-SocketIoPacket -Packet '2'
            $p.EioType | Should -Be '2'
            $p.Event | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-SocketIoEventArgs' {
    It 'finds an event among parsed packets' {
        InModuleScope ZwaveJsClient {
            $sep = [char]0x1e
            $raw = Split-EngineIoPayload -Body ('40{"sid":"x"}' + $sep + '42["INITED",{"nodes":[{"id":7}]}]')
            $packets = @(foreach ($p in $raw) { ConvertFrom-SocketIoPacket -Packet $p })
            $evtArgs = Get-SocketIoEventArgs -Packets $packets -Event 'INITED'
            $evtArgs[0].nodes[0].id | Should -Be 7
        }
    }

    It 'returns null when the event is absent' {
        InModuleScope ZwaveJsClient {
            $packets = @(ConvertFrom-SocketIoPacket -Packet '40{"sid":"x"}')
            Get-SocketIoEventArgs -Packets $packets -Event 'INITED' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-SocketIoConnectError' {
    It 'returns the message from a CONNECT_ERROR packet' {
        InModuleScope ZwaveJsClient {
            $packets = @(ConvertFrom-SocketIoPacket -Packet '44{"message":"Authentication failed"}')
            Get-SocketIoConnectError -Packets $packets | Should -Be 'Authentication failed'
        }
    }

    It 'strips control characters from the server message' {
        InModuleScope ZwaveJsClient {
            $packets = @(ConvertFrom-SocketIoPacket -Packet '44{"message":"bad[31mred"}')
            $msg = Get-SocketIoConnectError -Packets $packets
            $msg | Should -Not -Match "[`u{1b}`u{07}]"
        }
    }

    It 'returns null when there is no connect error' {
        InModuleScope ZwaveJsClient {
            $packets = @(ConvertFrom-SocketIoPacket -Packet '40{"sid":"x"}')
            Get-SocketIoConnectError -Packets $packets | Should -BeNullOrEmpty
        }
    }
}
