--[[Historic feature script for interwar cars by 
-kapasaki
-DimitriHarkov
-SLIGHTLYMADESTUDIOS / Tunari
-Garamond247

add gobs of simulation value to your historics

Failure Probability (2h Race and 24h race)
6666.7 ~41.74%
10000 ~30.12%
15000 ~21.34%
20000 ~16.52%
30000 ~11.29%
50000 ~6.94%
60000 ~5.8%
70000 ~5.0%
80000 ~4.4%
90000 ~3.9%
100000 ~3.5%
150000 ~2.37% - 25.1%
200000 ~1.79%
300000 ~1.19%
400000 ~0.90%
500000 ~0.72% - 8.5%
750000 ~0.48%
1000000 ~0.36% - 4.2%

10,000 + 39,000 = 36.39%
50,000 + 42,000 = 14.61%
]]

local VERSION = "2.6.1"

local acCarPhysics = ac.accessCarPhysics() --extension physics shortcut

if acCarPhysics.inputMethod == ac.InputMethod.AI then
    --absolutely do not execute any of this on an AI car, who knows how badly it fucks up.
    --you can maybe make a "lite" version of this that only runs the sparkplug routine, but aside from that, all of this is way too advance for AI to understand
    return
end

--READ ONLY

thisCar = ac.getCar()

require "car_parameters"
require "supercharger"
require "failure_rate_handling"
require "electricity"
require "script_psg"

-- Uncomment line below to enable the switch throttle model. Make sure to also get copy the script_switch_throttle_model.lua file and paste its content into this file.
--local switch_throttle_model = require("script_switch_throttle_model")

-- Enable/disable debug prints and test code.
-- *** Must always be false in release packages! ***
local DEBUG = false
local DEBUG_LOG_FILE = true  -- Left logging enabled for release 2.0.
local TEST_CODE = false

-- Override can be used to temporarily ignore the DEBUG flag,
-- if you want to print only certain debug data, but not all.
function printDebug(str1, str2, override)
    override = override or false
    if DEBUG or override then
        ac.debug(str1, str2)
    end
end

local tyrePunctureRates = {}

local function initTyrePunctureRates()
    for i = 0, 3 do
        tyrePunctureRates[i] = 0.0
    end
end

initTyrePunctureRates()

