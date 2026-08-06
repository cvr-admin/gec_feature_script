-- Gearbox failure simulation and in-pit repair.

require "script_car_parameters"

-- Shared state (global, reset by initDeadGears/resetCar)
deadGears = {} --dead gears, boolean array
gearFailureRampTimers = {}
gearFailureRampDurations = {}
gearFailureTargetClutches = {}

local drivetrainConfig = ac.INIConfig.carData(0, 'drivetrain.ini')
local gearboxRatios = {}
local doubleClutchState = {
    previousGear = 0,
    lastDriveRpm = 0,
    shiftOutGear = 0,
    shiftOutRpm = 0,
    shiftOutRatio = 0,
    shiftOutClutch = 0,
    neutralTime = 0,
    neutralStartRpm = 0,
    neutralPeakRpm = 0,
    neutralLowestRpm = 0,
    neutralClutchReleased = false,
    neutralSecondClutchIn = false,
    neutralBlipped = false,
    forcedGrindTimer = 0,
    forcedGrindSet = false,
    messageCooldown = 0,
    setupEnabled = true,
}

for i = 1, thisCar.gearCount do
    gearboxRatios[i] = math.abs(drivetrainConfig:get('GEARS', 'GEAR_' .. i, 1))
end

-- AC uses 1=neutral, 2=1st gear, etc.
function getCurrentGearIndex()
    return acCarPhysics.gear - 1
end

local function doubleClutchFeatureEnabled()
    if not isNonSynchroGearboxEnabled() then
        return false
    end

    if edwardianGearboxSetupToggleEnabled and doubleClutchState.setupEnabled == false then
        return false
    end

    if doubleClutchOnlyWithHShifter and not ac.getSim().controlsWithShifter then
        return false
    end

    return true
end

local function queueDoubleClutchMessage(reason)
    if doubleClutchState.messageCooldown <= 0 then
        overheadMessageQueue("GEAR GRIND", reason, 2)
        doubleClutchState.messageCooldown = doubleClutchMessageCooldown
    end
end

local function forceDoubleClutchGrinding(reason)
    doubleClutchState.forcedGrindTimer = math.max(doubleClutchState.forcedGrindTimer, doubleClutchBadShiftGrindTime)
    doubleClutchState.forcedGrindSet = true
    ac.setGearsGrinding(true, doubleClutchBadShiftDamageK)
    queueDoubleClutchMessage(reason)
    logDebug("<GBX>Double-clutch miss: ", reason, true)
end

local function hasMatchedDownshift(targetGear)
    local targetRatio = gearboxRatios[targetGear] or 1
    local oldRatio = doubleClutchState.shiftOutRatio
    if oldRatio <= 0 then
        return false
    end

    local expectedRpm = doubleClutchState.shiftOutRpm * (targetRatio / oldRatio)
    local lowestRpm = math.min(doubleClutchState.neutralLowestRpm or acCarPhysics.rpm, acCarPhysics.rpm)
    local highestRpm = math.max(doubleClutchState.neutralPeakRpm or acCarPhysics.rpm, acCarPhysics.rpm)
    if expectedRpm >= lowestRpm - doubleClutchDownshiftRpmTolerance
            and expectedRpm <= highestRpm + doubleClutchDownshiftRpmTolerance then
        return true
    end

    local rpmError = math.abs(acCarPhysics.rpm - expectedRpm)
    return rpmError <= doubleClutchDownshiftRpmTolerance
end

local function needsDownshiftBlip(targetGear)
    local targetRatio = gearboxRatios[targetGear] or 1
    local oldRatio = doubleClutchState.shiftOutRatio
    if oldRatio <= 0 then
        return true
    end

    local expectedRpm = doubleClutchState.shiftOutRpm * (targetRatio / oldRatio)
    local highestRpm = math.max(doubleClutchState.neutralPeakRpm or acCarPhysics.rpm, acCarPhysics.rpm)
    return highestRpm < expectedRpm - doubleClutchDownshiftRpmTolerance
end

local function hasSlowedEnoughForUpshift(targetGear)
    local targetRatio = gearboxRatios[targetGear] or 1
    local oldRatio = doubleClutchState.shiftOutRatio
    if oldRatio <= 0 then
        return false
    end

    local expectedRpm = doubleClutchState.shiftOutRpm * (targetRatio / oldRatio)
    local slowestNeutralRpm = doubleClutchState.neutralLowestRpm or acCarPhysics.rpm
    return slowestNeutralRpm <= expectedRpm + doubleClutchUpshiftRpmTolerance
