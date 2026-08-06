-- Electricity system


-- Cached original values (learned at runtime)
-- ORIG_RPM_LIMIT and ORIG_IDLE_RPM are set once during first update tick
local last_engaged    = last_engaged or 1
local idleRPM         = nil
local batteryDamageStages = batteryDamageStages or { false, false, false, false }
local alternatorDamageStages = alternatorDamageStages or { false, false, false, false }
local prevBatteryDamage = prevBatteryDamage or 0
local prevAlternatorDamage = prevAlternatorDamage or 0

-- Stage definitions: selected body-damage thresholds and failure probabilities.
local damageStages = {
    { threshold = 0.10, probability = 0.10 },
    { threshold = 0.30, probability = 0.25 },
    { threshold = 0.50, probability = 0.45 },
    { threshold = 0.80, probability = 0.75 },
}

-- Idle calibration helpers
local _idleCalTime = 0
local _idleCalSum  = 0
local _idleCalN    = 0

-- Battery cut simulation state (weak battery)
batteryCutActive = batteryCutActive or false
batteryCutTimer  = batteryCutTimer  or 0

local msgQueue = nil
local optimizationTimerLoc = 0  -- throttle some checks to every ~2s instead of every tick

local altWetTreshold = nil

local heatLogTimer = 0
local vibrationTimer = 0
local cvrPitCrewRoadsideElectricityService = false

-- Some CSP Lua contexts don't expose ac.setCondition()
local function setConditionSafe(name, value)
    if ac.setCondition then
        ac.setCondition(name, value)
        return
    end
    local acCarPhysics = ac.accessCarPhysics()
    acCarPhysics.controllerInputs[43] = math.clamp(value, 0, 1)
end

-- Some CSP Lua contexts don't have math.saturate(). Keep it safe.
local function saturate(x)
    if math.saturate then return math.saturate(x) end
    return math.clamp(x, 0, 1)
end

local function getElectricalComponentDamage(car, sides, defaultSides)
    local damage = car and car.damage
    if not damage then
        return 0
    end

    local selectedSides = sides or defaultSides
    local totalDamage = 0
    local selectedSideCount = 0
    for damageIndex = 0, 3 do
        if selectedSides[damageIndex + 1] then
            totalDamage = totalDamage + (damage[damageIndex] or 0)
            selectedSideCount = selectedSideCount + 1
        end
    end

    return selectedSideCount > 0 and saturate((totalDamage / selectedSideCount) / 200.0) or 0
end

local function getDamageStageState(damageN)
    local state = {}
    for i, stage in ipairs(damageStages) do
        state[i] = damageN >= stage.threshold
    end
    return state
end

-- End an active battery-cut event (hoisted to file scope to avoid re-creation per frame)
local function endCut()
    batteryCutActive = false
    batteryCutTimer  = 0
end


function ResetEle(resetComponents)
    local acCar = ac.getCar(0)
    local batteryDamageN = getElectricalComponentDamage(acCar, batteryDamageSides, {true, false, false, false})
    local alternatorDamageN = getElectricalComponentDamage(acCar, alternatorDamageSides, {false, true, false, false})

    -- Session resets restore components. Pit body repair can refresh the car
    -- model too, but must not repair the battery, generator or belt.
    if resetComponents ~= false then
        alternatorOK = true
        alternatorHealth = 1.0
        batteryCurrentCharge = 100.0
        batteryMaxCapacity = 100.0
    end

    -- Roadside repair
    isRepairingBelt = false
    beltRepairTimer = 0
    cvrPitCrewRoadsideElectricityService = false

    -- Battery ignition cut-out
    batteryCutActive = false
    batteryCutTimer  = 0

    -- Damage stage tracking
    batteryDamageStages = getDamageStageState(batteryDamageN)
    alternatorDamageStages = getDamageStageState(alternatorDamageN)
    prevBatteryDamage = batteryDamageN
    prevAlternatorDamage = alternatorDamageN

    -- Electrical gearbox memory
    last_engaged = 1

    -- Optimization throttle
    optimizationTimerLoc = 0

    heatLogTimer = 0
    vibrationTimer = 0

    -- Restore AC engine RPM settings (may have been lowered by dead-battery logic)
    if ORIG_IDLE_RPM or idleRPM then
        ac.setEngineRPMIdle(ORIG_IDLE_RPM or idleRPM)
    end
    if ORIG_RPM_LIMIT then
        ac.setEngineRPMLimit(ORIG_RPM_LIMIT)
    end

    -- Controller output
    ac.accessCarPhysics().controllerInputs[52] = 0
