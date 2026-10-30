-- App version. `build` is compared against GitHub release tags ("+N") by
-- the updater; the LÖVE port numbers its builds independently of Flutter's,
-- so it must publish to its own repo (the Flutter repo's build numbers
-- would always look newer).
return {
  name = "0.2.0",
  build = 26,
  -- src/platform/updater.lua: where releases are published, the zip asset
  -- each release must carry, and the executable inside it.
  releaseRepo = "jvthompson/cardtable",
  releaseAssetName = "cardtable-windows.zip",
  exeName = "CardTable.exe",
}
