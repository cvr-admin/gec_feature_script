-- Manual total-loss oiling system for early Grand Prix cars.
-- The engine consumes oil while running, and the driver must keep pressure
-- near the target range by feeding oil from the tank with a manual hand pump.

require "script_car_parameters"

-- Internal defaults. Put only broad car-character tuning in script_car_parameters.lua;
-- these values mostly control script feel, gauge smoothing, and edge-case handling.
oilEngineGalleryInitialLitres = oilEngineGalleryInitialLitres or 0.35
oilEngineGalleryTargetLitres = oilEngineGalleryTargetLitres or 0.45
oilEngineGalleryMaximumLitres = oilEngineGalleryMaximumLitres or 0.75
oilEngineGalleryMinimumLitres = oilEngineGalleryMinimumLitres or 0.08
oilPressureInitialPsi = oilPressureInitialPsi or math.min(oilOptimalPressurePsi * 0.8, oilOptimalPressurePsi - 2)
oilMaximumPressurePsi = oilMaximumPressurePsi or oilOptimalPressurePsi * 1.6
oilAutomaticPumpStartPressurePsi = oilAutomaticPumpStartPressurePsi or oilLowPressureWarningPsi + 3
oilPressureRecoveryPressurePsi = oilPressureRecoveryPressurePsi or oilLowPressureWarningPsi + 2
oilPressureEngineOffResidualPsi = oilPressureEngineOffResidualPsi or 4
oilEngineStoppedRpmThreshold = oilEngineStoppedRpmThreshold or 150
oilMaximumRpmDemandFactor = oilMaximumRpmDemandFactor or 2.0
oilThrottleDemandMultiplier = oilThrottleDemandMultiplier or 0.35
oilDemandPressureLossPsi = oilDemandPressureLossPsi or 5.5
oilPressureRiseRatePerSecond = oilPressureRiseRatePerSecond or 2.8
oilPressureFallRatePerSecond = oilPressureFallRatePerSecond or 1.3
oilManualPumpExtraCEnabled = oilManualPumpExtraCEnabled ~= false
oilPressurePumpStrokeGainPsi = oilPressurePumpStrokeGainPsi or 4.0
oilAutomaticPumpIntervalSeconds = oilAutomaticPumpIntervalSeconds or 0.5
oilPressureRecoveryGraceMultiplier = oilPressureRecoveryGraceMultiplier or 1.5
oilLowPressureMessageIntervalSeconds = oilLowPressureMessageIntervalSeconds or 8.0
oilTankEmptyMessageIntervalSeconds = oilTankEmptyMessageIntervalSeconds or 12.0
oilDebugIntervalSeconds = oilDebugIntervalSeconds or 0.5
oilPitRefillStartThresholdLitres = oilPitRefillStartThresholdLitres or oilTankCapacityLitres - 0.1
oilManualPumpActiveDisplaySeconds = oilManualPumpActiveDisplaySeconds or 0.35
oilStarvationEngineHeatGainPerSecond = oilStarvationEngineHeatGainPerSecond or 0.35
oilLeakageDamageSides = oilLeakageDamageSides or {false, true, true, true}
oilLeakageDamageThreshold = oilLeakageDamageThreshold or 45
oilLeakageDamageChance = oilLeakageDamageChance or 0.25
oilLeakageRateMinLitresPerMinute = oilLeakageRateMinLitresPerMinute or 1.0
oilLeakageRateMaxLitresPerMinute = oilLeakageRateMaxLitresPerMinute or 30.0
oilPitRefillInProgress = oilPitRefillInProgress or false
oilPitRefillTimer = oilPitRefillTimer or 0

-- Online oil-spill synchronisation is driven only by actual puncture leakage.
-- These are intentionally internal so cars need only tune their real leak rate.
local oilSpillSharedEventKey = 'vrc.oilSpill.v5'
local oilSpillMinimumIntervalSeconds = 0.25
local oilSpillDropThresholdLitres = 0.08
local oilSpillEndFlowMultiplier = 0.05
local oilSpillFlowTaperExponent = 2.0

