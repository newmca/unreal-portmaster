## Notes

Thanks to Epic MegaGames, Digital Extremes and Legend Entertainment for Unreal and Return to Na Pali, and to the [OldUnreal](https://www.oldunreal.com) team, whose 227 patch keeps the game running on today's systems, ARM64 Linux included.

On the first start the port asks you to agree to the [Epic Games Terms of Service](https://legal.epicgames.com/en-US/epicgames/tos), then downloads Unreal Gold and the [OldUnreal 227k_15 patch](https://github.com/OldUnreal/Unreal-testing/releases/tag/v227k_15) (770 MiB) from OldUnreal and installs them. This needs Wi-Fi and about 1.3 GB of free space, and takes 5 to 15 minutes. Without Wi-Fi, copy `UNREAL_GOLD.ISO` and `OldUnreal-UnrealPatch227k-Linux.tar.bz2` into `ports/unreal/` first.

Keep the default menu: the "Classic Menu" option doesn't scale well on small screens.

The New Game list also holds these community campaigns, which ship with the port. "[UT]" marks a campaign made for Unreal Tournament; its levels take a bit longer to load.

- **Unreal: Return to Na Pali (Ultimate)**: compiled by Lightning Hunter, with levels by Nivlek, Juan Pancho Eekels, Eenocks and Jeremy War next to Legend's originals by Cliff Bleszinski, Matthias Worch and Shane Caudle.
- **Unreal: Steele Dawn**: a cancelled expansion recovered by Leo (T.C.K.), turned into a campaign by Delacroix and finished by Yrex, with levels by Nick "Zarzoo" Parde, Emil "Doze" Gustavsson, Crista Forest, Steve Farrow, Myscha, Neil Munday, Jeffrey "Capp" Miner, Ryan Isenberg and Jim Semkiw.
- **Attacked**: Kevin "Waffnuffly" Letz.
- **Hard Crash**: Silver Serpent (Xer06siX).
- **One Day in the Life of...**: Chris Burgess.
- **Operation: Na Pali** (and its tutorial): Team Vortex, led by David "DavidM" Münnich, with levels by James "eVOLVE" Hamer-Morton, Arjan "Atje" Vroegop, Hyperion, Heiko "sm0k3r" Dreyer, Sjoerd "Hourences" De Jong, Paul "Tonnberry" Fahss, Silver Serpent, Jannis "DrPest" Borgers, Daniel "MClane" Pflugbeil, El Chicoverde, Tim "Kew" Jervis, Florian "Strogg" Oswald and Juan Pancho Eekels, and code by UsAaR33.
- **Project Zephon: Battle for Freedom**: Derdak2rot, with Tobby "Carthage" Ong, WhirlWindWabbit, Kimmo "Cardi" Kontto, L.J. Paranoid, milb and NR.2000.
- **The Fifth Vortex - Ehactora's Story**: Rob "Doublez-Down" Collins and Teridax, with Eenocks, Nivlek, Shane Caudle and Jeremy War.
- **The Illhaven Saga**: Tim "Kew" Jervis.
- **Unreal Forgotten**: Andrew "Sinistral" Allison.
- **Xidia: The Incident** and **Xidia: The Escape**: Will "Mr.Prophet" Drekker, with Sjoerd "Hourences" De Jong.
- **Xidia - Na Pali Haven (Redux)**: Mr.Prophet, remixing Jeremy War's original.
- **Xidia - Seven Bullets**: Team Red Nemesis: Mr.Prophet, Myscha, Darth Weasel, Juan Pancho Eekels, Waffnuffly and Eightball Maniac.

The campaigns run on code by UsAaR33 (OldSkool Amp'd), Masterkent (Botpack227, UMapMod), Mychaeel (ONPSPFix), Hugh Macdonald, Yoda and Stephen "Nemesis" Deaver (Unreal Movie System), Beppo (InfAdds), Asgard (u2rtnp) and Krull (EntryII, the level behind the menus).

The renderer descends from fgsfds' UE1 renderer (with BSzili and Rinnegatamante), Maxim Kaxd's [ut99dc](https://github.com/maximqaxd/ut99dc) and Andiweli's [UT99-Android](https://github.com/Andiweli/UT99-Android), by way of ToastedFrog's PortMaster Unreal Tournament '99 port. The SDL3-over-SDL2 backend is by bmdhacks, and the glibc conversion modules come from cizia64's [CrossMix-OS](https://github.com/cizia64/CrossMix-OS).

## Controls

Every button sends a key, as in the Unreal Tournament '99 port. The digits stay free for mods with keypad doors (Operation: Na Pali, Xidia), so weapons are switched with L1 and L2. The bindings are in `conf/User.ini`.

| Button | Key | Action |
|--|--|--|
| Left stick | Arrow keys | Move / strafe |
| Right stick | Mouse | Aim; moves the cursor in menus |
| R1 / R2 | Left / right mouse button | Fire / alternate fire; R1 clicks in menus |
| L1 / L2 | Mouse wheel down / up | Next / previous weapon |
| A | 8 | Jump |
| B | 7 | Crouch |
| X | 5 | Use the selected inventory item |
| Y | 6 | Reload the Automag or CAR (Seven Bullets) |
| D-pad up | 1 | Quick save |
| D-pad down | 3 | Quick load |
| D-pad left / right | 2 / 4 | Previous / next inventory item |
| L3 | 9 | Ask bots to guard a spot (Operation: Na Pali) |
| R3 | 0 | Ask bots to follow you (Operation: Na Pali) |
| Start | Escape | Menu |
| Select | Enter | Universal Translator; Enter in menus |

Select opens the translator once you have picked it up in Vortex Rikers.

## Compile

The patches and build scripts are in [newmca/unreal-portmaster](https://github.com/newmca/unreal-portmaster) under `source/`. With podman installed:

```
git clone https://github.com/newmca/unreal-portmaster.git
cd unreal-portmaster
source/build_all.sh --no-assemble
```

This builds `libSDL3.so.0` (bmdhacks' SDL3 with an SDL2 backend), `SDLDrv.so` and `NOpenGLESDrv.so` against the OldUnreal 227k_15 SDK in an Ubuntu 22.04 container, and stages them in `~/.cache/unrealgold-port/build/overlay/SystemARM64`. `source/BUILD.md` lists the pinned inputs and the steps.
