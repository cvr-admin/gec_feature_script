-- Engine ignition and stalling simulation.
-- Handles cranking, starting delays (hand-crank, push-start), and engine stall physics.

require "script_car_parameters"

local carState = {
    ignition = false,
    cranking = false,
    crankTimer = 0,
    startExtraDelay = 0,
    stalling = false,
    stallRPM = 0,
    fullyStalled = false,
    stallCooldownTimer = 0,
    stallThrottleBlockedFrames = 0,
    stallIntentConsumed = false,
    lastThrottleInput = 0,
    directionMismatchGraceTimer = 0,
    wasDirectionMismatch = false,
    revTrapTimer = 0,
    revTrapCooldownTimer = 0,
    lastGearIndex = 0,
    bumpStartBlockTimer = 0,
    stallingElapsed = 0,
    lowRpmStallTimer = 0,
}
local carInfo = {
    idleRPM = ac.INIConfig.carData(0, 'engine.ini'):get('ENGINE_DATA', 'MINIMUM', engineIdleRpm)
}
carInfo.starterRPM = carInfo.idleRPM + 700

local drivetrainConfig = ac.INIConfig.carData(0, 'drivetrain.ini')
local tyreConfig = ac.INIConfig.carData(0, 'tyres.ini')
local starterGearRatios = {}
local starterFinalRatio = math.abs(drivetrainConfig:get('GEARS', 'FINAL', 1))
local starterDrivenTyreRadius = tyreConfig:get('REAR', 'RADIUS', 0.36)
local starterRpmFactor = starterFinalRatio * 60.0 / (3.6 * 2.0 * math.pi * starterDrivenTyreRadius)
-- Reverse gear ratio (GEAR_R is stored as a negative value in drivetrain.ini)
local starterReverseGearRatio = math.abs(drivetrainConfig:get('GEARS', 'GEAR_R', 1))

for i = 1, thisCar.gearCount do
    starterGearRatios[i] = math.abs(drivetrainConfig:get('GEARS', 'GEAR_' .. i, 1))
end

-- Detect whether the clutch is bound to an analogue axis or a button via controls.ini
local clutchIsAnalogue = false
local controlsCfg = ac.INIConfig.controlsConfig()
local clutchAxis = controlsCfg:get('CLUTCH', 'AXLE', 'NONE')
clutchIsAnalogue = clutchAxis ~= '' and clutchAxis ~= '-1' and clutchAxis ~= 'NONE'

ac.setEngineStalling(true)
local starterTorque = 40.0
ac.setEngineStarterTorque(0)

local function applyLag(current, target, factor, dt)
    return current + (target - current) * factor * dt
end

local function getRandomStartTime()
    local minSeconds = math.max(1, math.floor((tonumber(engineStarterStartTimeMinSeconds) or 2) + 0.5))
    local maxSeconds = math.max(minSeconds, math.floor((tonumber(engineStarterStartTimeMaxSeconds) or 5) + 0.5))
    return math.random(minSeconds, maxSeconds)
end
local function getFluctuatingRPM()
    return math.random(10, math.max(10, carInfo.idleRPM - 100))
end

local timeToStart = getRandomStartTime()
local teleportPrevExtraA = false
local stallRecoveryCooldownSeconds = 1.0
local bumpStartCatchCooldownSeconds = 0.5
local stallThrottleIntentWindowFrames = 3
local stallThrottleIntentThreshold = 0.1
local directionMismatchSpeedDeadzoneKmh = 1.5
local directionMismatchGraceSeconds = 0.22
local clutchTakeupUpperThreshold = 0.92
local revTrapDetectThrottle = 0.35
local revTrapDetectRpmMargin = 180
local revTrapDetectMaxSpeedKmh = 6
local revTrapDetectHoldSeconds = 1.2
local revTrapRecoveryCooldownSeconds = 2.0
local bumpStartGearChangeDebounceSeconds = 0.25
local bumpStartStallDwellSeconds = 0.15
-- A generic anti-lug threshold derived from idle speed. Keep this internal:
-- individual engines instead use the grace/recovery settings in car parameters.
local drivetrainStallRpm = math.max(carInfo.idleRPM * 0.60, 350)