-- Shared oil state for debug apps, other scripts, and controllerInputs.
oilTankCurrentLitres = oilTankCapacityLitres
oilEngineGalleryLitres = oilEngineGalleryInitialLitres
oilPressurePsi = oilPressureInitialPsi
oilManualPumpIsActive = false
oilPressureDamageActive = false
oilTankIsEmpty = false
oilTankLeakageDamage = false
oilTankLeakageRateLitresPerMinute = 0
oilTankLeakageCurrentRateLitresPerMinute = 0
oilPressurePumpDamaged = false
oilPressurePumpEfficiency = 1.0
oilLastEngineConsumptionLitresPerMinute = 0

-- Module-local state.
local oilPreviousManualPumpButtonState = false
local oilAutomaticPumpTimer = 0
local oilLowPressureMessageTimer = 0
local oilTankEmptyMessageTimer = 0
local oilEngineDamageTimer = 0
local oilPressureDebugTimer = 0
local oilManualPumpActiveTimer = 0
local oilTankLeakageMessageShown = false
local oilTankLeakageRollDone = false
local oilTankLeakageLastRolledDamage = 0
local oilTankLeakageSeverity = 0
local oilSpillElapsedSeconds = 0
local oilSpillAccumulatedLitres = 0

local function clampNumber(value, minimumValue, maximumValue)
    return math.max(minimumValue, math.min(maximumValue, value))
end

local function resetOilSpillSync()
    oilSpillElapsedSeconds = 0
    oilSpillAccumulatedLitres = 0
end

local function getOilTankRemainingFraction()
    return clampNumber(oilTankCurrentLitres / math.max(oilTankCapacityLitres, 0.001), 0, 1)
end

local function updateOilSpillSync(dt, leakRateLitresPerSecond, oilLostLitres)
    if not oilTankLeakageDamage or oilLostLitres <= 0 then
        return
    end

    oilSpillElapsedSeconds = oilSpillElapsedSeconds + dt
    oilSpillAccumulatedLitres = oilSpillAccumulatedLitres + oilLostLitres

    local dropThresholdReached = oilSpillAccumulatedLitres >= oilSpillDropThresholdLitres
    local minimumIntervalReached = oilSpillElapsedSeconds >= oilSpillMinimumIntervalSeconds
    if (not dropThresholdReached or not minimumIntervalReached) and oilTankCurrentLitres > 0 then
        return
    end

    printDebug("Oil spill sync", string.format(
        "Drop: %.4f L | Remaining: %.2f / %.2f L | Interval: %.2f s",
        oilSpillAccumulatedLitres,
        oilTankCurrentLitres,
        oilTankCapacityLitres,
        oilSpillElapsedSeconds
    ))

    ac.broadcastSharedEvent(oilSpillSharedEventKey, {
        type = 'drop',
        version = 5,
        punctured = true,
        severity = oilTankLeakageSeverity,
        tankSizeLiters = oilTankCapacityLitres,
        oilRemainingLiters = oilTankCurrentLitres,
        leakRateLitersPerSecond = leakRateLitresPerSecond,
        interval = oilSpillElapsedSeconds,
        dropLiters = oilSpillAccumulatedLitres
    })

    resetOilSpillSync()
end

local function getEngineRunningFactor()
    if acCarPhysics.rpm <= oilEngineStoppedRpmThreshold then
        return 0
    end

    return 1
end

local function getOilDemandFactor()
    local rpmFactor = clampNumber(acCarPhysics.rpm / oilPressureReferenceRpm, 0, oilMaximumRpmDemandFactor)
    local throttleFactor = clampNumber(acCarPhysics.gas or 0, 0, 1)

    -- Oil demand rises mostly with engine speed, with throttle adding extra bearing load.
    return rpmFactor * (1 + throttleFactor * oilThrottleDemandMultiplier)
end

