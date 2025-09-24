--[[
    Optimized Client-Side Evasion + Hunting Script (Version 19.1 - Performance Fix)
    FIXES: 
    - Eliminated projectile detection pauses
    - Improved closest enemy targeting reliability
    - Added asynchronous processing for heavy operations
]]

--// Services
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

--// Configuration
local HUNT_STOPPING_DISTANCE = 12
local TELEPORT_COOLDOWN = 0.1
local HUNT_MOVEMENT_SPEED = 30
local MAX_SEARCH_RADIUS = 60
local TWEEN_DODGE_RADIUS = 35
local PROJECTILE_SAFETY_MARGIN = 4
local EMERGENCY_DODGE_MARGIN = 3
local MAX_FALL_HEIGHT = 15

--// Performance Optimization Variables
local lastProjectileCheck = 0
local lastEnemyScan = 0
local projectileCheckInterval = 0.05  -- More frequent but lighter checks
local enemyScanInterval = 0.1         -- Enemy scans don't need to be frame-perfect

--// Player & Character
local localPlayer = Players.LocalPlayer
local character = localPlayer.Character
local humanoid, hrp, camera

-- Initialize character with error handling
local function initializeCharacter()
    if not character then
        character = localPlayer.CharacterAdded:Wait()
    end
    humanoid = character:WaitForChild("Humanoid", 5)
    hrp = character:WaitForChild("HumanoidRootPart", 5)
    camera = Workspace.CurrentCamera
    return humanoid and hrp
end

if not initializeCharacter() then return end

--// Runtime Variables (Optimized)
local currentTarget = nil
local projectileZoneCache = {}
local lastMoveTime = 0
local lastEmergencyDodge = 0
local activeHuntTween = nil
local enemyHighlights = {}
local recentEnemies = {}  -- Cache enemy data between scans

--// Quick Projectile Detection (NON-BLOCKING)
local function quickProjectileScan()
    local dangerZones = {}
    local currentTime = tick()
    
    -- Only do full scan at intervals, otherwise use cache
    if currentTime - lastProjectileCheck < projectileCheckInterval then
        return projectileZoneCache
    end
    
    -- Lightweight scan - check only visible projectiles
    pcall(function()
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj:IsA("BasePart") and string.match(obj.Name:lower(), "hitbox") then
                table.insert(dangerZones, obj)
            elseif obj:IsA("Model") and (string.match(obj.Name:lower(), "projectile") or string.match(obj.Name:lower(), "bullet")) then
                local primary = obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
                if primary then
                    table.insert(dangerZones, primary)
                end
            end
        end
    end)
    
    projectileZoneCache = dangerZones
    lastProjectileCheck = currentTime
    return dangerZones
end

--// Fast Immediate Danger Check
local function isInImmediateDangerQuick(projectileZones)
    local hrpPos = hrp.Position
    local hrpSize = hrp.Size
    
    for _, zone in ipairs(projectileZones) do
        if zone and zone.Parent then
            local zonePos = zone.Position
            local zoneSize = zone.Size
            local safeDistance = (hrpSize.Magnitude + zoneSize.Magnitude) / 2 + EMERGENCY_DODGE_MARGIN
            
            if (hrpPos - zonePos).Magnitude < safeDistance then
                return true, zone
            end
        end
    end
    return false, nil
end

