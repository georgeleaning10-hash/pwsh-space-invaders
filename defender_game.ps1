[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null

$screenWidth = 800
$screenHeight = 600
$playerSpeed = 5
$bulletSpeed = 8
$enemySpeed = 2
$enemyBulletSize = 6

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$soundPath = Join-Path $scriptDir 'hit.wav'
if (Test-Path $soundPath) {
    $hitSound = New-Object System.Media.SoundPlayer($soundPath)
    try { $hitSound.LoadAsync() } catch {}
} else {
    $sampleRate = 22050
    $durationMs = 150
    $freq = 880
    $amp = 0.25
    $samples = [int]([math]::Floor($sampleRate * $durationMs / 1000))

    $msStream = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($msStream)

    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $bw.Write([int32](36 + $samples * 2))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))

    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int32]16)
    $bw.Write([int16]1)
    $bw.Write([int16]1)
    $bw.Write([int32]$sampleRate)
    $bw.Write([int32]($sampleRate * 1 * 16 / 8))
    $bw.Write([int16](1 * 16 / 8))
    $bw.Write([int16]16)

    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
    $bw.Write([int32]($samples * 2))

    for ($i = 0; $i -lt $samples; $i++) {
        $t = $i / $sampleRate
        $value = [math]::Round($amp * 32767 * [math]::Sin(2 * [math]::PI * $freq * $t))
        $bw.Write([int16]$value)
    }

    $bw.Flush()
    $msStream.Position = 0
    $hitSound = New-Object System.Media.SoundPlayer($msStream)
    try { $hitSound.LoadAsync() } catch {}
}

$gameState = @{
    playerX = $screenWidth / 2
    playerY = $screenHeight - 50
    playerWidth = 20
    playerHeight = 15
    playerHealth = 3
    score = 0
    bullets = @()
    enemyBullets = @()
    enemies = @()
    wave = 1
    gameOver = $false
    paused = $false
    keyPressed = @{}
    shields = @()
}

function New-Shield {
    $brickW = 8
    $brickH = 6
    $cols = 6
    $rows = 4
    $shieldWidth = $cols * $brickW
    $y = $screenHeight - 150

    $positions = @( [int]($screenWidth * 0.2), [int]($screenWidth * 0.5), [int]($screenWidth * 0.8) )

    $shields = @()
    foreach ($cx in $positions) {
        $startX = $cx - [int]($shieldWidth / 2)
        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt $cols; $c++) {
                $x = $startX + ($c * $brickW)
                $brick = @{ 
                    x = $x
                    y = $y + ($r * $brickH)
                    width = $brickW
                    height = $brickH
                    hp = 2
                }
                $shields += $brick
            }
        }
    }

    return $shields
}

function Make-PlayerShip {
    param($w, $h)
    
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Lime)
    
    $g.FillRectangle($br, 4, 6, 12, 8)
    $g.FillRectangle($br, 0, 8, 4, 4)
    $g.FillRectangle($br, 16, 8, 4, 4)
    
    $cockpitBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Cyan)
    $g.FillRectangle($cockpitBr, 7, 3, 6, 3)
    
    $g.Dispose()
    return $bmp
}

function Make-EnemyShip {
    param($w, $h)

    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)

    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)

    $pat = @(
        '00111100',
        '01111110',
        '11111111',
        '11011011',
        '11111111',
        '01100110',
        '01000010',
        '10100101'
    )

    $pw = $pat[0].Length
    $ph = $pat.Count

    $sx = [Math]::Floor($w / $pw)
    $sy = [Math]::Floor($h / $ph)
    $scale = [Math]::Max(1, [Math]::Min($sx, $sy))

    $sprW = $pw * $scale
    $sprH = $ph * $scale
    $ox = [Math]::Floor(($w - $sprW) / 2)
    $oy = [Math]::Floor(($h - $sprH) / 2)

    for ($y = 0; $y -lt $ph; $y++) {
        $row = $pat[$y]
        for ($x = 0; $x -lt $pw; $x++) {
            if ($row[$x] -eq '1') {
                $px = $ox + ($x * $scale)
                $py = $oy + ($y * $scale)
                $g.FillRectangle($br, $px, $py, $scale, $scale)
            }
        }
    }

    $g.Dispose()
    return $bmp
}

$pSprite = Make-PlayerShip 20 15
$eSprite = Make-EnemyShip 30 20

