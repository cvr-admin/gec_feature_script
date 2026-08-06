-- Change failure rates based on driving conditions and driver actions.
--
-- Overrevving
--  * Increase spark plug failure possibility
--  * Increase fuel pump failure
--  * Increase oil pressure problems
--  * Increase valve damage possibility in high revs
--
-- At low rpm
--  * Increase spark plug failure
--  * Increase fuel pump failure
--  * Increase oil pressure problems
--  * Increase radiator efficiency
--
-- Running behind other cars
--  * Increase fuel pump failure
--  * Increase oil pressure problems
--  * Increase valve damage possibility
--  * Reduce radiator efficiency
--
-- Running tank low
--  * Increase fuel pump failure
--
-- Running with high coolant temp
--  * Increase fuel pump failure
--  * Increase valve damage possibility
--  * Increase oil pressure problems
--  * Increase spark plug failure
--
-- Dusty roads
--  * Reduce radiator efficiency

require "script_car_parameters"

local coolantHandleCounter = 0
local coolantHandleInterval = 7
local fuelLevelHandleCounter = 0
local fuelLevelHandleInterval = 7

local printDebug = nil
local logDebug = nil

-- Debug logging stuff.
local overrevving = false
local lowRpm = false
local runningCloseToCarInFront = false
local coolantHandleDebugLoggingCounter = 0
local coolantHandleDebugLoggingInterval = 14
local fuelLevelHandleDebugLoggingCounter = 0
local fuelLevelHandleDebugLoggingInterval = 14

local cumulativeRateChanges = {
    overrevving = {
        sparkPlug = 0,
        fuelPump = 0,
        valveDamage = 0,
        oilPressure = 0
    },
    lowRpm = {
        sparkPlug = 0,
        fuelPump = 0,
        oilPressure = 0
    },
    runningCloseToCarInFront = {
        fuelPump = 0,
        valveDamage = 0,
        oilPressure = 0
    },
    highCoolantTemp = {
        sparkPlug = 0,
        fuelPump = 0,
        valveDamage = 0,
        oilPressure = 0
    },
    runningTankLow = {
        fuelPump = 0
    }
}

local overrevvingState = 0
radiatorDustClogLevel = radiatorDustClogLevel or 0

sparkPlugFailureRateInitialValue = sparkPlugFailureRateNominalValue
fuelPumpFailureRateInitialValue = fuelPumpFailureRateNominalValue
valveFailureRateInitialValue = valveFailureRateNominalValue
oilPressureFailureRateInitialValue = oilPressureFailureRateNominalValue

local function applySessionFailureRateRandomness(nominalRate)
    local spread = math.max(failureRateSessionRandomness or 0, 0)
    local factor = 1 + (math.random() * 2 - 1) * spread
    return math.max(1, math.floor(nominalRate * factor + 0.5))
end

function randomizeSessionFailureRates()
    sparkPlugFailureRateInitialValue = applySessionFailureRateRandomness(sparkPlugFailureRateNominalValue)
    fuelPumpFailureRateInitialValue = applySessionFailureRateRandomness(fuelPumpFailureRateNominalValue)
    valveFailureRateInitialValue = applySessionFailureRateRandomness(valveFailureRateNominalValue)
    oilPressureFailureRateInitialValue = applySessionFailureRateRandomness(oilPressureFailureRateNominalValue)
end

-- Apply the first per-session scatter immediately so script.lua's initial
-- live failure-rate values are randomized even if resetCar() is not called
-- before driving. resetCar() will roll a fresh set for normal session resets.
randomizeSessionFailureRates()

function initFailureHandlingVariables(printDebug_, logDebug_)
    printDebug = printDebug_
    logDebug = logDebug_
end

function resetCumulativeRateChanges()
    for _, modeChanges in pairs(cumulativeRateChanges) do
        for key, _ in pairs(modeChanges) do
            modeChanges[key] = 0
        end
    end
end

