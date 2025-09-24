--[[
    Client-Side Evasion + Hunting Script (Version 19.0 - Dynamic Smooth Lock-On)

    CHANGELOG (v19.0):
    - MERGED: Integrated dynamic closest-enemy targeting from v17.0. The script now always engages the nearest threat.
    - ADDED: Enemy highlighting system from v17.0.
        - Red: Closest enemy (current target).
        - Orange: 2nd closest enemy.
        - Yellow: 3rd closest enemy.
    - RETAINED: The advanced TweenService-based smooth lock-on movement from v18.0.
    - RETAINED: Instantaneous teleporting for emergency dodges to ensure maximum survivability.
]]

--// Services
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

--// Configuration
-- Movement
local HUNT_STOPPING_DISTANCE = 12
local TELEPORT_COOLDOWN = 0.1
local HUNT_MOVEMENT_SPEED = 30      -- Speed in studs/sec for smooth lock-on movement.

-- Detection Settings
local MAX_SEARCH_RADIUS = 60
local TWEEN_DODGE_RADIUS = 35
local SEARCH_INCREMENT = 3
local SEARCH_DENSITY = 24
local PROJECTILE_SAFETY_MARGIN = 4
local EMERGENCY_DODGE_MARGIN = 3
local PROJECTILE_SIZE_INFLATION = 3
local CONTINUOUS_POSITIONING_COOLDOWN = 0.05
local PATH_CHECK_INCREMENT = 2

-- Cliff Detection
local MAX_FALL_HEIGHT = 15

-- Highlighting Colors (from v17.0)
local HIGHLIGHT_COLORS = {
    Color3.fromRGB(255, 0, 0),    -- Red for closest
    Color3.fromRGB(255, 165, 0),  -- Orange for 2nd
    Color3.fromRGB(255, 255, 0)   -- Yellow for 3rd
}

--// Player & Character Variables
local localPlayer = Players.LocalPlayer
local character = localPlayer.Character
local humanoid, hrp, camera

-- Initialize character components
local function initializeCharacter()
    if not character then
        character = localPlayer.CharacterAdded:Wait()
    end
    humanoid = character:WaitForChild("Humanoid", 10)
    hrp = character:WaitForChild("HumanoidRootPart", 10)
    camera = Workspace.CurrentCamera
    if not humanoid or not hrp then
        return false
    end
    return true
end

if not initializeCharacter() then
    return
end

--// Module & Asset References
local enemyProjectilesFolder
local projectileNames = {}

local function loadProjectileFolder()
    local success, result = pcall(function()
        return ReplicatedStorage:WaitForChild("enemyProjectiles", 5)
    end)
    if success and result then
        enemyProjectilesFolder = result
        for _, projectileObject in ipairs(enemyProjectilesFolder:GetChildren()) do
            projectileNames[projectileObject.Name] = true
        end
        return true
    else
        return false
    end
end

local hasProjectileSystem = loadProjectileFolder()

--// Runtime Variables
local currentTarget = nil
local projectileZoneCache = {}
local lastProjectileCacheUpdate = 0
local lastMoveTime = 0
local lastEmergencyDodge = 0
local activeHuntTween = nil -- For smooth movement
local enemyHighlights = {}  -- (from v17.0) To manage highlight instances

----------------------------------------------------------------------
-- Highlighting System (from v17.0)
----------------------------------------------------------------------
local function createHighlight(target, color)
    local highlight = Instance.new("Highlight")
    highlight.Parent = target
    highlight.FillColor = color
    highlight.OutlineColor = color
    highlight.FillTransparency = 0.5
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    return highlight
end

local function clearHighlights()
    for _, highlight in pairs(enemyHighlights) do
        if highlight and highlight.Parent then
            highlight:Destroy()
        end
    end
    enemyHighlights = {}
end

local function updateHighlights(sortedEnemies)
    clearHighlights()
    
    for i = 1, math.min(3, #sortedEnemies) do
        local enemy = sortedEnemies[i]
        if enemy.model and enemy.model.Parent then
            local highlight = createHighlight(enemy.model, HIGHLIGHT_COLORS[i])
            table.insert(enemyHighlights, highlight)
        end
    end
end


----------------------------------------------------------------------
-- Ground Detection System
----------------------------------------------------------------------
local function createRaycastParams()
    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.FilterDescendantsInstances = {character}
    raycastParams.IgnoreWater = false
    return raycastParams
end

local function isGroundSafeAndSolid(position)
    local raycastParams = createRaycastParams()
    local rayOrigin = position + Vector3.new(0, 10, 0)
    local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -30, 0), raycastParams)
    if result and result.Instance.CanCollide then
        local heightDifference = position.Y - result.Position.Y
        return heightDifference <= MAX_FALL_HEIGHT
    end
    return false
