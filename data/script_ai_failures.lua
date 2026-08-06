-- Lightweight AI reliability system.
-- Uses the same base probability values as the player-facing damage systems,
-- but keeps the AI response simple enough to avoid confusing its driving logic.

local aiPhys = nil
local aiCar = nil

local aiState = {
    timer = 0,
    active = false,
    kind = nil,
    dnf = false,
    pitRequested = false,
    issueDistanceKm = 0,
    repairTimer = 0,
    slowMultiplier = 1,
    side = 1,
    tyre = 0,
    roadsideRepair = false,
    stopLogged = false
}

local aiStartupLogged = false

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function getCarLabel()
    local carIndex = aiCar and aiCar.index or "?"
    local driverName = aiCar and aiCar.driverName and aiCar:driverName() or nil

    if driverName and driverName ~= "" then
        return "AI car " .. tostring(carIndex) .. " (" .. driverName .. ")"
    end

    return "AI car " .. tostring(carIndex)
end

local function logAIEvent(event, details)
    if not aiIssueLoggingEnabled then
        return
    end

    ac.setLogSilent(false)

    local simTime = ac.getSim().time or 0
    local lap = aiCar and aiCar.lapCount or 0
    local speed = aiCar and aiCar.speedKmh or 0
    local message = string.format(
        "CVR_AI_LOG [%7.2fs] %s | lap=%s | speed=%.1f km/h | %s%s",
        simTime / 1000,
        getCarLabel(),
        tostring(lap),
        speed,
        event,
        details and (" | " .. details) or "")

    ac.log(message)
    ac.debug("CVR_AI_LOG " .. tostring(aiCar and aiCar.index or "?"), event)
end

local function debugAIState()
    if not aiIssueDebugOutputsEnabled then
        return
    end

    ac.debug("AI issues mode", aiMechanicalIssuesMode)
    ac.debug("AI issue car " .. tostring(aiCar.index), aiState.active and (aiState.kind or "active") or "none")
    ac.debug("AI issue DNF " .. tostring(aiCar.index), aiState.dnf)
    ac.debug("AI issue pit " .. tostring(aiCar.index), aiState.pitRequested)
end

local function randomRateHit(rate)
    rate = math.floor(tonumber(rate) or 0)
    return rate > 0 and math.random(1, rate) == 1
end

local function rollAnyRate(rates)
    for i = 1, #rates do
        if randomRateHit(rates[i]) then
            return true
        end
    end
    return false
end

local function sessionIsActive()
    local sim = ac.getSim()
    return not sim.isInMainMenu and not sim.isPaused and sim.isSessionStarted
end

local function resetAIControls()
    ac.setAIPitStopRequest(false)
end

local function resetAIState()
    resetAIControls()
    aiState.timer = 0
    aiState.active = false
    aiState.kind = nil
    aiState.dnf = false
    aiState.pitRequested = false
    aiState.issueDistanceKm = aiCar.distanceDrivenSessionKm or 0
    aiState.repairTimer = 0
    aiState.slowMultiplier = 1
    aiState.roadsideRepair = false
    aiState.stopLogged = false
end

local function startIssue(kind)
    aiState.active = true
    aiState.kind = kind
    aiState.dnf = false
    aiState.pitRequested = false
    aiState.issueDistanceKm = aiCar.distanceDrivenSessionKm or 0
    aiState.repairTimer = 0
    aiState.roadsideRepair = false
    aiState.stopLogged = false
    aiState.slowMultiplier = math.random(
        math.floor(aiIssueSlowdownMultiplierMin * 100 + 0.5),
        math.floor(aiIssueSlowdownMultiplierMax * 100 + 0.5)) / 100
    aiState.side = math.random(0, 1) == 0 and -1 or 1

    if kind == "tyre" then
        aiState.tyre = math.random(0, 3)
        ac.setTyreInflation(aiState.tyre, 0)
    end

    if aiMechanicalIssuesMode >= 3 and math.random(1, 100) <= aiIssueDNFPercent then
        aiState.dnf = true
        aiState.slowMultiplier = math.min(aiState.slowMultiplier, 0.18)
        ac.setAIPitStopRequest(false)
        logAIEvent("DNF issue started", string.format("kind=%s slowdown=%.2f", kind, aiState.slowMultiplier))
    else
        aiState.pitRequested = true
        ac.setAIPitStopRequest(true)
        logAIEvent("Issue started", string.format("kind=%s slowdown=%.2f pit_requested=true", kind, aiState.slowMultiplier))
    end
end