$gameState.shields = New-Shield

$f = New-Object System.Windows.Forms.Form
$f.Text = "Defender"
$f.Width = $screenWidth + 20
$f.Height = $screenHeight + 60
$f.FormBorderStyle = "FixedSingle"
$f.MaximizeBox = $false
$f.StartPosition = "CenterScreen"
$f.BackColor = [System.Drawing.Color]::Black

$pb = New-Object System.Windows.Forms.PictureBox
$pb.Width = $screenWidth
$pb.Height = $screenHeight
$pb.Location = New-Object System.Drawing.Point(0, 0)
$f.Controls.Add($pb)

$bmp = New-Object System.Drawing.Bitmap($screenWidth, $screenHeight)
$g = [System.Drawing.Graphics]::FromImage($bmp)

function Render {
    $g.Clear([System.Drawing.Color]::Black)
    
    $pgrid = New-Object System.Drawing.Pen([System.Drawing.Color]::DarkGreen, 1)
    
    $i = 0
    while ($i -lt $screenWidth) {
        $g.DrawLine($pgrid, $i, 0, $i, $screenHeight)
        $i += 40
    }
    
    $j = 0
    while ($j -lt $screenHeight) {
        $g.DrawLine($pgrid, 0, $j, $screenWidth, $j)
        $j = $j + 40
    }
    
    $g.DrawImage($pSprite, $gameState.playerX, $gameState.playerY)
    
    $hBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
    $healthcount = 0
    while ($healthcount -lt $gameState.playerHealth) {
        $hx = $gameState.playerX - 25 + ($healthcount * 8)
        $g.FillRectangle($hBr, $hx, $gameState.playerY - 10, 6, 5)
        $healthcount = $healthcount + 1
    }
    
    $bulBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Yellow)
    foreach ($b in $gameState.bullets) {
        $g.FillEllipse($bulBr, $b.x, $b.y, 4, 4)
    }
    
    $ebulBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
    $bulletcount = 0
    $totalebullets = $gameState.enemyBullets.Count
    while ($bulletcount -lt $totalebullets) {
        $bul = $gameState.enemyBullets[$bulletcount]
        $g.FillEllipse($ebulBr, $bul.x, $bul.y, $enemyBulletSize, $enemyBulletSize)
        $bulletcount++
    }
    
    foreach ($e in $gameState.enemies) {
        $g.DrawImage($eSprite, $e.x, $e.y)
    }

    $shieldcount = 0
    $totalshields = $gameState.shields.Count
    while ($shieldcount -lt $totalshields) {
        $br = $gameState.shields[$shieldcount]
        if ($br.hp -ge 2) {
            $brkBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::SaddleBrown)
        } elseif ($br.hp -eq 1) {
            $brkBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Sienna)
        } else {
            $shieldcount++
            continue
        }
        $g.FillRectangle($brkBr, $br.x, $br.y, $br.width, $br.height)
        $shieldcount++
    }
    
    $fnt = New-Object System.Drawing.Font("Arial", 12)
    $wBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    
    $scTxt = "Score: " + $gameState.score
    $wvTxt = "Wave: " + $gameState.wave
    $lvTxt = "Lives: " + $gameState.playerHealth
    
    $g.DrawString($scTxt, $fnt, $wBr, 10, 10)
    $g.DrawString($wvTxt, $fnt, $wBr, 10, 35)
    $g.DrawString($lvTxt, $fnt, $wBr, 10, 60)
    
    if ($gameState.gameOver -eq $true) {
        $gofnt = New-Object System.Drawing.Font("Arial", 28, [System.Drawing.FontStyle]::Bold)
        $goBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Magenta)
        $g.DrawString("GAME OVER", $gofnt, $goBr, 250, 250)
        
        $sfnt = New-Object System.Drawing.Font("Arial", 14)
        $fsTxt = "Final Score: " + $gameState.score
        $g.DrawString($fsTxt, $sfnt, $wBr, 300, 310)
        $g.DrawString("Press R to Restart", $sfnt, $wBr, 300, 340)
    }
    
    if ($gameState.paused -eq $true) {
        $pfnt = New-Object System.Drawing.Font("Arial", 20, [System.Drawing.FontStyle]::Bold)
        $pBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Cyan)
        $g.DrawString("PAUSED", $pfnt, $pBr, 350, 270)
    }
    
    $pb.Image = $bmp
}