end


-- Debug snapshot (shown in Lua Debug App via ac.debug())
ElecDbg = ElecDbg or {}
local _dbgTimer = 0
local electricityDebugEnabled = false
local electricityDebugInterval = 0.25

function setElectricityDebugEnabled(enabled, interval)
    electricityDebugEnabled = enabled == true
    electricityDebugInterval = interval or electricityDebugInterval
end

function debugElectricity(dt)
    if not electricityDebugEnabled then return end
    local interval = electricityDebugInterval
    _dbgTimer = _dbgTimer + (dt or 0)
    if _dbgTimer < interval then return end
    _dbgTimer = 0

    ac.debug("ELEC", string.format(
        "bat %.1f/%.1f | alt %s | health %.2f | net %.3f",
        ElecDbg.batteryCurrent or batteryCurrentCharge or 0,
        ElecDbg.batteryMax or batteryMaxCapacity or 0,
        (ElecDbg.alternatorOK == false and "OFF" or "ON"),
        ElecDbg.alternatorHealth or alternatorHealth or 0,
        ElecDbg.netFlow or 0
    ))

    ac.debug("ELEC loads", string.format(
        "altOut %.3f | drain %.3f | rpm %.0f | rain %.2f | slip %.2f",
        ElecDbg.alternatorOutput or 0,
        ElecDbg.powerDrain or 0,
        ElecDbg.rpm or 0,
        ElecDbg.rainFactor or 0,
        ElecDbg.slipFactor or 1
    ))

    ac.debug("ELEC stress", string.format(
        "temp%s %.1fC | batImpact %.2f | genImpact %.2f | maxDamper %.3f",
        ElecDbg.tempSrc or "?",
        ElecDbg.temp or 0,
        ElecDbg.batteryDamageN or 0,
        ElecDbg.alternatorDamageN or 0,
        ElecDbg.maxDamperSpeed or 0
    ))

    ac.debug("ELEC repair", string.format(
        "repairing %s | timer %.1f/%.0f",
        (isRepairingBelt and "YES" or "NO"),
        beltRepairTimer or 0,
        alternatorRepairTime or 0
    ))
end


