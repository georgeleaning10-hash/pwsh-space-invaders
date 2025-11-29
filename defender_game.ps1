[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null

# Game constants
$screenWidth = 800
$screenHeight = 600
$playerSpeed = 5
$bulletSpeed = 8
$enemySpeed = 2
$enemyBulletSize = 6

# Preload hit sound (non-blocking).
# If a `hit.wav` exists next to the script it will be used; otherwise generate a short tone in memory.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$soundPath = Join-Path $scriptDir 'hit.wav'
if (Test-Path $soundPath) {
    $hitSound = New-Object System.Media.SoundPlayer($soundPath)
    try { $hitSound.LoadAsync() } catch {}
} else {
    # Generate a short 150ms 880Hz sine tone WAV in memory (16-bit PCM, mono)
    $sampleRate = 22050
    $durationMs = 150
    $freq = 880
    $amp = 0.25
    $samples = [int]([math]::Floor($sampleRate * $durationMs / 1000))

    $msStream = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($msStream)

    # RIFF header
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
    $bw.Write([int32](36 + $samples * 2))
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))

    # fmt chunk
    $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
    $bw.Write([int32]16)
    $bw.Write([int16]1) # PCM
    $bw.Write([int16]1) # channels
    $bw.Write([int32]$sampleRate)
    $bw.Write([int32]($sampleRate * 1 * 16 / 8))
    $bw.Write([int16](1 * 16 / 8))
    $bw.Write([int16]16)

    # data chunk header
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

# Initialize game state
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

function Create-Shields {
    param()

    # Shield shape made of small bricks
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
                $brick = @{ x = $x; y = $y + ($r * $brickH); width = $brickW; height = $brickH; hp = 2 }
                $shields += $brick
            }
        }
    }

    return $shields
}

function Create-SpaceshipBitmap {
    param($width, $height)
    
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.Clear([System.Drawing.Color]::Black)
    
    # space invader type spaceship demo sprite
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Lime)
    
    # Main body - wider base
    $g.FillRectangle($brush, 4, 6, 12, 8)
    
    # Left wing
    $g.FillRectangle($brush, 0, 8, 4, 4)
    
    # Right wing
    $g.FillRectangle($brush, 16, 8, 4, 4)
    
    # Cockpit
    $cockpitBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Cyan)
    $g.FillRectangle($cockpitBrush, 7, 3, 6, 3)
    
    $g.Dispose()
    return $bitmap
}

function Create-EnemyBitmap {
    param($width, $height)

    # Create a small pixel-art Space Invader 
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.Clear([System.Drawing.Color]::Transparent)

    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)

    # 8x8 invader pattern (1 = pixel filled, 0 = empty)
    $pattern = @(
        '00111100',
        '01111110',
        '11111111',
        '11011011',
        '11111111',
        '01100110',
        '01000010',
        '10100101'
    )

    $pw = $pattern[0].Length
    $ph = $pattern.Count

    $scaleX = [Math]::Floor($width / $pw)
    $scaleY = [Math]::Floor($height / $ph)
    $scale = [Math]::Max(1, [Math]::Min($scaleX, $scaleY))

    $spriteWidth = $pw * $scale
    $spriteHeight = $ph * $scale
    $offsetX = [Math]::Floor(($width - $spriteWidth) / 2)
    $offsetY = [Math]::Floor(($height - $spriteHeight) / 2)

    for ($y = 0; $y -lt $ph; $y++) {
        $row = $pattern[$y]
        for ($x = 0; $x -lt $pw; $x++) {
            if ($row[$x] -eq '1') {
                $g.FillRectangle($brush, $offsetX + ($x * $scale), $offsetY + ($y * $scale), $scale, $scale)
            }
        }
    }

    $g.Dispose()
    return $bitmap
}

# Create sprite bitmaps
$playerSprite = Create-SpaceshipBitmap 20 15
$enemySprite = Create-EnemyBitmap 30 20

# Initialize shields (3 blocks of bricks)
$gameState.shields = Create-Shields

# Create main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Defender"
$form.Width = $screenWidth + 20
$form.Height = $screenHeight + 60
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::Black

# Create picture box for rendering
$pictureBox = New-Object System.Windows.Forms.PictureBox
$pictureBox.Width = $screenWidth
$pictureBox.Height = $screenHeight
$pictureBox.Location = New-Object System.Drawing.Point(0, 0)
$form.Controls.Add($pictureBox)

# Create bitmap for double buffering
$bitmap = New-Object System.Drawing.Bitmap($screenWidth, $screenHeight)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)