local function rollForNewIssue()
    if aiMechanicalIssuesMode <= 1 or aiState.active or aiCar.isInPitlane or aiCar.isInPit or aiCar.isRaceFinished then
        return
    end

    if randomRateHit(tyrePunctureRateAsphalt) then
        startIssue("tyre")
        return
    end

    local mechanicalRates = {
        sparkPlugFailureRateNominalValue,
        fuelPumpFailureRateNominalValue,
        valveFailureRateNominalValue,
        oilPressureFailureRateNominalValue
    }

    if aiMechanicalIssuesMode >= 3 then
        mechanicalRates[#mechanicalRates + 1] = gearFailureRate
        mechanicalRates[#mechanicalRates + 1] = turboFailureRate
        mechanicalRates[#mechanicalRates + 1] = alternatorFailureRate
    end

    if rollAnyRate(mechanicalRates) then
        startIssue("mechanical")
    end
end

local function applyLimpDriving(dt)
    aiPhys.gas = math.min(aiPhys.gas, aiPhys.gas * aiState.slowMultiplier)

    if aiCar.speedKmh > aiIssueSideRoadMaxSpeedKmh then
        aiPhys.brake = math.max(aiPhys.brake, 0.08)
    else
        local steerAdd = aiIssueSideSteer * aiState.side
        aiPhys.steer = clamp(aiPhys.steer + steerAdd, -0.45, 0.45)
    end
end

local function holdStopped()
    aiPhys.gas = 0
    aiPhys.brake = 1
    aiPhys.handbrake = 1
    ac.setEngineRPM(0)
end

local function completeIssue()
    if aiState.kind == "tyre" then
        ac.setTyreInflation(aiState.tyre, 1)
    end

    logAIEvent("Issue repaired", string.format("kind=%s", tostring(aiState.kind)))

    aiState.active = false
    aiState.kind = nil
    aiState.pitRequested = false
    aiState.roadsideRepair = false
    aiState.repairTimer = 0
    aiState.slowMultiplier = 1
    ac.setAIPitStopRequest(false)
end

local function updatePitRepair(dt)
    if not aiCar.isInPit then
        return false
    end

    holdStopped()
    aiState.repairTimer = aiState.repairTimer + dt

    if not aiState.stopLogged then
        logAIEvent("Pit service started", string.format("kind=%s", tostring(aiState.kind)))
        aiState.stopLogged = true
    end

    if aiState.repairTimer >= aiIssuePitServiceTime then
        completeIssue()
    end

    return true
end

local function updateRoadsideTyreRepair(dt)
    if aiCar.speedKmh > 2 then
        aiPhys.gas = 0
        aiPhys.brake = math.max(aiPhys.brake, 0.45)
        aiPhys.steer = clamp(aiPhys.steer + aiIssueSideSteer * aiState.side, -0.45, 0.45)
        return
    end

    holdStopped()
    aiState.repairTimer = aiState.repairTimer + dt

    if not aiState.stopLogged then
        logAIEvent("Roadside tyre service started", "tyre=" .. tostring(aiState.tyre))
        aiState.stopLogged = true
    end

    if aiState.repairTimer >= aiIssueRoadsideTyreChangeTime then
        completeIssue()
    end
end

local function updateDNF(dt)
    if aiCar.speedKmh > 3 then
        aiPhys.gas = math.min(aiPhys.gas, 0.08)
        aiPhys.brake = math.max(aiPhys.brake, aiCar.speedKmh > 25 and 0.2 or 0.55)
        aiPhys.steer = clamp(aiPhys.steer + aiIssueDNFSteer * aiState.side, -0.65, 0.65)
        return
    end

    holdStopped()
    aiState.repairTimer = aiState.repairTimer + dt

    if not aiState.stopLogged then
        logAIEvent("DNF stopped", string.format("kind=%s", tostring(aiState.kind)))
        aiState.stopLogged = true
    end
end

local function updateActiveIssue(dt)
    if aiState.dnf then
        updateDNF(dt)
        return
    end

    if updatePitRepair(dt) then
        return
    end

    local distanceSinceIssueKm = (aiCar.distanceDrivenSessionKm or aiState.issueDistanceKm) - aiState.issueDistanceKm

    if aiState.kind == "tyre" and not aiState.roadsideRepair and distanceSinceIssueKm >= aiIssuePitSearchDistanceKm then
        aiState.roadsideRepair = true
        ac.setAIPitStopRequest(false)
        logAIEvent("Pit not reached, starting roadside plan", string.format("distance=%.2f km", distanceSinceIssueKm))
    end

    if aiState.roadsideRepair then
        updateRoadsideTyreRepair(dt)
    else
        applyLimpDriving(dt)
    end
end

function initAIFailureSystem(physicsState, carState)
    aiPhys = physicsState
    aiCar = carState
    ac.setLogSilent(false)
    math.randomseed(os.time() + aiCar.index * 977 + math.random(0, 1000))
    resetAIState()
end

function updateAIFailureSystem(dt)
    if aiMechanicalIssuesMode <= 1 then
        resetAIControls()
        return
    end

    if not aiStartupLogged then
        logAIEvent("AI failure logging active", string.format(
            "mode=%s dnf_percent=%s",
            tostring(aiMechanicalIssuesMode),
            tostring(aiIssueDNFPercent)))
        aiStartupLogged = true
    end

    ac.setLogSilent(false)

    debugAIState()

    if dt < 0.0001 or not sessionIsActive() then
        return
    end

    if aiCar.justJumped then
        if aiState.active then
            logAIEvent("AI car jumped while issue active", string.format(
                "kind=%s dnf=%s",
                tostring(aiState.kind),
                tostring(aiState.dnf)))
        end
        resetAIState()
        return
    end

    aiState.timer = aiState.timer + dt
    if aiState.timer >= aiIssueRollInterval then
        rollForNewIssue()
        aiState.timer = 0
    end

    if aiState.active then
        updateActiveIssue(dt)
    end
end

function resetAIFailureSystem()
    resetAIState()
end