-- Log debug messages to the csp log file. Append 'true' as the last argument
-- to force logging regardless of the DEBUG_LOG_FILE flag.
-- For example: logDebug("This will always be logged!", true)
--              logDebug("This will be logged only if DEBUG_LOG_FILE is true.")
function logDebug(...)
    local argCount = select('#', ...)
    local lastArg = select(argCount, ...)
    local isLastArgBooleanAndTrue = argCount > 0 and type(lastArg) == "boolean" and lastArg == true

    if DEBUG_LOG_FILE or isLastArgBooleanAndTrue then
        local args = {...}
        local message = "CVR_LOG " .. os.date("[%H:%M:%S]") .. "\t"
        local limit = isLastArgBooleanAndTrue and (#args - 1) or #args
        for i = 1, limit do
            message = message .. tostring(args[i])
        end
        ac.log(message)
    end
end

local debugPrevExtraA = false
local debugPrevExtraB = false
local debugPrevExtraC = false
local debugPrevExtraD = false
local debugPrevExtraE = false
local debugPrevExtraF = false
local debugPrevInPits = false
local debugPrevHandbrake = false

local doOnceAtStart = false

initTurboVariables(ac, printDebug, logDebug)

local superchargerExists = 0
if getTurboCount() > 0 then
    superchargerExists = 1
end

local turboFailureTimer = 0
local currentEngineHeatGainMult = engineHeatGainMult
local prevFailedTurboCount = 0
local turboSmokeDuration = 25
local turboSmokeTimer = turboSmokeDuration

local deadGears = {} --dead gears, boolean array

-- Initialize deadGears array - index 1 for 1st gear, etc.
local function initDeadGears()
    for i = 1, thisCar.gearCount do
        deadGears[i] = false
    end
end

initDeadGears()

local function initTyrePunctureTables()
    for i = 0, 3 do
        tyrePunctureDeflateFactor[i] = 0.0
        tyrePuncturePressureFactor[i] = 0.0
    end
end

initTyrePunctureTables()

local tyreWear = {}
local prevTyreWear = {}

local function initTyreWearTable()
    for i = 0, 3 do
        tyreWear[i] = 0.0
        prevTyreWear[i] = 0.0
    end
end

initTyreWearTable()

local roadsideTyreChange = 0

local carHasTeleportedToPits = false

-- Teleport to pits callback. Will be called when the car is teleported to pits.
-- When this happens we will prevent starting of the engine, thus ending the race
-- for the car that was teleported to pits.
function teleportToPitsCallback(carIndex)
    printDebug("Car teleported to pits", "Car index: " .. carIndex)
    printDebug("This car index", "Car index: " .. thisCar.index)
    local raceStarted = (ac.getSim().raceSessionType == ac.SessionType.Race and ac.getSim().isSessionStarted)

    if raceStarted and thisCar.isInPit then
        carHasTeleportedToPits = true
    end
end

ac.onCarJumped(thisCar.index, teleportToPitsCallback)

local optimizationTimer = 0 --run a small timer rather than running some of the checks every tick. should save on CPU.
local coolantTemp = 70 --store our own water temp, since the AC one is arbitrary and read-only.
local engineTemp = 70 --engine core temp - once this hits the meltdown value its OVER.
local airAmbientTemp = ac.getSim().ambientTemperature --get the ambient air temp, it will affect the coolant temperature cool factor
local radiatorSetup = 0 -- get this when exiting pits
local prevRadiatorSetup = 0
local turboEnabled = true
local prevextraDState = false
local prevextraEState = false
local prevextraFState = false
local currentSpares = 2 -- get this when exiting pits
local carStoppedTimer = 0 --the timer to check if car is stopped for a tyre replacement
local tyreChangeInProgress = false --is the car changing a tyre
local tyrePressures = {} --store the original tyre pressures here (do it when exiting pits)
local tyrevKMs = {} --store the tyre vKMs here
local sparkPlugFailed = false
local fuelPumpFailed = false
local valveFailed = false
local oilPressureFailed = false
local gearboxDamageValue = thisCar.gearboxDamage
local brakesFailed = false
local hasRadiatorDamage = false
local hasRadiatorMajorDamage = false
local totalMeltdown = false
local waterTempWarning = false
local oilPressureWarning = false
local oilPressureWarning2 = false
local valveWarning = false
local engineLife = thisCar.engineLifeLeft
local tyreStockEmpty = false

local queuedOverheadNotifs = {} --queue'd system messages. contains tables. (structs)
local overheadMessagesEnabled = true --overhead messages enabled through setup menu

local mediumSpeedDtTimer = 0
local tyreBlowCrashingTimer = 0

local prevDamageFront = thisCar.damage[0]
local prevDamageRear = thisCar.damage[1]
local prevDamageLeft = thisCar.damage[2]
local prevDamageRight = thisCar.damage[3]

initFailureHandlingVariables(printDebug, logDebug)

local sparkPlugFailureRate = sparkPlugFailureRateInitialValue
local sparkPlugFailureRateBase = sparkPlugFailureRateInitialValue
local fuelPumpFailureRate = fuelPumpFailureRateInitialValue
local fuelPumpFailureRateBase = fuelPumpFailureRateInitialValue
local valveFailureRate = valveFailureRateInitialValue
local valveFailureRateBase = valveFailureRateInitialValue
local oilPressureFailureRate = oilPressureFailureRateInitialValue
local oilPressureFailureRateBase = oilPressureFailureRateInitialValue

local radiatorCoolCoefficient = radiatorCoolCoefficientInitialValue
local radiatorCoolCoefficientBase = radiatorCoolCoefficientInitialValue

local hasEngineDamage = false

local ENGINE_MAP_RICH = 0
local ENGINE_MAP_NORMAL = 1
local ENGINE_MAP_LEAN = 2
local ENGINE_MAP_PUSH = 3
local EGINE_MAP_DESCRIPTIONS = { "Rich", "Normal", "Lean", "Push" }

local prevEngineMap = -1
local prevLapCount = 0

local failureRateHandlingTimer = 0
local failureRateHandlingInterval = 0.3

local trackSurfaceType = ac.SurfaceExtendedType.Base

local isCarInPits = false

local maxDistanceBetweenTyreStacks = 1000
local tyreStacksPerLap = math.max(math.ceil(ac.getSim().trackLengthM / maxDistanceBetweenTyreStacks) - 1, 2)
local tyreStacksPositions = {}

local normalFuelConsumptionRate = acCarPhysics.fuelConsumption
local fuelLeakageDamage = false

-- Variables for limiting engine damage at gentle crashes on the sides.
local bodyDamageLimitAtCrashEngine = 20
local prevDamageFrontEngine = 0
local prevDamageRearEngine = 0
local prevDamageLeftEngine = 0
local prevDamageRightEngine = 0
local currentEngineLifeLeft = acCarPhysics.engineLifeLeft


local tyreReplacementTime = ac.INIConfig.carData(0, 'car.ini'):get('PIT_STOP', 'TYRE_CHANGE_TIME_SEC', 55)

local function initTyreStacksPositions()
    local trackLength = ac.getSim().trackLengthM
    for i = 0, tyreStacksPerLap - 1 do
        local position = (i * trackLength) / tyreStacksPerLap
        table.insert(tyreStacksPositions, position)
    end

    -- Insert the track length at the end to complete the loop.
    table.insert(tyreStacksPositions, trackLength)

    printDebug("tyreStacksPositions", tyreStacksPositions)
    printDebug("Tyre stack count", tyreStacksPerLap)
end

initTyreStacksPositions()

if TEST_CODE then
    local tyrePunctureTestIndex = -1
end

local function overheadMessageQueue(head, description, displayTime, override)
    --put data into a table since LUA dont got no stucts (GOOD LANGUAGE VITTU!)
    override = override or false

    if override == true and #queuedOverheadNotifs > 0 then
        queuedOverheadNotifs[1].time = 0
    end

    sneed = {
    topText = head,
    bottomText = description,
    time = displayTime,
    }
    table.insert(queuedOverheadNotifs, sneed)
end

local function overheadMessageDisplay(dt)
    if overheadMessagesEnabled then

        if queuedOverheadNotifs[1] ~= nil then
            queuedOverheadNotifs[1]["time"] = queuedOverheadNotifs[1]["time"] - dt
            ac.setSystemMessage(queuedOverheadNotifs[1]["topText"], queuedOverheadNotifs[1]["bottomText"])
            if queuedOverheadNotifs[1]["time"] < 0 then
                table.remove(queuedOverheadNotifs, 1)
            end
        end
    end
end

-- AC uses 1=neutral, 2=1st gear, etc.
local function getCurrentGearIndex()
    return acCarPhysics.gear - 1
end

-- Function to adjust gear failure rate dynamically
local function updateGearFailureRate(gearboxDamageValue)
    -- Ensure gearboxDamage is within valid range (0 to 1)
    gearboxDamageValue = math.clamp(gearboxDamageValue, 0, 1)

    if gearboxDamageValue > 0.5 then
        boostedGearFailureRate = gearFailureRate / 3  -- Increase failure chance
    else
        boostedGearFailureRate = gearFailureRate  -- Reset to base rate
    end
end

local function getRandomStartTime() return math.random(1, 5) end
local function getFluctuatingRPM() return math.random(300, 700) end

local timeToStart = getRandomStartTime()

local carState = { ignition = false, cranking = false, crankTimer = 0, stalling = false, stallRPM = 0 }
local carInfo = {
    idleRPM = ac.INIConfig.carData(0, 'engine.ini'):get('ENGINE_DATA', 'MINIMUM', engineIdleRpm),
    starterRPM = engineIdleRpm + 700
}

ac.setEngineStalling(true)
local starterTorque = 40.0
ac.setEngineStarterTorque(0)

local function applyLag(current, target, factor, dt)
    return current + (target - current) * factor * dt
end

local function lerp(a, b, t) return a + (b - a) * t end

local function getWearMultiplier(rpmFactor)
    for i = 1, #wearLUT - 1 do
        if rpmFactor >= wearLUT[i][1] and rpmFactor <= wearLUT[i+1][1] then
            local t = (rpmFactor - wearLUT[i][1]) / (wearLUT[i+1][1] - wearLUT[i][1])
            return lerp(wearLUT[i][2], wearLUT[i+1][2], t)
        end
    end
    return wearLUT[#wearLUT][2]
end

local teleportPrevExtraA = false

local function engineStaller(dt)
    -- engine stalling / ignition functions
    local inputs = { ignition = car.extraA, clutch = acCarPhysics.clutch }
    local fixingOngoing = fuelPumpRepairInProgress or gearboxRepairInProgress

    if car.extraA and carHasTeleportedToPits then
        if car.extraA and not teleportPrevExtraA then
            overheadMessageQueue("START DISABLED", "You have teleported to the pits, race restart is not allowed", 3)
        end
        inputs.ignition = false
    end
    teleportPrevExtraA = car.extraA

    -- Cranking Logic
    if inputs.ignition and not carState.ignition and not fixingOngoing then
        carState.cranking = true
        carState.crankTimer = carState.crankTimer + dt
        ac.setEngineStarterTorque(starterTorque)

        -- push start simulation: add ~10-12 secs to timeToStart - also add hand crank penalty if not in the pits or on the grid
        -- Electro starter or on grid/in pits: as it was. Crank start elsewhere: a little bit longer. Push start for stalled hybrids out in the wild: much longer.
        
        local pushStartTimer = 0
        local onGrid = (ac.getSim().raceSessionType == ac.SessionType.Race and not ac.getSim().isSessionStarted)
        if not onGrid and not (thisCar.isInPitlane and thisCar.isInPit) then    -- fast starts if on grid and in pits - will have human or mechanical help there
            if ignitionType == 3 then       -- push start for stalled hybrids with flat battery
                if (acCarPhysics.controllerInputs[44] or 1) <= 0.05 then
                    pushStartTimer = math.random(8,12)
                    overheadMessageQueue("PUSH STARTING", "...because the battery is empty. This may take a good while longer.", 1, true)
                end
            end
            if (ignitionType or 1) < 2 then       -- crank start for stalled magneto or undefined types
                    pushStartTimer = math.random(4,6)
                    overheadMessageQueue("CRANK STARTING", "This may take a bit longer.", 1, true)
            end
        end


        if carState.crankTimer < (timeToStart + pushStartTimer) then
            -- Simulate fluctuating RPM between 400 and 600
            ac.setEngineRPM(getFluctuatingRPM())
        else
            -- Set RPM to starterRPM when timeToStart is reached
            ac.setEngineRPM(carInfo.starterRPM)
            carState.ignition = true
            carState.cranking = false
            ac.setEngineStarterTorque(0)
        end
    else
        carState.cranking = false
        carState.crankTimer = 0
    end

    printDebug("Ignition Time", timeToStart)

    -- Running and Stalling Logic
    if carState.ignition then
        if acCarPhysics.rpm < carInfo.idleRPM * 0.9 then -- Adjusted threshold to avoid premature stalling
            carState.ignition = false
            carState.stalling = true
            carState.stallRPM = acCarPhysics.rpm
        else
            -- Stabilize idle RPM
            acCarPhysics.rpm = math.max(acCarPhysics.rpm, carInfo.idleRPM)
        end
    elseif carState.stalling then
        carState.stallRPM = applyLag(carState.stallRPM, 0, 2.0, dt)
        ac.setEngineRPM(carState.stallRPM)
        if carState.stallRPM < 10 then
            carState.stalling = false
            timeToStart = getRandomStartTime()
        end
    else
        if not carState.cranking then ac.setEngineRPM(0) end
    end

    acCarPhysics.controllerInputs[5] = carInfo.idleRPM
    acCarPhysics.controllerInputs[6] = acCarPhysics.rpm

-- engine stalling / ignition functions end
end

local function brakeWear(dt)
    -- BRAKE WEAR STUFF START
    local totalWear = 0
    local brakeInput = acCarPhysics.brake

    -- Calculate wear for each wheel
    for i = 0, 3 do
        local wheel = acCarPhysics.wheels[i]

        -- Convert angular velocity (rad/s) to RPM
        local wheelRPM = math.abs(wheel.angularSpeed) * 60 / (2 * math.pi)
        local rpmFactor = wheelRPM / maxBrakeRPM

        -- Calculate effective brake torque (simplified model)
        local brakeTorque = brakeInput * maxBrakeTorque

        local wearMult = getWearMultiplier(rpmFactor)

        -- Combine factors for wear calculation
        local wheelWear = wearMult * brakeInput * brakeTorque * baseWearRate
        totalWear = totalWear + wheelWear * dt
    end

    brakeWearLevel = math.min(brakeWearLevel + totalWear, 1000)

    -- Calculate brake fade with smooth interpolation
    local brakeFade = 0.0
    if brakeWearLevel > brakeFadeStart then
        local fadeT = (brakeWearLevel - brakeFadeStart) / (1000 - brakeFadeStart)
        brakeFade = fadeT * maxBrakeFade
    end

    -- Apply fade to brakes while preserving ABS functionality
    acCarPhysics.brake = acCarPhysics.brake * (1 - brakeFade)

    -- Debug output
    printDebug("Brake Wear", string.format("Total: %.1f/%d | Fade: %.1f%%", brakeWearLevel, brakeFadeStart, brakeFade * 100))
    printDebug("Brake Wear Factors", string.format("Rate: %.2f/s | Input: %.2f", totalWear/dt, brakeInput))
    acCarPhysics.controllerInputs[11] = brakeFade
    -- BRAKE WEAR STUFF END
end

--spark plug failure
--simply, if you roll unlucky, you get slapped with random engine damage between certain values.
--if you already have more damage, its skipped.
local function sparkPlugFailure()
    if sparkPlugFailed == false then
        if math.random(1, sparkPlugFailureRate) == 1 then
            sparkPlugFailed = true
            if acCarPhysics.engineLifeLeft > sparkPlugFailureDamage then
                ac.setEngineLifeLeft(sparkPlugFailureDamage)
                -- recalculate spark plug failure amount
                --math.randomseed(os.time() + math.random(0, 10000))
                sparkPlugFailureDamage = math.random(200, 600)
                overheadMessageQueue("Spark plug failure", "You may experience engine cut-offs and power loss", 10)
                -- audioQueue("sparkplugFailure")
                logDebug("<FLR>Spark Plug Fail, rate: ", sparkPlugFailureRate, true)
            end
        end
    end
    printDebug("Spark Plug Failure", string.format("Status: %s | Amount: %.2f", tostring(sparkPlugFailed), sparkPlugFailureDamage))

end --end of spark plug failure

-- Add with other variables at the top
local fuelPumpFailureCooldown = 0
local fuelPumpFailureDuration = 0
local fuelPumpCutoffActive = false

local function fuelPumpFailureActivation()
    -- Only check for activation if not already failed
    if not fuelPumpFailed then
        -- Roll for failure (every 2 seconds)
        if math.random(1, fuelPumpFailureRate) == 1 then
            fuelPumpFailed = true
            fuelPumpFailureDuration = math.random(1, 3)
            fuelPumpFailureCooldown = math.random(4, 7)
            overheadMessageQueue("Fuel Pump Failure", "Fuel flow disrupted!", 5)
            printDebug("Fuel Pump", "Failure activated!")
            logDebug("<FLR>Fuel Pump Fail, rate: ", fuelPumpFailureRate, true)
        end
    end
end

local function fuelPumpFailure(dt)
    -- Only process if failed state is active
    if not fuelPumpFailed then return end

    -- Failure behavior system (runs every tick)
    if fuelPumpCutoffActive then
        -- Active cutoff phase
        fuelPumpFailureDuration = fuelPumpFailureDuration - dt
        acCarPhysics.gas = 0  -- Hard throttle cutoff
        if fuelPumpFailureDuration <= 0 then
            fuelPumpCutoffActive = false
        end
    else
        -- Cooldown phase
        fuelPumpFailureCooldown = fuelPumpFailureCooldown - dt

        if fuelPumpFailureCooldown <= 0 then
            fuelPumpCutoffActive = true
            fuelPumpFailureDuration = math.random(1, 3)
            fuelPumpFailureCooldown = math.random(4, 7)
        end
    end

    -- Optional debug
    printDebug("Fuel Pump Behavior", string.format(
        "Cutoff: %s | Duration: %.1f | Cooldown: %.1f",
        tostring(fuelPumpCutoffActive),
        fuelPumpFailureDuration,
        fuelPumpFailureCooldown
    ))
end --end of fuel pump failure

--valve failure
--simply, if you roll unlucky, you get slapped with random engine damage between certain values.
--if you already have more damage, its skipped.
-- Valve Failure Parameters
valveFailureMinDamage = engineLife
-- Initialize
valveFailureDamage = valveFailureMinDamage

local function valveFailure(dt)
    if not valveFailed then
        if math.random(1, valveFailureRate) == 1 then
            valveFailureActive = true
            valveFailed = true
            overheadMessageQueue("Valve problems", "Early stage valve issues detected", 5)
            logDebug("<FLR>Valve Fail, rate: ", valveFailureRate, true)
        end
        return
    end

    if valveFailureActive then
        -- RPM-based progression control
        if acCarPhysics.rpm > 0 and not totalMeltdown then
            valveFailureMinDamage = acCarPhysics.engineLifeLeft
            -- Calculate RPM factor (0-2.0 range)
            local rpmFactor = math.clamp(acCarPhysics.rpm / valveReferenceRPM, 0.1, 2.0)

            -- Effective time accumulation
            valveFailureElapsed = valveFailureElapsed + (dt * rpmFactor)

            -- Calculate progression (0-1)
            local progression = math.clamp(valveFailureElapsed / valveFailureBaseTime, 0, 1)

            -- Non-linear damage curve
            local damageProgression = progression^1.3  -- Faster initial degradation
            valveFailureDamage = math.lerp(valveFailureMinDamage, valveFailureMaxDamage, damageProgression)

            -- Apply damage if engine still has life
            if acCarPhysics.engineLifeLeft > valveFailureDamage then
                ac.setEngineLifeLeft(valveFailureDamage)
            end

            -- Progressive warnings
            if progression > 0.8 and not valveWarning then
                overheadMessageQueue("CRITICAL VALVE FAILURE", "Immediate pit stop required!", 10)
                valveWarning = true
            elseif progression > 0.5 then
                overheadMessageQueue("Severe valve damage", "Power loss increasing significantly", 5)
            end

            -- Final failure state
            if progression >= 1.0 then
                valveFailureActive = false
                ac.setEngineLifeLeft(valveFailureMaxDamage)
                overheadMessageQueue("Total Valve Failure", "Engine no longer operational", 0)
            end
        else
            -- Pause progression when engine is off/stalled
            overheadMessageQueue("Valve Damage Halted", "Engine shutdown paused deterioration", 2)
        end
    end

end --end of valve failure

--oil pressure failure
--simply, if you roll unlucky, you get slapped with random engine damage between certain values.
--if you already have more damage, its skipped.
--oil pressure failure parameters
oilPressureMinDamage = engineLife
-- Initialize
oilPressureFailureDamage = oilPressureFailureMinDamage

local function oilPressureFailure(dt)
    if not oilPressureFailed then
        if math.random(1, oilPressureFailureRate) == 1 then
            oilPressureFailureActive = true
            oilPressureFailed = true
            overheadMessageQueue("Oil pressure problems", "Early stage oil pressure issues detected", 5)
            logDebug("<FLR>Oil Pressure Fail, rate: ", oilPressureFailureRate, true)
        end
        return
    end

    if oilPressureFailureActive then
        -- RPM-based progression control
        if acCarPhysics.rpm > 0 and not totalMeltdown then
            oilPressureFailureMinDamage = acCarPhysics.engineLifeLeft
            -- Calculate RPM factor (0-2.0 range)
            local oilPressurerpmFactor = math.clamp(acCarPhysics.rpm / oilPressureReferenceRPM, 0.1, 2.0)

            -- Effective time accumulation
            oilPressureFailureElapsed = oilPressureFailureElapsed + (dt * oilPressurerpmFactor)

            -- Calculate progression (0-1)
            local oilPressureProgression = math.clamp(oilPressureFailureElapsed / oilPressureFailureBaseTime, 0, 1)

            -- Non-linear damage curve
            local oilPressureDamageProgression = oilPressureProgression^1.3  -- Faster initial degradation
            oilPressureFailureDamage = math.lerp(oilPressureFailureMinDamage, oilPressureFailureMaxDamage, oilPressureDamageProgression)

            -- Apply damage if engine still has life
            if acCarPhysics.engineLifeLeft > oilPressureFailureDamage then
                ac.setEngineLifeLeft(oilPressureFailureDamage)
            end

            -- Progressive warnings
            if oilPressureProgression > 0.8 and not oilPressureWarning then
                overheadMessageQueue("CRITICAL OIL PRESSURE", "Immediate pit stop required!", 10)
                oilPressureWarning = true
            elseif oilPressureProgression > 0.5 and not oilPressureWarning2 then
                overheadMessageQueue("Really low oil pressure", "Power loss and engine overheating increasing significantly", 5)
                oilPressureWarning2 = true
            end

            -- Final failure state
            if oilPressureProgression >= 1.0 then
                oilPressureFailureActive = false
                ac.setEngineLifeLeft(oilPressureFailureMaxDamage)
                overheadMessageQueue("Total oil pressure issue", "Engine no longer operational", 0)
            end
        else
            -- Pause progression when engine is off/stalled
            overheadMessageQueue("Engine stalled", "Cooling down", 2)
        end
    end

end --end of oil pressure failure

local function gearboxFailure()
    local currentGearIndex = getCurrentGearIndex()
    if currentGearIndex > 0 and math.random(1, boostedGearFailureRate) == 1 then
        deadGears[currentGearIndex] = true  -- Mark gear as dead
        overheadMessageQueue("GEAR FAILURE", "Gear "..(currentGearIndex).." has failed!", 5)
        logDebug("<FLR>Gear Fail, gear: ", currentGearIndex, ", rate: ", boostedGearFailureRate, true)
    end
end

local function isAnyGearBroken()
    for i = 1, thisCar.gearCount do
        if deadGears[i] then
            return true
        end
    end
    return false
end

local function debugTyrevKMs()
    for i = 0, 3 do
        printDebug("tyrevKM_" .. i, tyrevKMs[i])
    end
end

local function getWheelName(tyreIndex)
    wheelNames = {"Front left", "Front right", "Rear left", "Rear right"}
    return wheelNames[tyreIndex + 1]
end

local function generateSlowPuncture(tyreIndex, minFactor, maxFactor)
    -- Generate a factor to use deflating the tyre, defining the speed of deflation.
    -- This value will be subtracted from the pressure factor 10 times a second.
    tyrePunctureDeflateFactor[tyreIndex] = 1 / math.random(minFactor, maxFactor)
    -- Set the tyre pressure factor to start the deflation from. See ac.setTyreInflation() comment in slowTyrePuncture().
    tyrePuncturePressureFactor[tyreIndex] = 1.0
    overheadMessageQueue("Tyre puncture", getWheelName(tyreIndex) .. " tyre is leaking!", 3)
    printDebug(string.format("Puncture factor, tyre: %d", tyreIndex), string.format("%f", tyrePunctureDeflateFactor[tyreIndex]))
    logDebug("<FLR>Tyre Puncture, tyre: ", tyreIndex, " Deflate factor: ", tyrePunctureDeflateFactor[tyreIndex], true)
end

local function getTyreTypeFactor()
    local tyreTypeFactors = {
        {"SH", 1.2},
        {"HS", 4},
        {"LS", 4},
        {"HSI", 1},
        {"FS", 4}
    }
    local tyreName = ac.getTyresName(thisCar.index)
    printDebug("tyreName", tyreName)
    local tyreTypeFactor = 1
    for i = 1, #tyreTypeFactors do
        if tyreName == tyreTypeFactors[i][1] then
            tyreTypeFactor = tyreTypeFactors[i][2]
            break
        end
    end

    return tyreTypeFactor
end

--tyre blow function. rest of tyre stuff in other functions
local function tyreBlow()
    local checkTyreBlow = not isCarInPits and thisCar.speedKmh > 1
    local tyreTypeFactor = getTyreTypeFactor()
    printDebug("tyreTypeFactor", tyreTypeFactor)

    for i = 0, 3 do
        -- Car must be out of the pits and not in the grid, moving and tyre must not be already punctured.
        if checkTyreBlow and tyrePunctureDeflateFactor[i] == 0.0 then
            local rateToUse = 0

            if thisCar.wheels[i].surfaceExtendedType == ac.SurfaceExtendedType.Gravel then
                rateToUse = tyrePunctureRateGravel
                ac.setTyreWearMultiplier(i, tyreWearGravel)
                trackSurfaceType = ac.SurfaceExtendedType.Gravel
            elseif thisCar.wheels[i].surfaceExtendedType == ac.SurfaceExtendedType.Ice or
                   thisCar.wheels[i].surfaceExtendedType == ac.SurfaceExtendedType.Snow then
                rateToUse = tyrePunctureRateIce
                ac.setTyreWearMultiplier(i, tyreWearIce)
                trackSurfaceType = ac.SurfaceExtendedType.Ice
            else
                rateToUse = tyrePunctureRateAsphalt
                ac.setTyreWearMultiplier(i, tyreWearAsphalt)
                trackSurfaceType = ac.SurfaceExtendedType.Base
            end

            -- Modify rateFactor so that more worn tyres are more likely to puncture. The tyreWear table
            -- contains the accumulated wear since the start of the session, 0 meaning brand new tyres and
            -- 1 meaning fully worn tyres.
            local tyreWearFactor = 1.0 - math.min(tyreWear[i] * tyreTypeFactor, 0.999)
            rateToUse = math.floor(rateToUse * tyreWearFactor + 0.5)
            printDebug(string.format("Puncture rate, tyre: %d", i), string.format("%d", rateToUse))
            if DEBUG_LOG_FILE then
                tyrePunctureRates[i] = rateToUse
            end

            local tyrePunctureTesting = false
            if TEST_CODE and tyrePunctureTestIndex == i then
                tyrePunctureTesting = true
            end
            if math.random(1, rateToUse) == 1 or tyrePunctureTesting then
                generateSlowPuncture(i, minPunctureDeflateFactor, maxPunctureDeflateFactor)
            end
        end

        --check tyre pressure for each wheel and set to blow if it's too high
        if thisCar.wheels[i].tyrePressure > tyreBlowPressure and thisCar.wheels[i].isBlown == false and tyrePunctureDeflateFactor[i] == 0.0 then
            -- In this case, make sure the tyre always deflates quickly.
            generateSlowPuncture(i, minPunctureDeflateFactor, minPunctureDeflateFactor)

            if currentSpares > 0 then
                overheadMessageQueue("Spares available", "You have " .. currentSpares .. " spares left, pull over to the side when safe.", 2)
            else
                overheadMessageQueue("No spares", "You have no spares left, just get to the pits safely!", 2)
            end
        end
        --check tyrevKM and blow it if its past its life
        if thisCar.wheels[i].tyreVirtualKM > tyrevKMs[i] and thisCar.wheels[i].isBlown == false and tyrePunctureDeflateFactor[i] == 0.0 then
            generateSlowPuncture(i, minPunctureDeflateFactor, maxPunctureDeflateFactor)

            if currentSpares > 0 then
                overheadMessageQueue("Spares available", "You have " .. currentSpares .. " spares left, pull over to the side when safe.", 2)
            else
                overheadMessageQueue("No spares", "You have no spares left, just get to the pits safely!", 2)
            end
        end
    end
end--end of tyre blow function

-- Slow tyre puncture: deflate the tyre over time.
local function slowTyrePuncture()
    for i = 0, 3 do
        -- If the tyre is punctured, we need to deflate it.
        if tyrePunctureDeflateFactor[i] > 0.0 then
            -- Calculate new (deflated) pressure factor and set it to the tyre.
            tyrePuncturePressureFactor[i] = tyrePuncturePressureFactor[i] - tyrePunctureDeflateFactor[i]
            -- Limit the pressure factor to 0, to blow the tyre.
            if tyrePuncturePressureFactor[i] < 0 then
                tyrePuncturePressureFactor[i] = 0
            end
            -- Set the deflated tyre pressure. setTyreInflation() takes a "percentage" as a parameter,
            -- from 0 to 1. 1 sets the full original pressure, and e.g. 0,5 sets half of that. For
            -- example, if the original pressure value was 50 psi, setting 0,5 here would set the pressure
            -- to 25 psi. When the factor reaches zero, the tyre will be blown.
            ac.setTyreInflation(i, tyrePuncturePressureFactor[i])

            printDebug(string.format("Set tyre: %d", i), string.format("deflated pressure: %f", tyrePuncturePressureFactor[i]))
        end
    end
end

local function isAnyTyrePunctured()
    for i = 0, 3 do
        if tyrePunctureDeflateFactor[i] > 0.0 then
            return true
        end
    end
    return false
end

local function updateTyreWear()
    for i = 0, 3 do
        if thisCar.wheels[i].tyreWear > prevTyreWear[i] then
            local wearDiff = thisCar.wheels[i].tyreWear - prevTyreWear[i]
            tyreWear[i] = tyreWear[i] + wearDiff
            prevTyreWear[i] = thisCar.wheels[i].tyreWear
            printDebug(string.format("tyreWear " .. i), tyreWear[i])
        end
    end
end

--helper function for generating a fresh tyre.
local function generateTyrevKM()
    local randomFactor = math.random() -- Uniform random value between 0 and 1
    -- Apply weighting toward the upper end of the range
    local weightedLife = tyreBasevKM + (tyrevKMvariance * (randomFactor ^ biasStrength))
    return weightedLife
end

local function blowTyreAtCrash(damageDiff, sideDamage1, sideDamage2, tyre1, tyre2)
    local tyreToBlow = 0
    local rate = tyreBlowCrashingRate

    -- In a really hard crash, just blow both tyres.
    if damageDiff > tyreBlowDamageChangeMax then
        ac.setTyreInflation(tyre1, 0)
        ac.setTyreInflation(tyre2, 0)
        return
    end

    -- Check if there is enough change in damage to blow a tyre.
    if damageDiff > tyreBlowDamageChange then
        -- Is the damage hard enough to blow the tyre using 100% probability?
        if damageDiff > tyreBlowDamageChangeHard then
            rate = 1
        end

        -- Blow the tyre from that side, which has more damage.
        -- For example, if this is a front crash, then choose left or right.
        if sideDamage1 > sideDamage2 then
            tyreToBlow = tyre1
        else
            tyreToBlow = tyre2
        end

        if math.random(1, rate) == 1 then
            ac.setTyreInflation(tyreToBlow, 0)
        end
    end
end

-- Blow a tyre when the car is crashed into something. Check the change in
-- car damage, and when it exceeds the predefined value, then blow a tyre.
local function tyreBlowWhenCrashing()
    printDebug("-Front dmg", thisCar.damage[0])
    printDebug("-Rear dmg", thisCar.damage[1])
    printDebug("-Left dmg", thisCar.damage[2])
    printDebug("-Right dmg", thisCar.damage[3])

    -- Front crash.
    blowTyreAtCrash(thisCar.damage[0] - prevDamageFront, thisCar.damage[2], thisCar.damage[3], 0, 1)
    -- Rear crash.
    blowTyreAtCrash(thisCar.damage[1] - prevDamageRear, thisCar.damage[2], thisCar.damage[3], 2, 3)
    -- Left crash.
    blowTyreAtCrash(thisCar.damage[2] - prevDamageLeft, thisCar.damage[0], thisCar.damage[1], 0, 2)
    -- Right crash.
    blowTyreAtCrash(thisCar.damage[3] - prevDamageRight, thisCar.damage[0], thisCar.damage[1], 1, 3)

    prevDamageFront = thisCar.damage[0]
    prevDamageRear = thisCar.damage[1]
    prevDamageLeft = thisCar.damage[2]
    prevDamageRight = thisCar.damage[3]
end

--coolant behavior/engine damage handling
local function coolantBehavior(dt)
    carDamageClamp = math.clampN((thisCar.damage[0] + thisCar.damage[2] + thisCar.damage[3]) / 3 * 0.01, 0, 1)
    --clamp the actual bumper damage as ac can make it over 100%
    if thisCar.damage[0] > 30 or thisCar.damage[2] > 35 or thisCar.damage[3] > 35 then
        if hasRadiatorDamage == false then
            hasRadiatorDamage = true
            overheadMessageQueue("Cooling damage", "Engine cooling is slightly damaged. Watch for engine temps.", 2)
        end
    end

    --if damage is over 50% you lose some of the brake power
    if thisCar.damage[0] > 50 or thisCar.damage[2] > 50 or thisCar.damage[3] > 50 then
        if brakesFailed == false then
            brakesFailed = true
            overheadMessageQueue("Brake problem", "Front damage caused brakes to lose power. Take it careful!", 3)
        end
    end
    if brakesFailed == true then
        if randomBrakeLimit == nil then
            randomBrakeLimit = 0.4 + math.random() * (0.9 - 0.4)
        end
        if acCarPhysics.brake > randomBrakeLimit then
            acCarPhysics.brake = randomBrakeLimit
        end
    end


    if thisCar.damage[0] > 75 or thisCar.damage[2] > 75 or thisCar.damage[3] > 75  then
        if hasRadiatorMajorDamage == false then
            hasRadiatorMajorDamage = true
        if acCarPhysics.engineLifeLeft > 500 then
            acCarPhysics.engineLifeLeft = 500
        end
        overheadMessageQueue("Major radiator damage", "Engine cooling has major damage. Watch for engine temps.", 2)
        end
    end

    if engineTemp > engineOverboilTemp and totalMeltdown == false then
        totalMeltdown = true
        overheadMessageQueue("Engine meltdown", "Your racing prospects are over!", 5)
        acCarPhysics.engineLifeLeft = 0
    end

    if coolantTemp > engineOverboilTemp - 5 and not waterTempWarning then
        overheadMessageQueue("Coolant temperature", "Water temperature is nearing boiling point. Hold off the throttle.", 3)
        waterTempWarning = true
    end

    if engineTemp > engineOverboilTemp - 5 then
        if acCarPhysics.gas > 0.8 then
            acCarPhysics.gas = 0.8
        end
    end

    --all the radiator/engine thermals are handled here

    engineAmbientFactor = math.clamp(math.log(engineTemp - airAmbientTemp) * engineTemp^0.01 * engineCoolAmbientFalloff, 0, 1)
    radiatorAmbientFactor = math.clamp(math.log(coolantTemp - airAmbientTemp) * coolantTemp^0.01 *engineCoolAmbientFalloff, 0, 1)

    engineHeatingFactor = (1 - engineGainThrottleCoefficient^(-5 * (acCarPhysics.rpm * 0.0001))) * currentEngineHeatGainMult * acCarPhysics.gas

    if oilPressureFailureActive == true then
        engineHeatingFactor = engineHeatingFactor * 1.25
    end

    engineCoolingFactor = (engineBaseCoolCoefficient + engineSpeedCoolCoefficient * acCarPhysics.speedKmh^2) * engineAmbientFactor
    engineTemp = engineTemp + ((engineHeatingFactor - engineCoolingFactor) * dt)

    radiatorCoolingFactor = (math.clamp(radiatorCoolCoefficient - (radiatorDamageCoefficientLoss * carDamageClamp), 0, 1) + radiatorSpeedCoolCoefficient * acCarPhysics.speedKmh^2) * radiatorAmbientFactor
    coolantTemp = coolantTemp - (radiatorCoolingFactor * dt)

    --temperatureAvg = ((engineTemp * engineCoolantTransferGain) + (coolantTemp * (1 - engineCoolantTransferGain))) * 0.5
    temperatureDifferential = (engineTemp - coolantTemp) * dt

    engineTemp = engineTemp - (temperatureDifferential * engineCoolantTransferGain)
    coolantTemp = coolantTemp + (temperatureDifferential * engineCoolantTransferGain)

    --give weighted transfer gains another try once i get back home
    --engineTemp = engineTemp - (temperatureDifferential * engineCoolantTransferGain)
    --coolantTemp = coolantTemp + (temperatureDifferential * (1 - engineCoolantTransferGain))

    --coolantTemp = math.lerp(coolantTemp, temperatureAvg, 0.5)
    --engineTemp = math.lerp(engineTemp, temperatureAvg, 0.5)

    --prevent temps go under 70 if idle or waiting for race start
    coolantTemp = math.max(coolantTemp, 70)
    engineTemp = math.max(engineTemp, 70)

    acCarPhysics.controllerInputs[0] = coolantTemp
    acCarPhysics.controllerInputs[1] = engineTemp
    --these dynamic controllers can be read by analog or digital instruments with INPUT = CPHYS_SCRIPT_X

end--end of coolant behavior function

local function getBrakeDuctWingGain(brakeDuctPercentage)
    local steps = {
        {duct = 0, wingGain = 1.00000},
        {duct = 30, wingGain = 0.99200},
        {duct = 60, wingGain = 0.98400},
        {duct = 90, wingGain = 0.97600},
    }

    -- Find the step with the brakeDuctPercentage value. Default to the first step if not found.
    local s = steps[1]
    for _, step in ipairs(steps) do
        if step.duct == brakeDuctPercentage then
            s = step
            break
        end
    end

    return s.wingGain
end

--radiator setup
local function applyRadiatorSetup(setup)
    local flapPosition = {
        "Shutters fully open",
        "Shutters one quarter closed",
        "Shutters half closed",
        "Shutters three quarters closed",
        "Shutters almost closed"
    }

    -- Get brake duct settings from setup and combine their effects with the radiator setup.
    local brakeDuctPercentageFront = ac.getScriptSetupValue("BRAKE_DUCT_F")()
    printDebug("BrakeDuct F", brakeDuctPercentageFront)
    local brakeDuctPercentageRear = ac.getScriptSetupValue("BRAKE_DUCT_R")()
    printDebug("BrakeDuct R", brakeDuctPercentageRear)
    local brakeDuctWingGainFront = getBrakeDuctWingGain(brakeDuctPercentageFront)
    printDebug("BrakeDuct Wing Gain F", brakeDuctWingGainFront)
    local brakeDuctWingGainRear = getBrakeDuctWingGain(brakeDuctPercentageRear)
    printDebug("BrakeDuct Wing Gain R", brakeDuctWingGainRear)

    -- map setup steps to wing gain + cooling multiplier
    local steps = {
        {wingIndex = 0, wingGain = 1.00000, coolMul = 1.00},
        {wingIndex = 0, wingGain = 0.98000, coolMul = 0.85},
        {wingIndex = 0, wingGain = 0.96000, coolMul = 0.70},
        {wingIndex = 0, wingGain = 0.94000, coolMul = 0.55},
        {wingIndex = 0, wingGain = 0.92000, coolMul = 0.40},
    }
    local s = steps[setup + 1]
    ac.setWingGain(s.wingIndex, s.wingGain * brakeDuctWingGainFront * brakeDuctWingGainRear, 1)
    printDebug("Combined Wing Gain", s.wingGain * brakeDuctWingGainFront * brakeDuctWingGainRear)
    radiatorCoolCoefficientBase = radiatorCoolCoefficientInitialValue * s.coolMul
    return flapPosition[setup + 1]
end

-- call once so current setup is applied on load
applyRadiatorSetup(radiatorSetup)

--this quick helper func to convert some of the setup params to bool.
local function inputToBool(value)
    maldito = {}
    maldito[0] = false
    maldito[1] = true
    return maldito[value]
end

local function getCurrentSpares()
    local spares = ac.getScriptSetupValue("SPARE_WHEELS")()
    printDebug("Current spares", spares)
        if spares == "Trackside" then
            spares = -1
        end

    return spares
end

--this function gets the setup menu values for the tyre pressures (so that when you restore a wheel, it gives the correct static pressure, in case its not built-in)
--and also the count of spare wheels. the spare wheels get also replaced with a fresh set of spares when you pit.

--get some setup params when leaving pits so that they can be reset to the original state at one point or another
local function setupBits()
    local inGrid = (ac.getSim().raceSessionType == ac.SessionType.Race and not ac.getSim().isSessionStarted)
    --check if cars in pit to reset the values, and also check nil for initialization
    if isCarInPits or inGrid or tyrePressures[0] == nil then
        --get setup tyre pressures, and initialize vKMs
        for i = 0, 3 do
            -- 1.0 means inflated to the pressure defined in the setup.
            tyrePressures[i] = 1.0
            ac.setTyreInflation(i, tyrePressures[i])
            -- Only generate a new lifespan if the tyre is not already initialized
            if not tyrevKMs[i] or tyrevKMs[i] < thisCar.wheels[i].tyreVirtualKM then
                tyrevKMs[i] = generateTyrevKM()
                -- tyrevKMs[i] = thisCar.wheels[i].tyreVirtualKM + generateTyrevKM()
            end
            --debugTyrevKMs() -- Log initialized vKM values
            tyrePunctureDeflateFactor[i] = 0.0

            -- Reset the tyre wear for the replaced tyre(s).
            tyreWear[i] = 0.0
            prevTyreWear[i] = 0.0

            -- Check if brake wear is to be reset when changing tyres.
            if resetBrakeWearAtTyreChange ~= nil then
                if resetBrakeWearAtTyreChange == true and thisCar.wheels[i].tyreVirtualKM < 0.1 then
                    brakeWearLevel = 0.0
                end
            end
        end--end of tyre vKM generation

        -- Get a bunch of stuff that should be reset when you enter pits
        -- but only if engine has been fixed already.
        if acCarPhysics.engineLifeLeft == 1000 then
            sparkPlugFailed = false

            valveFailed = false
            valveFailureActive = false
            valveFailureElapsed = 0
            valveFailureDamage = valveFailureMinDamage

            oilPressureFailed = false
            oilPressureFailureActive = false
            oilPressureFailureElapsed = 0
            oilPressureFailureDamage = oilPressureFailureMinDamage

            -- Cut the failure rate losses to half, if the engine has been fixed,
            -- i.e. if there was engine damage before entering the pits.
            if hasEngineDamage then
                sparkPlugFailureRateBase = sparkPlugFailureRateBase + (sparkPlugFailureRateInitialValue - sparkPlugFailureRateBase) * 0.5
                valveFailureRateBase = valveFailureRateBase + (valveFailureRateInitialValue - valveFailureRateBase) * 0.5
                oilPressureFailureRateBase = oilPressureFailureRateBase + (oilPressureFailureRateInitialValue - oilPressureFailureRateBase) * 0.5
                hasEngineDamage = false
            end
        end

        --[[ for i = 1, thisCar.gearCount do
        --offset the index by 1 due to janky implementation
        deadGears[i + 1] = false
        end ]]

        --get count of spare wheels equipped in the setup
        --and add the additional mass
        --MAKE SURE TO ADD THE LINE INTO THE SETUP.INI!!!
        currentSpares = getCurrentSpares()
        overheadMessagesEnabled = inputToBool(ac.getScriptSetupValue("OVERHEAD_MESSAGES")())
        radiatorSetup = ac.getScriptSetupValue("RADIATOR")()
        applyRadiatorSetup(radiatorSetup)
        tyreChangeInProgress = false

        -- Drop coolant temp down to a more reasonable temp... (irl they throw buckets of water on the rads)
        if coolantTemp > 80 or engineTemp > 80 then
            coolantTemp = 80
            engineTemp = 80
        else
            --once thats been called, reset JEFF the next time around
            totalMeltdown = false
            waterTempWarning = false
        end
        --SETTING CAR EXTRA MASS (SPARE WHEEL) CAN BE DONE IN UPDATE LOOP!!
    end--end of checking if car is in pits insanity

    -- Fix turbo in other sessions, than race.
    if superchargerExists == 1 and isCarInPits and ac.getSim().raceSessionType ~= ac.SessionType.Race then
        initTurboVariables(ac, printDebug)
        acCarPhysics.controllerInputs[25] = 0
        turboSmokeTimer = turboSmokeDuration
        currentEngineHeatGainMult = engineHeatGainMult
        prevFailedTurboCount = 0
    end

    -- Call the radiator dmg warning resets only after radiator has been fixed.
    -- For this we don't need to be in the pits. It fixes a bug where a pit
    -- stop was not correctly detected, therefore faults stayed active, even though
    -- they were fixed during the pit stop.
    if thisCar.damage[0] < 10 and thisCar.damage[2] < 10 and thisCar.damage[3] < 10  then
        hasRadiatorDamage = false
        hasRadiatorMajorDamage = false
        brakesFailed = false
        boxDamaged = false
        randomBrakeLimit = nil
    end
end--end of setupbits function

local function getDistanceToClosestTyreStack()
    local carPositionOnTrack = thisCar.splinePosition * ac.getSim().trackLengthM
    -- Find the distance to the closest tyre stack.
    local closestTyreStackDistance = math.huge
    for i = 1, #tyreStacksPositions do
        local stackPosition = tyreStacksPositions[i]
        local distance = math.abs(stackPosition - carPositionOnTrack)
        if distance < closestTyreStackDistance then
            closestTyreStackDistance = distance
        end
    end

    return closestTyreStackDistance
end

-- Get tyre change time. If we're doing a 30's tyre change, calculate the time based on
-- the distance to the closest tyre stack.
local function getTyreChangeTime()
    if currentSpares >= 0 then
        return tyreReplacementTime
    end

    local jeffRunSpeedMs = 4.0
    local timeToTyreStackAndBack = getDistanceToClosestTyreStack() / jeffRunSpeedMs * 2
    printDebug("Time to tyre stack and back", timeToTyreStackAndBack)

    return tyreReplacementTime + timeToTyreStackAndBack
end

--tyre replacement bits - this function is the whole routine
local function tyreReplacement(dt)
    --dont check if speed is just 0, chances are that ac sometimes breaks and doesnt let you come to a full stop
    if thisCar.speedKmh < 1 and thisCar.handbrake == 1 or tyreChangeInProgress then
        carStoppedTimer = carStoppedTimer + dt

        --starting the tyre replacement routine
        if carStoppedTimer > tyreReplacementReactionTime and tyreChangeInProgress == false then
            --check that there is actually a burst tyre
            blownTyres = false
            for i = 0, 3 do
                if thisCar.wheels[i].isBlown or tyrePunctureDeflateFactor[i] > 0.0 then
                    tyreChangeInProgress = true
                    blownTyres = true
                end
            end
            --check that you have an available spare, if not, cancel routine
            --also reset the timer, no point in checking it every tick if you dont have a spare
            if currentSpares == 0 then
                tyreChangeInProgress = false
                blownTyres = false
                ac.setSystemMessage("You have no spare tyres left", "Drive carefully to the pits")
            end
            if blownTyres == false then
                carStoppedTimer = 0
            end
        end

        --tyre change routine, seize controls
        if tyreChangeInProgress then
            acCarPhysics.gas = 0
            acCarPhysics.brake = 1
            acCarPhysics.handbrake = 1
            local tyreChangeTime = getTyreChangeTime()
            if carStoppedTimer < tyreChangeTime - tyreReplacementTime then
                ac.setSystemMessage("Fetching tyre", "Getting a tyre from the nearest stack...")
                roadsideTyreChange = 1
            else
                ac.setSystemMessage("Changing tyre", "Sit tight...")
                roadsideTyreChange = 2
            end
            --skip the queue for this because its essential info regardless
            --and also breaks the queue by spamming it

            --end the routine once the time has passed
            if carStoppedTimer > getTyreChangeTime() then
                overheadMessageQueue("Tyre change complete", "!VAMOS!", 2)
                tyreChangeInProgress = false
                roadsideTyreChange = 3
                currentSpares = math.max(currentSpares - 1, -1)
                if currentSpares > 0 then
                    overheadMessageQueue("Tyre change complete", "You have " .. currentSpares .. " spares left.", 3)
                end
                if currentSpares == 0 then
                    tyreStockEmpty = true
                else
                    tyreStockEmpty = false
                end
                carStoppedTimer = 0
                for i = 0, 3 do
                    if thisCar.wheels[i].isBlown or tyrePunctureDeflateFactor[i] > 0.0 then
                        ac.setTyreInflation(i, tyrePressures[i])
                        --because current vKM doesnt reset when just reinflating the tyre, add the existing vKM on top.
                        tyrevKMs[i] = thisCar.wheels[i].tyreVirtualKM + generateTyrevKM()
                        tyrePunctureDeflateFactor[i] = 0.0
                        -- Reset the tyre wear for the replaced tyre.
                        tyreWear[i] = 0.0
                        break;
                    end
                end--find the first tyre and repair it
            end--end of repair routine

        end--end of seizing controls
        acCarPhysics.controllerInputs[3] = carStoppedTimer
    end--end of stop-checking

    if thisCar.speedKmh > 30 then
        roadsideTyreChange = 0
    end

    printDebug("Tyre change state", roadsideTyreChange)
end--end of tyre replacement function

local function adjustRatesAccordingToEngineMap()
    local engineMap = thisCar.fuelMap + 1

    -- Calculate the actual failure rates using the base rates, which may have changed by e.g.
    -- overrevving, or other factors. This way the possibly modified base rates are adjusted
    -- according to the engine map factors.
    sparkPlugFailureRate = math.floor(sparkPlugFailureRateBase * sparkPlugEngineMapFactors[engineMap] + 0.5)
    fuelPumpFailureRate = math.floor(fuelPumpFailureRateBase * fuelPumpEngineMapFactors[engineMap] + 0.5)
    valveFailureRate = math.floor(valveFailureRateBase * valveEngineMapFactors[engineMap] + 0.5)
    oilPressureFailureRate = math.floor(oilPressureFailureRateBase * oilPressureEngineMapFactors[engineMap] + 0.5)

    printDebug("Engine map", EGINE_MAP_DESCRIPTIONS[engineMap])

    if DEBUG_LOG_FILE and engineMap ~= prevEngineMap then
        logDebug("Engine map: ", EGINE_MAP_DESCRIPTIONS[engineMap])
        prevEngineMap = engineMap
    end
end

local function fuelTankDamage()
    local cumulativeDamage = 0

    for i = 0, 3 do
        if fuelLeakageDamageSides[i + 1] then
            cumulativeDamage = cumulativeDamage + thisCar.damage[i]
        end
    end

    printDebug("Cumulative damage for fuel leakage", cumulativeDamage)

    if cumulativeDamage > fuelLeakageDamageThreshold then
        local fuelConsumptionRate = normalFuelConsumptionRate + cumulativeDamage / 100

        if fuelConsumptionRate > 1 then
            fuelConsumptionRate = 1
        end

        ac.setFuelConsumption(fuelConsumptionRate)
        printDebug("Fuel consumption rate", fuelConsumptionRate)
        fuelLeakageDamage = true
    else
        ac.setFuelConsumption(normalFuelConsumptionRate)
        printDebug("Fuel consumption rate", normalFuelConsumptionRate)
        fuelLeakageDamage = false
    end
end

local fuelExhState = 0
local fuelExhStartCount = 0
local fuelExhStartCounter = 0
local fuelExhCutLength = 0
local fuelDependentGForceThreshold = 0
local fuelExhInterval = 0
local fuelExhIntervalCounter = 0

local function fuelExhaustion()
    printDebug("Fuel, fuelExhState", fuelExhState)
    -- Adjust the g-force threshold based on the current fuel level. The less fuel we have,
    -- the easier it is to trigger a stall.
    fuelDependentGForceThreshold = fuelExhaustionGForceThreshold * (thisCar.fuel / fuelExhaustionAmount)
    printDebug("Fuel, G-force", fuelDependentGForceThreshold)

    -- Idle state.
    if fuelExhState == 0 then
        if math.abs(acCarPhysics.gForces.x) > fuelDependentGForceThreshold and thisCar.fuel < fuelExhaustionAmount then
            fuelExhStartCount = thisCar.fuel
            fuelExhStartCounter = 0
            fuelExhCutLength = 0
            fuelExhInterval = 0
            fuelExhIntervalCounter = 0
            fuelExhState = 10
        end
    -- Stall detection state. Wait for enough g-force events to trigger a stall. The less we have fuel,
    -- the easier it is to trigger a stall.
    elseif fuelExhState == 10 then
        if math.abs(acCarPhysics.gForces.x) > fuelDependentGForceThreshold then
            fuelExhStartCounter = fuelExhStartCounter + 1
        else
            fuelExhStartCounter = 0
            fuelExhState = 0
        end

        if fuelExhStartCounter >= fuelExhStartCount then
            fuelExhCutLength = math.random() * (fuelExhaustionAmount - thisCar.fuel) / fuelExhaustionAmount / 2
            -- Take the speed of the car into account: under 100 km/h the cut length is minimal, but at higher speeds
            -- the cut length increases quadratically.
            fuelExhCutLength = fuelExhCutLength + (thisCar.speedKmh / 100) ^ 2
            printDebug("Fuel, cut length", fuelExhCutLength)
            fuelExhInterval = math.random() * 2
            fuelExhState = 20
        end
    -- Fuel cut active state.
    elseif fuelExhState == 20 then
        if fuelExhCutLength == 0 then
            if fuelExhIntervalCounter > fuelExhInterval then
                fuelExhState = 0
            else
                fuelExhIntervalCounter = fuelExhIntervalCounter + 0.1
            end
        end
    end
end

local function limitEngineDamageAtCrash()
    -- When the car touches for example a wall just slightly, the engine can take a huge amount of damage,
    -- which is not very realistic. To limit this, we can check the change in damage at front, and if it's
    -- not too big, then we can limit the engine damage.
    local damageDiffFront = thisCar.damage[0] - prevDamageFrontEngine
    local damageDiffRear = thisCar.damage[1] - prevDamageRearEngine
    local damageDiffLeft = thisCar.damage[2] - prevDamageLeftEngine
    local damageDiffRight = thisCar.damage[3] - prevDamageRightEngine
    printDebug("DmgFront", thisCar.damage[0])
    printDebug("DmgRear", thisCar.damage[1])
    printDebug("DmgLeft", thisCar.damage[2])
    printDebug("DmgRight", thisCar.damage[3])

    if damageDiffLeft > 0 or damageDiffRight > 0 then
        if damageDiffFront < bodyDamageLimitAtCrashEngine and damageDiffRear < bodyDamageLimitAtCrashEngine then
            local maxEngineDamage = math.min(currentEngineLifeLeft - acCarPhysics.engineLifeLeft, (damageDiffFront + damageDiffRear) * 10)
            printDebug("damageDiffFront", damageDiffFront)
            printDebug("damageDiffRear", damageDiffRear)
            printDebug("Engine life left before", currentEngineLifeLeft)
            ac.setEngineLifeLeft(currentEngineLifeLeft - maxEngineDamage)
            printDebug("Engine life left after", acCarPhysics.engineLifeLeft)
        end
    end

    printDebug("Engine life", acCarPhysics.engineLifeLeft)
    prevDamageFrontEngine = thisCar.damage[0]
    prevDamageRearEngine = thisCar.damage[1]
    prevDamageLeftEngine = thisCar.damage[2]
    prevDamageRightEngine = thisCar.damage[3]
    currentEngineLifeLeft = acCarPhysics.engineLifeLeft
end

local function logRates()
    logDebug("Rates, Spark plug: ", sparkPlugFailureRate)
    logDebug("Fuel pump: ", fuelPumpFailureRate)
    logDebug("Valves: ", valveFailureRate)
    logDebug("Oil pressure: ", oilPressureFailureRate)
    logDebug("Radiator cool coefficient: ", radiatorCoolCoefficient)
end

-- Set everything to initial state. Useful for resetting the
-- car for a race, for example.
local function resetCar()
    sparkPlugFailed = false
    valveFailed = false
    valveFailureActive = false
    valveFailureElapsed = 0
    valveFailureDamage = valveFailureMinDamage
    oilPressureFailed = false
    oilPressureFailureActive = false
    oilPressureFailureElapsed = 0
    oilPressureFailureDamage = oilPressureFailureMinDamage
    currentSpares = getCurrentSpares()
    hasRadiatorDamage = false
    hasRadiatorMajorDamage = false
    brakesFailed = false
    brakeWearLevel = 0.0
    boxDamaged = false
    randomBrakeLimit = nil
    fuelPumpFailed = false
    initDeadGears()
    ac.setEngineLifeLeft(1000)
    carHasTeleportedToPits = false
    coolantTemp = 70
    engineTemp = 70
    radiatorSetup = 0
    prevRadiatorSetup = 0
    radiatorCoolCoefficient = radiatorCoolCoefficient
    sparkPlugFailureRate = sparkPlugFailureRateInitialValue
    sparkPlugFailureRateBase = sparkPlugFailureRateInitialValue
    fuelPumpFailureRate = fuelPumpFailureRateInitialValue
    fuelPumpFailureRateBase = fuelPumpFailureRateInitialValue
    valveFailureRate = valveFailureRateInitialValue
    valveFailureRateBase = valveFailureRateInitialValue
    oilPressureFailureRate = oilPressureFailureRateInitialValue
    oilPressureFailureRateBase = oilPressureFailureRateInitialValue
    radiatorCoolCoefficient = radiatorCoolCoefficientInitialValue
    radiatorCoolCoefficientBase = radiatorCoolCoefficientInitialValue
    hasEngineDamage = false

    if superchargerExists == 1 then
        initTurboVariables(ac, printDebug)
        currentEngineHeatGainMult = engineHeatGainMult
        prevFailedTurboCount = 0
        turboSmokeTimer = turboSmokeDuration
        acCarPhysics.controllerInputs[25] = 0
    end

    tyreStockEmpty = false
    tyreChangeInProgress = false
    blownTyres = false
    initTyrePunctureTables()
    for i = 0, 3 do
        ac.setTyreInflation(i, 1.0)
    end

    initTyreWearTable()
    resetCumulativeRateChanges()


    ResetEle()  --added for electricity

    logDebug("Physics script version: ", VERSION, true)
    logDebug("Car reset done.")
    logRates()
end

----------------- Debug/testing code -----------------
--
-- While not in pits, press extra B to select a failure,
-- then press and hold extra C until the failure occurs.
-- To clear all failures, select it using extra B, then
-- press extra C.

local failureTypes = {
    sparkPlugFailure = 1,
    fuelPumpFailure = 2,
    valveFailure = 3,
    oilPressureFailure = 4,
    gearFailure = 5,
    tyrePuncture_FL = 6,
    tyrePuncture_FR = 7,
    tyrePuncture_RL = 8,
    tyrePuncture_RR = 9,
    highSpeedLightCollision1 = 10,
    highSpeedLightCollision2 = 11,
    clearAllFailures = 12
}

local failureDescriptions = {
    "Spark plug failure",
    "Fuel pump failure",
    "Valve failure",
    "Oil pressure failure",
    "Gear failure",
    "Tyre puncture front left",
    "Tyre puncture front right",
    "Tyre puncture rear left",
    "Tyre puncture rear right",
    "Test high speed collision - 150",
    "Test high speed collision - 750",
    "Clear all failures"
}

local origSparkPlugFailureRateBase = sparkPlugFailureRateBase
local origFuelPumpFailureRateBase = fuelPumpFailureRateBase
local origValveFailureRateBase = valveFailureRateBase
local origOilPressureFailureRateBase = oilPressureFailureRateBase
local origGearFailureRate = gearFailureRate
local origBoostedGearFailureRate = boostedGearFailureRate
local origTyrePunctureRate = tyrePunctureRate

local highSpeedCollisionDone = false

local failureTypeCount = 0

local function initFailureTypeCount()
    for _ in pairs(failureTypes) do
        failureTypeCount = failureTypeCount + 1
    end
end

if TEST_CODE then
    initFailureTypeCount()
end

local selectedFailure = 0
local originalValue = 0
local prevExtraBState = false

-- These should not be included in release packages,
-- therefore calls to these functions MUST be behind
-- the TEST_CODE flag!
local function selectFailureForTesting()
    if not isCarInPits and not thisCar.extraB and prevExtraBState then
        selectedFailure = selectedFailure + 1
        if selectedFailure > failureTypeCount then
            selectedFailure = 1
        end
        prevExtraBState = false
        printDebug("Selected failure type:", failureDescriptions[selectedFailure], true)
    end

    if thisCar.extraB then
        prevExtraBState = true
    else
        prevExtraBState = false
    end
end

local function setFailureForTesting()
    if  not isCarInPits and thisCar.extraC then
        if selectedFailure == failureTypes.clearAllFailures then
            resetCar()
            highSpeedCollisionDone = false
            tyrePunctureTestIndex = -1
        elseif selectedFailure == failureTypes.sparkPlugFailure then
            sparkPlugFailureRateBase = 1
        elseif selectedFailure == failureTypes.fuelPumpFailure then
            fuelPumpFailureRateBase = 1
        elseif selectedFailure == failureTypes.valveFailure then
            valveFailureRateBase = 1
        elseif selectedFailure == failureTypes.oilPressureFailure then
            oilPressureFailureRateBase = 1
        elseif selectedFailure == failureTypes.gearFailure then
            gearFailureRate = 1
            boostedGearFailureRate = 1
        elseif selectedFailure == failureTypes.tyrePuncture_FL then
            tyrePunctureTestIndex = 0
        elseif selectedFailure == failureTypes.tyrePuncture_FR then
            tyrePunctureTestIndex = 1
        elseif selectedFailure == failureTypes.tyrePuncture_RL then
            tyrePunctureTestIndex = 2
        elseif selectedFailure == failureTypes.tyrePuncture_RR then
            tyrePunctureTestIndex = 3
        elseif selectedFailure == failureTypes.highSpeedLightCollision1 then
            if not highSpeedCollisionDone then
                prevDamageRightEngine = prevDamageRightEngine - 10
                prevDamageFrontEngine = prevDamageFrontEngine - 7
                prevDamageRearEngine = prevDamageRearEngine - 8
                ac.setEngineLifeLeft(acCarPhysics.engineLifeLeft-500)
                highSpeedCollisionDone = true
            end
        elseif selectedFailure == failureTypes.highSpeedLightCollision2 then
            if not highSpeedCollisionDone then
                prevDamageRightEngine = prevDamageRightEngine - 5
                prevDamageFrontEngine = prevDamageFrontEngine - 21
                ac.setEngineLifeLeft(acCarPhysics.engineLifeLeft-750)
                highSpeedCollisionDone = true
            end
        end
    else
        sparkPlugFailureRateBase = origSparkPlugFailureRateBase
        fuelPumpFailureRateBase = origFuelPumpFailureRateBase
        valveFailureRateBase = origValveFailureRateBase
        oilPressureFailureRateBase = origOilPressureFailureRateBase
        gearFailureRate = origGearFailureRate
        boostedGearFailureRate = origBoostedGearFailureRate
        tyrePunctureRate = origTyrePunctureRate
        tyrePunctureTestIndex = -1
    end
end

local function logStaticInfo()
    logDebug("Track Name: ", ac.getTrackName())
    logDebug("Car Name: ", ac.getCarName(thisCar.index, true))
    local brakeDuctPercentageFront = ac.getScriptSetupValue("BRAKE_DUCT_F")()
    logDebug("BrakeDuct F: ", brakeDuctPercentageFront)
    local brakeDuctPercentageRear = ac.getScriptSetupValue("BRAKE_DUCT_R")()
    logDebug("BrakeDuct R: ", brakeDuctPercentageRear)
    local brakeDuctWingGainFront = getBrakeDuctWingGain(brakeDuctPercentageFront)
    logDebug("BrakeDuct Wing Gain F: ", brakeDuctWingGainFront)
    local brakeDuctWingGainRear = getBrakeDuctWingGain(brakeDuctPercentageRear)
    logDebug("BrakeDuct Wing Gain R: ", brakeDuctWingGainRear)
end

local function logDebugDataToFile()
    logRates()

    local tyreName = ac.getTyresName(thisCar.index)
    local tyreTypeFactor = getTyreTypeFactor()
    logDebug("Tyre name: ", tyreName, ", factor: ", tyreTypeFactor)

    for i = 0, 3 do
        logDebug("Tyre " .. i .. " rate: ", tyrePunctureRates[i])
        logDebug("Tyre " .. i .. " vkm: ", thisCar.wheels[i].tyreVirtualKM)
    end

    logDebug("Engine / coolant temp: ", engineTemp, " / ", coolantTemp)
    logDebug("Engine life: ", acCarPhysics.engineLifeLeft)
    logDebug("Lap time: ", ac.lapTimeToString(thisCar.previousLapTimeMs))

    logDebug("Brake wear: ", brakeWearLevel)

    local turboCount = getTurboCount()
    for i = 0, turboCount-1 do
        logDebug("Turbo " .. i .. " fail rate: " .. getTurboFailureRate(i))
    end

    logDebug("Laps completed: ", thisCar.lapCount)
    logCumulativeRateChanges()
end

local function logExtraButtonPresses()
    if thisCar.extraA and not debugPrevExtraA then
        logDebug("ExtraA pressed", true)
    end
    debugPrevExtraA = thisCar.extraA

    if thisCar.extraB and not debugPrevExtraB then
        logDebug("ExtraB pressed", true)
    end
    debugPrevExtraB = thisCar.extraB

    if thisCar.extraC and not debugPrevExtraC then
        logDebug("ExtraC pressed", true)
    end
    debugPrevExtraC = thisCar.extraC

    if thisCar.extraD and not debugPrevExtraD then
        logDebug("ExtraD pressed", true)
    end
    debugPrevExtraD = thisCar.extraD

    if thisCar.extraE and not debugPrevExtraE then
        logDebug("ExtraE pressed", true)
    end
    debugPrevExtraE = thisCar.extraE

    if thisCar.extraF and not debugPrevExtraF then
        logDebug("ExtraF pressed", true)
    end
    debugPrevExtraF = thisCar.extraF

    if thisCar.handbrake == 1 and not debugPrevHandbrake then
        logDebug("Handbrake engaged", true)
    end
    debugPrevHandbrake = (thisCar.handbrake == 1)
end

local function logCarEnterAndLeavePits()
    if isCarInPits and not debugPrevInPits then
        logDebug("Enter pits", true)
    end
    if not isCarInPits and debugPrevInPits then
        logDebug("Exit pits", true)
        logStaticInfo()
    end

    debugPrevInPits = isCarInPits
end

----------------- End of debug/testing code -----------------

local fuelExhCutTimer = 0

-- MAIN UPDATE STARTS
function update(dt)
    if acCarPhysics.inputMethod == ac.InputMethod.AI then
        return
    end
    if currentSpares ~= 0 then
        tyreStockEmpty = false
    end
    if TEST_CODE then
        selectFailureForTesting()
        setFailureForTesting()
    end

    if thisCar.isInPitlane then
        if thisCar.isInPit then
            isCarInPits = true
        end
    else
        isCarInPits = false
    end
    printDebug("isCarInPits", isCarInPits)

    if ac.getSim().inputMode ~= ac.UserInputMode.Keyboard then
        switch_throttle_model.runThrottleModel()
    end

    logExtraButtonPresses()
    logCarEnterAndLeavePits()

    optimizationTimer = optimizationTimer + dt

    brakeWear(dt)
    fuelPumpFailure(dt)
    setupBits()
    coolantBehavior(dt)
    tyreReplacement(dt)
    overheadMessageDisplay(dt)
    engineStaller(dt)

    if (ignitionType == 2) or (ignitionType == 3) then       
    
        updateElectricity(dt)
        handleRepairs(dt, overheadMessageQueue)
        
        debugElectricity(dt)  -- <-- added

        if thisCar.isInPit and (batteryCurrentCharge < 95 or batteryMaxCapacity < 95 or alternatorHealth < 0.9 or not alternatorOK) then
            -- Check if Extra B is pressed
            if thisCar.extraB and not isRepairingBelt then
                isRepairingBelt = true
                beltRepairTimer = 0  -- Reset timer when repair starts
                overheadMessageQueue("Alternator Repair", "Repair started. Hold position until done", 3)
                printDebug("Alternator Repair", "Repair process started")
            end

            -- If repair is in progress, count time
            if isRepairingBelt then
                beltRepairTimer = beltRepairTimer + dt

                -- todo: adjust batteryMaxCapacity based on what is the problem. new battery - for simplicity I'll just assume they check and replace everything

                -- Show repair progress - repairing the alternator in the pits only takes half as long
                overheadMessageQueue("ELECTRICITY", "Repairing alternator: " .. string.format("%d%%", math.floor((beltRepairTimer / (alternatorRepairTime/2)) * 100)) .. " done", 1, true)
                printDebug("Alternator Repair Progress", string.format("%.1f sec left", (alternatorRepairTime/2) - beltRepairTimer))

                -- When repair time has passed, complete the repair
                if beltRepairTimer >= (alternatorRepairTime/2) then
                    alternatorOK = true
                    alternatorHealth = math.min((alternatorHealth or 0) + 0.5, 1.0) --? why not just 1?
                    beltRepairTimer = 0
                    isRepairingBelt = false
                    acCarPhysics.controllerInputs[52] = 0
                    alternatorRepairTime = math.random(100, 200)
                    batteryCurrentCharge = 100
                    batteryMaxCapacity = 100
                    overheadMessageQueue("ELECTRICITY", "The Alternator has been repaired", 3)
                end
            end
        end
    end

    mediumSpeedDtTimer = mediumSpeedDtTimer + dt

    if mediumSpeedDtTimer >= 0.1 then
        slowTyrePuncture()
        fuelExhaustion()
        limitEngineDamageAtCrash()
        mediumSpeedDtTimer = 0
    end

    if fuelExhCutLength > 0 then
        if fuelExhCutTimer < fuelExhCutLength then
            acCarPhysics.gas = math.random() * 0.2
            fuelExhCutTimer = fuelExhCutTimer + dt
        else
            fuelExhCutLength = 0
            fuelExhCutTimer = 0
        end
    end

    if superchargerExists == 1 then
        turboFailureTimer = turboFailureTimer + dt

        if not isCarInPits and turboFailureTimer >= 1 then
            updateTurboState(logDebug)
            if isTurboFailureEngineOverheatingActive() then
                currentEngineHeatGainMult = engineHeatGainMultTurbo
                printDebug("Turbo", "Engine overheating active")
            end
            turboFailureTimer = 0
        end
    end

    tyreBlowCrashingTimer = tyreBlowCrashingTimer + dt

    if tyreBlowCrashingTimer >= 0.2 then
        tyreBlowWhenCrashing()
        tyreBlowCrashingTimer = 0
    end

    -- Enable/disable turbo, if the option is available.
    if turboOnOffButtonEnabled then
        if thisCar.extraD and not prevExtraDState then
            turboEnabled = not turboEnabled
            enableTurbo(turboEnabled)

            if turboEnabled then
                overheadMessageQueue("Turbo enabled", "", 3)
            else
                overheadMessageQueue("Turbo disabled", "", 3)
            end
        end
        prevExtraDState = thisCar.extraD
    end

    -- radiator setup
    if radiatorShutterAdjustEnabled then
        if thisCar.extraE and not prevextraEState then
            radiatorSetup = (radiatorSetup + 1) % 5
        end
        if thisCar.extraF and not prevextraFState then
            radiatorSetup = (radiatorSetup - 1) % 5
        end
        if radiatorSetup ~= prevRadiatorSetup then
            local shutterMsg = applyRadiatorSetup(radiatorSetup)
            overheadMessageQueue("Radiator setup", shutterMsg, 3, true)
            printDebug("Radiator setup", tostring(radiatorSetup))
            logDebug("Radiator setup: ", tostring(radiatorSetup))
        end
        prevextraEState = thisCar.extraE
        prevextraFState = thisCar.extraF
        prevRadiatorSetup = radiatorSetup
    end

    failureRateHandlingTimer = failureRateHandlingTimer + dt

    if failureRateHandlingTimer >= failureRateHandlingInterval and thisCar.speedKmh > 1 then
        local rates = {
            sparkPlug = sparkPlugFailureRateBase,
            fuelPump = fuelPumpFailureRateBase,
            valveDamage = valveFailureRateBase,
            oilPressure = oilPressureFailureRateBase
        }

        local rpmRounded = math.floor(thisCar.rpm + 0.5)
        handleOverrevving(rates, rpmRounded)
        local lowRpm = handleLowRpm(rates, rpmRounded)
        local runningCloseStep = handleRunningCloseToCarInFront(rates, thisCar.speedKmh, ac)
        handleHighCoolantTemp(rates, coolantTemp)
        handleRunningTankLow(rates, thisCar.fuel)
        radiatorCoolCoefficient = handleRadiatorEfficiency(radiatorCoolCoefficientBase, lowRpm, runningCloseStep, trackSurfaceType, thisCar.fuelMap + 1)

        sparkPlugFailureRateBase = rates.sparkPlug
        fuelPumpFailureRateBase = rates.fuelPump
        valveFailureRateBase = rates.valveDamage
        oilPressureFailureRateBase = rates.oilPressure

        printDebug("Spark plug failure rate", sparkPlugFailureRate)
        printDebug("Fuel pump failure rate", fuelPumpFailureRate)
        printDebug("Valve failure rate", valveFailureRate)
        printDebug("Oil pressure failure rate", oilPressureFailureRate)
        printDebug("radiatorCoolCoefficient", radiatorCoolCoefficient)

        failureRateHandlingTimer = 0
    end

    if DEBUG_LOG_FILE then
        ac.setLogSilent(false)

        if thisCar.lapCount ~= prevLapCount then
            if ac.getSim().raceFlagType == ac.FlagType.Finished then
                logDebug("*** SESSION FINISHED ***")
            else
                logDebug("* LAP COMPLETED *")
            end

            logDebugDataToFile()
            logDebug("***")
            prevLapCount = thisCar.lapCount
        end
    end

    --run some bits only every few ticks, no point in checking them every tick.
    if optimizationTimer > 2 then
    --setExtraMass call is free if the position and mass is the same as last call, so this is fine here.

        if currentSpares > 0 then
            local currentSparesBugfix = currentSpares + 0.1
            ac.setExtraMass(spareWheelPos, currentSparesBugfix * spareWheelMass, vec3(0.05,0.05,0.05))
        end
        
        -- Prior starting the race, reset all possible failures and wear
        -- accumulated in previous (practice) sessions.
        local inGrid = (ac.getSim().raceSessionType == ac.SessionType.Race and not ac.getSim().isSessionStarted)
        if inGrid then
            if not doOnceAtStart then
                resetCar()
                logStaticInfo()
                doOnceAtStart = true
            end
        else
            tyreBlow()
            fuelPumpFailureActivation()
            updateTyreWear()
        end

        adjustRatesAccordingToEngineMap()

        printDebug("Engine life left", acCarPhysics.engineLifeLeft)
        if acCarPhysics.engineLifeLeft < 1000 then
            hasEngineDamage = true
        end

        -- Only run failure checks when NOT in repair state
        if not gearboxRepairInProgress and not isCarInPits and not inGrid then
            sparkPlugFailure()
            valveFailure(dt)
            oilPressureFailure(dt)
            gearboxFailure()
            fuelTankDamage()
        end

        fuelTankDamage()

        local deadGearCount = 0
        for i = 1, thisCar.gearCount do
            if deadGears[i] then deadGearCount = deadGearCount + 1 end
        end
        local gearboxDamage = deadGearCount / thisCar.gearCount
        updateGearFailureRate(gearboxDamage)

        -- If repairs are on going then force engine off.
        if fuelPumpRepairInProgress or gearboxRepairInProgress or isRepairingBelt then
            ac.setEngineRPM(0)
        end

        optimizationTimer = 0
    end

    if isCarInPits and fuelPumpFailed then
        -- Check if Extra B is pressed
        if thisCar.extraB and not fuelPumpRepairInProgress then
            fuelPumpRepairInProgress = true
            fuelPumpPitTimer = 0  -- Reset timer when repair starts
            overheadMessageQueue("Fuel Pump Repair", "Repair started. Hold position until done", 3)
            printDebug("Fuel Pump Repair", "Repair process started")
        end

        -- If repair is in progress, count time
        if fuelPumpRepairInProgress then
            fuelPumpPitTimer = fuelPumpPitTimer + dt

            -- Show repair progress
            --ac.setSystemMessage("Fuel Pump Repair", string.format("Time left: %.1f sec", math.max(0, fuelPumpRepairTime - fuelPumpPitTimer)))
            ac.setSystemMessage("Fuel Pump Repair",
                    string.format("Progress: %.1f%%",
                    (fuelPumpPitTimer/fuelPumpRepairTime)*100))
            printDebug("Fuel Pump Repair Progress", string.format("%.1f sec left", fuelPumpRepairTime - fuelPumpPitTimer))

            -- When repair time has passed, complete the repair
            if fuelPumpPitTimer >= fuelPumpRepairTime then
                fuelPumpFailed = false
                fuelPumpRepairInProgress = false
                fuelPumpPitTimer = 0
                fuelPumpRepairTime = math.random(30, 180)

                -- Reset failure rates to initial values, as the pump has been fixed.
                fuelPumpFailureRate = fuelPumpFailureRateInitialValue
                fuelPumpFailureRateBase = fuelPumpFailureRateInitialValue

                overheadMessageQueue("Fuel Pump Repaired", "You're good to go!", 3)
                printDebug("Fuel Pump Repair", "Repair complete!")
            end
        end
    else
        -- Reset if car leaves pits
        fuelPumpRepairInProgress = false
        fuelPumpPitTimer = 0
    end

    -- Simulate gear failure by cutting throttle
    local currentGearIndex = getCurrentGearIndex()
    if currentGearIndex > 0 and deadGears[currentGearIndex] then
        acCarPhysics.clutch = 0.1 + math.random() * 0.4  -- Generates a value between 0.1 and 0.6 - Fuck up failed gears
        --overheadMessageQueue("Gear failure", "Gear "..(currentGearIndex).." is broken!", 3)
    end

    -- Gearbox Repair Logic (new)
    if isCarInPits and not fuelPumpRepairInProgress then
        local needsRepair = false
        for i = 1, thisCar.gearCount do
            if deadGears[i] then
                needsRepair = true
                break
            end
        end

        if needsRepair then
            if thisCar.extraB and not gearboxRepairInProgress then
                gearboxRepairInProgress = true
                gearboxPitTimer = 0
                overheadMessageQueue("Gearbox Repair", "Repair started. Hold position!", 3)
            end

            if gearboxRepairInProgress then
                gearboxPitTimer = gearboxPitTimer + dt
                ac.setSystemMessage("Gearbox Repair",
                    string.format("Progress: %.1f%%",
                    (gearboxPitTimer/gearboxRepairTime)*100))

                -- Complete repair
                if gearboxPitTimer >= gearboxRepairTime then
                    initDeadGears()
                    gearboxRepairInProgress = false
                    gearboxRepairTime = math.random(30, 180)
                    overheadMessageQueue("GEARBOX REPAIRED", "All gears restored!", 5)
                end
            end
        end
    end

    -- Limit the minimum failure rates.
    if sparkPlugFailureRateBase < sparkPlugFailureRateMinimumValue then
        sparkPlugFailureRateBase = sparkPlugFailureRateMinimumValue
    end
    if fuelPumpFailureRateBase < fuelPumpFailureRateMinimumValue then
        fuelPumpFailureRateBase = fuelPumpFailureRateMinimumValue
    end
    if valveFailureRateBase < valveFailureRateMinimumValue then
        valveFailureRateBase = valveFailureRateMinimumValue
    end
    if oilPressureFailureRateBase < oilPressureFailureRateMinimumValue then
        oilPressureFailureRateBase = oilPressureFailureRateMinimumValue
    end

    -- Avoid calling printDebug() at every iteration in normal use,
    -- since function calls are pretty expensive in Lua.
    if DEBUG then
        -- local tyreName = ac.getTyresName(0, -1)
        --printDebug("TyreName", tyreName)

        printDebug("Extra Buttons", string.format("A: %s | B: %s", tostring(thisCar.extraA), tostring(thisCar.extraB)))

        printDebug("Radiator", string.format("Damage: %.1f | Coolant: %.1f°C | Engine: %.1f°C", carDamageClamp, coolantTemp, engineTemp))
        printDebug("Tyres", string.format("Spares: %s | Time: %.2f", tostring(currentSpares), carStoppedTimer))
        printDebug("Brake Damage", brakesFailed)
        printDebug("Gearbox Failure", "Status: " .. tostring(isGearboxFailed))
        printDebug("Gearbox Ratio", acCarPhysics.gearsFinalRatio)
        printDebug("Gearbox", string.format("Damage: %.1f | Rate: %.1f", thisCar.gearboxDamage, boostedGearFailureRate))
        printDebug("Repair times", string.format("Fuel pump: %s | Gearbox: %s", fuelPumpRepairTime, gearboxRepairTime))
        printDebug("Valve Failure", string.format(
        "RPM: %d | Progress: %.1f%% | Damage: %.1f/%.1f | Status: %s",
            acCarPhysics.rpm,
            (valveFailureElapsed/valveFailureBaseTime)*100,
            valveFailureDamage,
            valveFailureMaxDamage,
            tostring(valveFailureActive)
        ))
        printDebug("Oil pressure problems", string.format(
        "RPM: %d | Progress: %.1f%% | Damage: %.1f/%.1f | Status: %s",
        tonumber(acCarPhysics.rpm) or 0,
        (tonumber(oilPressureFailureElapsed) or 0) / (tonumber(oilPressureFailureBaseTime) or 1) * 100,
        tonumber(oilPressureFailureDamage) or 0,
        tonumber(oilPressureFailureMaxDamage) or 1,
        tostring(oilPressureFailureActive)
    ))

        printDebug("Fuel Pump failure", string.format(
            "Gas: %.3f | Fuel flows: %.1f%% | Status: %s",
            tonumber(acCarPhysics.gas) or 0,  -- Ensuring gas is a number, default to 0 if nil
            tonumber(fuelPumpFailureCooldown) or 0,  -- Ensure a valid number
            tostring(fuelPumpFailed) -- Convert boolean/nil to string safely
        ))
        --printDebug("Fuel Pump Repair", string.format("[%-30s] %.1f sec left", string.rep("#", (fuelPumpPitTimer / fuelPumpRepairTime) * 30), fuelPumpRepairTime - fuelPumpPitTimer))

        local currGearIndex = getCurrentGearIndex()
        printDebug("Gearbox Status", "Gear " .. currGearIndex .. ": " .. tostring(deadGears[currGearIndex]))
        printDebug("Fuel Pump", "Active: " .. tostring(fuelPumpFailed))
    end

    -- PSG update loop
    if gearboxIsPSG then
        
        if not psgInitialized then
            initPSG(ac, overheadMessageQueue)
            psgInitialized = true
        end

        updatePSG(dt,thisCar)
    end

    acCarPhysics.controllerInputs[2] = currentSpares
    acCarPhysics.controllerInputs[4] = brakesFailed
    acCarPhysics.controllerInputs[7] = oilPressureFailureActive
    acCarPhysics.controllerInputs[8] = valveFailureActive
    acCarPhysics.controllerInputs[9] = fuelPumpFailed
    acCarPhysics.controllerInputs[10] = sparkPlugFailed
    acCarPhysics.controllerInputs[12] = gearboxRepairInProgress
    acCarPhysics.controllerInputs[13] = fuelPumpRepairInProgress
    acCarPhysics.controllerInputs[14] = isAnyGearBroken()
    acCarPhysics.controllerInputs[15] = hasRadiatorDamage or hasRadiatorMajorDamage
    acCarPhysics.controllerInputs[16] = isAnyTyrePunctured()
    acCarPhysics.controllerInputs[17] = tyreStockEmpty
    acCarPhysics.controllerInputs[20] = ac.getAltitude()
    acCarPhysics.controllerInputs[21] = acCarPhysics.airDensity
    acCarPhysics.controllerInputs[22] = superchargerExists
    acCarPhysics.controllerInputs[23] = isAboveBoostLimit()

    if not isCarInPits and superchargerExists == 1 then
        local currentFailedTurboCount = getFailedTurboCount()
        acCarPhysics.controllerInputs[24] = currentFailedTurboCount

        if currentFailedTurboCount > prevFailedTurboCount then
            if turboSmokeTimer < turboSmokeDuration then
                acCarPhysics.controllerInputs[25] = 0
            end
            turboSmokeTimer = 0
        end

        prevFailedTurboCount = currentFailedTurboCount

        if turboSmokeTimer < turboSmokeDuration then
            turboSmokeTimer = turboSmokeTimer + dt
        end

        if turboSmokeTimer < turboSmokeDuration then
            -- Delay the sound a bit, otherwise if another supercharger
            -- explodes during the `turboSmokeDuration` time, then
            -- the event wouldn't be caught in `supercharger.lua`.
            if turboSmokeTimer > 0.5 then
                acCarPhysics.controllerInputs[25] = 1
            end
        else
            acCarPhysics.controllerInputs[25] = 0
        end

        printDebug("turboSmokeTimer", "" .. turboSmokeTimer)
    end

    if resetBrakeWearAtTyreChange == nil then
        acCarPhysics.controllerInputs[26] = false
    else
        acCarPhysics.controllerInputs[26] = resetBrakeWearAtTyreChange
    end

    acCarPhysics.controllerInputs[27] = carHasTeleportedToPits

    acCarPhysics.controllerInputs[28] = thisCar.fuelMap
    printDebug("Fuelmap", "" .. thisCar.fuelMap)
    acCarPhysics.controllerInputs[29] = radiatorSetup
    acCarPhysics.controllerInputs[30] = turboEnabled
    acCarPhysics.controllerInputs[31] = getDistanceToClosestTyreStack()
    printDebug("Distance to closest tyre stack", acCarPhysics.controllerInputs[31])
    acCarPhysics.controllerInputs[32] = getOverrevvingState()
    printDebug("OverrevvingState", acCarPhysics.controllerInputs[32])
    acCarPhysics.controllerInputs[33] = fuelLeakageDamage
    acCarPhysics.controllerInputs[34] = fuelExhaustionAmount

    acCarPhysics.controllerInputs[35] = sparkPlugFailureRate
    acCarPhysics.controllerInputs[36] = fuelPumpFailureRate
    acCarPhysics.controllerInputs[37] = oilPressureFailureRate
    acCarPhysics.controllerInputs[38] = valveFailureRate
    acCarPhysics.controllerInputs[39] = brakeFadeStart
    acCarPhysics.controllerInputs[40] = brakeWearLevel

    acCarPhysics.controllerInputs[41] = getLowRpmState()

    -- 0 = nothing's happening, 1 = fetching tyre, 2 = changing tyre, 3 = tyre change done
    acCarPhysics.controllerInputs[42] = roadsideTyreChange
    -- 43 - 48: electricity stuff
    -- 49 & 50 == PSG
    acCarPhysics.controllerInputs[51] = ignitionType
    -- 52 == Alternator being repaired 0 or 1
end
-- MAIN UPDATE ENDS
