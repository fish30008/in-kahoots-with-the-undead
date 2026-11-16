# Lab 5 manual tests: what the Postman collection cannot do, because it needs docker
# (stopping a database node, asking each node for its role).
#
# Load the functions into your PowerShell session once, from the repo root:
#
#   . .\lab5-tests.ps1
#
# then run any of them by name:
#
#   Show-Replication          the role of every database node (primary / replica)
#   Test-Failover player      [stops a container] stop the Player primary, time the outage, put the node back
#   Test-Failover game        [stops a container] the same for the Game database
#   Test-QuickRestart player  [restarts a container] the primary restarts before anyone noticed: still one primary
#   Show-Warehouse            the last ETL runs and what the warehouse holds
#   Show-CacheKeys            how many keys each Redis node holds
#   Show-HashRing             10000 keys on the ring: the spread, a 4th node added, ring against hash % N
#   Test-CacheNodeDown        [stops a container] one Redis node stops: only its keys move, no request fails
#   Show-Sagas                the broker's last sagas, with the state of every step
#   Test-SagaInterrupted      [kills the broker] the broker dies between step 1 and step 2 of a join:
#                             the next start finds the saga in its log and compensates it
#   Test-Postman              postman/lab5-defence, every folder
#
# Needs the stack up: docker compose up -d

$Root = $PSScriptRoot
$Gateway = 'http://localhost:8080'
$ProgressPreference = 'SilentlyContinue'

$script:Passed = 0
$script:Failed = 0

function dc { docker compose -f (Join-Path $Root 'compose.yml') @args }
function Write-Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Write-Note($text) { Write-Host "   $text" -ForegroundColor DarkGray }
function Check($condition, $text) {
    if ($condition) { $script:Passed++; Write-Host "   PASS  $text" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "   FAIL  $text" -ForegroundColor Red }
}

