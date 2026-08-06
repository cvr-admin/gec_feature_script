require("car_parameters")

local P = ac.getCarPhysics(0)

local function clamp(value, minimumValue, maximumValue)
    return math.max(minimumValue, math.min(maximumValue, value))
end

local radiatorSmoke = {}
radiatorSmoke["color"] = rgbm(0.9, 0.9, 0.9, 0.5) --color
radiatorSmoke["colorConsistency"] = 1.0 --how fast smoke loses color as it dissipates. 0-1
radiatorSmoke["thickness"] = 0.2  --smoke strength. 0-1
radiatorSmoke["life"] = 1.1 --smoke particle lifespan in seconds
radiatorSmoke["size"] = 0.01 --particle spawn size
radiatorSmoke["spreadK"] = 2.0 --randomness factor for speed and direction (affects other variables slightly)
radiatorSmoke["growK"] = 0.01 --how fast smoke spreads/expands
radiatorSmoke["targetYVelocity"] = 0.5 --smoke "temperature". 1 makes smoke rise, -1 makes smoke go down
radiatorSmokeStrength = 0.5 --emitter "amount" variable. higher value will make more smoke

local radiatorSmokeEmitter = ac.Particles.Smoke(radiatorSmoke)
--create emitter object
local COOLING_SYSTEM_RADIATOR = 1

local function radiatorDamage()
    if P.scriptControllerInputs[73] == COOLING_SYSTEM_RADIATOR and P.scriptControllerInputs[0] > 90 then
    --if car.damage[4] > 50 then
        local emitterOffset = car.localVelocity * 0.01
        --offset value for emitter positions, as emitters lag behind.
        radiatorSmokeEmitter:emit(
            vec3(radiatorSteamPosLeftRight, radiatorSteamPosHeight, radiatorSteamPosDistance) + emitterOffset,
            vec3(0.0,0.1,0.0),
            0.1
        )
    end
end

local turboExplSmoke = {}
turboExplSmoke["color"] = rgbm(0.714, 0.714, 1.0, 1.0) --color
turboExplSmoke["colorConsistency"] = 1.0 --how fast smoke loses color as it dissipates. 0-1
turboExplSmoke["thickness"] = 1  --smoke strength. 0-1
turboExplSmoke["life"] = 15.1 --smoke particle lifespan in seconds
turboExplSmoke["size"] = 0.01 --particle spawn size
turboExplSmoke["spreadK"] = 2.0 --randomness factor for speed and direction (affects other variables slightly)
turboExplSmoke["growK"] = 0.01 --how fast smoke spreads/expands
turboExplSmoke["targetYVelocity"] = 0.5 --smoke "temperature". 1 makes smoke rise, -1 makes smoke go down
turboExplSmokeStrength = 150.5 --emitter "amount" variable. higher value will make more smoke

local turboExplSmokeEmitter = ac.Particles.Smoke(turboExplSmoke)
--create emitter object

local engineFireFlame = ac.Particles.Flame({
    color = rgbm(1.0, 0.62, 0.22, 1.0),
    size = 0.45,
    temperatureMultiplier = 0.85,
    flameIntensity = 1.4
})

local engineFireSmoke = {}
engineFireSmoke["color"] = rgbm(0.08, 0.07, 0.06, 0.75)
engineFireSmoke["colorConsistency"] = 0.65
engineFireSmoke["thickness"] = 0.75
engineFireSmoke["life"] = 4.5
engineFireSmoke["size"] = 0.08
engineFireSmoke["spreadK"] = 2.5
engineFireSmoke["growK"] = 0.08
engineFireSmoke["targetYVelocity"] = 1.0

local engineFireSmokeEmitter = ac.Particles.Smoke(engineFireSmoke)

local soundExplosion = ui.MediaPlayer()
soundExplosion:setSource("./sfx/explosion.mp3"):setAutoPlay(false)

local prevInput = 0
local prevEngineFireInput = 0
local soundDuration = 1
local soundTimer = soundDuration
local engineFireSoundTimer = soundDuration

local function turboExplosionDamage(dt)
    if P.scriptControllerInputs[25] == 1 then
        local emitterOffset = car.localVelocity * 0.01
        --offset value for emitter positions, as emitters lag behind.
        turboExplSmokeEmitter:emit(
            vec3(turboSmokePosLeftRight, turboSmokePosHeight, turboSmokePosDistance) + emitterOffset,
            vec3(0.0,0.1,0.0),
            0.1
        )

        -- Only play sound once.
        if prevInput == 0 then
            soundTimer = 0
        end
    end

    if soundTimer < soundDuration then
        soundExplosion:play()
        soundTimer = soundTimer + dt
    end

    prevInput = P.scriptControllerInputs[25]
end

local function engineCrashFire(dt)
    local fireInput = P.scriptControllerInputs[80] or 0
    local fireIntensity = math.max(P.scriptControllerInputs[81] or 0, 0)
    local fireLifeRemaining = clamp(P.scriptControllerInputs[82] or 0, 0, 1)

    if fireInput > 0 and fireIntensity > 0 then
        local emitterOffset = car.localVelocity * 0.01
        local enginePosition = vec3(turboSmokePosLeftRight, turboSmokePosHeight, turboSmokePosDistance) + emitterOffset
        local burstPhase = clamp((fireLifeRemaining - 0.72) / 0.28, 0, 1)
        local sustainedPhase = clamp(fireLifeRemaining / 0.72, 0, 1)
        local visualScale = 0.25 + sustainedPhase * 0.75 + burstPhase * 2.2
        local sideFlicker = (math.random() - 0.5) * (0.45 + burstPhase * 0.9)
        local lengthFlicker = (math.random() - 0.5) * (0.30 + burstPhase * 0.7)
        local flameVelocity = vec3(sideFlicker, 0.75 + fireIntensity * (0.55 + visualScale * 0.35), lengthFlicker) - car.localVelocity * 0.015
        local smokeVelocity = vec3(sideFlicker * 0.4, 0.8 + visualScale * 0.25, lengthFlicker * 0.4) - car.localVelocity * 0.01

        engineFireFlame.size = 0.35 + visualScale * 0.22
        engineFireFlame.flameIntensity = 0.65 + visualScale * 1.15

        engineFireFlame:emit(enginePosition + vec3(sideFlicker * 0.12, 0, lengthFlicker * 0.12), flameVelocity, 0.16 * fireIntensity * visualScale)
        engineFireSmokeEmitter:emit(enginePosition + vec3(0, 0.1, 0), smokeVelocity, 0.13 * fireIntensity * (0.6 + visualScale * 0.55))

        if prevEngineFireInput == 0 then
            engineFireSoundTimer = 0
        end
    end

    if engineFireSoundTimer < soundDuration then
        soundExplosion:play()
        engineFireSoundTimer = engineFireSoundTimer + dt
    end

    prevEngineFireInput = fireInput
end

function script.update(dt)
    radiatorDamage()
    turboExplosionDamage(dt)
    engineCrashFire(dt)
end