--// Improved Enemy Targeting
local function getClosestEnemyFast()
    local currentTime = tick()
    
    -- Only rescan enemies at intervals to reduce CPU load
    if currentTime - lastEnemyScan < enemyScanInterval and next(recentEnemies) ~= nil then
        return recentEnemies
    end
    
    local enemies = {}
    local playerPos = hrp.Position
    
    pcall(function()
        -- Method 1: Check workspace for humanoids (fastest)
        for _, model in ipairs(Workspace:GetChildren()) do
            if model:IsA("Model") and model ~= character then
                local humanoid = model:FindFirstChildOfClass("Humanoid")
                local rootPart = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
                
                if humanoid and humanoid.Health > 0 and rootPart then
                    local distance = (playerPos - rootPart.Position).Magnitude
                    if distance <= MAX_SEARCH_RADIUS then
                        table.insert(enemies, {
                            model = model,
                            hrp = rootPart,
                            hum = humanoid,
                            distance = distance
                        })
                    end
                end
            end
        end
        
        -- Method 2: Check dungeon structure if method 1 finds nothing
        if #enemies == 0 then
            local dungeon = Workspace:FindFirstChild("dungeon")
            if dungeon then
                for _, room in ipairs(dungeon:GetChildren()) do
                    if string.match(room.Name, "^room%d+$") or room.Name == "bossRoom" then
                        local enemyFolder = room:FindFirstChild("enemyFolder")
                        if enemyFolder then
                            for _, enemyModel in ipairs(enemyFolder:GetChildren()) do
                                local hrpE = enemyModel:FindFirstChild("HumanoidRootPart")
                                local hum = enemyModel:FindFirstChild("Humanoid")
                                if hrpE and hum and hum.Health > 0 then
                                    local distance = (playerPos - hrpE.Position).Magnitude
                                    if distance <= MAX_SEARCH_RADIUS then
                                        table.insert(enemies, {
                                            model = enemyModel,
                                            hrp = hrpE,
                                            hum = hum,
                                            distance = distance
                                        })
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    
    -- Sort by distance (closest first)
    table.sort(enemies, function(a, b)
        return a.distance < b.distance
    end)
    
    recentEnemies = enemies
    lastEnemyScan = currentTime
    return enemies
end

--// Non-Blocking Safe Position Finder
local function findQuickSafePosition(projectileZones, threat)
    local hrpPos = hrp.Position
    local bestPosition = nil
    local bestScore = -math.huge
    
    -- Try directions away from threat first
    if threat then
        local awayDirection = (hrpPos - threat.Position).Unit
        for i = 1, 3 do
            local distance = 10 + (i * 5)  -- 10, 15, 20 studs
            local candidatePos = hrpPos + (awayDirection * distance)
            candidatePos = Vector3.new(candidatePos.X, hrpPos.Y, candidatePos.Z)
            
            -- Quick safety check
            local safe = true
            for _, zone in ipairs(projectileZones) do
                if (candidatePos - zone.Position).Magnitude < 8 then
                    safe = false
                    break
                end
            end
            
            if safe then
                return candidatePos  -- Return first safe position found
            end
        end
    end
    
    -- Fallback: simple circle check (limited points for performance)
    for i = 1, 8 do  -- Only 8 directions instead of 24+
        local angle = (i / 8) * 2 * math.pi
        local offset = Vector3.new(math.cos(angle) * 12, 0, math.sin(angle) * 12)
        local candidatePos = hrpPos + offset
        
        local safe = true
        for _, zone in ipairs(projectileZones) do
            if (candidatePos - zone.Position).Magnitude < 10 then
                safe = false
                break
            end
        end
        
        if safe then
            return candidatePos
        end
    end
    
    return hrpPos + Vector3.new(0, 5, 0)  -- Emergency upward teleport
end

--// Optimized Movement Function
local function performSmartPositioning(target)
    if activeHuntTween then
        activeHuntTween:Cancel()
        activeHuntTween = nil
    end

    local enemyHrp = target.hrp
    if not enemyHrp or not enemyHrp.Parent then return end

    -- Calculate behind position
    local targetPos = enemyHrp.Position
    local behindDirection = -enemyHrp.CFrame.LookVector
    local behindPosition = targetPos + (behindDirection * HUNT_STOPPING_DISTANCE)
    
    -- Keep current Y level to avoid falling
    behindPosition = Vector3.new(behindPosition.X, hrp.Position.Y, behindPosition.Z)

    local distance = (hrp.Position - behindPosition).Magnitude
    if distance < 2 then return end  -- Already close enough

    local duration = math.max(0.1, distance / HUNT_MOVEMENT_SPEED)
    local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local goal = { CFrame = CFrame.new(behindPosition, targetPos) }
    
    activeHuntTween = TweenService:Create(hrp, tweenInfo, goal)
    activeHuntTween:Play()
end

--// Fast Teleport (Emergency Only)
local function quickTeleport(targetPosition)
    if tick() - lastMoveTime < TELEPORT_COOLDOWN then return false end
    
    local currentY = hrp.Position.Y
    local newPosition = Vector3.new(targetPosition.X, currentY, targetPosition.Z)
    hrp.CFrame = CFrame.new(newPosition)
    
    lastMoveTime = tick()
    return true
end

--// OPTIMIZED MAIN LOOP
RunService.Heartbeat:Connect(function()
    if not (character and character.Parent and hrp and humanoid and humanoid.Health > 0) then
        return
    end
    
    -- PHASE 1: Quick projectile check (NON-BLOCKING)
    local projectileZones = quickProjectileScan()
    local inDanger, threat = isInImmediateDangerQuick(projectileZones)
    
    -- Emergency dodge (fast path)
    if inDanger then
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
        
        local safeSpot = findQuickSafePosition(projectileZones, threat)
        quickTeleport(safeSpot)
        return
    end
    
    -- PHASE 2: Enemy targeting (cached, rarely blocks)
    local enemies = getClosestEnemyFast()
    
    if #enemies == 0 then
        currentTarget = nil
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
        return
    end
    
    -- Always target closest enemy
    local closestEnemy = enemies[1]
    if not closestEnemy or not closestEnemy.hrp or not closestEnemy.hrp.Parent then
        currentTarget = nil
        return
    end
    
    -- Update target if changed
    if currentTarget ~= closestEnemy then
        currentTarget = closestEnemy
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
    end
    
    -- PHASE 3: Continuous movement (non-blocking)
    performSmartPositioning(currentTarget)
end)

-- Cleanup
character.AncestryChanged:Connect(function(_, parent)
    if not parent then
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
    end
end)