local function getEngineMaxRpm()
    maxRPM = ac.INIConfig.carData(0, 'engine.ini'):get('DAMAGE', 'RPM_THRESHOLD', 0)
    assert(maxRPM > 0, "DAMAGE/RPM_THRESHOLD value not found. Check engine.ini!")
    return maxRPM
end

local engineMaxRpm = getEngineMaxRpm()

local function getCarInFrontDistance(ac)
    local CAR_FORWARDNESS_TRESHOLD = 0.995
    local thisCar = ac.getCar()
    local myPos = thisCar.position
    local myDir = thisCar.look

    local closestDistance = math.huge
    local closestForwardness = -1

    for i = 1, ac.getSim().carsCount - 1 do
        local otherCar = ac.getCar(i)
        local delta = otherCar.position - myPos
        local forwardness = vec3.dot(delta:normalize(), myDir)

        if forwardness > CAR_FORWARDNESS_TRESHOLD then -- car is directly in front
            local dist = vec3.distance(myPos, otherCar.position)
            if dist < closestDistance then
                closestDistance = dist
                closestForwardness = forwardness
            end
        end
    end

    if closestForwardness < CAR_FORWARDNESS_TRESHOLD then
        printDebug("Forwardness", "0")
        return math.huge
    end

    printDebug("Forwardness", "" .. closestForwardness)

    return closestDistance
end

function handleOverrevving(failureRates, engineRpm)
    printDebug("Engine RPM", "" .. engineRpm)
    local overrevvingThreshold = math.floor(engineMaxRpm * overrevvingThresholdFactor + 0.5)
    local overrevvingThresholdHigh = math.floor(engineMaxRpm * overrevvingThresholdFactorHigh + 0.5)
    local overrevvingWarningThreshold = math.floor(overrevvingThreshold * overrevvingWarningThresholdFactor + 0.5)

    if engineRpm > overrevvingThresholdHigh then
        overrevvingState = 2
    elseif engineRpm > overrevvingWarningThreshold then
        overrevvingState = 1
    else
        overrevvingState = 0
    end
    if engineRpm > overrevvingThreshold then
        printDebug("Overrevving", "ACTIVE")

        local rpmOverrevAmount = engineRpm - overrevvingThreshold
        local overrevvingRange = math.max(overrevvingThresholdHigh - overrevvingThreshold, 1)
        local softSeverity = math.clamp(rpmOverrevAmount / overrevvingRange, 0, 1)
        local hardSeverity = math.clamp((engineRpm - overrevvingThresholdHigh) / overrevvingRange, 0, 3)
        local softRateStep = (softSeverity ^ overrevvingProgressionExponent) * overrevvingRateDecreaseStepFactor
        local hardRateStep = hardSeverity * (overrevvingHighRateDecreaseStepFactor or overrevvingRateDecreaseStepFactor * 2.5)
        local progressiveRpmAmount = math.floor(softRateStep + hardRateStep + 0.5)

        failureRates.sparkPlug = failureRates.sparkPlug - progressiveRpmAmount
        failureRates.fuelPump = failureRates.fuelPump - progressiveRpmAmount
        failureRates.valveDamage = failureRates.valveDamage - progressiveRpmAmount
        failureRates.oilPressure = failureRates.oilPressure - progressiveRpmAmount

        cumulativeRateChanges.overrevving.sparkPlug = cumulativeRateChanges.overrevving.sparkPlug + progressiveRpmAmount
        cumulativeRateChanges.overrevving.fuelPump = cumulativeRateChanges.overrevving.fuelPump + progressiveRpmAmount
        cumulativeRateChanges.overrevving.valveDamage = cumulativeRateChanges.overrevving.valveDamage + progressiveRpmAmount
        cumulativeRateChanges.overrevving.oilPressure = cumulativeRateChanges.overrevving.oilPressure + progressiveRpmAmount

        overrevving = true
    else
        printDebug("Overrevving", "inactive")
        if overrevving then
            logDebug("<FRH>Overrevving, rates after:")
            logDebug(" SPlug: " .. failureRates.sparkPlug .. ", Fpump: " .. failureRates.fuelPump ..
                     ", VDmg: " .. failureRates.valveDamage .. ", OPres: " .. failureRates.oilPressure)
        end
        overrevving = false
    end