# One HTTP call; returns the status code, 0 when there was no answer.
function Get-Status($Method, $Url, $Body = $null) {
    $p = @{ Method = $Method; Uri = $Url; UseBasicParsing = $true; TimeoutSec = 10 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    try { return [int](Invoke-WebRequest @p).StatusCode }
    catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

# Run one SQL statement inside a database node, as the postgres superuser (the service's
# own user may not see other sessions in pg_stat_replication).
function Invoke-NodeSql($Node, $Sql) {
    # the statement goes in on stdin: PowerShell 5.1 mangles quotes inside an argument
    $command = 'PGPASSWORD=$POSTGRESQL_POSTGRES_PASSWORD psql -U postgres -d $POSTGRESQL_DATABASE -h 127.0.0.1 -At'
    # docker is called directly: the dc function would not pass the pipeline on
    $out = $Sql | docker compose -f (Join-Path $Root 'compose.yml') exec -T $Node sh -c $command 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Select-Object -Last 1)
}

# primary, replica, or down
function Get-NodeRole($Node) {
    $inRecovery = Invoke-NodeSql $Node 'select pg_is_in_recovery()'
    if ($inRecovery -eq 'f') { return 'primary' }
    if ($inRecovery -eq 't') { return 'replica' }
    return 'down'
}

function Get-Nodes($Cluster) { 0..2 | ForEach-Object { "$Cluster-db-$_" } }

function Get-Primary($Cluster) {
    Get-Nodes $Cluster | Where-Object { (Get-NodeRole $_) -eq 'primary' } | Select-Object -First 1
}

# How many replicas are streaming from this node right now.
function Get-Streaming($Node) {
    [int](Invoke-NodeSql $Node "select count(*) from pg_stat_replication where state = 'streaming'")
}

# Wait until the node streams to that many replicas; returns the last count seen.
function Wait-Streaming($Node, $Count, $Seconds = 90) {
    $seen = 0
    foreach ($i in 1..($Seconds / 3)) {
        $seen = Get-Streaming $Node
        if ($seen -ge $Count) { break }
        Start-Sleep -Seconds 3
    }
    return $seen
}

# Grade 5: every node of both clusters, its role and how far its replicas are
function Show-Replication {
    Write-Step 'Grade 5: database nodes and their roles'
    foreach ($cluster in 'player', 'game') {
        foreach ($node in (Get-Nodes $cluster)) {
            Write-Host ("   {0,-12} {1}" -f $node, (Get-NodeRole $node))
        }
        $primaries = @(Get-Nodes $cluster | Where-Object { (Get-NodeRole $_) -eq 'primary' })
        Check ($primaries.Count -eq 1) "$cluster-db has exactly one primary: $($primaries -join ', ')"
        if ($primaries.Count -eq 1) {
            $streaming = Get-Streaming $primaries[0]
            Check ($streaming -eq 2) "$($primaries[0]) streams its WAL to $streaming replicas"
        }
    }
}

# Grade 5: stop the primary, time how long writes fail, then put the node back as a replica.
function Test-Failover($Cluster = 'player') {
    Write-Step "Grade 5: failover of $Cluster-db [stops a container]"
    $old = Get-Primary $Cluster
    Check ($null -ne $old) "primary before: $old"
    if (-not $old) { return }

    # a write that needs the cluster's primary: a new player, or a new session
    $user = "failover_$(Get-Date -Format 'HHmmssfff')"
    Check ((Get-Status POST "$Gateway/auth/register" @{ username = $user; password = 'hunter2hunter2' }) -eq 201) 'a write works before'
    $token = ((Invoke-WebRequest -Method POST -Uri "$Gateway/auth/login" -UseBasicParsing -ContentType 'application/json' `
                -Body (@{ username = $user; password = 'hunter2hunter2' } | ConvertTo-Json)).Content | ConvertFrom-Json).access_token
    function Write-Once {
        if ($Cluster -eq 'player') {
            return (Get-Status POST "$Gateway/auth/register" @{ username = "w_$(Get-Random)"; password = 'hunter2hunter2' }) -eq 201
        }
        try {
            $r = Invoke-WebRequest -Method GET -Uri "$Gateway/game/sessions" -UseBasicParsing -TimeoutSec 10 -Headers @{ Authorization = "Bearer $token" }
            return [int]$r.StatusCode -eq 200
        } catch { return $false }
    }

    Write-Note "docker stop $old"
    dc stop $old | Out-Null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $failed = 0
    while ($watch.Elapsed.TotalSeconds -lt 90) {
        if (Write-Once) { break }
        $failed++
        Start-Sleep -Milliseconds 500
    }
    $seconds = [int]$watch.Elapsed.TotalSeconds
    Check ($seconds -lt 90) "the service works again after $seconds s ($failed failed requests in between)"

    $new = Get-Primary $Cluster
    Check ($new -and $new -ne $old) "a replica was promoted: $new is the primary now"
    Check ((Get-Status POST "$Gateway/auth/login" @{ username = $user; password = 'hunter2hunter2' }) -eq 200) `
        'the player written before the failover can still log in (nothing lost)'
    dc logs $new --since 2m 2>$null | Select-String 'promoted to primary' | Select-Object -Last 1 | ForEach-Object { Write-Note $_.Line.Trim() }

    # Started at once, on purpose: this is the moment that used to end with two primaries
    # (the other replica does not follow the new primary yet). The guard in
    # db/replication/start.sh makes the node wait until its partners agree.
    Write-Note "docker start $old"
    dc start $old | Out-Null
    $streaming = Wait-Streaming $new 2
    # the node restarts once more while it joins, so its role is asked until it answers
    $role = 'down'
    foreach ($i in 1..15) {
        $role = Get-NodeRole $old
        if ($role -eq 'replica') { break }
        Start-Sleep -Seconds 2
    }
    Check ($role -eq 'replica') "$old came back as a replica of $new (was the primary)"
    Check ($streaming -eq 2) "$new streams to $streaming replicas again"
    $primaries = @(Get-Nodes $Cluster | Where-Object { (Get-NodeRole $_) -eq 'primary' })
    Check ($primaries.Count -eq 1) "one primary, not two: $($primaries -join ', ')"
    dc logs $old --since 3m 2>$null | Select-String 'db-guard' | Select-Object -Last 2 | ForEach-Object { Write-Note $_.Line.Trim() }
}

# Grade 5: the primary is restarted at once (a crash and an automatic restart). Whatever
# the nodes decide, there is one primary at the end and two replicas streaming from it.
function Test-QuickRestart($Cluster = 'player') {
    Write-Step "Grade 5: quick restart of the $Cluster-db primary [restarts a container]"
    $old = Get-Primary $Cluster
    Check ($null -ne $old) "primary before: $old"
    if (-not $old) { return }
    Write-Note "docker restart $old"
    dc restart $old | Out-Null
    $new = $null
    foreach ($i in 1..40) {
        Start-Sleep -Seconds 3
        $primaries = @(Get-Nodes $Cluster | Where-Object { (Get-NodeRole $_) -eq 'primary' })
        if ($primaries.Count -eq 1 -and (Get-Streaming $primaries[0]) -eq 2) { $new = $primaries[0]; break }
    }
    Check ($null -ne $new) "one primary with 2 replicas streaming again: $new"
    dc logs $old --since 3m 2>$null | Select-String 'db-guard' | Select-Object -Last 2 | ForEach-Object { Write-Note $_.Line.Trim() }
}

# Grade 4: the last ETL runs and what they loaded
function Show-Warehouse {
    Write-Step 'Grade 4: Data Warehouse'
    $w = { param($sql) dc exec -T warehouse-db psql -U warehouse -d warehouse -c $sql }
    & $w 'SELECT started_at, status, players, sessions, actions, error FROM etl_runs ORDER BY id DESC LIMIT 5'
    & $w "SELECT 'dim_player' AS tbl, COUNT(*) FROM dim_player UNION ALL SELECT 'fact_session', COUNT(*) FROM fact_session UNION ALL SELECT 'fact_action', COUNT(*) FROM fact_action"
    & $w 'SELECT type, status, COUNT(*) AS actions, SUM(xp_awarded) AS xp FROM fact_action GROUP BY type, status ORDER BY type'
    dc logs etl --tail 3
}

# --- cache (grades 6 and 7) ---------------------------------------------------

# A player and a token for the cache tests.
function New-Token {
    $user = "cache_$(Get-Date -Format 'HHmmssfff')"
    $body = @{ username = $user; password = 'hunter2hunter2' } | ConvertTo-Json
    Invoke-WebRequest -Method POST -Uri "$Gateway/auth/register" -UseBasicParsing -ContentType 'application/json' -Body $body | Out-Null
    ((Invoke-WebRequest -Method POST -Uri "$Gateway/auth/login" -UseBasicParsing -ContentType 'application/json' -Body $body).Content | ConvertFrom-Json).access_token
}

# The cache node the gateway picked for GET /players/<id>, and the status; node '' when the call failed.
function Get-CacheNode($Id, $Token) {
    try {
        $r = Invoke-WebRequest -Method GET -Uri "$Gateway/players/$Id" -UseBasicParsing -TimeoutSec 10 -Headers @{ Authorization = "Bearer $Token" }
        return @{ Status = [int]$r.StatusCode; Node = [string]$r.Headers['X-Cache-Node'] }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { return @{ Status = [int]$resp.StatusCode; Node = [string]$resp.Headers['X-Cache-Node'] } }
        return @{ Status = 0; Node = '' }
    }
}

# Grade 7: keys per Redis node
function Show-CacheKeys {
    Write-Step 'Grade 7: keys on each cache node'
    foreach ($node in 'cache-1', 'cache-2', 'cache-3') {
        $keys = dc exec -T $node redis-cli dbsize 2>$null
        Write-Host ("   {0}  {1} keys" -f $node, $keys)
    }
}

# Grade 7: the ring's numbers, computed by the gateway's own hashring.py
function Show-HashRing {
    Write-Step 'Grade 7: consistent hashing against hash % N (python -m app.hashring in the gateway)'
    dc exec -T gateway python -m app.hashring
}

# Grade 7: a node stops. Its keys go to the next node on the ring, every other key stays
# where it is, and no request fails. When the node is back, its keys return to it.
function Test-CacheNodeDown($Node = 'cache-2') {
    Write-Step "Grade 7: $Node stops [stops a container]"
    $token = New-Token
    $ids = 1..40
    $before = @{}
    foreach ($id in $ids) { $before[$id] = (Get-CacheNode $id $token).Node }
    $owned = @($ids | Where-Object { $before[$_] -eq $Node })
    $spread = $before.Values | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Check (($before.Values | Sort-Object -Unique).Count -eq 3) "40 keys on three nodes: $($spread -join ', ')"

    Write-Note "docker stop $Node"
    dc stop $Node | Out-Null
    $failed = 0; $after = @{}
    # asked twice: the first call to the stopped node is what tells the gateway it is down
    foreach ($round in 1, 2) {
        foreach ($id in $ids) {
            $r = Get-CacheNode $id $token
            if ($r.Status -eq 0 -or $r.Status -ge 500) { $failed++ }
            $after[$id] = $r.Node
        }
    }
    Check ($failed -eq 0) 'no request failed while the node was down (80 requests)'
    $stayed = @($ids | Where-Object { $before[$_] -ne $Node -and $after[$_] -eq $before[$_] })
    Check ($stayed.Count -eq ($ids.Count - $owned.Count)) "the $($stayed.Count) keys of the other nodes did not move"
    $moved = @($owned | Where-Object { $after[$_] -and $after[$_] -ne $Node })
    Check ($moved.Count -eq $owned.Count) "the $($owned.Count) keys of $Node went to the next node on the ring"
    dc logs gateway --since 1m 2>$null | Select-String 'gateway-cache' | Select-Object -Last 1 | ForEach-Object { Write-Note $_.Line.Trim() }

    Write-Note "docker start $Node (the gateway tries it again after 10 s)"
    dc start $Node | Out-Null
    Start-Sleep -Seconds 12
    $back = @($owned | Where-Object { (Get-CacheNode $_ $token).Node -eq $Node })
    Check ($back.Count -eq $owned.Count) "its $($owned.Count) keys are on $Node again"
}

# --- sagas (grades 8 and 9) ------------------------------------------------------

function Get-InternalKey {
    ((Get-Content (Join-Path $Root '.env') | Where-Object { $_ -match '^INTERNAL_KEY=' }) -split '=', 2)[1]
}

# The broker's saga log, newest first.
function Get-Sagas {
    $r = Invoke-WebRequest -Uri 'http://localhost:8070/sagas' -UseBasicParsing -Headers @{ 'X-Internal-Key' = (Get-InternalKey) }
    ($r.Content | ConvertFrom-Json).sagas
}

function Show-Sagas {
    Write-Step 'Grade 9: the last sagas'
    Get-Sagas | Select-Object -First 10 | ForEach-Object {
        $steps = ($_.steps | ForEach-Object { "$($_.n). $($_.name): $($_.state)" }) -join '  |  '
        Write-Host ("   {0}  {1,-12} {2}" -f $_.id.Substring(0, 8), $_.state, $steps)
    }
}

# Grade 9: the coordinator dies in the middle of a saga, after step 1 and before step 2.
# Step 1 is already committed in the Player database, and visible: a saga has no
# isolation. The next broker finds the saga in its log and compensates it.
function Test-SagaInterrupted {
    Write-Step 'Grade 9: the broker is killed between step 1 and step 2 [kills the broker]'
    $body = { param($u) @{ username = $u; password = 'hunter2hunter2' } | ConvertTo-Json }
    $stamp = Get-Date -Format 'HHmmssfff'
    $hostUser = "sagahost_$stamp"; $mateUser = "sagamate_$stamp"
    $hostId = ((Invoke-WebRequest -Method POST -Uri "$Gateway/auth/register" -UseBasicParsing -ContentType 'application/json' -Body (& $body $hostUser)).Content | ConvertFrom-Json).id
    $mateId = ((Invoke-WebRequest -Method POST -Uri "$Gateway/auth/register" -UseBasicParsing -ContentType 'application/json' -Body (& $body $mateUser)).Content | ConvertFrom-Json).id
    $token = ((Invoke-WebRequest -Method POST -Uri "$Gateway/auth/login" -UseBasicParsing -ContentType 'application/json' -Body (& $body $hostUser)).Content | ConvertFrom-Json).access_token
    $auth = @{ Authorization = "Bearer $token" }
    $session = ((Invoke-WebRequest -Method POST -Uri "$Gateway/game/sessions" -UseBasicParsing -ContentType 'application/json' -Headers $auth `
                -Body (@{ name = 'saga test'; host_player_id = $hostId } | ConvertTo-Json)).Content | ConvertFrom-Json).id
    $online = { Invoke-NodeSql (Get-Primary player) "select is_online from players where id = $mateId" }
    $seated = { Invoke-NodeSql (Get-Primary game) "select count(*) from session_members where session_id = '$session' and player_id = $mateId" }

    Write-Note 'broker restarted with SAGA_PAUSE=10: it waits 10 s after every step'
    $env:BROKER_SAGA_PAUSE = '10'
    dc up -d broker 2>$null | Out-Null
    Remove-Item Env:\BROKER_SAGA_PAUSE
    Start-Sleep -Seconds 12

    # the join, in the background: its answer never comes, the broker dies first
    $job = Start-Job -ScriptBlock {
        param($url, $token, $mateId)
        try {
            Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -TimeoutSec 60 -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $token" } -Body (@{ player_id = $mateId } | ConvertTo-Json) | Out-Null
        } catch { }
    } -ArgumentList "$Gateway/game/sessions/$session/players", $token, $mateId
    Start-Sleep -Seconds 4

    $saga = Get-Sagas | Select-Object -First 1
    Check ($saga.state -eq 'running' -and $saga.steps[0].state -eq 'done' -and $saga.steps[1].state -eq 'pending') `
        "saga $($saga.id.Substring(0, 8)) is running: step 1 done, step 2 pending"
    Check ((& $online) -eq 't') 'step 1 is committed and visible: the player is online, not seated yet (no isolation, no locks)'
    Write-Note 'docker kill broker'
    dc kill broker | Out-Null
    Check ((& $online) -eq 't' -and (& $seated) -eq '0') 'half done: online in player-db, no member row in game-db'

    Write-Note 'broker started again, without the pause'
    dc up -d broker 2>$null | Out-Null
    $state = ''
    foreach ($i in 1..20) {
        Start-Sleep -Seconds 3
        try { $state = (Get-Sagas | Where-Object { $_.id -eq $saga.id }).state } catch { $state = '' }
        if ($state -eq 'compensated') { break }
    }
    Check ($state -eq 'compensated') "the new broker found the saga in its log and compensated it: '$state'"
    Check ((& $online) -eq 'f' -and (& $seated) -eq '0') 'consistent again: the player is offline and not seated'
    dc logs broker --since 2m 2>$null | Select-String 'broker-saga' | Select-Object -Last 3 | ForEach-Object { Write-Note $_.Line.Trim() }
    Remove-Job $job -Force
}

function Test-Postman {
    Write-Step 'postman/lab5-defence'
    $file = Join-Path $Root 'postman\lab5-defence.postman_collection.json'
    $out = npx -y newman@6.2.1 run $file --reporters cli 2>&1 | Out-String
    $total = $null; $failed = 0
    if ($out -match 'assertions\D+(\d+)\D+(\d+)') { $total = $Matches[1]; $failed = [int]$Matches[2] }
    Check ($total -and $failed -eq 0) "postman/lab5-defence: $total assertions, $failed failed"
}