function Draw-Game {
    $graphics.Clear([System.Drawing.Color]::Black)
    
    # Draw background grid
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::DarkGreen, 1)
    for ($i = 0; $i -lt $screenWidth; $i += 40) {
        $graphics.DrawLine($pen, $i, 0, $i, $screenHeight)
    }
    for ($i = 0; $i -lt $screenHeight; $i += 40) {
        $graphics.DrawLine($pen, 0, $i, $screenWidth, $i)
    }
    
    # Draw player spaceship
    $graphics.DrawImage($playerSprite, $gameState.playerX, $gameState.playerY)
    
    # Draw player health bars
    $healthBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
    for ($i = 0; $i -lt $gameState.playerHealth; $i++) {
        $graphics.FillRectangle($healthBrush, $gameState.playerX - 25 + ($i * 8), $gameState.playerY - 10, 6, 5)
    }
    
    # Draw bullets
    $bulletBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Yellow)
    foreach ($bullet in $gameState.bullets) {
        $graphics.FillEllipse($bulletBrush, $bullet.x, $bullet.y, 4, 4)
    }
    
    # Draw enemy bullets
    $enemyBulletBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
    foreach ($bullet in $gameState.enemyBullets) {
        $graphics.FillEllipse($enemyBulletBrush, $bullet.x, $bullet.y, $enemyBulletSize, $enemyBulletSize)
    }
    
    # Draw enemies
    foreach ($enemy in $gameState.enemies) {
        $graphics.DrawImage($enemySprite, $enemy.x, $enemy.y)
    }

    # Draw shields (bricks)
    foreach ($brick in $gameState.shields) {
        if ($brick.hp -ge 2) {
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::SaddleBrown)
        } elseif ($brick.hp -eq 1) {
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Sienna)
        } else {
            continue
        }
        $graphics.FillRectangle($brush, $brick.x, $brick.y, $brick.width, $brick.height)
    }
    
    # Draw HUD
    $font = New-Object System.Drawing.Font("Arial", 12)
    $whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $graphics.DrawString("Score: $($gameState.score)", $font, $whiteBrush, 10, 10)
    $graphics.DrawString("Wave: $($gameState.wave)", $font, $whiteBrush, 10, 35)
    $graphics.DrawString("Lives: $($gameState.playerHealth)", $font, $whiteBrush, 10, 60)
    
    if ($gameState.gameOver) {
        $gameOverFont = New-Object System.Drawing.Font("Arial", 28, [System.Drawing.FontStyle]::Bold)
        $gameOverBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Magenta)
        $graphics.DrawString("GAME OVER", $gameOverFont, $gameOverBrush, 250, 250)
        
        $smallFont = New-Object System.Drawing.Font("Arial", 14)
        $graphics.DrawString("Final Score: $($gameState.score)", $smallFont, $whiteBrush, 300, 310)
        $graphics.DrawString("Press R to Restart", $smallFont, $whiteBrush, 300, 340)
    }
    
    if ($gameState.paused) {
        $pauseFont = New-Object System.Drawing.Font("Arial", 20, [System.Drawing.FontStyle]::Bold)
        $pauseBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Cyan)
        $graphics.DrawString("PAUSED", $pauseFont, $pauseBrush, 350, 270)
    }
    
    $pictureBox.Image = $bitmap
}

