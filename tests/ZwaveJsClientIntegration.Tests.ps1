#Requires -Version 7.0

<#
    Integration test for Get-ZwaveJsNodes using an in-process HttpListener that
    emulates zwave-js-ui's socket.io polling endpoint. Two server behaviors are
    tested: (a) INITED delivered immediately, and (b) a ping ('2') body returned
    on the first sid-poll before INITED on the next, which exercises the
    pong/backoff and multi-poll paths. No real zwave-js-ui needed.
#>

$CanListen = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'modules/ZwaveJsClient/ZwaveJsClient.psd1') -Force -ErrorAction Stop

    # Starts a listener in a thread job on a free port; returns @{ Job; Port }.
    # $Mode: 'immediate' (INITED at once) or 'ping-first' (ping then INITED).
    function Start-FakeZwaveJs {
        param([string]$Mode)
        $sep = [char]0x1e
        $open = '0{"sid":"eio1","pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}'
        $inited = '40{"sid":"nsp1"}' + $sep + '42["INITED",{"nodes":[{"id":5,"loc":"Zone Alpha","name":"PIR","productLabel":"TESTPIR","values":[{"id":"5-48-0-Motion","label":"Sensor state (Motion)"}],"hassDevices":{"x":{"discovery_payload":{"device":{"identifiers":["test_node5"]}}}}}]}]'
        $pingBody = '40{"sid":"nsp1"}' + $sep + '2'

        foreach ($attempt in 1..10) {
            $port = Get-Random -Minimum 34000 -Maximum 44000
            $prefix = "http://localhost:$port/"
            $ready = $false
            $job = Start-ThreadJob -ScriptBlock {
                param($prefix, $open, $inited, $pingBody, $mode)
                $listener = [System.Net.HttpListener]::new()
                $listener.Prefixes.Add($prefix)
                try { $listener.Start() } catch { return "BIND_FAILED" }
                $sidGetCount = 0
                try {
                    while ($listener.IsListening) {
                        $ctx = $listener.GetContext()
                        $req = $ctx.Request
                        if ($req.Url.AbsolutePath -eq '/__stop') { $ctx.Response.OutputStream.Close(); break }
                        $body =
                            if ($req.HttpMethod -eq 'POST') { 'ok' }
                            elseif ($req.Url.Query -notmatch 'sid=') { $open }
                            else {
                                $sidGetCount++
                                if ($mode -eq 'ping-first' -and $sidGetCount -eq 1) { $pingBody } else { $inited }
                            }
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                        $ctx.Response.ContentType = 'text/plain'
                        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $ctx.Response.OutputStream.Close()
                    }
                } catch { }
                finally { $listener.Stop() }
                return "STOPPED"
            } -ArgumentList $prefix, $open, $inited, $pingBody, $Mode

            # Readiness probe: poll the handshake endpoint until it answers.
            foreach ($i in 1..25) {
                if ($job.State -eq 'Completed') { break }  # BIND_FAILED
                try {
                    Invoke-WebRequest -Uri "$prefix`socket.io/?EIO=4&transport=polling&t=probe" -TimeoutSec 1 -ErrorAction Stop | Out-Null
                    $ready = $true; break
                } catch { Start-Sleep -Milliseconds 100 }
            }
            if ($ready) { return @{ Job = $job; Port = $port; Prefix = $prefix } }
            Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        throw "Could not start fake zwave-js-ui listener after 10 attempts."
    }

    function Stop-FakeZwaveJs {
        param($Server)
        try { Invoke-WebRequest -Uri "$($Server.Prefix)__stop" -TimeoutSec 2 -ErrorAction SilentlyContinue | Out-Null } catch { }
        Stop-Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ZwaveJsNodes (integration)' -Skip:(-not $CanListen) {

    It 'fetches the nodes array when INITED is immediate' {
        $server = Start-FakeZwaveJs -Mode 'immediate'
        try {
            $nodes = Get-ZwaveJsNodes -Url "http://localhost:$($server.Port)" -TimeoutSec 5
            $nodes.Count | Should -Be 1
            $nodes[0].loc | Should -Be 'Zone Alpha'
            $nodes[0].values[0].id | Should -Be '5-48-0-Motion'
        }
        finally { Stop-FakeZwaveJs $server }
    }

    It 'fetches the nodes array across a ping then INITED (pong/backoff path)' {
        $server = Start-FakeZwaveJs -Mode 'ping-first'
        try {
            $nodes = Get-ZwaveJsNodes -Url "http://localhost:$($server.Port)" -TimeoutSec 6
            $nodes[0].loc | Should -Be 'Zone Alpha'
        }
        finally { Stop-FakeZwaveJs $server }
    }

    It 'throws a clear error for an unreachable host' {
        { Get-ZwaveJsNodes -Url 'http://localhost:1' -TimeoutSec 2 } | Should -Throw '*Could not reach zwave-js-ui*'
    }

    It 'refuses to send a token over http' {
        { Get-ZwaveJsNodes -Url 'http://localhost:1' -Token 'jwt' -TimeoutSec 2 } | Should -Throw '*http*'
    }
}