end

local function resetDoubleClutchShiftState()
    doubleClutchState.shiftOutGear = 0
    doubleClutchState.shiftOutRpm = 0
    doubleClutchState.shiftOutRatio = 0
    doubleClutchState.shiftOutClutch = 0
    doubleClutchState.neutralTime = 0
    doubleClutchState.neutralStartRpm = 0
    doubleClutchState.neutralPeakRpm = 0
    doubleClutchState.neutralLowestRpm = 0
    doubleClutchState.neutralClutchReleased = false
    doubleClutchState.neutralSecondClutchIn = false
    doubleClutchState.neutralBlipped = false
end

function setDoubleClutchGearboxSetupEnabled(enabled)
    doubleClutchState.setupEnabled = enabled ~= false
end

function resetDoubleClutchGearbox()
    resetDoubleClutchShiftState()
    doubleClutchState.previousGear = getCurrentGearIndex()
    doubleClutchState.lastDriveRpm = acCarPhysics.rpm
    doubleClutchState.forcedGrindTimer = 0
    doubleClutchState.forcedGrindSet = false
    doubleClutchState.messageCooldown = 0
    ac.setGearsGrinding(false, 0)
end

function updateDoubleClutchGearbox(dt)
    if doubleClutchState.messageCooldown > 0 then
        doubleClutchState.messageCooldown = doubleClutchState.messageCooldown - dt
    end

    if not doubleClutchFeatureEnabled() or isCarInPits then
        if doubleClutchState.forcedGrindSet then
            ac.setGearsGrinding(false, 0)
        end
        doubleClutchState.forcedGrindTimer = 0
        doubleClutchState.forcedGrindSet = false
        doubleClutchState.previousGear = getCurrentGearIndex()
        resetDoubleClutchShiftState()
        return
    end

    if doubleClutchState.forcedGrindTimer > 0 then
        doubleClutchState.forcedGrindTimer = doubleClutchState.forcedGrindTimer - dt
        ac.setGearsGrinding(true, doubleClutchBadShiftDamageK)
    elseif doubleClutchState.forcedGrindSet then
        ac.setGearsGrinding(false, 0)
        doubleClutchState.forcedGrindSet = false
    end

    local currentGear = getCurrentGearIndex()
    local previousGear = doubleClutchState.previousGear
    local driverClutch = thisCar.clutch
    if driverClutch == nil then
        driverClutch = acCarPhysics.clutch
    end

    -- AC reports clutch as 1.0 released/engaged and 0.0 fully pressed.
    -- The setup value is expressed as "pressed amount", so invert it here.
    local clutchInValueThreshold = 1 - doubleClutchClutchInThreshold
    local clutchIn = driverClutch <= clutchInValueThreshold
    local clutchOutInNeutral = math.abs(driverClutch - doubleClutchState.shiftOutClutch) >= doubleClutchNeutralClutchReleaseTravel

    if currentGear == 0 then
        if previousGear > 0 and doubleClutchState.shiftOutGear ~= previousGear then
            doubleClutchState.shiftOutGear = previousGear
            doubleClutchState.shiftOutRpm = doubleClutchState.lastDriveRpm
            doubleClutchState.shiftOutRatio = gearboxRatios[previousGear] or 1
            doubleClutchState.shiftOutClutch = driverClutch
            doubleClutchState.neutralTime = 0
            doubleClutchState.neutralStartRpm = acCarPhysics.rpm
            doubleClutchState.neutralPeakRpm = acCarPhysics.rpm
            doubleClutchState.neutralLowestRpm = acCarPhysics.rpm
            doubleClutchState.neutralClutchReleased = false
            doubleClutchState.neutralSecondClutchIn = false
            doubleClutchState.neutralBlipped = false
        end

        if doubleClutchState.shiftOutGear > 0 then
            doubleClutchState.neutralTime = doubleClutchState.neutralTime + dt
            doubleClutchState.neutralPeakRpm = math.max(doubleClutchState.neutralPeakRpm, acCarPhysics.rpm)
            doubleClutchState.neutralLowestRpm = math.min(doubleClutchState.neutralLowestRpm, acCarPhysics.rpm)

            if clutchOutInNeutral then
                doubleClutchState.neutralClutchReleased = true
            end

            if doubleClutchState.neutralClutchReleased and clutchIn then
                doubleClutchState.neutralSecondClutchIn = true
            end

            if acCarPhysics.gas >= doubleClutchMinimumBlipGas
                    or (doubleClutchState.neutralPeakRpm - doubleClutchState.neutralStartRpm) >= doubleClutchMinimumBlipRpmRise then
                doubleClutchState.neutralBlipped = true
            end
        end
    elseif previousGear == 0 and doubleClutchState.shiftOutGear > 0 then
        local oldGear = doubleClutchState.shiftOutGear
        local targetGear = currentGear
        local isDownshift = targetGear < oldGear
        local isUpshift = targetGear > oldGear

        if isDownshift then
            if doubleClutchState.neutralTime < doubleClutchMinimumNeutralTime then
                forceDoubleClutchGrinding("Rushed downshift")
            elseif not doubleClutchState.neutralClutchReleased then
                forceDoubleClutchGrinding("Clutch held in neutral")
            elseif needsDownshiftBlip(targetGear) and not doubleClutchState.neutralBlipped then
                forceDoubleClutchGrinding("No throttle blip")
            elseif doubleClutchDownshiftClutchInRequired and not clutchIn and not doubleClutchState.neutralSecondClutchIn then
                forceDoubleClutchGrinding("Clutch not fully in")
            elseif not hasMatchedDownshift(targetGear) then
                forceDoubleClutchGrinding("Rev mismatch")
            end
        elseif isUpshift then
            if doubleClutchState.neutralTime < doubleClutchUpshiftNeutralTime then
                forceDoubleClutchGrinding("Rushed upshift")
            elseif doubleClutchUpshiftRequiresNeutralClutchRelease and not doubleClutchState.neutralClutchReleased then
                forceDoubleClutchGrinding("No neutral clutch release")
            elseif doubleClutchUpshiftClutchInRequired and not clutchIn then
                forceDoubleClutchGrinding("Clutch not fully in")
            elseif not hasSlowedEnoughForUpshift(targetGear) then
                forceDoubleClutchGrinding("Shaft speed too high")
            end
        end

        resetDoubleClutchShiftState()
    elseif currentGear > 0 and previousGear > 0 and currentGear ~= previousGear then
        forceDoubleClutchGrinding("Skipped neutral gate")
        resetDoubleClutchShiftState()
    end

    doubleClutchState.previousGear = currentGear
    if currentGear > 0 then
        doubleClutchState.lastDriveRpm = acCarPhysics.rpm
    end