local function addOilPumpStroke()
    if oilTankCurrentLitres <= 0 then
        oilTankCurrentLitres = 0
        oilTankIsEmpty = true
        oilManualPumpIsActive = false
        return false
    end

    local requestedOilMovedLitres = oilPumpLitresPerStroke * oilPressurePumpEfficiency
    local oilGalleryFreeSpaceLitres = math.max(0, oilEngineGalleryMaximumLitres - oilEngineGalleryLitres)
    local pressureDeficitFraction = clampNumber(
        (oilMaximumPressurePsi - oilPressurePsi) / math.max(oilPressurePumpStrokeGainPsi * oilPressurePumpEfficiency, 0.001),
        0,
        1
    )

    -- Do not waste a full pump stroke into an already-full gallery. A stroke
    -- can still move oil to build pressure, but only while pressure has room
    -- to rise. This prevents automatic mode from draining the tank unrealistically.
    local usefulOilCapacityLitres = math.max(oilGalleryFreeSpaceLitres, requestedOilMovedLitres * pressureDeficitFraction)
    local oilMovedLitres = math.min(requestedOilMovedLitres, oilTankCurrentLitres, usefulOilCapacityLitres)

    if oilMovedLitres <= 0 then
        oilManualPumpIsActive = false
        return false
    end

    oilTankCurrentLitres = oilTankCurrentLitres - oilMovedLitres
    oilEngineGalleryLitres = clampNumber(oilEngineGalleryLitres + oilMovedLitres, 0, oilEngineGalleryMaximumLitres)
    oilPressurePsi = clampNumber(
        oilPressurePsi + oilPressurePumpStrokeGainPsi * oilPressurePumpEfficiency * (oilMovedLitres / requestedOilMovedLitres),
        0,
        oilMaximumPressurePsi
    )
    oilManualPumpIsActive = true
    oilManualPumpActiveTimer = oilManualPumpActiveDisplaySeconds
    oilTankIsEmpty = oilTankCurrentLitres <= 0

    return true
end

local function updateManualOilPumpInput()
    if oilAutomaticPumpAssistantEnabled or not oilManualPumpExtraCEnabled then
        return
    end

    -- Extra C represents one hand-pump stroke. Holding the button will not
    -- machine-gun the pump; each press is a deliberate manual action.
    if thisCar.extraC and not oilPreviousManualPumpButtonState then
        if addOilPumpStroke() then
            overheadMessageQueue("Oil pump", "Manual stroke added oil pressure", 2, true)
        else
            overheadMessageQueue("Oil tank empty", "Manual pump has no oil left to feed", 4, true)
        end
    end

    oilPreviousManualPumpButtonState = thisCar.extraC
end

local function updateAutomaticOilPumpAssistant(dt)
    if not oilAutomaticPumpAssistantEnabled then
        return
    end

    if getEngineRunningFactor() == 0 then
        oilAutomaticPumpTimer = 0
        return
    end

    oilAutomaticPumpTimer = oilAutomaticPumpTimer + dt

    -- In automatic mode the car still has oil pressure physics, oil use, and
    -- leakage, but the driver does not have to operate the hand pump manually.
    if oilPressurePsi < oilAutomaticPumpStartPressurePsi and oilAutomaticPumpTimer >= oilAutomaticPumpIntervalSeconds then
        addOilPumpStroke()
        oilAutomaticPumpTimer = 0
    end
end

function setManualOilPumpDriverEnabled(enabled)
    oilAutomaticPumpAssistantEnabled = not enabled
end

function isManualOilPumpDriverEnabled()
    return oilManualPumpExtraCEnabled and not oilAutomaticPumpAssistantEnabled
end

local function getCumulativeOilTankDamage()
    local cumulativeOilTankDamage = 0

    for damageIndex = 0, 3 do
        if oilLeakageDamageSides[damageIndex + 1] then
            cumulativeOilTankDamage = cumulativeOilTankDamage + thisCar.damage[damageIndex]
        end
    end

    return cumulativeOilTankDamage
end