end

function handleLowRpm(failureRates, engineRpm)
    local lowRpmThresholdRpm = math.floor(engineMaxRpm * lowRpmThreshold + 0.5)

    if engineRpm < lowRpmThresholdRpm then
        printDebug("Low RPM", "ACTIVE")

        local lowRpmStep = math.floor((lowRpmThresholdRpm - engineRpm) / 100 + 0.5)
        printDebug("Step", lowRpmStep)

        failureRates.sparkPlug = failureRates.sparkPlug - lowRpmStep
        failureRates.fuelPump = failureRates.fuelPump - lowRpmStep
        failureRates.oilPressure = failureRates.oilPressure - lowRpmStep

        cumulativeRateChanges.lowRpm.sparkPlug = cumulativeRateChanges.lowRpm.sparkPlug + lowRpmStep
        cumulativeRateChanges.lowRpm.fuelPump = cumulativeRateChanges.lowRpm.fuelPump + lowRpmStep
        cumulativeRateChanges.lowRpm.oilPressure = cumulativeRateChanges.lowRpm.oilPressure + lowRpmStep

        lowRpm = true
        return true
    else
        printDebug("Low RPM", "inactive")

        if lowRpm then
            logDebug("<FRH>Low RPM, below treshold: " .. engineMaxRpm * lowRpmThreshold)
            logDebug("Rates after:")
            logDebug(" SPlug: " .. failureRates.sparkPlug .. ", Fpump: " .. failureRates.fuelPump ..
                     ", OPres: " .. failureRates.oilPressure)
        end

        lowRpm = false
    end

    return false
end

function handleRunningCloseToCarInFront(failureRates, speed, ac)
    if speed < closeCarInFrontSpeedThreshold then
        return 0
    end

    local distance = getCarInFrontDistance(ac)
    printDebug("Distance to car in front", "" .. distance)
    if distance < closeCarInFrontDistanceThreshold then
        -- The closer the car is running to the car in front, the larger the step to subtract.
        -- The divider 4 is to reduce the effect to be less severe, since this is called every
        -- 0,3 seconds.
        local step = math.floor(closeCarInFrontDistanceMin / math.max(distance, closeCarInFrontDistanceMin) * closeCarInFrontDistanceThreshold / 4 + 0.5)
        failureRates.fuelPump = failureRates.fuelPump - step
        failureRates.valveDamage = failureRates.valveDamage - step
        failureRates.oilPressure = failureRates.oilPressure - step
        printDebug("Distance to car", "ACTIVE: " .. step)

        cumulativeRateChanges.runningCloseToCarInFront.fuelPump = cumulativeRateChanges.runningCloseToCarInFront.fuelPump + step
        cumulativeRateChanges.runningCloseToCarInFront.valveDamage = cumulativeRateChanges.runningCloseToCarInFront.valveDamage + step
        cumulativeRateChanges.runningCloseToCarInFront.oilPressure = cumulativeRateChanges.runningCloseToCarInFront.oilPressure + step

        runningCloseToCarInFront = true
        return step
    else
        printDebug("Distance to car", "inactive")

        if runningCloseToCarInFront then
            logDebug("<FRH>Running close to car in front, rates after:")
            logDebug(" Fpump: " .. failureRates.fuelPump .. ", VDmg: " .. failureRates.valveDamage ..
                     ", OPres: " .. failureRates.oilPressure)
        end

        runningCloseToCarInFront = false
    end

    return 0
end

