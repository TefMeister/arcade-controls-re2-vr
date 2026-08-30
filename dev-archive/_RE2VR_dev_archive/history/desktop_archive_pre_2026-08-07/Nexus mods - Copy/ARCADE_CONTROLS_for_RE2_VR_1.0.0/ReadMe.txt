WHAT IS THIS MOD YOU ASK?

IT USES 90% OF ANDYALPA'S "RE2VRMODRELOADED" MOD AND ONLY REPLACES THE SOMEWHAT WIP'ISH FEELING BITS, ALSO REWORKS SOME OF THE CONTROLS AND MOVEMENT USED IN-GAME.


changes and key binds compared to RE2VRMODRELOADED :

- minigun, spark shot, anti tank rocket, chemical flamethrower are in the 4th holster, moved to the top center of HMD about 27 cm upwards (only tested the flamethrower though)
- other 3 holsters are still chest, right shoulder, right hip
- RG held suppresses LG and LT, so that the sub weapon or flashlight doesn't get equipped by accident
- LG held suppresses LT
- LG + RG can be used to throw grenades, LG + RT just drops it at your feet
- LT equips/unequips the flashlight, enabled by default
- camera light is also enabled by default, meant to be used with the VR light mod. you can disable it in the reframework menu under FirstPerson, General Settings and tick "Disable camera light"
- to finish manual reload on handguns and pull the pistol slider after inserting the mag, hold LG to put your hand on the slider and press LT to pull it back, let go of LT to release the slider
- RG + LG to 2-hand the shotgun, then LT to pull the pump handle down, release LT to push it up. works only if no live round is in the chamber. also shotgun has to have ammo in it.
- movement speed when RG is held (weapon ready to fire) is increased by 30%
- weapon selection moved to : RThumb + LS up, down, left, right
- sub weapon selection : LG + RThumb + LS up, left, right

installation : 

1. install praydog's reframework. I use MrSurviv0r's hub to do that because he's normally got all the latest versions and stuff, so I don't have to worry about getting the right version from GitHub and so on.
https://mrsurvivor-installers.com/

2. then install this mod with either fluffy 5000 (just make sure you choose re2 and RE-READ GAME ARCHIVES first, then install) or get these 3 from the zip file : reframework folder,_interaction_profiles_oculus_touch_controller.json and re2_fw_config.txt and put them into your game's root folder, overwrite everything when prompted to do so.
https://www.nexusmods.com/residentevil22019/mods/119

3. start the game in vr, open reframework in-game overlay with Insert key, you'll have to do this on your monitor using your mouse(OpenXR) or point right controller at your left controller(SteamVR), find ScriptRunner and click Reset scripts. otherwise some things like the flashlight key binding to LT and weapon selection with RThumb won't kick in and it will interfere with other key bindings.

4. it is save game friendly, but sometimes things need to be "reset" to start working properly, when loading in to an existing save. for example, if you got a shotgun equipped, but the right shoulder holster doesn't work or something similar, then simply go to inventory and unequip, then equip your weapon again and it's fixed, sort of thing.


this mod was created using Claude code, proper hands on "check if it works after every little change", not just have ai work unchecked while I watch Netflix or something. but still, ai made all the changes to the actual code, I just had the ideas and tested things step by step.


other mods that work well in vr (not all mods are available for both RT and DX11 versions, so do check first depending on what version of the game you got installed, I use RT version of the game with DLSS upscaler) :

lot of info about everything RE in virtual reality
https://www.biohazardvr.com/

if you're gonna use the HD texture pack, install that first, other stuff might need to overwrite it if using other mods
https://www.nexusmods.com/residentevil22019/mods/1115
HD Texture Pack (Ray Tracing Version)

https://www.nexusmods.com/residentevil22019/mods/2483
RE2VRMODRELOADED

https://www.nexusmods.com/residentevil22019/mods/2526
Peaceful Mr. X

https://www.nexusmods.com/residentevil22019/mods/2478
Peaceful Enemies Collection (RT and Non-RT) - I just use the dogs, really don't wanna kill dogs, even zombie dogs

https://www.nexusmods.com/residentevil22019/mods/2493
VR Light

https://www.nexusmods.com/residentevil22019/mods/2240
Fix for Route A-B RT - I have not played through it all yet, but so far no issues

https://www.nexusmods.com/residentevil22019/mods/2480
VR Hands (RT and Non-RT)

https://www.nexusmods.com/residentevil22019/mods/2522
No Ammo Counter - VR

https://www.nexusmods.com/residentevil22019/mods/935
On-Screen Blood Remover

https://www.nexusmods.com/residentevil22019/mods/2301
No Yellow Crap Everywhere RE2R

https://www.nexusmods.com/residentevil22019/mods/977
Oculus Touch Button Prompts for RE2VR (works with RT version of the game, even though Fluffy manager gives a warning)


so far the reload finalizing action (RG + LG + LT) works only for matilda, lightning hawk and W-870

if you do like how it plays in vr and want to support future projects like this (RE3 is next after this one here is fully done), then please donate to Andyalpa on KoFi https://ko-fi.com/andyalpa or here on Nexus Mods, as this fork of his mod would not exist without him creating the foundation for it.