function CheckCollision {
    param($x1, $y1, $w1, $h1, $x2, $y2, $w2, $h2)
    
    $collided = $false
    
    if ($x1 -lt ($x2 + $w2)) {
        if (($x1 + $w1) -gt $x2) {
            if ($y1 -lt ($y2 + $h2)) {
                if (($y1 + $h1) -gt $y2) {
                    $collided = $true
                }
            }
        }
    }
    
    return $collided
}

function Tick {  
    if ($gameState.gameOver -eq $true) {
        return
    }
    if ($gameState.paused -eq $true) {
        return
    }
    
    if ($gameState.keyPressed['Left'] -or $gameState.keyPressed['A']) {
        $gameState.playerX = $gameState.playerX - $playerSpeed
    }
    if ($gameState.keyPressed['Right'] -or $gameState.keyPressed['D']) {
        $gameState.playerX = $gameState.playerX + $playerSpeed
    }
    
    if ($gameState.playerX -lt 0) { 
        $gameState.playerX = 0 
    }
    if (($gameState.playerX + $gameState.playerWidth) -gt $screenWidth) { 
        $gameState.playerX = $screenWidth - $gameState.playerWidth 
    }
    
    $newbullets = @()
    foreach ($b in $gameState.bullets) {
        if ($b.y -gt 0) {
            $newbullets += $b
        }
    }
    $gameState.bullets = $newbullets
    
    foreach ($b in $gameState.bullets) {
        $b.y = $b.y - $bulletSpeed
    }

    $bulletstokeep = @()
    foreach ($b in $gameState.bullets) {
        $hitshield = $false
        foreach ($br in $gameState.shields) {
            $col = CheckCollision $b.x $b.y 4 4 $br.x $br.y $br.width $br.height
            if ($col -eq $true) {
                $br.hp = $br.hp - 1
                if ($br.hp -le 0) {
                    $gameState.shields = @($gameState.shields | Where-Object { $_ -ne $br })
                }
                $hitshield = $true
                break
            }
        }
        if ($hitshield -eq $false) {
            $bulletstokeep += $b
        }
    }
    $gameState.bullets = $bulletstokeep
    
    $newenemybullets = @()
    foreach ($b in $gameState.enemyBullets) {
        if ($b.y -lt $screenHeight) {
            $newenemybullets += $b
        }
    }
    $gameState.enemyBullets = $newenemybullets
    
    foreach ($b in $gameState.enemyBullets) {
        $b.y = $b.y + $bulletSpeed
    }

    $enemybulletstokeep = @()
    foreach ($b in $gameState.enemyBullets) {
        $hitshieldeb = $false
        foreach ($br in $gameState.shields) {
            $col2 = CheckCollision $b.x $b.y $enemyBulletSize $enemyBulletSize $br.x $br.y $br.width $br.height
            if ($col2 -eq $true) {
                $br.hp = $br.hp - 1
                if ($br.hp -le 0) {
                    $gameState.shields = @($gameState.shields | Where-Object { $_ -ne $br })
                }
                $hitshieldeb = $true
                break
            }
        }
        if ($hitshieldeb -eq $false) {
            $enemybulletstokeep += $b
        }
    }
    $gameState.enemyBullets = $enemybulletstokeep
    
    foreach ($e in $gameState.enemies) {
        $e.x = $e.x + ($e.dx * $enemySpeed)
        if ($e.x -lt 0) {
            $e.dx = -1 * $e.dx
            $e.y = $e.y + 30
        }
        if (($e.x + $e.width) -gt $screenWidth) {
            $e.dx = $e.dx * -1
            $e.y = $e.y + 30
        }
        
        $r = Get-Random -Minimum 0 -Maximum 100
        if ($r -lt 5) {
            $bulletx = $e.x + ($e.width / 2) - ($enemyBulletSize / 2)
            $bullety = $e.y + $e.height
            $nB = @{
                x = $bulletx
                y = $bullety
            }
            $gameState.enemyBullets += $nB
        }
    }
    
    $bulletstoremove = @()
    $enemiesToRemove = @()
    
    foreach ($b in $gameState.bullets) {
        foreach ($e in $gameState.enemies) {
            $c = CheckCollision $b.x $b.y 4 4 $e.x $e.y $e.width $e.height
            if ($c -eq $true) {
                $bulletstoremove += $b
                $enemiesToRemove += $e
                $gameState.score = $gameState.score + 100
                try {
                    if ($hitSound) { 
                        $hitSound.Play() 
                    } else { 
                        [System.Media.SystemSounds]::Beep.Play() 
                    }
                } catch {
                }
                break
            }
        }
    }
    
    $finalBullets = @()
    foreach ($b in $gameState.bullets) {
        if ($bulletstoremove -notcontains $b) {
            $finalBullets += $b
        }
    }
    $gameState.bullets = $finalBullets
    
    $finalEnemies = @()
    foreach ($e in $gameState.enemies) {
        if ($enemiesToRemove -notcontains $e) {
            $finalEnemies += $e
        }
    }
    $gameState.enemies = $finalEnemies
    
    foreach ($e in $gameState.enemies) {
        $c2 = CheckCollision $e.x $e.y $e.width $e.height $gameState.playerX $gameState.playerY $gameState.playerWidth $gameState.playerHeight
        if ($c2 -eq $true) {
            $gameState.playerHealth = $gameState.playerHealth - 1
            $gameState.enemies = @($gameState.enemies | Where-Object { $_ -ne $e })
            if ($gameState.playerHealth -le 0) {
                $gameState.gameOver = $true
            }
        }
    }
    
    $bulletstoremoveeb = @()
    foreach ($b in $gameState.enemyBullets) {
        $c3 = CheckCollision $b.x $b.y $enemyBulletSize $enemyBulletSize $gameState.playerX $gameState.playerY $gameState.playerWidth $gameState.playerHeight
        if ($c3 -eq $true) {
            $gameState.playerHealth = $gameState.playerHealth - 1
            $bulletstoremoveeb += $b
            if ($gameState.playerHealth -le 0) {
                $gameState.gameOver = $true
            }
        }
    }
    
    $finalEnemyBullets = @()
    foreach ($b in $gameState.enemyBullets) {
        if ($bulletstoremoveeb -notcontains $b) {
            $finalEnemyBullets += $b
        }
    }
    $gameState.enemyBullets = $finalEnemyBullets
    
    if ($gameState.enemies.Count -eq 0) {
        $gameState.wave = $gameState.wave + 1
        $cnt = 2 + $gameState.wave
        $enemyspawnindex = 0
        while ($enemyspawnindex -lt $cnt) {
            $nE = @{
                x = Get-Random -Minimum 0 -Maximum ($screenWidth - 30)
                y = Get-Random -Minimum 20 -Maximum 150
                width = 30
                height = 20
                dx = if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { 1 } else { -1 }
            }
            $gameState.enemies += $nE
            $enemyspawnindex = $enemyspawnindex + 1
        }
    }
}

