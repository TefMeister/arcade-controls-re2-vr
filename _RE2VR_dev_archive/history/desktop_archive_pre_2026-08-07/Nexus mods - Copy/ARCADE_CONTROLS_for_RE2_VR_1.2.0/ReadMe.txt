UPDATE v1.2.0 :

- shotgun pump handle can now be racked freely at any time, empty gun or a live round chambered, doesn't matter. it's just for feel/fidgeting now, won't waste or eject a round unless the game actually needs you to cycle it (used to only work in the exact right ammo state)
- leon's holster reach tweaked: hip and shoulder pushed further out, and the chest holster relocated to sit low on his left hip instead, so it doesn't swing into RG's reach anymore when turning your head to look right
- fixed a couple of Ada-specific tuning values (mag reload range, ammo pouch position) that were saved correctly in-game but weren't actually baked into the mod's shipped defaults


UPDATE v1.1.0 :

Ada's chapter got a full VR pass:
- added trigger-driven slide rack (LG + hold LT to pull, release LT to finish) for her Broom Hc handgun, same as Matilda/Lightning Hawk
- tuned the mag insertion range and the ammo pouch reach position for her specifically, since her handgun/mag models are smaller than the other characters'
- the EMF Visualizer (her hacking device) can now be holstered on the right shoulder, same reach-to-draw/stow mechanic as Leon's shotgun (RG still activates it, same as before, that part is unchanged)


UPDATE v1.0.1 :

fixed a bug where several VR inputs (including the LT flashlight toggle) could fail to register on a fresh game launch, needing a Reset Scripts click in the REFramework overlay before they'd work. should just work straight away now, no workaround needed.


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
- RG + LG to 2-hand the shotgun, then LT to pull the pump handle down, release LT to push it up. works any time now, live round chambered or completely empty, doesn't matter - only actually cycles/ejects a shell when the game needs it to, otherwise it's just for feel
- movement speed when RG is held (weapon ready to fire) is increased by 30%
- weapon selection moved to : RThumb + LS up, down, left, right
- sub weapon selection : LG + RThumb + LS up, left, right
- Ada's spy gun thingie can be holstered in the right shoulder spot

installation : 

1. install praydog's reframework. I use MrSurviv0r's hub to do that because he's normally got all the latest versions and stuff, so I don't have to worry about getting the right version from GitHub and so on.
https://mrsurvivor-installers.com/

2. then install this mod with either fluffy 5000 (just make sure you choose re2 and RE-READ GAME ARCHIVES first, then install) or get these 3 from the zip file : reframework folder,_interaction_profiles_oculus_touch_controller.json and re2_fw_config.txt and put them into your game's root folder, overwrite everything when prompted to do so.
https://www.nexusmods.com/residentevil22019/mods/119

3. it is save game friendly, but sometimes things need to be "reset" to start working properly, when loading in to an existing save (what i mean is a save game from before any mods or reframework were installed). for example, if you got a shotgun equipped, but the right shoulder holster doesn't work or something similar, then simply go to inventory and unequip, then equip your weapon again and it's fixed, sort of thing.


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