local function getStartExtraDelay()
    local delay = 0
    local onGrid = (ac.getSim().raceSessionType == ac.SessionType.Race and not ac.getSim().isSessionStarted)

    if not onGrid and not (thisCar.isInPitlane and thisCar.isInPit) then
        if ignitionType == 3 and (acCarPhysics.controllerInputs[44] or 1) <= 0.05 then
            delay = math.random(8, 12)
            overheadMessageQueue("PUSH STARTING", "...because the battery is empty. This may take a good while longer.", 1, true)
        elseif (ignitionType or 1) < 2 then
            delay = math.random(4, 6)
            overheadMessageQueue("CRANK STARTING", "This may take a bit longer.", 1, true)
        end
    end

    return delay
end

local function getDrivenEngineRpm(currentGearIndex)
    -- currentGearIndex: -1 = reverse, 0 = neutral, 1+ = forward gears
    if currentGearIndex == 0 then
        return 0
    end

    local ratio
    if currentGearIndex == -1 then
        ratio = starterReverseGearRatio
    else
        ratio = starterGearRatios[currentGearIndex] or 0
    end

    return math.abs(thisCar.speedKmh or acCarPhysics.speedKmh or 0)
        * math.abs(ratio)
        * starterRpmFactor
end

local function getSignedLongitudinalSpeedKmh()
    local localVelocity = acCarPhysics.localVelocity or thisCar.localVelocity
    if localVelocity and localVelocity.z then
        return localVelocity.z * 3.6
    end
    return 0
end

local function getSelectedGearDirection(currentGearIndex)
    if currentGearIndex == -1 then
        return -1
    elseif currentGearIndex > 0 then
        return 1
    end
    return 0
end

local function isDirectionMismatch(currentGearIndex, signedSpeedKmh)
    local gearDirection = getSelectedGearDirection(currentGearIndex)
    if gearDirection == 0 or math.abs(signedSpeedKmh) < directionMismatchSpeedDeadzoneKmh then
        return false
    end

    return signedSpeedKmh * gearDirection < 0
end

local function canBumpStartEngine(currentGearIndex, clutchPedalIn)
    -- currentGearIndex ~= 0 covers both forward (>0) and reverse (-1)
    return currentGearIndex ~= 0
        and not clutchPedalIn
        and (thisCar.speedKmh or acCarPhysics.speedKmh or 0) >= (engineBumpStartMinSpeedKmh or 12)
        and getDrivenEngineRpm(currentGearIndex) >= (engineBumpStartMinDrivenRpm or carInfo.idleRPM * 0.75)
end

function resetEngineStarter()
    carState.ignition = false
    carState.cranking = false
    carState.crankTimer = 0
    carState.startExtraDelay = 0
    carState.stalling = false
    carState.stallRPM = 0
    carState.fullyStalled = false
    carState.stallCooldownTimer = 0
    carState.stallThrottleBlockedFrames = 0
    carState.stallIntentConsumed = false
    carState.lastThrottleInput = 0
    carState.directionMismatchGraceTimer = 0
    carState.wasDirectionMismatch = false
    carState.revTrapTimer = 0
    carState.revTrapCooldownTimer = 0
    carState.bumpStartBlockTimer = 0
    carState.stallingElapsed = 0
    carState.lowRpmStallTimer = 0

    carState.lastGearIndex = (acCarPhysics.gear or 1) - 1
    timeToStart = getRandomStartTime()
    teleportPrevExtraA = false

    ac.setEngineStarterTorque(0)
    ac.setEngineRPM(0)
end