function repairOilTankLeakage()
    if not oilTankLeakageDamage then
        return
    end

    oilTankLeakageDamage = false
    oilTankLeakageRateLitresPerMinute = 0
    oilTankLeakageCurrentRateLitresPerMinute = 0
    oilTankLeakageMessageShown = false
    oilTankLeakageRollDone = true
    oilTankLeakageLastRolledDamage = getCumulativeOilTankDamage()
    oilTankLeakageSeverity = 0
    resetOilSpillSync()
end

local function updateOilTankLeakage(dt)
    local cumulativeOilTankDamage = getCumulativeOilTankDamage()

    if cumulativeOilTankDamage > oilLeakageDamageThreshold then
        if not oilTankLeakageDamage and (not oilTankLeakageRollDone or cumulativeOilTankDamage > oilTankLeakageLastRolledDamage) then
            oilTankLeakageRollDone = true
            oilTankLeakageLastRolledDamage = cumulativeOilTankDamage
            oilTankLeakageDamage = math.random() < oilLeakageDamageChance
            if oilTankLeakageDamage then
                oilTankLeakageSeverity = clampNumber(
                    (cumulativeOilTankDamage - oilLeakageDamageThreshold) / math.max(oilLeakageDamageThreshold, 1),
                    0.15,
                    1
                )
            end
        end

        if not oilTankLeakageDamage then
            return
        end

        if oilTankLeakageRateLitresPerMinute <= 0 then
            oilTankLeakageDamage = true
            local rateBlend = clampNumber(oilTankLeakageSeverity * 0.65 + math.random() * 0.55, 0, 1)
            oilTankLeakageRateLitresPerMinute = oilLeakageRateMinLitresPerMinute
                + (oilLeakageRateMaxLitresPerMinute - oilLeakageRateMinLitresPerMinute) * rateBlend
            oilTankLeakageMessageShown = false
        end

        local remainingFraction = getOilTankRemainingFraction()
        local flowMultiplier = oilSpillEndFlowMultiplier
            + (1 - oilSpillEndFlowMultiplier) * remainingFraction ^ oilSpillFlowTaperExponent
        local currentLeakRateLitresPerMinute = oilTankLeakageRateLitresPerMinute * flowMultiplier
        oilTankLeakageCurrentRateLitresPerMinute = currentLeakRateLitresPerMinute
        local oilLostLitres = math.min(oilTankCurrentLitres, currentLeakRateLitresPerMinute / 60 * dt)

        oilTankCurrentLitres = math.max(0, oilTankCurrentLitres - oilLostLitres)
        oilTankIsEmpty = oilTankCurrentLitres <= 0
        updateOilSpillSync(dt, currentLeakRateLitresPerMinute / 60, oilLostLitres)

        if not oilTankLeakageMessageShown then
            overheadMessageQueue("Oil leak", "Body damage has opened an oil leak", 4)
            oilTankLeakageMessageShown = true
        end
    else
        oilTankLeakageDamage = false
        oilTankLeakageRateLitresPerMinute = 0
        oilTankLeakageCurrentRateLitresPerMinute = 0
        oilTankLeakageMessageShown = false
        oilTankLeakageRollDone = false
        oilTankLeakageLastRolledDamage = 0
        oilTankLeakageSeverity = 0
        resetOilSpillSync()
    end
end

local function updateOilConsumption(dt)
    local engineRunningFactor = getEngineRunningFactor()
    local oilDemandFactor = getOilDemandFactor()

    if engineRunningFactor == 0 then
        return
    end

    -- Total-loss and splash/pressure systems both consume some oil in use.
    -- More RPM and throttle means more oil sent through the engine and lost.
    local oilConsumedLitres = oilBaseConsumptionLitresPerMinute / 60 * dt
    oilConsumedLitres = oilConsumedLitres + oilDemandConsumptionLitresPerMinute / 60 * oilDemandFactor * dt
    oilLastEngineConsumptionLitresPerMinute = oilConsumedLitres / math.max(dt, 0.001) * 60
    oilEngineGalleryLitres = clampNumber(oilEngineGalleryLitres - oilConsumedLitres, 0, oilEngineGalleryMaximumLitres)