end

function isDoubleClutchGearGrinding()
    return doubleClutchState.forcedGrindTimer > 0
end

-- Initialize deadGears array - index 1 for 1st gear, etc.
function initDeadGears()
    for i = 1, thisCar.gearCount do
        deadGears[i] = false
        gearFailureRampTimers[i] = 0
        gearFailureRampDurations[i] = 0
        gearFailureTargetClutches[i] = 0
    end
end

local function getRandomGearFailureRampDuration()
    local minTime = gearFailureRampTimeMinSeconds or 2.0
    local maxTime = math.max(gearFailureRampTimeMaxSeconds or 5.0, minTime)
    return minTime + math.random() * (maxTime - minTime)
end

local function getRandomGearFailureTargetClutch()
    local clutchMin = gearFailureClutchMin or 0.10
    local clutchMax = math.max(gearFailureClutchMax or 0.50, clutchMin)
    return clutchMin + math.random() * (clutchMax - clutchMin)
end

function markGearAsFailed(gearIndex)
    if deadGears[gearIndex] then
        return false
    end

    deadGears[gearIndex] = true
    gearFailureRampTimers[gearIndex] = 0
    gearFailureRampDurations[gearIndex] = getRandomGearFailureRampDuration()
    gearFailureTargetClutches[gearIndex] = getRandomGearFailureTargetClutch()
    return true
end

-- Function to adjust gear failure rate dynamically
function updateGearFailureRate(gearboxDamageValue)
    -- Ensure gearboxDamage is within valid range (0 to 1)
    gearboxDamageValue = math.clamp(gearboxDamageValue, 0, 1)

    if gearboxDamageValue > 0.5 then
        boostedGearFailureRate = gearFailureRate / 3  -- Increase failure chance
    else
        boostedGearFailureRate = gearFailureRate  -- Reset to base rate
    end
