#Requires -Version 7.0

<#
    Integration test for Get-ZwaveJsNodes using an in-process WebSocket server
    that emulates zwave-js-ui's socket.io endpoint: engine.io open -> socket.io
    connect ack -> (optional ping) -> reply to the 'INITED' emit with an ACK
    carrying the node state.

    The server is a raw TcpListener that performs the WebSocket upgrade by hand
    and wraps the stream with [WebSocket]::CreateFromStream. HttpListener's
    AcceptWebSocketAsync is Windows-only, so this keeps the test cross-platform.

    The fake node's 'values' is a MAP (as the live socket state sends it) so the
    map->array normalization is covered too. No real zwave-js-ui needed.
#>

$CanListen = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'modules/ZwaveJsClient/ZwaveJsClient.psd1') -Force -ErrorAction Stop

    function Start-FakeZwaveJs {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper starting an in-process listener.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper name.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Variables are passed via -ArgumentList/param, not captured.')]
        param([string]$Mode)  # 'immediate' or 'ping-first'

        $open = '0{"sid":"eio1","pingInterval":25000,"pingTimeout":20000}'
        # State ACK: node.values is a MAP keyed by value id (live socket shape).
        $ack  = '430[{"nodes":[{"id":5,"loc":"Zone Alpha","name":"PIR","productLabel":"TESTPIR","values":{"5-48-0-Motion":{"id":"5-48-0-Motion","label":"Sensor state (Motion)"}},"hassDevices":{"x":{"discovery_payload":{"device":{"identifiers":["test_node5"]}}}}}]}]'

        foreach ($attempt in 1..10) {
            $port = Get-Random -Minimum 34000 -Maximum 44000
            $job = Start-ThreadJob -ScriptBlock {
                param($port, $open, $ack, $mode)
                $ct = [System.Threading.CancellationToken]::None
                function SrvSend($ws, $s) {
                    $b = [System.Text.Encoding]::UTF8.GetBytes($s)
                    $ws.SendAsync([System.ArraySegment[byte]]::new($b), 'Text', $true, $ct).GetAwaiter().GetResult()
                }
                function SrvRecv($ws) {
                    $ms = [System.IO.MemoryStream]::new(); $buf = [byte[]]::new(16384)
                    do {
                        $r = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), $ct).GetAwaiter().GetResult()
                        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
                        $ms.Write($buf, 0, $r.Count)
                    } while (-not $r.EndOfMessage)
                    [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                }

                $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
                try { $tcp.Start() } catch { return "BIND_FAILED" }
                try {
                    while ($true) {
                        $client = $tcp.AcceptTcpClient()
                        $stream = $client.GetStream()

                        # Read the HTTP upgrade request byte by byte up to the blank line.
                        $hb = [System.IO.MemoryStream]::new()
                        while ($true) {
                            $bi = $stream.ReadByte()
                            if ($bi -lt 0) { break }
                            $hb.WriteByte([byte]$bi)
                            $a = $hb.ToArray()
                            if ($a.Length -ge 4 -and $a[-4] -eq 13 -and $a[-3] -eq 10 -and $a[-2] -eq 13 -and $a[-1] -eq 10) { break }
                        }
                        $headers = [System.Text.Encoding]::ASCII.GetString($hb.ToArray())
                        $key = $null
                        foreach ($line in ($headers -split "`r`n")) {
                            if ($line -match '^(?i)Sec-WebSocket-Key:\s*(.+)$') { $key = $Matches[1].Trim() }
                        }
                        if (-not $key) { $client.Close(); continue }  # readiness probe / non-ws; keep waiting

                        $accept = [Convert]::ToBase64String(
                            [System.Security.Cryptography.SHA1]::HashData(
                                [System.Text.Encoding]::ASCII.GetBytes($key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))
                        $resp = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Accept: $accept`r`n`r`n"
                        $rb = [System.Text.Encoding]::ASCII.GetBytes($resp)
                        $stream.Write($rb, 0, $rb.Length); $stream.Flush()

                        $ws = [System.Net.WebSockets.WebSocket]::CreateFromStream($stream, $true, [NullString]::Value, [TimeSpan]::FromSeconds(30))
                        SrvSend $ws $open
                        [void](SrvRecv $ws)                     # '40' connect
                        SrvSend $ws '40{"sid":"nsp1"}'
                        [void](SrvRecv $ws)                     # '420["INITED",true]'
                        if ($mode -eq 'ping-first') { SrvSend $ws '2'; [void](SrvRecv $ws) }  # ping, recv pong
                        SrvSend $ws $ack
                        # complete the close handshake so the client's close returns promptly
                        try {
                            [void](SrvRecv $ws)   # client's close frame
                            $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $ct).GetAwaiter().GetResult()
                        } catch { $null = $_ }  # best-effort close
                        break
                    }
                }
                catch { $null = $_ }  # fake server: swallow session errors
                finally { $tcp.Stop() }
                return "DONE"
            } -ArgumentList $port, $open, $ack, $Mode

            # Readiness: a raw TCP connect succeeds once the listener is bound. The
            # server loop reads no upgrade key from it and moves on to the real client.
            $ready = $false
            foreach ($i in 1..40) {
                if ($job.State -eq 'Completed') { break }  # BIND_FAILED
                try {
                    $probe = [System.Net.Sockets.TcpClient]::new(); $probe.Connect('localhost', $port); $probe.Close()
                    $ready = $true; break
                } catch { Start-Sleep -Milliseconds 100 }
            }
            if ($ready) { return @{ Job = $job; Port = $port } }
            Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        throw "Could not start fake zwave-js-ui WebSocket listener after 10 attempts."
    }

    function Stop-FakeZwaveJs {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper stopping a job.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper name.')]
        param($Server)
        Stop-Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ZwaveJsNodes (integration)' -Skip:(-not $CanListen) {

    It 'fetches nodes over WebSocket and normalizes the values map to an array' {
        $server = Start-FakeZwaveJs -Mode 'immediate'
        try {
            $nodes = Get-ZwaveJsNodes -Url "http://localhost:$($server.Port)" -TimeoutSec 10
            $nodes.Count | Should -Be 1
            $nodes[0].loc | Should -Be 'Zone Alpha'
            $nodes[0].values -is [array] | Should -BeTrue          # map was flattened
            $nodes[0].values[0].id | Should -Be '5-48-0-Motion'
        }
        finally { Stop-FakeZwaveJs $server }
    }

    It 'answers a server ping with a pong before receiving the state' {
        $server = Start-FakeZwaveJs -Mode 'ping-first'
        try {
            $nodes = Get-ZwaveJsNodes -Url "http://localhost:$($server.Port)" -TimeoutSec 10
            $nodes[0].loc | Should -Be 'Zone Alpha'
        }
        finally { Stop-FakeZwaveJs $server }
    }

    It 'throws a clear error for an unreachable host' {
        { Get-ZwaveJsNodes -Url 'http://localhost:1' -TimeoutSec 3 } | Should -Throw '*Could not reach zwave-js-ui*'
    }

    It 'refuses to send a token over http' {
        { Get-ZwaveJsNodes -Url 'http://localhost:1' -Token 'jwt' -TimeoutSec 3 } | Should -Throw '*non-https*'
    }
}