function handleHighCoolantTemp(failureRates, coolantTemp)
    -- Handle coolant temperature effects at a lower frequency.
    coolantHandleCounter = coolantHandleCounter + 1
    if coolantHandleCounter < coolantHandleInterval then
        return
    end
    coolantHandleCounter = 0

    local coolantTemperatureExcess = coolantTemp - highEngineTempThreshold
    if coolantTemperatureExcess > 0 then
        -- Make hot-running consequences ramp up more aggressively than the old
        -- simple linear step. A few degrees over the limit is survivable, but
        -- sustained running deep in the danger zone accelerates failures fast.
        local temperatureRamp = math.clamp(coolantTemperatureExcess / 20, 0, 1)
        local fuelPumpFailureRateStep = math.floor(coolantTemperatureExcess * (1.35 + 1.65 * temperatureRamp) + 0.5)
        local valveFailureRateStep = math.floor(coolantTemperatureExcess * (1.20 + 1.80 * temperatureRamp) + 0.5)
        local sparkPlugFailureRateStep = math.floor(coolantTemperatureExcess * (0.85 + 1.10 * temperatureRamp) + 0.5)
        local oilPressureFailureRateStep = math.floor(coolantTemperatureExcess * (0.55 + 0.85 * temperatureRamp) + 0.5)
        
        -- Add an extra cliff once coolant is well past the threshold. This
        -- mirrors the older implementation where very hot running piled on
        -- fuel-pump and valve risk much faster.
        if coolantTemp > highEngineTempThreshold + 12 then
            local extraHotTemperatureExcess = coolantTemp - (highEngineTempThreshold + 12)
            fuelPumpFailureRateStep = fuelPumpFailureRateStep + math.floor(extraHotTemperatureExcess * 0.8 + 0.5)
            valveFailureRateStep = valveFailureRateStep + math.floor(extraHotTemperatureExcess * 1.0 + 0.5)
            sparkPlugFailureRateStep = sparkPlugFailureRateStep + math.floor(extraHotTemperatureExcess * 0.55 + 0.5)
            oilPressureFailureRateStep = oilPressureFailureRateStep + math.floor(extraHotTemperatureExcess * 0.35 + 0.5)
        end

        printDebug("High coolant", "ACTIVE: " .. coolantTemperatureExcess .. " | FP step: " .. fuelPumpFailureRateStep .. " | V step: " .. valveFailureRateStep)
        failureRates.sparkPlug = failureRates.sparkPlug - sparkPlugFailureRateStep
        failureRates.fuelPump = failureRates.fuelPump - fuelPumpFailureRateStep
        failureRates.valveDamage = failureRates.valveDamage - valveFailureRateStep
        failureRates.oilPressure = failureRates.oilPressure - oilPressureFailureRateStep

        cumulativeRateChanges.highCoolantTemp.sparkPlug = cumulativeRateChanges.highCoolantTemp.sparkPlug + sparkPlugFailureRateStep
        cumulativeRateChanges.highCoolantTemp.fuelPump = cumulativeRateChanges.highCoolantTemp.fuelPump + fuelPumpFailureRateStep
        cumulativeRateChanges.highCoolantTemp.valveDamage = cumulativeRateChanges.highCoolantTemp.valveDamage + valveFailureRateStep
        cumulativeRateChanges.highCoolantTemp.oilPressure = cumulativeRateChanges.highCoolantTemp.oilPressure + oilPressureFailureRateStep

        if coolantHandleDebugLoggingCounter == 0 then
            logDebug("<FRH>High coolant temperature: " .. coolantTemp .. " C")
            logDebug("Current rates:")
            logDebug(" SPlug: " .. failureRates.sparkPlug ..
                    ", Fpump: " .. failureRates.fuelPump ..
                    ", VDmg: " .. failureRates.valveDamage ..
                    ", OPres: " .. failureRates.oilPressure ..
                    " | steps SP: " .. sparkPlugFailureRateStep ..
                    ", FP: " .. fuelPumpFailureRateStep ..
                    ", V: " .. valveFailureRateStep ..
                    ", OP: " .. oilPressureFailureRateStep)
        end
        coolantHandleDebugLoggingCounter = (coolantHandleDebugLoggingCounter + 1) % coolantHandleDebugLoggingInterval
    else
        printDebug("High coolant", "inactive")
        coolantHandleDebugLoggingCounter = 0
    end