end

local function updateOilPressure(dt)
    local engineRunningFactor = getEngineRunningFactor()
    local oilDemandFactor = getOilDemandFactor()
    local targetPressureFromGallery = oilOptimalPressurePsi * clampNumber(oilEngineGalleryLitres / oilEngineGalleryTargetLitres, 0, 1.25)
    local demandPressureLoss = oilDemandPressureLossPsi * oilDemandFactor * engineRunningFactor
    demandPressureLoss = demandPressureLoss + oilDamagedPumpPressureLossPsi * (1 - oilPressurePumpEfficiency) * engineRunningFactor
    local desiredOilPressurePsi = clampNumber(targetPressureFromGallery - demandPressureLoss, 0, oilMaximumPressurePsi)

    if engineRunningFactor == 0 then
        desiredOilPressurePsi = math.min(desiredOilPressurePsi, oilPressureEngineOffResidualPsi)
    end

    -- Pressure does not jump instantly: the gauge and oil gallery lag behind
    -- pump strokes and pressure loss.
    local pressureResponseRate = oilPressureRiseRatePerSecond
    if desiredOilPressurePsi < oilPressurePsi then
        pressureResponseRate = oilPressureFallRatePerSecond
    end

    oilPressurePsi = oilPressurePsi + (desiredOilPressurePsi - oilPressurePsi) * clampNumber(pressureResponseRate * dt, 0, 1)
end

local function updateOilPressureDamage(dt)
    local engineRunningFactor = getEngineRunningFactor()

    if engineRunningFactor == 0 then
        oilEngineDamageTimer = 0
        oilPressureDamageActive = false
        return
    end

    if oilPressurePsi < oilCriticalPressurePsi then
        oilEngineDamageTimer = oilEngineDamageTimer + dt
    else
        oilEngineDamageTimer = math.max(0, oilEngineDamageTimer - dt * oilPressureRecoveryGraceMultiplier)
    end

    oilPressureDamageActive = oilEngineDamageTimer >= oilLowPressureGraceSeconds

    if oilPressureDamageActive and not totalMeltdown then
        local pressureShortfallFactor = clampNumber((oilCriticalPressurePsi - oilPressurePsi) / oilCriticalPressurePsi, 0, 1)
        local rpmStressFactor = clampNumber(acCarPhysics.rpm / oilPressureReferenceRpm, 0.25, 2)

        -- Feed the existing oilPressureFailure(dt) path so current warning,
        -- damage, and integration behavior stays in one place.
        oilPressureFailureActive = true
        oilPressureFailed = true
        oilPressureFailureElapsed = oilPressureFailureElapsed + oilLowPressureEngineDamagePerSecond * pressureShortfallFactor * rpmStressFactor * dt

        -- Poor lubrication also means extra friction heat before the engine
        -- fails outright. Thermal code also multiplies heat while the warning
        -- flag is active, this adds the direct dry-bearing heat spike.
        engineTemp = engineTemp + oilStarvationEngineHeatGainPerSecond * pressureShortfallFactor * rpmStressFactor * dt
    elseif oilPressureFailureActive and oilPressurePsi > oilPressureRecoveryPressurePsi then
        -- Once pressure has recovered, pause the progressive oil-failure path.
        oilPressureFailureActive = false
        if not oilPressurePumpDamaged then
            oilPressureFailed = false
        end
    end
end