function engineStaller(dt)
    -- engine stalling / ignition functions
    local inputs = { ignition = car.extraA, clutch = acCarPhysics.clutch }
    local fixingOngoing = fuelPumpRepairInProgress or gearboxRepairInProgress
        or oilPitRefillInProgress or isRepairingBelt
        or sparkPlugRepairInProgress or sparkPlugRoadsideRepairInProgress
        or pitCrewTyreChangeInProgress
    local currentGearIndex = (acCarPhysics.gear or 1) - 1
    local clutchPedalIn = (inputs.clutch or 1) < engineStallClutchInThreshold
    local throttleInput = math.max(acCarPhysics.gas or 0, thisCar.gas or 0)
    local signedSpeedKmh = getSignedLongitudinalSpeedKmh()
    -- ~= 0 covers both forward gears (>0) and reverse (-1); neutral (0) is excluded
    local drivetrainCanStallEngine = currentGearIndex ~= 0 and not clutchPedalIn
    local drivenEngineRpm = getDrivenEngineRpm(currentGearIndex)
    local directionMismatchActive = isDirectionMismatch(currentGearIndex, signedSpeedKmh)
    local clutchTakeupActive = (inputs.clutch or 1) >= engineStallClutchInThreshold
        and (inputs.clutch or 1) <= clutchTakeupUpperThreshold

    -- Normalize impossible carry-over state that can occur across hard session transitions.
    if carState.ignition and not carState.cranking and not carState.stalling and (acCarPhysics.rpm or 0) <= 10 then
        carState.ignition = false
        carState.revTrapTimer = 0
        carState.revTrapCooldownTimer = 0
    end

    if carState.lastGearIndex ~= currentGearIndex then
        carState.bumpStartBlockTimer = bumpStartGearChangeDebounceSeconds
        carState.lastGearIndex = currentGearIndex
    end

    if car.extraA and carHasTeleportedToPits then
        if car.extraA and not teleportPrevExtraA then
            overheadMessageQueue("START DISABLED", "You have teleported to the pits, race restart is not allowed", 3)
        end
        inputs.ignition = false
    end
    teleportPrevExtraA = car.extraA

    if pitCrewTyreChangeInProgress then
        resetEngineStarter()
        acCarPhysics.controllerInputs[5] = carInfo.idleRPM
        acCarPhysics.controllerInputs[6] = 0
        return
    end

    -- Cranking Logic
    if inputs.ignition and not carState.ignition and not fixingOngoing then
        if not carState.cranking then
            carState.cranking = true
            carState.crankTimer = 0
            carState.startExtraDelay = getStartExtraDelay()
            carState.stalling = false
            carState.revTrapTimer = 0
        end

        carState.crankTimer = carState.crankTimer + dt
        ac.setEngineStarterTorque(starterTorque)

        if carState.crankTimer < (timeToStart + carState.startExtraDelay) then
            -- Simulate cranking RPM below idle.
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
        carState.startExtraDelay = 0
        ac.setEngineStarterTorque(0)
    end

    if carState.cranking then
        carState.stalling = false
        carState.stallRPM = 0
    end

    printDebug("Ignition Time", timeToStart)

    carState.stallCooldownTimer = math.max(0, (carState.stallCooldownTimer or 0) - dt)
    carState.revTrapCooldownTimer = math.max(0, (carState.revTrapCooldownTimer or 0) - dt)
    carState.bumpStartBlockTimer = math.max(0, (carState.bumpStartBlockTimer or 0) - dt)

    if carState.stalling then
        carState.stallingElapsed = (carState.stallingElapsed or 0) + dt
    else
        carState.stallingElapsed = 0
    end

    local bumpStartEligible = canBumpStartEngine(currentGearIndex, clutchPedalIn)
    local canAutoCatchBumpStart = bumpStartEligible
        and (carState.bumpStartBlockTimer or 0) <= 0
        and (not carState.stalling or (carState.stallingElapsed or 0) >= bumpStartStallDwellSeconds)


    if directionMismatchActive and not carState.wasDirectionMismatch then
        carState.directionMismatchGraceTimer = directionMismatchGraceSeconds
    elseif not directionMismatchActive then
        carState.directionMismatchGraceTimer = 0
    end
    carState.wasDirectionMismatch = directionMismatchActive
    carState.directionMismatchGraceTimer = math.max(0, (carState.directionMismatchGraceTimer or 0) - dt)

    -- Running and Stalling Logic
    if carState.ignition then
        local revTrapCandidate = not carState.cranking
            and not carState.stalling
            and (carState.revTrapCooldownTimer or 0) <= 0
            and throttleInput > revTrapDetectThrottle
            and math.abs(acCarPhysics.rpm - carInfo.idleRPM) <= revTrapDetectRpmMargin
            and math.abs(thisCar.speedKmh or acCarPhysics.speedKmh or 0) <= revTrapDetectMaxSpeedKmh

        if revTrapCandidate then
            carState.revTrapTimer = (carState.revTrapTimer or 0) + dt
        else
            carState.revTrapTimer = math.max(0, (carState.revTrapTimer or 0) - dt * 2.0)
        end

        if carState.revTrapTimer >= revTrapDetectHoldSeconds then
            carState.ignition = false
            carState.cranking = false
            carState.stalling = true
            carState.stallingElapsed = 0
            carState.fullyStalled = false
            carState.stallRPM = math.max(40, math.min(acCarPhysics.rpm, drivenEngineRpm, carInfo.idleRPM * 0.4))
            carState.stallThrottleBlockedFrames = 0
            carState.stallIntentConsumed = false
            carState.directionMismatchGraceTimer = 0
            carState.wasDirectionMismatch = false
            carState.revTrapTimer = 0
            carState.revTrapCooldownTimer = revTrapRecoveryCooldownSeconds
            ac.setEngineStarterTorque(0)
        else
        local stallFromDrivetrainCandidate = drivetrainCanStallEngine
            and drivenEngineRpm < drivetrainStallRpm
            and not (ac.getSim().inputMode == ac.UserInputMode.Keyboard or ac.getSim().inputMode == ac.UserInputMode.Gamepad or not clutchIsAnalogue)
        local stallFromLowRpmCandidate = acCarPhysics.rpm < carInfo.idleRPM * 0.9
            and drivetrainCanStallEngine
            and drivenEngineRpm < (engineBumpStartMinDrivenRpm or carInfo.idleRPM * 0.75)
        local stallRecoveryInputActive = throttleInput > (engineLowRpmStallSaveThrottle or 0.18)
        local stallRecovered = acCarPhysics.rpm >= carInfo.idleRPM * 0.95
            or clutchPedalIn
            or drivenEngineRpm >= (engineBumpStartMinDrivenRpm or carInfo.idleRPM * 0.75)

        if (stallFromDrivetrainCandidate or stallFromLowRpmCandidate) and not stallRecovered then
            local timerRate = stallRecoveryInputActive and 0.35 or 1.0
            carState.lowRpmStallTimer = (carState.lowRpmStallTimer or 0) + dt * timerRate
        else
            carState.lowRpmStallTimer = math.max(0, (carState.lowRpmStallTimer or 0) - dt * 2.0)
        end

        local stallFromDrivetrain = stallFromDrivetrainCandidate
            and (carState.lowRpmStallTimer or 0) >= (engineLowRpmStallGraceSeconds or 1.4)
        local stallFromLowRpm = stallFromLowRpmCandidate
            and (carState.lowRpmStallTimer or 0) >= (engineLowRpmStallGraceSeconds or 1.4)

        local mismatchSofteningActive = directionMismatchActive
            and clutchTakeupActive
            and (carState.directionMismatchGraceTimer or 0) > 0

        if (stallFromDrivetrain or stallFromLowRpm)
            and carState.stallCooldownTimer <= 0
            and not carState.fullyStalled
            and not mismatchSofteningActive
        then
            carState.ignition = false
            carState.stalling = true
                carState.stallingElapsed = 0
            carState.stallRPM = math.min(acCarPhysics.rpm, drivenEngineRpm)
            carState.stallThrottleBlockedFrames = stallThrottleIntentWindowFrames
            carState.stallIntentConsumed = false
            carState.lastThrottleInput = throttleInput
                carState.lowRpmStallTimer = 0
                carState.revTrapTimer = 0
            ac.setEngineStarterTorque(0)
        elseif not drivetrainCanStallEngine then
            -- Stabilize idle RPM (only in neutral or with clutch in)
            acCarPhysics.rpm = math.max(acCarPhysics.rpm, carInfo.idleRPM)
            carState.lowRpmStallTimer = 0
            end
        end
    elseif carState.stalling then
        local throttleRisingEdge = throttleInput > stallThrottleIntentThreshold
            and (carState.lastThrottleInput or 0) <= stallThrottleIntentThreshold

        if carState.stallThrottleBlockedFrames > 0 then
            carState.stallThrottleBlockedFrames = carState.stallThrottleBlockedFrames - 1
        end

        if not carState.stallIntentConsumed and carState.stallThrottleBlockedFrames > 0 and throttleRisingEdge then
            carState.stallIntentConsumed = true
            if canAutoCatchBumpStart then
                carState.stalling = false
                carState.stallingElapsed = 0
                carState.fullyStalled = false
                carState.ignition = true
                carState.stallRPM = 0
                carState.stallCooldownTimer = bumpStartCatchCooldownSeconds
                carState.revTrapTimer = 0
                carState.revTrapCooldownTimer = revTrapRecoveryCooldownSeconds
                carState.stallThrottleBlockedFrames = 0
                carState.stallIntentConsumed = false
                ac.setEngineRPM(math.max(acCarPhysics.rpm, drivenEngineRpm, carInfo.idleRPM))
                overheadMessageQueue("ENGINE STARTED", "The engine caught from road speed", 2)
            end
        elseif canAutoCatchBumpStart then
            carState.stalling = false
            carState.stallingElapsed = 0
            carState.fullyStalled = false
            carState.ignition = true
            carState.stallRPM = 0
            carState.stallCooldownTimer = bumpStartCatchCooldownSeconds
            carState.revTrapTimer = 0
            carState.revTrapCooldownTimer = revTrapRecoveryCooldownSeconds
            carState.stallThrottleBlockedFrames = 0
            carState.stallIntentConsumed = false
            ac.setEngineRPM(math.max(acCarPhysics.rpm, drivenEngineRpm, carInfo.idleRPM))
            overheadMessageQueue("ENGINE STARTED", "The engine caught from road speed", 2)
        else
            carState.stallRPM = applyLag(carState.stallRPM, 0, 2.0, dt)
            ac.setEngineRPM(carState.stallRPM)

            if carState.stallRPM < 10 then
                carState.stalling = false
                carState.fullyStalled = true
                carState.stallCooldownTimer = stallRecoveryCooldownSeconds
                carState.stallThrottleBlockedFrames = 0
                carState.stallIntentConsumed = false
                carState.revTrapTimer = 0
                ac.setEngineRPM(0)
                timeToStart = getRandomStartTime()
            end
        end
    else
        if carState.fullyStalled and carState.stallCooldownTimer <= 0 then
            carState.fullyStalled = false
        end

        if not carState.cranking then
            if canAutoCatchBumpStart then
                carState.ignition = true
                carState.fullyStalled = false
                carState.stallCooldownTimer = bumpStartCatchCooldownSeconds
                carState.revTrapTimer = 0
                carState.revTrapCooldownTimer = revTrapRecoveryCooldownSeconds
                ac.setEngineRPM(math.max(acCarPhysics.rpm, drivenEngineRpm, carInfo.idleRPM))
            else
                ac.setEngineRPM(0)
            end
        end
    end

    carState.lastThrottleInput = throttleInput

    acCarPhysics.controllerInputs[5] = carInfo.idleRPM
    acCarPhysics.controllerInputs[6] = acCarPhysics.rpm

-- engine stalling / ignition functions end
end
