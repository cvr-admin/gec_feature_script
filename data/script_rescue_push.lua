-- Rescue push: gives a nearly stationary car a short assisted shove.
--
-- Extra P starts the push. Direction is forward by default, backward in
-- reverse, right in 2nd gear, and left in 3rd gear.

local M = {}

local data = nil
local carState = nil

local RESCUE_DURATION = 1.0
local MAX_SPEED_KMH = 1.0
local LIFT_FORCE_N = 3000
local PUSH_FORCE_N = 3500
local LEVEL_FORCE_N = 1200
local STEER_YAW_N = 0
local ANGULAR_DAMP_N = 400
local LINEAR_DAMP_N = 250
local REARM_SEC = 1.0
local ENABLE_PUSH_LATERAL = true
local CAR_MASS_KG = 750

local ptLeft = vec3(-0.6, 0, 0)
local ptRight = vec3(0.6, 0, 0)
local ptCenter = vec3(0, 0.15, 0)
local ptFL = vec3(-0.7, 0, 0)
local ptFR = vec3(0.7, 0, 0)
local ptFront = vec3(0, 0, 1.0)
local ptRear = vec3(0, 0, -1.0)
local ptYawF = vec3(0, 0, 1)
local ptYawR = vec3(0, 0, -1)
local ptDamp = vec3(0, 0.1, 0)

local fv = vec3()

local active = false
local timer = 0
local rearm = 0
local massFactor = 1.0

local function smoothstep(t)
    if t < 0 then
        t = 0
    elseif t > 1 then
        t = 1
    end
    return t * t * (3 - 2 * t)
end

local function refreshCarState()
    carState = car or ac.getCar(0)
end

local function queueRescueMessage(title, message, duration, force)
    if overheadMessageQueue then
        overheadMessageQueue(title, message, duration, force)
    end
end

local function logRescue(message)
    if logDebug then
        logDebug(message)
    end
end

local function beginRescue()
    if data.speedKmh > MAX_SPEED_KMH then
        queueRescueMessage("Rescue Push", "Car must be nearly stationary", 2, true)
        return false
    end

    active = true
    timer = RESCUE_DURATION
    logRescue("Car is being pushed.")
    return true
end

local function currentConventionalGear()
    refreshCarState()
    if carState and carState.gear ~= nil then
        return carState.gear
    end

    -- ac.accessCarPhysics() uses 0=reverse, 1=neutral, 2=first.
    if data and data.gear ~= nil then
        return data.gear - 1
    end

    return 0
end

local function applyRescue(dt)
    if not active then return end

    timer = timer - dt
    if timer <= 0 then
        active = false
        rearm = REARM_SEC
        return
    end

    ac.awakeCarPhysics()

    local fade = smoothstep(timer / RESCUE_DURATION) * massFactor

    local lift = LIFT_FORCE_N * fade
    fv:set(0, lift, 0)
    ac.addForce(ptLeft, true, fv, false)
    fv:set(0, lift, 0)
    ac.addForce(ptRight, true, fv, false)

    local push = PUSH_FORCE_N * fade
    local dx, dz
    local gear = currentConventionalGear()
    if gear == 2 and ENABLE_PUSH_LATERAL then
        dx, dz = data.side.x, data.side.z
    elseif gear == 3 and ENABLE_PUSH_LATERAL then
        dx, dz = -data.side.x, -data.side.z
    else
        local dir = (gear < 0) and -1 or 1
        dx, dz = data.look.x * dir, data.look.z * dir
    end

    local hLen = math.sqrt(dx * dx + dz * dz)
    if hLen > 0.001 then
        local invH = push / hLen
        fv:set(dx * invH, 0, dz * invH)
        ac.addForce(ptCenter, true, fv, false)
    end

    local steerF = data.steer * STEER_YAW_N * fade
    fv:set(steerF, 0, 0)
    ac.addForce(ptYawF, true, fv, true)
    fv:set(-steerF, 0, 0)
    ac.addForce(ptYawR, true, fv, true)

    local lev = LEVEL_FORCE_N * fade
    local rollErr = data.up.x * lev
    fv:set(0, -rollErr, 0)
    ac.addForce(ptFL, true, fv, false)
    fv:set(0, rollErr, 0)
    ac.addForce(ptFR, true, fv, false)

    local pitchErr = data.up.z * lev * 0.5
    fv:set(0, -pitchErr, 0)
    ac.addForce(ptFront, true, fv, false)
    fv:set(0, pitchErr, 0)
    ac.addForce(ptRear, true, fv, false)

    local aD = ANGULAR_DAMP_N * fade
    local yawRate = data.localAngularVelocity.y
    fv:set(-yawRate * aD, 0, 0)
    ac.addForce(ptYawF, true, fv, true)
    fv:set(yawRate * aD, 0, 0)
    ac.addForce(ptYawR, true, fv, true)

    local lD = LINEAR_DAMP_N * fade
    fv:set(-data.localVelocity.x * lD, 0, -data.localVelocity.z * lD * 0.3)
    ac.addForce(ptDamp, true, fv, true)
end

function M.init(carPhysics)
    data = carPhysics
    refreshCarState()
    local carIni = ac.INIConfig.carData(0, 'car.ini')
    massFactor = (carIni:get('BASIC', 'TOTALMASS', CAR_MASS_KG)) / CAR_MASS_KG
end

function M.update(dt)
    if not data then return end

    if rearm > 0 then
        rearm = rearm - dt
    end

    refreshCarState()
    if carState and carState.extraP and not active and rearm <= 0 then
        beginRescue()
    end

    applyRescue(dt)
end

function M.reset()
    active = false
    timer = 0
    rearm = 0
end

return M