local function updateOilMessages(dt)
    if getEngineRunningFactor() == 0 then
        return
    end

    oilLowPressureMessageTimer = oilLowPressureMessageTimer + dt
    oilTankEmptyMessageTimer = oilTankEmptyMessageTimer + dt

    if oilAutomaticPumpAssistantEnabled then
        -- Automatic pumping is normal operation, so do not announce it.
        oilLowPressureMessageTimer = 0
    elseif oilPressurePsi < oilLowPressureWarningPsi and oilLowPressureMessageTimer >= oilLowPressureMessageIntervalSeconds then
        overheadMessageQueue("Low oil pressure", "Use the hand pump to feed the engine", 4, true)
        oilLowPressureMessageTimer = 0
    end

    if oilTankIsEmpty and oilTankEmptyMessageTimer >= oilTankEmptyMessageIntervalSeconds then
        overheadMessageQueue("Oil tank empty", "Pressure can no longer be restored", 5, true)
        oilTankEmptyMessageTimer = 0
    end
end

local function updateOilDebug(dt)
    oilPressureDebugTimer = oilPressureDebugTimer + dt

    if oilPressureDebugTimer >= oilDebugIntervalSeconds then
        printDebug("Oil pressure", string.format("%.1f psi", oilPressurePsi))
        printDebug("Oil tank", string.format("%.2f / %.2f L", oilTankCurrentLitres, oilTankCapacityLitres))
        printDebug("Oil gallery", string.format("%.3f L", oilEngineGalleryLitres))
        printDebug("Oil use", string.format("%.3f L/min", oilLastEngineConsumptionLitresPerMinute))
        printDebug("Oil starvation damage", tostring(oilPressureDamageActive))
        printDebug("Oil tank puncture", string.format(
            "Active: %s | Leak: %.2f L/min | Severity: %.0f%%",
            tostring(oilTankLeakageDamage),
            oilTankLeakageCurrentRateLitresPerMinute,
            oilTankLeakageSeverity * 100
        ))
        oilPressureDebugTimer = 0
    end
end

function resetOilPressureSystem()
    oilTankCurrentLitres = oilTankCapacityLitres
    oilEngineGalleryLitres = oilEngineGalleryInitialLitres
    oilPressurePsi = oilPressureInitialPsi
    oilManualPumpIsActive = false
    oilPressureDamageActive = false
    oilTankIsEmpty = false
    oilTankLeakageDamage = false
    oilTankLeakageRateLitresPerMinute = 0
    oilTankLeakageCurrentRateLitresPerMinute = 0
    oilTankLeakageMessageShown = false
    oilTankLeakageRollDone = false
    oilTankLeakageLastRolledDamage = 0
    oilTankLeakageSeverity = 0
    resetOilSpillSync()
    repairOilPressurePump()
    oilPitRefillInProgress = false
    oilPitRefillTimer = 0
    oilPreviousManualPumpButtonState = false
    oilManualPumpActiveTimer = 0
    oilAutomaticPumpTimer = 0
    oilLowPressureMessageTimer = 0
    oilTankEmptyMessageTimer = 0
    oilEngineDamageTimer = 0
    oilPressureDebugTimer = 0
end

function refillOilPressureSystemInPits()
    oilTankCurrentLitres = oilTankCapacityLitres
    oilEngineGalleryLitres = math.max(oilEngineGalleryLitres, oilEngineGalleryInitialLitres)
    oilPressurePsi = math.max(oilPressurePsi, oilPressureInitialPsi)
    oilManualPumpIsActive = false
    oilPressureDamageActive = false
    oilTankIsEmpty = false
    oilEngineDamageTimer = 0
    oilPitRefillInProgress = false
    oilPitRefillTimer = 0
    oilManualPumpActiveTimer = 0
end

function damageOilPressurePump()
    oilPressurePumpDamaged = true
    oilPressurePumpEfficiency = oilPressurePumpFailureEfficiencyMin + math.random() * (oilPressurePumpFailureEfficiencyMax - oilPressurePumpFailureEfficiencyMin)
end

function repairOilPressurePump()
    oilPressurePumpDamaged = false
    oilPressurePumpEfficiency = 1.0
end

function oilPressureSystemCanLubricateEngine()
    return oilPressurePsi >= oilPressureRecoveryPressurePsi and oilEngineGalleryLitres > oilEngineGalleryMinimumLitres