end

local function findSafeGroundLevel(position)
    local raycastParams = createRaycastParams()
    local rayOrigin = position + Vector3.new(0, 20, 0)
    local result = Workspace:Raycast(rayOrigin, Vector3.new(0, -50, 0), raycastParams)
    if result and result.Instance.CanCollide then
        return result.Position.Y + humanoid.HipHeight
    end
    return position.Y
end

----------------------------------------------------------------------
-- Unified Teleport Movement (FOR EMERGENCY DODGES ONLY)
----------------------------------------------------------------------
local function teleportTo(targetPosition, lookAtPosition, isEmergency)
    local currentTime = tick()
    if isEmergency then
        lastEmergencyDodge = currentTime
        lastMoveTime = currentTime
    else
        if currentTime - lastMoveTime < TELEPORT_COOLDOWN then return false end
        lastMoveTime = currentTime
    end

    local finalPosition
    if currentTarget and currentTarget.hrp and currentTarget.hrp.Parent then
        finalPosition = Vector3.new(targetPosition.X, currentTarget.hrp.Position.Y, targetPosition.Z)
    else
        local safeY = findSafeGroundLevel(targetPosition)
        finalPosition = Vector3.new(targetPosition.X, safeY, targetPosition.Z)
    end

    local targetCFrame
    if lookAtPosition and (finalPosition - lookAtPosition).Magnitude > 0.1 then
        local flatLookAtPosition = Vector3.new(lookAtPosition.X, finalPosition.Y, lookAtPosition.Z)
        targetCFrame = CFrame.new(finalPosition, flatLookAtPosition)
    else
        targetCFrame = CFrame.new(finalPosition) * (hrp.CFrame - hrp.CFrame.Position)
    end
    
    hrp.CFrame = targetCFrame
    return true
end

----------------------------------------------------------------------
-- Projectile Detection (REVISED AND SIMPLIFIED)
----------------------------------------------------------------------

-- This function recursively searches through an object and all its descendants.
-- It adds any part with a dangerous-sounding name to the results table.
local function findDangerPartsRecursive(object, dangerZonesTable)
    -- KEYWORDS to identify a dangerous part. Added "primarypart" as a keyword.
    local DANGER_KEYWORDS = {"hitbox", "precast", "damagearea", "ball", "primarypart"}

    -- Check if the object itself is a part we should test
    if object:IsA("BasePart") then
        local partNameLower = object.Name:lower()
        for _, keyword in ipairs(DANGER_KEYWORDS) do
            -- Use string.find() to match the keyword within the part's name
            -- (e.g., finds "hitbox" in "leftHitbox")
            if string.find(partNameLower, keyword) then
                table.insert(dangerZonesTable, object)
                break -- Part is added, no need to check other keywords for it
            end
        end
    end

    -- Continue the search by checking all children of the current object
    for _, child in ipairs(object:GetChildren()) do
        findDangerPartsRecursive(child, dangerZonesTable)
    end
end


local function getProjectileDangerZones()
    if not hasProjectileSystem then return {} end
    if tick() - lastProjectileCacheUpdate < 0.1 then return projectileZoneCache end
    
    local dangerZones = {}
    pcall(function()
        for _, projectileModel in ipairs(Workspace:GetChildren()) do
            -- Check if the model is a known projectile type
            if projectileNames[projectileModel.Name] then
                -- Perform a single, deep search for all dangerous parts within it.
                -- This function handles everything: nesting, multiple parts, and varied names.
                findDangerPartsRecursive(projectileModel, dangerZones)
            end
        end
    end)

    projectileZoneCache = dangerZones
    lastProjectileCacheUpdate = tick()
    return dangerZones
end

