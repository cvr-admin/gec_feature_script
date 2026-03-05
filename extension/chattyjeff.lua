--CHATTY CODRIVER by SLIGHTLYMADESTUDIOS
--version 0.5
--youregoingtobrazil.eu - tunarisgame.com
--description:
--built to work along the HISTORIC DAMAGE script by SLIGHTLYMADE
--your codrivers fixin a HOLLER!!!!! useful especially for VR users who dont want on screen bits popping up

--CONFIGURATION
isJeffReal = true --do you want jeff hollerin at u
soundBankPath = "./sfx/jeff.bank"
soundBankGUIDS = "./sfx/GUIDs.txt"
soundBankAudioEventPrefix = "event:/jeff/"
jeffVolumeAdd = 9.0 --add some volume to jeff, if you are having a hard time hearin em. this setting depends on soundbank

if isJeffReal == false then
--if you dont want jeff then this will prevent the script from resolving.
return nil
end


--READ ONLY

local audioConnection = ac.connect{
ac.StructItem.key("audioBits"),
clipName = ac.StructItem.string(40),
}
ac.loadSoundbank(soundBankPath, soundBankGUIDS)
local codriverSound = ac.AudioEvent(soundBankAudioEventPrefix .. "none", true)--if you get an error then maybe swap this into any available sound clip
local currentSoundFxName = "none"

function script.update(dt)
audioRoutineHandler()

--ac.debug("sneed", audioConnection.clipName)
--ac.debug("sneed2", codriverSound.volume)
end

function audioRoutineHandler()
--load new soundfx if there is one
if currentSoundFxName ~= audioConnection.clipName then
codriverSound = ac.AudioEvent(soundBankAudioEventPrefix .. audioConnection.clipName, true)
currentSoundFxName = audioConnection.clipName
end

codriverSound.volume = ac.getAudioVolume('main') + jeffVolumeAdd
codriverSound:resumeIf(audioConnection.clipName ~= "none")
codriverSound:setPosition(vec3(0, 0, 0))
end
