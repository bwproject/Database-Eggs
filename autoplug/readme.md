# ProjectBW AutoPlug Egg

Based on [ImLunaUwU/PteroPlug](https://github.com/ImLunaUwU/PteroPlug).

## Main change

The original PteroPlug egg uses the panel's `config.files` mechanism to rewrite `autoplug/general.yml` and `autoplug/updater.yml` from environment variables during startup.

This version removes that mechanism completely.

### New behavior

- AutoPlug configuration is generated during installation/reinstallation.
- `SERVER_KEY`, `SERVER_TYPE`, `GAME_VERSION` and `JAVA_ARGS` are written once during installation.
- Normal server start/restart only starts `AutoPlug-Client.jar`.
- Existing AutoPlug configuration is not overwritten on every start.
- If an egg variable is changed later, reinstall the server/egg to regenerate the configuration.

## Files

- `egg-auto-plug-minecraft.json` — Pelican/Pterodactyl egg.
- `general.yml` — AutoPlug general configuration.
- `updater.yml` — AutoPlug updater configuration.
- `start.sh` — compatibility start script.