function Update-Game {  
    if ($gameState.gameOver -or $gameState.paused) { return }
    
    # Player movement
    if ($gameState.keyPressed['Left'] -or $gameState.keyPressed['A']) {
        $gameState.playerX -= $playerSpeed
    }
    if ($gameState.keyPressed['Right'] -or $gameState.keyPressed['D']) {
        $gameState.playerX += $playerSpeed
    }
    
    # Constrain player to screen
    if ($gameState.playerX -lt 0) { $gameState.playerX = 0 }
    if ($gameState.playerX + $gameState.playerWidth -gt $screenWidth) { $gameState.playerX = $screenWidth - $gameState.playerWidth }
    
    # Update bullets
    $gameState.bullets = @($gameState.bullets | Where-Object { $_.y -gt 0 })
    foreach ($bullet in $gameState.bullets) {
        $bullet.y -= $bulletSpeed
    }

    # Collision detection - player bullets and shields
    foreach ($bullet in @($gameState.bullets)) {
        foreach ($brick in @($gameState.shields)) {
            if ($bullet.x -lt $brick.x + $brick.width -and
                $bullet.x + 4 -gt $brick.x -and
                $bullet.y -lt $brick.y + $brick.height -and
                $bullet.y + 4 -gt $brick.y) {
                $brick.hp--
                if ($brick.hp -le 0) {
                    $gameState.shields = @($gameState.shields | Where-Object { $_ -ne $brick })
                }
                $gameState.bullets = @($gameState.bullets | Where-Object { $_ -ne $bullet })
                break
            }
        }
    }
    
    # Update enemy bullets
    $gameState.enemyBullets = @($gameState.enemyBullets | Where-Object { $_.y -lt $screenHeight })
    foreach ($bullet in $gameState.enemyBullets) {
        $bullet.y += $bulletSpeed
    }

    # Collision detection - enemy bullets and shields
    foreach ($bullet in @($gameState.enemyBullets)) {
        foreach ($brick in @($gameState.shields)) {
            if ($bullet.x -lt $brick.x + $brick.width -and
                $bullet.x + $enemyBulletSize -gt $brick.x -and
                $bullet.y -lt $brick.y + $brick.height -and
                $bullet.y + $enemyBulletSize -gt $brick.y) {
                $brick.hp--
                if ($brick.hp -le 0) {
                    $gameState.shields = @($gameState.shields | Where-Object { $_ -ne $brick })
                }
                $gameState.enemyBullets = @($gameState.enemyBullets | Where-Object { $_ -ne $bullet })
                break
            }
        }
    }
    
    # Update enemies
    foreach ($enemy in $gameState.enemies) {
        $enemy.x += $enemy.dx * $enemySpeed
        if ($enemy.x -lt 0 -or $enemy.x + $enemy.width -gt $screenWidth) {
            $enemy.dx *= -1
            $enemy.y += 30  # Move down one layer
        }
        
        # Enemy shoots randomly (5% chance per frame)
        if ((Get-Random -Minimum 0 -Maximum 100) -lt 5) {
            $gameState.enemyBullets += @{
                x = $enemy.x + $enemy.width / 2 - ($enemyBulletSize / 2)
                y = $enemy.y + $enemy.height
            }
        }
    }
    
    # Collision detection - bullets and enemies
    foreach ($bullet in $gameState.bullets) {
        foreach ($enemy in $gameState.enemies) {
            if ($bullet.x -lt $enemy.x + $enemy.width -and
                $bullet.x + 4 -gt $enemy.x -and
                $bullet.y -lt $enemy.y + $enemy.height -and
                $bullet.y + 4 -gt $enemy.y) {
                $gameState.bullets = @($gameState.bullets | Where-Object { $_ -ne $bullet })
                $gameState.enemies = @($gameState.enemies | Where-Object { $_ -ne $enemy })
                $gameState.score += 100
                # Play hit sound asynchronously (preloaded); fallback to SystemSounds.Beep
                try {
                    if ($hitSound) { $hitSound.Play() } else { [System.Media.SystemSounds]::Beep.Play() }
                } catch {
                    # ignore sound errors so game loop doesn't crash
                }
                # audio feedback on enemy hit
                break
            }
        }
    }
    
    # Collision detection - enemies and player
    foreach ($enemy in $gameState.enemies) {
        if ($enemy.x -lt $gameState.playerX + $gameState.playerWidth -and
            $enemy.x + $enemy.width -gt $gameState.playerX -and
            $enemy.y -lt $gameState.playerY + $gameState.playerHeight -and
            $enemy.y + $enemy.height -gt $gameState.playerY) {
            $gameState.playerHealth--
            $gameState.enemies = @($gameState.enemies | Where-Object { $_ -ne $enemy })
            if ($gameState.playerHealth -le 0) {
                $gameState.gameOver = $true
            }
        }
    }
    
    # Collision detection - enemy bullets and player
    foreach ($bullet in $gameState.enemyBullets) {
        if ($bullet.x -lt $gameState.playerX + $gameState.playerWidth -and
            $bullet.x + $enemyBulletSize -gt $gameState.playerX -and
            $bullet.y -lt $gameState.playerY + $gameState.playerHeight -and
            $bullet.y + $enemyBulletSize -gt $gameState.playerY) {
            $gameState.playerHealth--
            $gameState.enemyBullets = @($gameState.enemyBullets | Where-Object { $_ -ne $bullet })
            if ($gameState.playerHealth -le 0) {
                $gameState.gameOver = $true
            }
        }
    }
    
    # Spawn enemies
    if ($gameState.enemies.Count -eq 0) {
        $gameState.wave++
        for ($i = 0; $i -lt (2 + $gameState.wave); $i++) {
            $gameState.enemies += @{
                x = Get-Random -Minimum 0 -Maximum ($screenWidth - 30)
                y = Get-Random -Minimum 20 -Maximum 150
                width = 30
                height = 20
                dx = if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { 1 } else { -1 }
            }
        }
    }
}

# Event handlers
$form.Add_KeyDown({
    $gameState.keyPressed[$_.KeyCode.ToString()] = $true
    
    if ($_.KeyCode -eq "Space") {
        if (-not $gameState.gameOver) {
            $gameState.bullets += @{
                x = $gameState.playerX + $gameState.playerWidth / 2 - 2
                y = $gameState.playerY - 10
            }
        }
    }
    
    if ($_.KeyCode -eq "P") {
        $gameState.paused = -not $gameState.paused
    }
    
    if ($_.KeyCode -eq "R" -and $gameState.gameOver) {
        $gameState.playerX = $screenWidth / 2
        $gameState.playerY = $screenHeight - 50
        $gameState.playerHealth = 3
        $gameState.score = 0
        $gameState.bullets = @()
        $gameState.enemies = @()
        $gameState.wave = 1
        $gameState.gameOver = $false
    }
})

$form.Add_KeyUp({
    $gameState.keyPressed[$_.KeyCode.ToString()] = $false
})

$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
})

# Game loop
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30
$timer.Add_Tick({
    try {
        Update-Game
        Draw-Game
    } catch {
        Write-Host "Error in game loop: $_"
    }
})
$timer.Start()

$form.ShowDialog() | Out-Null
$graphics.Dispose()
$bitmap.Dispose()