end

function forceOilPressureSystemFailureForTesting()
    damageOilPressurePump()
    oilEngineGalleryLitres = math.min(oilEngineGalleryLitres, oilEngineGalleryMinimumLitres * 0.5)
    oilPressurePsi = math.min(oilPressurePsi, oilCriticalPressurePsi * 0.5)
    oilEngineDamageTimer = oilLowPressureGraceSeconds
    oilPressureDamageActive = true
    oilPressureFailed = true
    oilPressureFailureActive = true
end

function oilPressureSystemNeedsPitRefill()
    return oilTankCurrentLitres < oilPitRefillStartThresholdLitres
end

function oilPressureSystemNeedsPitService()
    return oilPressureSystemNeedsPitRefill()
        or oilTankLeakageDamage
        or oilPressurePumpDamaged
        or oilPressureFailed
        or oilPressureFailureActive
        or oilPressureDamageActive
end

function oilPressureSystemPitRefill(dt)
    if not isCarInPits then
        oilPitRefillInProgress = false
        oilPitRefillTimer = 0
        acCarPhysics.controllerInputs[58] = false
        return
    end

    if not oilPressureSystemNeedsPitService() and not oilPitRefillInProgress then
        oilPitRefillInProgress = false
        oilPitRefillTimer = 0
        acCarPhysics.controllerInputs[58] = false
        if isPitRepairQueueCurrent("oil") then
            completePitRepairQueueItem("oil")
        end
        return
    end

    if isPitRepairQueueCurrent("oil") and not oilPitRefillInProgress then
        oilPitRefillInProgress = true
        oilPitRefillTimer = 0
        overheadMessageQueue("Oil service", "Service started. Hold position until done", 3, true)
    end

    if oilPitRefillInProgress then
        oilPitRefillTimer = oilPitRefillTimer + dt
        acCarPhysics.controllerInputs[58] = true

        overheadMessageQueue("Oil service",
            string.format("Progress: %d%%",
            math.floor(math.min(100, (oilPitRefillTimer / math.max(0.1, oilPitRefillTimeSeconds)) * 100))), 1, true)

        if oilPitRefillTimer >= oilPitRefillTimeSeconds then
            repairOilTankLeakage()
            refillOilPressureSystemInPits()
            repairOilPressurePump()
            oilPressureFailed = false
            oilPressureFailureActive = false
            oilPressureFailureElapsed = 0
            oilPressureFailureDamage = oilPressureFailureMinDamage
            overheadMessageQueue("Oil service", "Service complete", 3, true)
            completePitRepairQueueItem("oil")
        end
    end
end

function updateOilPressureSystem(dt)
    if oilManualPumpActiveTimer > 0 then
        oilManualPumpActiveTimer = math.max(0, oilManualPumpActiveTimer - dt)
        oilManualPumpIsActive = true
    else
        oilManualPumpIsActive = false
    end

    updateManualOilPumpInput()
    updateAutomaticOilPumpAssistant(dt)
    updateOilTankLeakage(dt)
    updateOilConsumption(dt)
    updateOilPressure(dt)
    updateOilPressureDamage(dt)
    updateOilMessages(dt)
    updateOilDebug(dt)

    acCarPhysics.controllerInputs[53] = oilPressurePsi
    acCarPhysics.controllerInputs[54] = oilTankCurrentLitres
    acCarPhysics.controllerInputs[55] = oilTankCurrentLitres / math.max(oilTankCapacityLitres, 0.001)
    acCarPhysics.controllerInputs[56] = oilManualPumpIsActive
    acCarPhysics.controllerInputs[57] = oilPressureDamageActive
    acCarPhysics.controllerInputs[59] = oilTankLeakageDamage
    acCarPhysics.controllerInputs[60] = oilTankLeakageCurrentRateLitresPerMinute
    acCarPhysics.controllerInputs[61] = oilPressurePumpDamaged
    acCarPhysics.controllerInputs[62] = oilPressurePumpEfficiency
end