end

function gearboxFailure()
    local currentGearIndex = getCurrentGearIndex()
    if currentGearIndex > 0 and math.random(1, boostedGearFailureRate) == 1 then
        if markGearAsFailed(currentGearIndex) then
            overheadMessageQueue("GEAR FAILURE", "Gear "..(currentGearIndex).." has failed!", 5)
            logDebug("<FLR>Gear Fail, gear: ", currentGearIndex, ", rate: ", boostedGearFailureRate, true)
        end
    end
end

function gearboxFailureHshifter(tick)
    local currentGearIndex = getCurrentGearIndex()
    -- this factor increases the failure chance for h-shifters to make it more likely to see failures in a reasonable time frame. The actual per-2s failure chance is boostedGearFailureRate / hShifterGearFailFactor, and the per-dt chance is calculated from that.
    local hShifterGearFailFactor = 2833     -- 2833 gives an average failure time of 60s when boostedGearFailureRate is 85000; 1420 ~120s; very conservative, but one has to start somewhere
    local p = (tick) / (2 * (boostedGearFailureRate / hShifterGearFailFactor)) -- this would be the faster approximation; use below for accuracy
    --local q = 1 / (boostedGearFailureRate / hShifterGearFailFactor)
    --local p = 1 - (1 - q)^(tick / 2)

    if currentGearIndex > 0 and not deadGears[currentGearIndex] and math.random() < p then
        markGearAsFailed(currentGearIndex)
        overheadMessageQueue("GEAR FAILURE (H-Shifter)", "Gear "..(currentGearIndex).." has failed!", 5)
        logDebug("<FLR>Gear Fail, gear: ", currentGearIndex, ", rate: ", boostedGearFailureRate, true)
    end
end

function updateFailedGearEffect(dt)
    local currentGearIndex = getCurrentGearIndex()
    if currentGearIndex <= 0 or not deadGears[currentGearIndex] then
        return
    end

    local rampDuration = math.max(gearFailureRampDurations[currentGearIndex] or 0, 0.001)
    gearFailureRampTimers[currentGearIndex] = math.min(
        (gearFailureRampTimers[currentGearIndex] or 0) + (dt or 0),
        rampDuration
    )

    local ramp = math.clamp(gearFailureRampTimers[currentGearIndex] / rampDuration, 0, 1)
    local failedClutch = gearFailureTargetClutches[currentGearIndex] or getRandomGearFailureTargetClutch()
    acCarPhysics.clutch = acCarPhysics.clutch * (1 - ramp) + failedClutch * ramp
end

function isAnyGearBroken()
    for i = 1, thisCar.gearCount do
        if deadGears[i] then
            return true
        end
    end
    return false
end

-- In-pit gearbox repair routine. Call from update() when car is in pits.
function gearboxPitRepair(dt)
    if isCarInPits and (gearboxRepairInProgress or isPitRepairQueueCurrent("gearbox")) then
        local needsRepair = false
        for i = 1, thisCar.gearCount do
            if deadGears[i] then
                needsRepair = true
                break
            end
        end

        if needsRepair then
            if isPitRepairQueueCurrent("gearbox") and not gearboxRepairInProgress then
                gearboxRepairInProgress = true
                gearboxPitTimer = 0
                overheadMessageQueue("Gearbox repair", "Service started. Hold position until done", 3, true)
            end

            if gearboxRepairInProgress then
                gearboxPitTimer = gearboxPitTimer + dt
                overheadMessageQueue("Gearbox repair",
                    string.format("Progress: %d%%",
                    math.floor(math.min(100, (gearboxPitTimer / math.max(0.1, gearboxRepairTime)) * 100))), 1, true)

                -- Complete repair
                if gearboxPitTimer >= gearboxRepairTime then
                    initDeadGears()
                    if resetDogboxGearDamage then
                        resetDogboxGearDamage()
                    end
                    gearboxRepairInProgress = false
                    gearboxRepairTime = math.random(30, 180)
                    overheadMessageQueue("Gearbox repair", "Service complete", 3, true)
                    completePitRepairQueueItem("gearbox")
                end
            end
        elseif isPitRepairQueueCurrent("gearbox") then
            completePitRepairQueueItem("gearbox")
        end
    end
end

-- Initialise on load
initDeadGears()
resetDoubleClutchGearbox()