$f.Add_KeyDown({
    $code = $_.KeyCode.ToString()
    $gameState.keyPressed[$code] = $true
    
    if ($_.KeyCode -eq "Space") {
        if ($gameState.gameOver -ne $true) {
            $newbullet = @{
                x = ($gameState.playerX + $gameState.playerWidth / 2) - 2
                y = $gameState.playerY - 10
            }
            $gameState.bullets += $newbullet
        }
    }
    
    if ($_.KeyCode -eq "P") {
        if ($gameState.paused -eq $true) {
            $gameState.paused = $false
        } else {
            $gameState.paused = $true
        }
    }
    
    if ($_.KeyCode -eq "R") {
        if ($gameState.gameOver -eq $true) {
            $gameState.playerX = $screenWidth / 2
            $gameState.playerY = $screenHeight - 50
            $gameState.playerHealth = 3
            $gameState.score = 0
            $gameState.bullets = @()
            $gameState.enemies = @()
            $gameState.wave = 1
            $gameState.gameOver = $false
        }
    }
})

$f.Add_KeyUp({
    $code = $_.KeyCode.ToString()
    $gameState.keyPressed[$code] = $false
})

$f.Add_FormClosing({
    $tm.Stop()
    $tm.Dispose()
})

$tm = New-Object System.Windows.Forms.Timer
$tm.Interval = 30
$tm.Add_Tick({
    try {
        Tick
        Render
    } catch {
        Write-Host "Error occurred: $_"
    }
})
$tm.Start()

$f.ShowDialog() | Out-Null
$g.Dispose()
$bmp.Dispose()