local function isInProjectileZone3D(position, projectileZones, margin)
    if not hasProjectileSystem then return false end
    margin = margin or PROJECTILE_SAFETY_MARGIN
    for _, zone in ipairs(projectileZones) do
        if zone and zone.Parent then
            local localPos = zone.CFrame:PointToObjectSpace(position)
            local inflatedHalfSize = (zone.Size / 2) + Vector3.new(PROJECTILE_SIZE_INFLATION, PROJECTILE_SIZE_INFLATION * 0.7, PROJECTILE_SIZE_INFLATION)
            local halfSizeWithMargin = inflatedHalfSize + Vector3.new(margin, margin * 0.7, margin)
            
            if math.abs(localPos.X) <= halfSizeWithMargin.X and math.abs(localPos.Y) <= halfSizeWithMargin.Y and math.abs(localPos.Z) <= halfSizeWithMargin.Z then
                return true
            end
        end
    end
    return false
end

local function isInImmediateDanger(projectileZones)
    if not hasProjectileSystem then return false, nil end
    
    local closestThreat = nil
    local minDistanceSq = math.huge
    
    for _, zone in ipairs(projectileZones) do
        if zone and zone.Parent then
            local localPos = zone.CFrame:PointToObjectSpace(hrp.Position)
            local halfSize = (zone.Size / 2) + Vector3.new(PROJECTILE_SIZE_INFLATION, PROJECTILE_SIZE_INFLATION * 0.7, PROJECTILE_SIZE_INFLATION) + Vector3.new(EMERGENCY_DODGE_MARGIN, EMERGENCY_DODGE_MARGIN * 0.7, EMERGENCY_DODGE_MARGIN)
            if math.abs(localPos.X) <= halfSize.X and math.abs(localPos.Y) <= halfSize.Y and math.abs(localPos.Z) <= halfSize.Z then
                local distSq = (hrp.Position - zone.Position).Magnitude^2
                if distSq < minDistanceSq then
                    minDistanceSq = distSq
                    closestThreat = zone
                end
            end
        end
    end
    
    return closestThreat ~= nil, closestThreat
end

local function findBestSafePosition(projectileZones)
    if not hasProjectileSystem then return nil end
    local allSafePositions = {}
    for radius = SEARCH_INCREMENT, TWEEN_DODGE_RADIUS, SEARCH_INCREMENT do
        for i = 1, SEARCH_DENSITY do
            local angle = (i / SEARCH_DENSITY) * 2 * math.pi
            local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            local candidatePos = hrp.Position + offset
            if not isInProjectileZone3D(candidatePos, projectileZones, PROJECTILE_SAFETY_MARGIN) and isGroundSafeAndSolid(candidatePos) then
                local score = 0
                local distFromCurrent = (candidatePos - hrp.Position).Magnitude
                local minThreatDist = math.huge
                for _, zone in ipairs(projectileZones) do
                    if zone and zone.Parent then
                        local threatDist = (candidatePos - zone.Position).Magnitude
                        minThreatDist = math.min(minThreatDist, threatDist)
                    end
                end
                score = score + minThreatDist * 4 - (distFromCurrent * 10)
                table.insert(allSafePositions, {pos = candidatePos, score = score})
            end
        end
    end
    if #allSafePositions > 0 then
        table.sort(allSafePositions, function(a, b) return a.score > b.score end)
        return allSafePositions[1].pos
    end
    for radius = SEARCH_INCREMENT, TWEEN_DODGE_RADIUS * 1.5, SEARCH_INCREMENT do
        for i = 1, SEARCH_DENSITY * 2 do
            local angle = (i / (SEARCH_DENSITY * 2)) * 2 * math.pi
            local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            local candidatePos = hrp.Position + offset
            if not isInProjectileZone3D(candidatePos, projectileZones, 1) then
                local adjustedY = findSafeGroundLevel(candidatePos)
                local finalPos = Vector3.new(candidatePos.X, adjustedY, candidatePos.Z)
                if math.abs(finalPos.Y - hrp.Position.Y) <= MAX_FALL_HEIGHT * 2 then
                    return finalPos
                end
            end
        end
    end
    return nil
end