end

function handleRunningTankLow(failureRates, fuelLevel)
    -- Handle fuel level effects at a lower frequency.
    fuelLevelHandleCounter = fuelLevelHandleCounter + 1
    if fuelLevelHandleCounter < fuelLevelHandleInterval then
        return
    end
    fuelLevelHandleCounter = 0

    if fuelLevel < fuelLevelThreshold then
        printDebug("Running tank low", "ACTIVE")
        failureRates.fuelPump = failureRates.fuelPump - fuelPumpLowFuelStep

        cumulativeRateChanges.runningTankLow.fuelPump = cumulativeRateChanges.runningTankLow.fuelPump + fuelPumpLowFuelStep

        if fuelLevelHandleDebugLoggingCounter == 0 then
            logDebug("<FRH>Running tank low, fuel level: " .. fuelLevel .. " L")
            logDebug("Fpump rate: " .. failureRates.fuelPump)
        end
        fuelLevelHandleDebugLoggingCounter = (fuelLevelHandleDebugLoggingCounter + 1) % fuelLevelHandleDebugLoggingInterval
    else
        printDebug("Running tank low", "inactive")
        fuelLevelHandleDebugLoggingCounter = 0
    end
end

function resetRadiatorDustClog()
    radiatorDustClogLevel = 0
end

function cleanRadiatorDustClog(cleanFraction)
    radiatorDustClogLevel = radiatorDustClogLevel * (1 - math.clamp(cleanFraction or radiatorDustClogPitCleanFraction, 0, 1))
end

local function updateRadiatorDustClog(trackSurfaceType, speedKmh, dt, runningCloseToCarInFrontStep)
    if trackSurfaceType ~= ac.SurfaceExtendedType.Gravel then
        return
    end

    local speedFactor = math.clamp((speedKmh or 0) / math.max(radiatorDustClogSpeedReferenceKmh, 1), 0.15, 1.75)
    local followingFactor = runningCloseToCarInFrontStep > 0 and radiatorDustClogFollowingMultiplier or 1
    radiatorDustClogLevel = math.clamp(
        radiatorDustClogLevel + radiatorDustClogBuildRatePerSecond * speedFactor * followingFactor * (dt or 0),
        0,
        1
    )
end

function handleRadiatorEfficiency(radiatorCoolCoefficientBase, lowRpm, runningCloseToCarInFrontStep, trackSurfaceType, speedKmh, dt)
    if lowRpm then
        radiatorCoolCoefficientBase = radiatorCoolCoefficientBase * radiatorEfficiencyLowRpmMultiplier
    end

    if runningCloseToCarInFrontStep > 0 then
        -- This reduces the radiator efficiency based on how close the car is to the car in front,
        -- with e.g. 1 meter resulting in a factor 0.6, 2 meters 0.8 and 3 meters 0.88, etc.
        radiatorCoolCoefficientBase = radiatorCoolCoefficientBase * (1 - runningCloseToCarInFrontStep / 25)
    end

    if trackSurfaceType == ac.SurfaceExtendedType.Gravel then
        radiatorCoolCoefficientBase = radiatorCoolCoefficientBase * radiatorEfficiencyDustMultiplier
    end

    updateRadiatorDustClog(trackSurfaceType, speedKmh, dt, runningCloseToCarInFrontStep)
    radiatorCoolCoefficientBase = radiatorCoolCoefficientBase * (1 - radiatorDustClogLevel * radiatorDustClogMaxCoolingLoss)

    return radiatorCoolCoefficientBase
end

function logCumulativeRateChanges()
    logDebug("Cumulative rate changes:")
    for mode, changes in pairs(cumulativeRateChanges) do
        local changesStr = mode .. ":"
        for key, value in pairs(changes) do
            changesStr = changesStr .. " " .. key .. "=" .. value .. ","
        end
        logDebug(changesStr)
        printDebug("RC", changesStr)
    end
end

function getOverrevvingState()
    return overrevvingState
end

function getLowRpmState()
    return lowRpm
end