function updateElectricity(dt)
    -- Type 3 (Hybrid) not yet implemented
    if ignitionType ~= 2 and ignitionType ~= 3 then
        return
    end

    optimizationTimerLoc = optimizationTimerLoc + dt

    local acCarPhysics = ac.accessCarPhysics()
    local carState     = ac.getCar(0)
    local cond         = ac.getConditionsSet()
    local batteryDamageN = getElectricalComponentDamage(carState, batteryDamageSides, {true, false, false, false})
    local alternatorDamageN = getElectricalComponentDamage(carState, alternatorDamageSides, {false, true, false, false})

    -- Note: 'alternatorOK' = belt status, 'alternatorHealth' = alternator unit itself

    -- Cache original RPM limit once
    if not ORIG_RPM_LIMIT then
        ORIG_RPM_LIMIT = acCarPhysics.rpmLimit or 7000
    end

    -- Read idle RPM from engine.ini (once), with fallback
    if not ORIG_IDLE_RPM and not idleRPM then
        local engineIni = ac.INIConfig.carData(0, 'engine.ini')
        idleRPM = 1001  -- fallback
        if engineIni then
            idleRPM = engineIni:get('ENGINE_DATA', 'MINIMUM', idleRPM)
        end
    end

    -- Wet threshold: belt struggles above ~2/3 of the healthy rev range
    if not altWetTreshold then
        altWetTreshold = idleRPM + (ORIG_RPM_LIMIT - idleRPM) * (2 / 3)
    end

    -- Safety clamps (pre)
    alternatorHealth     = math.clamp(alternatorHealth or 1.0, 0.0, 1.0)
    batteryMaxCapacity   = math.clamp(batteryMaxCapacity or 100.0, 5.0, 100.0)
    batteryCurrentCharge = math.clamp(batteryCurrentCharge or 100.0, 0.0, batteryMaxCapacity)

    local rainFactor = (cond and cond.rainIntensity) or 0
    local slipFactor = 1.0
    if rainFactor > 0 then
        slipFactor = 1.0 - rainFactor * 0.2
    end
    if getAirCoolingGeneratorEfficiency then
        slipFactor = slipFactor * getAirCoolingGeneratorEfficiency()
    end

    -- 1) VIBRATION / SHOCK via damperSpeed
    -- Must run every tick to catch transient suspension spikes.
    local maxDamperSpeed = 0
    for i = 0, 3 do
        local w = acCarPhysics.wheels[i]
        if w then
            maxDamperSpeed = math.max(maxDamperSpeed, math.abs(w.damperSpeed or 0))
        end
    end
    if maxDamperSpeed > suspensionShockThreshold then
        batteryMaxCapacity = math.clamp(batteryMaxCapacity - 0.1 * dt, 5.0, 100.0)
        vibrationTimer = 1
    else
        if vibrationTimer > 0 then
            vibrationTimer = vibrationTimer - dt
        end
        if vibrationTimer < 0 then
            logDebug("Battery capacity after vibration damage: " .. batteryMaxCapacity)
            vibrationTimer = 0
        end
    end

    -- 2) HEAT (sanitized)
    local temp = acCarPhysics.controllerInputs[0] or 0
    if temp < -20 or temp > 200 then
        temp = carState.oilTemperature or 0
        if temp < -20 or temp > 250 then temp = 0 end
    end
    if temp > tempThresholdElectricity then
        local heatDamage = (temp - tempThresholdElectricity) * 0.0001
        alternatorHealth = math.clamp(alternatorHealth - heatDamage * dt, 0.0, 1.0)
        heatLogTimer = heatLogTimer + dt
        if heatLogTimer >= 10 then
            logDebug("Alternator health after heat damage: " .. alternatorHealth)
            heatLogTimer = 0
        end
    end

    if optimizationTimerLoc > 2 then
        -- 3) BODY DAMAGE: battery and generator have separate, car-defined locations.
        if batteryDamageN < prevBatteryDamage * 0.85 then
            batteryDamageStages = getDamageStageState(batteryDamageN)
        end
        prevBatteryDamage = batteryDamageN
        for i, stage in ipairs(damageStages) do
            if not batteryDamageStages[i] and batteryDamageN >= stage.threshold then
                batteryMaxCapacity = math.clamp(batteryMaxCapacity - math.random(0, i * 10), 5.0, 100.0)
                logDebug("Battery capacity after body damage: " .. batteryMaxCapacity)
                batteryDamageStages[i] = true
            end
        end

        if alternatorDamageN < prevAlternatorDamage * 0.85 then
            alternatorDamageStages = getDamageStageState(alternatorDamageN)
        end
        prevAlternatorDamage = alternatorDamageN
        for i, stage in ipairs(damageStages) do
            if not alternatorDamageStages[i] and alternatorDamageN >= stage.threshold then
                if math.random() < stage.probability and alternatorHealth > 0 then
                    alternatorHealth = math.clamp(alternatorHealth - stage.probability / 2, 0.0, 1.0)
                    logDebug("Generator health after body damage: " .. alternatorHealth)
                end

                if math.random() < stage.probability and alternatorOK then
                    local handledByAirCooling = forceAirCoolingBeltBroken and forceAirCoolingBeltBroken("Generator/fan belt has been thrown by damage")
                    if not handledByAirCooling then
                        alternatorOK = false
                    end
                    logDebug("Generator belt snapped after body damage")
                    if msgQueue and not handledByAirCooling then
                        msgQueue("ELECTRICITY", "The generator belt snapped from body damage!", 3)
                    end
                end

                alternatorDamageStages[i] = true
            end
        end

        -- 4) BELT SLIP/BREAK in rain & OVERREV belt break
        -- Speed check: overrev warning only works while moving
        local overrevLevel = acCarPhysics.controllerInputs[32] or 0

        if rainFactor > 0 and alternatorOK and acCarPhysics.speedKmh > 1
           and (acCarPhysics.rpm or 0) > altWetTreshold then
            -- The lower the number, the easier it breaks.
            -- rainFactor < 1 increases fr_final (harder to break in light rain).
            local fr_final = alternatorFailureRate / rainFactor

            if overrevLevel == 2 then
                fr_final = fr_final / 1.5
            elseif overrevLevel == 1 then
                fr_final = fr_final / 1.25
            end

            if math.random(1, fr_final) == 1 then
                local handledByAirCooling = forceAirCoolingBeltBroken and forceAirCoolingBeltBroken("Wet fan belt has been thrown")
                if not handledByAirCooling then
                    alternatorOK = false
                end
                logDebug("Alternator belt snapped in the rain! FRF: " .. fr_final .. " RF: " .. rainFactor .. " RPM: " .. acCarPhysics.rpm)
                if msgQueue and not handledByAirCooling then
                    msgQueue("ELECTRICITY", "The alternator belt broke in the rain!", 3)
                end
            end
        end

        -- Maybe that's too easy on the player. Could go from 2 to 1
        if alternatorOK and acCarPhysics.speedKmh > 1 and overrevLevel == 2 then
            if math.random(1, alternatorFailureRate) == 1 then
                local handledByAirCooling = forceAirCoolingBeltBroken and forceAirCoolingBeltBroken("The fan belt broke from over-revving")
                if not handledByAirCooling then
                    alternatorOK = false
                end
                logDebug("Alternator belt broke from over-revving.")
                if msgQueue and not handledByAirCooling then
                    msgQueue("ELECTRICITY", "The alternator belt broke from over-revving!", 3)
                end
            end
        end

        optimizationTimerLoc = 0
    end

    -- 5) ALTERNATOR OUTPUT (quadratic dynamo curve: weak at idle, strong at revs)
    -- Some might have better or worse alternators
    local alternatorOutput = 0
    if alternatorOK then
        local rpmNorm = math.max(((acCarPhysics.rpm or 0) - alternatorOutputRpmOffset) / alternatorOutputRpmRange, 0)
        alternatorOutput = math.clamp(rpmNorm ^ alternatorOutputExponent * alternatorOutputMaxAmps, 0, alternatorOutputMaxAmps)
        alternatorOutput = alternatorOutput * alternatorHealth * slipFactor
    end

    -- 6) ELECTRICAL LOADS
    powerDrain = powerDrainSystems or 0.00833
    powerDrainHeadlights = powerDrainHeadlights or 0.01296
    -- Less drain for hybrid type (no power needed for ignition)
    if ignitionType == 3 then
        powerDrain = powerDrainSystems / 2
    end

    -- low beams consume half the power only
    if carState.headlightsActive and carState.lowBeams then
        powerDrain = powerDrain + powerDrainHeadlights / 2
    end
    if carState.highBeams then
        powerDrain = powerDrain + powerDrainHeadlights
    end

    local netFlow = alternatorOutput - powerDrain
    local batteryPercentPerAmpSecond = 100 / (math.max(batteryCapacityAh or 12.0, 0.1) * 3600)
    batteryCurrentCharge = math.clamp(batteryCurrentCharge + netFlow * batteryPercentPerAmpSecond * dt, 0, batteryMaxCapacity)

    -- Update debug snapshot
    ElecDbg.rpm              = acCarPhysics.rpm or 0
    ElecDbg.maxDamperSpeed   = maxDamperSpeed
    ElecDbg.batteryDamageN   = batteryDamageN
    ElecDbg.alternatorDamageN = alternatorDamageN
    ElecDbg.temp             = temp
    ElecDbg.tempSrc          = (temp >= -20 and temp <= 200) and "W" or "O"
    ElecDbg.rainFactor       = rainFactor
    ElecDbg.slipFactor       = slipFactor
    ElecDbg.alternatorOK     = alternatorOK
    ElecDbg.alternatorHealth = alternatorHealth
    ElecDbg.alternatorOutput = alternatorOutput
    ElecDbg.powerDrain       = powerDrain
    ElecDbg.netFlow          = netFlow
    ElecDbg.batteryCurrent   = batteryCurrentCharge
    ElecDbg.batteryMax       = batteryMaxCapacity

    -- ========================================
    -- BATTERY -> IGNITION BEHAVIOUR
    -- ========================================
    local idleBase = ORIG_IDLE_RPM or 1000

    local BAT_DEAD     = 0.05
    local BAT_WEAK     = 6.0
    local CUT_RATE_HZ  = 1.2   -- max cut frequency at worst battery (per second)
    local CUT_DURATION = 0.25  -- seconds per cut

    -- Ignition-dependent stalling (type 2 only; type 3/hybrid not yet implemented)
    if ignitionType == 2 then

        -- DEAD: stall properly (kills idle so engine can't creep)
        if batteryCurrentCharge <= BAT_DEAD then
            ac.setEngineRPMIdle(0)
            if (acCarPhysics.rpm or 0) > 200 then
                ac.setEngineRPM(0)
                logDebug("Dead Battery stalled engine. Current Charge: " .. batteryCurrentCharge)
            end
            ac.setEngineRPMLimit(math.min(ORIG_RPM_LIMIT or 7000, 1500))
            endCut()

        -- WEAK: intermittent ignition cut-outs
        elseif batteryCurrentCharge < BAT_WEAK then
            ac.setEngineRPMLimit(ORIG_RPM_LIMIT or 7000)

            if batteryCutActive then
                batteryCutTimer = batteryCutTimer - dt
                ac.setEngineRPMIdle(0)
                logDebug("Engine ignition cut due to weak battery. Current Charge: " .. batteryCurrentCharge)
                if batteryCutTimer <= 0 then
                    endCut()
                    ac.setEngineRPMIdle(idleBase)
                end
            else
                ac.setEngineRPMIdle(idleBase)
                local weakness = (BAT_WEAK - batteryCurrentCharge) / BAT_WEAK
                local p = CUT_RATE_HZ * weakness * dt
                if math.random() < p then
                    batteryCutActive = true
                    batteryCutTimer  = CUT_DURATION
                    ac.setEngineRPMIdle(0)
                end
            end

        -- OK: restore normal
        else
            ac.setEngineRPMIdle(idleBase)
            ac.setEngineRPMLimit(ORIG_RPM_LIMIT or 7000)
            endCut()
        end

    end

    -- No-power consequences --

    -- Lights go out
    if batteryCurrentCharge <= BAT_DEAD then
        ac.setHeadlights(false)
        -- TODO: find a way to do this for brake lights too
        logDebug("Headlights turned off due to dead battery. Current Charge: " .. batteryCurrentCharge)
    else
        -- TODO: find a way to do this for brake lights too
    end

    -- Electrical gearbox ceases operation (PSG needs separate logic in its own script)
    if isCotalElectricGearboxEnabled() then
        if batteryCurrentCharge <= BAT_DEAD then
            acCarPhysics.requestedGearIndex = last_engaged
            logDebug("Cant change gears due to dead battery. Current Charge: " .. batteryCurrentCharge)
        else
            last_engaged = acCarPhysics.requestedGearIndex
        end
    end

    -- Send values to apps
    acCarPhysics.controllerInputs[43] = netFlow
    acCarPhysics.controllerInputs[44] = batteryCurrentCharge
    acCarPhysics.controllerInputs[45] = batteryMaxCapacity
    acCarPhysics.controllerInputs[46] = alternatorOK
    acCarPhysics.controllerInputs[47] = alternatorOutput
    acCarPhysics.controllerInputs[48] = alternatorHealth
    if acCarPhysics.controllerInputs[52] == nil then
        acCarPhysics.controllerInputs[52] = 0
    end

end


-- Roadside belt repairs
function handleRepairs(dt, overheadMessageQueue_)
    local acCarPhysics = ac.accessCarPhysics()
    local carState     = ac.getCar(0)
    msgQueue = overheadMessageQueue_

    -- Roadside repair: charging belt broken, or a shared fan/charging belt is
    -- slipping/broken. Component and battery damage remains pit-only.
    local sharedBeltNeedsService = needsAirCoolingSharedBeltService and needsAirCoolingSharedBeltService()
    local appRoadsideRequest = isCVRPitCrewRoadsideRepairRequested
        and isCVRPitCrewRoadsideRepairRequested(CVR_ROADSIDE_REPAIR_ELECTRICITY)
    if (not alternatorOK or sharedBeltNeedsService) and (acCarPhysics.speedKmh or 0) < 1
       and ((carState.handbrake or 0) > 0.9 or isRepairingBelt or appRoadsideRequest)
       and not carState.isInPit
       and not tyreChangeInProgress then

        if appRoadsideRequest and not cvrPitCrewRoadsideElectricityService then
            cvrPitCrewRoadsideElectricityService = true
            if beginCVRPitCrewRoadsideService then
                beginCVRPitCrewRoadsideService()
            end
        end
        isRepairingBelt = true
        acCarPhysics.gas = 0
        acCarPhysics.brake = 1
        acCarPhysics.handbrake = 1
        ac.setEngineRPM(0)
        acCarPhysics.controllerInputs[52] = 1
        beltRepairTimer = (beltRepairTimer or 0) + dt

        local pct = math.floor((beltRepairTimer / alternatorRepairTime) * 100)
        local beltName = sharedBeltNeedsService and "fan/charging belt" or "charging belt"
        msgQueue("ELECTRICITY",
            "Fitting a new " .. beltName .. ": " .. string.format("%d%%", pct) .. " done", 1, true)

        if beltRepairTimer >= alternatorRepairTime then
            alternatorOK = true
            if repairAirCoolingSharedBelt then
                repairAirCoolingSharedBelt()
            end
            -- Not sure if this should really be here; but sounds reasonable that
            -- the driver would attempt some alternator repair while changing the belt
            alternatorHealth = math.min((alternatorHealth or 0) + 0.5, 1.0)
            beltRepairTimer = 0
            isRepairingBelt = false
            acCarPhysics.controllerInputs[52] = 0
            alternatorRepairTime = math.random(100, 200)
            if cvrPitCrewRoadsideElectricityService then
                cvrPitCrewRoadsideElectricityService = false
                if completeCVRPitCrewRoadsideRepairService then
                    completeCVRPitCrewRoadsideRepairService(CVR_ROADSIDE_REPAIR_ELECTRICITY)
                end
            end
        end

    elseif isRepairingBelt and (acCarPhysics.speedKmh or 0) > 2 then
        isRepairingBelt = false
        acCarPhysics.controllerInputs[52] = 0
        beltRepairTimer = 0
        if cvrPitCrewRoadsideElectricityService then
            cvrPitCrewRoadsideElectricityService = false
            if cancelCVRPitCrewRoadsideService then
                cancelCVRPitCrewRoadsideService()
            end
        end
    end
end