----------------------------------------------------------------------
-- Enemy Detection & Targeting (UPDATED)
----------------------------------------------------------------------
-- REPLACED: This function now sorts by distance to enable dynamic closest targeting.
local function getAliveEnemiesSortedByDistance()
    local enemies = {}
    pcall(function()
        local dungeon = Workspace:FindFirstChild("dungeon")
        if not dungeon then return end
        
        local function addEnemiesFromFolder(folder)
            if not folder then return end
            for _, enemyModel in ipairs(folder:GetChildren()) do
                local hrpE = enemyModel:FindFirstChild("HumanoidRootPart")
                local hum = enemyModel:FindFirstChild("Humanoid")
                if hrpE and hum and hum.Health > 0 then
                    local distance = (hrp.Position - hrpE.Position).Magnitude
                    table.insert(enemies, {model = enemyModel, hrp = hrpE, hum = hum, distance = distance})
                end
            end
        end
        
        -- Check all rooms and boss room
        for _, room in ipairs(dungeon:GetChildren()) do
            if string.match(room.Name, "^room%d+$") or room.Name == "bossRoom" then
                addEnemiesFromFolder(room:FindFirstChild("enemyFolder"))
            end
        end
    end)
    
    -- Sort by distance (closest first)
    table.sort(enemies, function(a, b)
        return a.distance < b.distance
    end)
    
    return enemies
end

local function getHuntPosition(target)
    local targetHrp = target.hrp
    local targetPos = targetHrp.Position
    local enemyLookDirection = targetHrp.CFrame.LookVector
    local behindDirection = -enemyLookDirection
    local behindPosition = targetPos + behindDirection * HUNT_STOPPING_DISTANCE
    
    if isGroundSafeAndSolid(behindPosition) then
        return behindPosition
    end
    return nil
end

-- RETAINED: This function uses TweenService for smooth, continuous movement.
local function performContinuousPositioning(target)
    local enemyHrp = target.hrp
    if not enemyHrp or not enemyHrp.Parent then
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
        return
    end

    local idealBehindPosition = getHuntPosition(target)
    if not idealBehindPosition then return end
    
    -- "Rotation Wars Style" Y-Lock: Match the target's Y-level.
    local finalTargetPosition = Vector3.new(idealBehindPosition.X, enemyHrp.Position.Y, idealBehindPosition.Z)

    -- Tolerance check: Don't create new tweens for tiny movements.
    if activeHuntTween and activeHuntTween.PlaybackState == Enum.PlaybackState.Playing then
        if (activeHuntTween.Goal.Position - finalTargetPosition).Magnitude < 1.5 then
            return
        end
    end
    
    if (hrp.Position - finalTargetPosition).Magnitude < 1 then return end

    if activeHuntTween then activeHuntTween:Cancel() end

    local distance = (hrp.Position - finalTargetPosition).Magnitude
    local duration = distance / HUNT_MOVEMENT_SPEED
    
    local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
    local goal = { CFrame = CFrame.new(finalTargetPosition, enemyHrp.Position) }
    
    activeHuntTween = TweenService:Create(hrp, tweenInfo, goal)
    activeHuntTween:Play()
end


----------------------------------------------------------------------
-- Main Loop (UPDATED)
----------------------------------------------------------------------
RunService.Heartbeat:Connect(function()
    if not (character and character.Parent and hrp and humanoid and humanoid.Health > 0) then
        clearHighlights() -- Clean up highlights if character is gone
        return
    end
    
    local projectileZones = getProjectileDangerZones()
    
    -- Priority 1: EMERGENCY DODGE
    local inDanger, closestThreat = isInImmediateDanger(projectileZones)
    if inDanger then
        -- Cancel any smooth movement if we need to dodge.
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
        
        local safeSpot = findBestSafePosition(projectileZones)
        if safeSpot then
            teleportTo(safeSpot, closestThreat and closestThreat.Position, true)
            return -- Prioritize survival
        end
    end
    
    -- Priority 2: Find and target closest enemy
    local enemies = getAliveEnemiesSortedByDistance() -- Use the new distance-sorted function
    
    updateHighlights(enemies) -- NEW: Update highlights for the top 3 enemies
    
    if #enemies == 0 then
        currentTarget = nil
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
        return
    end
    
    -- Always target the closest enemy
    currentTarget = enemies[1]
    
    if not currentTarget then return end
    
    -- Priority 3: Continuous tactical positioning with smooth movement
    performContinuousPositioning(currentTarget)
end)

-- ADDED: Cleanup on character death/removal (from v17.0)
character.AncestryChanged:Connect(function(_, parent)
    if not parent then
        clearHighlights()
        if activeHuntTween then
            activeHuntTween:Cancel()
            activeHuntTween = nil
        end
    end
end)
