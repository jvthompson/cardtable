-- Ports of game_loader_test, image_path_resolver_test,
-- game_definition_file_ops_test, save_game_file_ops_test and
-- game_log_file_ops_test, plus deck library / migration / avatar coverage.
local json = require("lib.json")
local fs = require("src.data.fs")
local models = require("src.core.models")
local util = require("src.core.util")
local loader = require("src.data.game_loader")
local resolver = require("src.data.image_resolver")
local decks = require("src.data.deck_library")
local saves = require("src.data.save_files")
local ops = require("src.data.gamedef_ops")
local imageUtils = require("src.data.image_utils")
local profile = require("src.data.profile")
local handSettings = require("src.data.hand_settings")
local settings = require("src.data.settings")
local tableSettings = require("src.data.table_settings")
local H = require("tests.helpers")

return function(t)
  local counter = 0
  -- Fresh scratch folder (with a non-ASCII name, to keep wide-path I/O honest).
  local function tempDir()
    counter = counter + 1
    love.filesystem.createDirectory("test_tmp")
    local dir = fs.join(love.filesystem.getSaveDirectory(), "test_tmp", "dé" .. counter)
    fs.removeTree(dir)
    fs.mkdirs(dir)
    return dir
  end
  local function write(path, value)
    fs.mkdirs(fs.dirname(path))
    fs.writeFile(path, type(value) == "string" and value or json.encode(value))
  end
  local function png(w, h, path)
    local d = love.image.newImageData(w, h)
    d:setPixel(0, 0, 1, 0, 0, 1) -- red top-left marker
    write(path, imageUtils.encodePng(d))
  end

  t.describe("game loader", function()
    t.it("loadStandardDeck loads all 52 cards", function()
      local g = loader.loadStandardDeck()
      t.eq(g.id, "standard_52")
      t.ok(#g.cards >= 52)
    end)
    t.it("finds gamedef.json case-insensitively, ignoring stray files", function()
      local dir = tempDir()
      write(fs.join(dir, "GameDef.JSON"), { id = "my_game", name = "My", cards = { { id = "c1", cardTitle = "One" } } })
      write(fs.join(dir, "notes.txt"), "not a game")
      write(fs.join(dir, "My Deck.json"), { id = "other", name = "O", cards = {} })
      local games = loader.loadFromFolder(dir)
      t.eq(#games, 1)
      t.eq(games[1].id, "my_game")
      t.eq(games[1].folderPath, dir)
    end)
    t.it("resolves card/back/set image paths", function()
      local dir = tempDir()
      write(fs.join(dir, "gamedef.json"), '{"id":"g","name":"G","cardBacks":[{"id":"d","name":"D","imagePath":"back.png"}],'
        .. '"sets":[{"id":"core","name":"Core","cards":[{"id":"a","cardTitle":"A","imagePath":"a.jpg"}]}]}')
      local g = loader.loadFromFolder(dir)[1]
      t.eq(g.cards[1].imagePath, fs.join(dir, "core", "a.jpg"))
      t.eq(g.cards[1].setId, "core")
      t.eq(g.cardBacks[1].imagePath, fs.join(dir, "back.png"))
    end)
    t.it("skips invalid files, reports them, and handles a missing folder", function()
      local dir = tempDir()
      write(fs.join(dir, "gamedef.json"), "{not json")
      local games, errors = loader.loadFromFolder(dir)
      t.eq(#games, 0)
      t.eq(#errors, 1)
      t.eq(#loader.loadFromFolder(fs.join(dir, "missing")), 0)
    end)
    t.it("resolveGameImagePaths keeps hasScenarios/scenarios (play-ready game copies don't lose them)", function()
      local dir = tempDir()
      write(fs.join(dir, "gamedef.json"), '{"id":"g","name":"G","cards":[],"hasScenarios":true,'
        .. '"scenarios":[{"id":"scen1","name":"Opening","zones":[{"id":"z1","name":"Battlefield","shared":true}]}]}')
      local g = loader.loadFromFolder(dir)[1]
      t.ok(g.hasScenarios)
      t.eq(#g.scenarios, 1)
      t.eq(g.scenarios[1].zones[1].id, "z1")
    end)
    t.it("appends standard cards when a zone asks for them; library scans subfolders", function()
      local root = tempDir()
      write(fs.join(root, "g1", "gamedef.json"), { id = "g1", name = "G1", cards = {},
        zones = { { id = "deck", name = "Deck", shared = true, standardDeck = true } } })
      write(fs.join(root, "g2", "gamedef.json"), { id = "g2", name = "G2", cards = {} })
      local lib = loader.loadLibrary(root)
      t.eq(#lib, 3)
      t.eq(lib[3].id, "standard_52")
      local g1 = lib[1].id == "g1" and lib[1] or lib[2]
      t.eq(#g1.cards, 52)
      t.ok(models.GameDefinition.cardById(g1, "__standard52_spades_K"))
    end)
  end)

  t.describe("image resolver", function()
    t.it("bare paths", function()
      t.eq(resolver.resolveBareImagePath("C:\\g", "a.jpg"), fs.join("C:\\g", "a.jpg"))
      t.eq(resolver.resolveBareImagePath("C:\\g", "a.jpg", "s"), fs.join("C:\\g", "s", "a.jpg"))
      t.isNil(resolver.resolvedImagePathForDisplay("C:\\g", nil))
    end)
    t.it("mergeLocalImagePaths", function()
      local remote = models.GameDefinition.new({ id = "g", name = "G",
        cards = { H.cardDef("c1", {}, { imagePath = "C:/host/c1.jpg" }), H.cardDef("c2", {}, { imagePath = "C:/host/c2.jpg" }) },
        cardBacks = { models.CardBackDefinition.new({ id = "d", name = "D", imagePath = "C:/host/b.jpg" }) } })
      local localGame = models.GameDefinition.new({ id = "g", name = "G", folderPath = "C:/client",
        cards = { H.cardDef("c1", {}, { imagePath = "C:/client/c1.jpg" }) },
        cardBacks = { models.CardBackDefinition.new({ id = "d", name = "D", imagePath = "C:/client/b.jpg" }) } })
      local m = resolver.mergeLocalImagePaths(remote, localGame)
      t.eq(m.cards[1].imagePath, "C:/client/c1.jpg")
      t.isNil(m.cards[2].imagePath)
      t.eq(m.cardBacks[1].imagePath, "C:/client/b.jpg")
      t.eq(m.folderPath, "C:/client")
    end)
    t.it("card backs: default, alternate, fallback, empty", function()
      local backs = { models.CardBackDefinition.new({ id = "d", name = "D", imagePath = "d.png" }),
        models.CardBackDefinition.new({ id = "alt", name = "Alt", imagePath = "alt.png", orientation = "left" }) }
      local p, missing, o = resolver.resolveCardBackImagePath(backs, H.cardDef("c"))
      t.eq({ p, missing, o }, { "d.png", false, "portrait" })
      p, missing, o = resolver.resolveCardBackImagePath(backs, H.cardDef("c", {}, { cardBackId = "alt" }))
      t.eq({ p, o }, { "alt.png", "left" })
      p = resolver.resolveCardBackImagePath(backs, H.cardDef("c", {}, { cardBackId = "gone" }))
      t.eq(p, "d.png")
      p, missing, o = resolver.resolveCardBackImagePath({}, H.cardDef("c"))
      t.eq({ p, missing, o }, { nil, false, "portrait" })
    end)
    t.it("unique backs", function()
      local dir = tempDir()
      write(fs.join(dir, "a_BACK.png"), "x")
      resolver.clearCache()
      local card = H.cardDef("a", {}, { imagePath = fs.join(dir, "a.png"), cardBackId = "__unique__", uniqueBackOrientation = "right" })
      local p, missing, o = resolver.resolveCardBackImagePath({}, card)
      t.eq({ p, missing, o }, { fs.join(dir, "a_BACK.png"), false, "right" })
      local noFile = H.cardDef("b", {}, { imagePath = fs.join(dir, "b.png"), cardBackId = "__unique__" })
      t.eq({ resolver.resolveCardBackImagePath({}, noFile) }, { nil, true, "portrait" })
      local noImage = H.cardDef("b", {}, { cardBackId = "__unique__" })
      t.eq(select(2, resolver.resolveCardBackImagePath({}, noImage)), true)
    end)
    t.it("pack generator and logo images", function()
      local dir = tempDir()
      resolver.clearCache()
      t.isNil(resolver.resolvePackGeneratorImagePath(dir))
      t.isNil(resolver.resolvePackGeneratorImagePath(nil))
      write(fs.join(dir, "gamelogo.jpg"), "x")
      write(fs.join(dir, "gamelogo.gif"), "x")
      resolver.clearCache()
      t.eq(resolver.resolveGameLogoImagePath(dir), fs.join(dir, "gamelogo.jpg"))
    end)
  end)

  t.describe("gamedef ops", function()
    t.it("name helpers", function()
      t.eq(ops.basenameOf("C:/a/b/mygame/"), "mygame")
      t.eq(ops.basenameOf("C:\\a/b\\mygame"), "mygame")
      t.eq(ops.stripExtension("a.b.png"), "a.b")
      t.ok(ops.isImageFile("x.JPEG"))
      t.notOk(ops.isImageFile("x.gif"))
      t.notOk(ops.isImageFile("noext"))
      t.eq(ops.uniqueCardId("a", { a = true, a_001 = true }), "a_002")
      t.ok(ops.isSamePath("C:/X/y.png", "c:\\x\\Y.PNG"))
    end)
    t.it("copy helpers and findGameDefFile", function()
      local dir = tempDir()
      write(fs.join(dir, "src", "a.png"), "img")
      write(fs.join(dir, "src", "notes.txt"), "x")
      t.eq(ops.copyPickedImage(fs.join(dir, "src", "a.png"), fs.join(dir, "dest")), "a.png")
      t.eq(fs.readFile(fs.join(dir, "dest", "a.png")), "img")
      ops.copySetImages(fs.join(dir, "src"), fs.join(dir, "set"))
      t.ok(fs.isFile(fs.join(dir, "set", "a.png")))
      t.notOk(fs.exists(fs.join(dir, "set", "notes.txt")))
      t.isNil(ops.findGameDefFile(dir))
      write(fs.join(dir, "GAMEDEF.json"), "{}")
      t.eq(ops.findGameDefFile(dir), fs.join(dir, "GAMEDEF.json"))
    end)
    t.it("rotates landscape PNGs to portrait only when asked", function()
      local dir = tempDir()
      png(40, 20, fs.join(dir, "src", "land.png"))
      png(20, 40, fs.join(dir, "src", "port.png"))
      ops.copySetImages(fs.join(dir, "src"), fs.join(dir, "set"))
      local land = imageUtils.decodeFile(fs.join(dir, "set", "land.png"))
      t.eq({ land:getDimensions() }, { 20, 40 })
      -- Clockwise: the top-left marker ends up at the top-right.
      local r = land:getPixel(19, 0)
      t.eq(r, 1)
      t.eq({ imageUtils.decodeFile(fs.join(dir, "set", "port.png")):getDimensions() }, { 20, 40 })
      ops.copyPickedImage(fs.join(dir, "src", "land.png"), fs.join(dir, "plain"), false)
      t.eq({ imageUtils.decodeFile(fs.join(dir, "plain", "land.png")):getDimensions() }, { 40, 20 })
    end)
    t.it("buildCardsFromImageFolder", function()
      local dir = tempDir()
      for _, n in ipairs({ "b.png", "a.jpg", "a_BACK.jpg", "a.png", "x.txt" }) do write(fs.join(dir, n), "x") end
      local cards = ops.buildCardsFromImageFolder(dir, "core", { "b" })
      t.eq(t.ids(cards, "id"), { "a", "a_001", "b_001" })
      t.eq(cards[2].imagePath, "a.png")
      t.eq(cards[2].cardTitle, "a")
      t.eq(cards[1].setId, "core")
    end)
    t.it("writeGameDefinition writes bare names, pretty-printed", function()
      local dir = tempDir()
      local g = models.GameDefinition.new({ id = "mygame", name = "My Game",
        sets = { models.GameSet.new({ id = "core_set", name = "Core Set" }) },
        cards = { H.cardDef("a", {}, { imagePath = "a.jpg", setId = "core_set" }) },
        cardBacks = { models.CardBackDefinition.new({ id = "default", name = "Default", imagePath = "cardback.jpg" }) } })
      ops.writeGameDefinition(fs.join(dir, "mygame"), g)
      local raw = fs.readFile(fs.join(dir, "mygame", "gamedef.json"))
      t.ok(raw:find('\n  "sets": [', 1, true))
      local back = models.GameDefinition.fromJson(json.decode(raw))
      t.eq(back.cards[1].imagePath, "a.jpg")
      t.eq(back.cardBacks[1].imagePath, "cardback.jpg")
    end)
    t.it("writeGameDefinition/loadGameDefFile round-trips a scenario game with hasScenarios in the raw JSON", function()
      local dir = tempDir()
      local zone = models.ZoneDefinition.new({ id = "z1", name = "Battlefield", shared = true, orientation = "left",
        entries = { models.DeckEntry.new("a", 2) } })
      local placement = models.ScenarioPlacement.new({ definitionId = "a", x = 0.4, y = 0.6, faceUp = false })
      local deck = models.SubDeck.new("boss_deck", { models.DeckEntry.new("a", 1) })
      local scenario = models.Scenario.new({ id = "scen1", name = "Opening", zones = { zone },
        placements = { placement }, decks = { deck } })
      local g = models.GameDefinition.new({ id = "scenariogame", name = "Scenario Game",
        cards = { H.cardDef("a", {}, { imagePath = "a.jpg" }) }, hasScenarios = true, scenarios = { scenario } })
      ops.writeGameDefinition(fs.join(dir, "scenariogame"), g)
      local path = fs.join(dir, "scenariogame", "gamedef.json")
      local raw = fs.readFile(path)
      t.ok(raw:find('"hasScenarios": true', 1, true))
      local back = ops.loadGameDefFile(path, fs.join(dir, "scenariogame"))
      back.folderPath = nil
      t.eq(back, g)
    end)
    t.it("validates game ids", function()
      t.eq(ops.validateGameId(""), "Enter a game ID.")
      t.eq(ops.validateGameId(".."), "Invalid ID.")
      t.ok(ops.validateGameId("a/b"))
      t.ok(ops.validateGameId("what?"))
      t.isNil(ops.validateGameId("my game-2"))
    end)
    t.it("creates and scans the library unresolved, sorted by name", function()
      local root = tempDir()
      local folder, g = ops.createGameDefinition(root, "zeta")
      t.eq(folder, fs.join(root, "zeta"))
      t.eq(g.name, "zeta")
      local b = models.GameDefinition.new({ id = "b", name = "alpha",
        cards = { H.cardDef("c", {}, { imagePath = "c.png" }) } })
      ops.writeGameDefinition(fs.join(root, "b"), b)
      write(fs.join(root, "bad", "gamedef.json"), "{ nope")
      write(fs.join(root, "empty", "readme.txt"), "x")
      local entries = ops.scanGameLibrary(root)
      t.eq(#entries, 2)
      t.eq(entries[1].game.name, "alpha")
      t.eq(entries[1].game.cards[1].imagePath, "c.png")
      t.eq(entries[1].folderPath, fs.join(root, "b"))
      t.eq(entries[2].game.id, "zeta")
      t.eq(ops.scanGameLibrary(fs.join(root, "missing")), {})
    end)
    t.it("finds duplicate ids and merges duplicate images", function()
      local cards = {
        H.cardDef("a", { "x" }, { imagePath = "1.png", setId = "s" }),
        H.cardDef("b", { "y", "x" }, { imagePath = "1.png", setId = "s" }),
        H.cardDef("a", {}, { imagePath = "1.png", setId = "t" }),
        H.cardDef("d", { "z" }, { imagePath = "1.png", setId = "s" }),
        H.cardDef("e"),
        H.cardDef("f"),
      }
      local idGroups = ops.duplicateIdGroups(cards)
      t.eq(#idGroups, 1)
      t.eq(idGroups[1].key, "a")
      t.eq(idGroups[1].indices, { 1, 3 })
      local imgGroups = ops.duplicateImageGroups(cards)
      t.eq(#imgGroups, 1)
      t.eq(imgGroups[1].indices, { 1, 2, 4 })
      local merged = ops.mergeDuplicateImageCards(cards)
      t.eq(t.ids(merged, "id"), { "a", "a", "e", "f" })
      t.eq(merged[1].types, { "x", "y", "z" })
      t.eq(cards[1].types, { "x" }, "input untouched")
      t.eq(merged[2].setId, "t")
    end)
    t.it("finds cards a save would drop for having no set", function()
      local cards = { H.cardDef("a", {}, { setId = "s" }), H.cardDef("b"), H.cardDef("c", {}, { setId = "gone" }) }
      local g = models.GameDefinition.new({ id = "g", name = "G", cards = cards,
        sets = { models.GameSet.new({ id = "s", name = "S" }) } })
      t.eq(t.ids(ops.cardsOutsideSets(g), "id"), { "b", "c" })
      t.eq(ops.cardsOutsideSets(models.GameDefinition.new({ id = "g", name = "G", cards = cards })), {})
    end)
    t.it("rarity tags", function()
      t.eq(ops.rarityTags({ models.TagGroup.new({ id = "1", name = "Type", tags = { "A" } }),
        models.TagGroup.new({ id = "2", name = " rarity ", tags = { "Common", "Rare" } }) }), { "Common", "Rare" })
      t.eq(ops.rarityTags({}), {})
    end)
    t.it("renameTagGroupInCards: rewrites only the renamed group's qualified entries", function()
      local cards = {
        H.cardDef("a", { "Rarity|Common", "Faction|Common" }),
        H.cardDef("b", { "Common" }),
      }
      ops.renameTagGroupInCards(cards, "Rarity", "Tier")
      t.eq(cards[1].types, { "Tier|Common", "Faction|Common" })
      t.eq(cards[2].types, { "Common" }, "legacy bare entries are untouched")
    end)
    t.it("library migration", function()
      local dir = tempDir()
      t.notOk(ops.directoryHasEntries(fs.join(dir, "from")))
      write(fs.join(dir, "from", "g", "gamedef.json"), "{}")
      write(fs.join(dir, "to", "keep.txt"), "k")
      t.ok(ops.directoryHasEntries(fs.join(dir, "from")))
      ops.moveDirectoryContents(fs.join(dir, "from"), fs.join(dir, "to"))
      t.notOk(fs.exists(fs.join(dir, "from")))
      t.eq(fs.readFile(fs.join(dir, "to", "g", "gamedef.json")), "{}")
      t.eq(fs.readFile(fs.join(dir, "to", "keep.txt")), "k")
    end)
  end)

  t.describe("deck library", function()
    t.it("scans own + built-in decks, filters by game, flags legacy files", function()
      local root, gameDir = tempDir(), tempDir()
      local game = models.GameDefinition.new({ id = "g", name = "G", folderPath = gameDir })
      local deck = models.DeckConfig.new("g", { models.SubDeck.new("main_deck", { models.DeckEntry.new("a", 3) }) })
      t.ok(decks.writeDeck(root, "g", "Zeta", deck))
      decks.writeDeck(root, "g", "Alpha", deck)
      write(fs.join(root, "g", "Other.json"), '{"gameId":"other","subdecks":[]}')
      write(fs.join(root, "g", "Old.json"), '{"gameId":"g","entries":[]}')
      write(fs.join(root, "g", "junk.json"), "nope")
      write(fs.join(gameDir, "decks", "Starter.json"), json.encode(models.DeckConfig.toJson(deck)))
      local scan = decks.loadAllDecksForGame(root, game)
      t.eq(t.ids(scan.entries, "displayName"), { "Alpha", "Zeta", "Starter" })
      t.eq(scan.entries[3].isBuiltIn, true)
      t.eq(decks.cardCount(scan.entries[1]), 3)
      t.eq(t.ids(scan.incompatible, "displayName"), { "Old" })
      t.eq(fs.readFile(decks.deckPath(root, "g", "Alpha")), '{"gameId":"g","subdecks":[{"name":"main_deck","entries":[{"definitionId":"a","quantity":3}]}]}')
      t.ok(decks.deckExists(root, "g", "Alpha"))
      t.eq(select(2, decks.readDeckFile(fs.join(root, "g", "Old.json"))), "legacy")
    end)
    t.it("name validation", function()
      t.eq(decks.validateName(""), "Enter a deck name.")
      t.eq(decks.validateName(".."), "Invalid name.")
      t.ok(decks.validateName("a:b"))
      t.isNil(decks.validateName("My Deck"))
    end)
  end)

  t.describe("save files", function()
    t.it("write/list/read round-trip, newest first, corrupt skipped", function()
      local dir = tempDir()
      t.eq(#saves.listSaveGames(dir), 0)
      local state = H.state({ players = { H.player("p1"), H.player("p2") },
        cards = { H.card({ id = "c", definitionId = "d", x = 0.25, zone = "hand", ownerId = "p1", faceUp = true }) } })
      saves.writeSaveGame(dir, "older", models.SavedGame.new("2026-01-01T10:00:00.000", state))
      saves.writeSaveGame(dir, "newer", models.SavedGame.new("2026-03-01T09:00:00.000", state))
      write(fs.join(dir, "savegames", "junk.json"), '{"foo":1}')
      t.ok(saves.saveExists(dir, "newer"))
      t.notOk(saves.saveExists(dir, "nope"))
      local list = saves.listSaveGames(dir)
      t.eq(t.ids(list, "displayName"), { "newer", "older" })
      t.eq(list[1].playerCount, 2)
      local back = saves.readSaveGame(list[1].filePath)
      t.eq(back.state.cards[1], state.cards[1])
      t.eq(saves.formatSavedAt("2026-03-01T09:05:00.000"), "2026-03-01 09:05")
    end)
    t.it("loadedZones/loadedScenarioIds survive writeSaveGame/readSaveGame unchanged", function()
      local dir = tempDir()
      local zone = models.ZoneDefinition.new({ id = "z1", name = "Battlefield", shared = true, orientation = "left" })
      local state = util.copyWith(H.state({ players = { H.player("p1") } }),
        { loadedZones = { zone }, loadedScenarioIds = { "scen1" } })
      saves.writeSaveGame(dir, "scenariosave", models.SavedGame.new("2026-01-01T10:00:00.000", state))
      local list = saves.listSaveGames(dir)
      local back = saves.readSaveGame(list[1].filePath)
      t.eq(back.state.loadedZones, state.loadedZones)
      t.eq(back.state.loadedScenarioIds, state.loadedScenarioIds)
    end)
    t.it("log export", function()
      local dir = tempDir()
      write(fs.join(dir, "gamelogs", "other.txt"), "keep")
      local text = saves.formatLog({ models.LogEntry.new(61000, "A drew a card."), models.LogEntry.new(0, "B connected.") })
      t.eq(text, "[00:01:01] A drew a card.\n[00:00:00] B connected.")
      saves.writeLog(dir, "log.txt", text)
      t.eq(fs.readFile(fs.join(dir, "gamelogs", "log.txt")), text)
      t.eq(fs.readFile(fs.join(dir, "gamelogs", "other.txt")), "keep")
      t.ok(saves.logFileName():match("^gamelog_%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d%.txt$"))
    end)
  end)

  t.describe("webp", function()
    t.it("decodes WebP when libwebp is next to the app (skipped otherwise)", function()
      if not imageUtils.webpAvailable() then
        print("  (webp test skipped: no libwebp DLL found)")
        return
      end
      -- Encode a known image with libwebp itself, then decode it through
      -- the same path card art uses.
      local ffi = require("ffi")
      pcall(ffi.cdef, [[
        size_t WebPEncodeLosslessRGBA(const uint8_t* rgba, int width, int height, int stride, uint8_t** output);
      ]])
      local lib
      for _, e in ipairs(fs.list(love.filesystem.getSource()) or {}) do
        if e.name:lower():match("^libwebp.*%.dll$") then lib = ffi.load(fs.join(love.filesystem.getSource(), e.name)) end
      end
      t.ok(lib, "libwebp loaded")
      local src = love.image.newImageData(30, 20)
      src:setPixel(29, 0, 0, 0, 1, 1) -- blue top-right marker
      local out = ffi.new("uint8_t*[1]")
      local size = lib.WebPEncodeLosslessRGBA(ffi.cast("const uint8_t*", src:getFFIPointer()), 30, 20, 30 * 4, out)
      t.ok(tonumber(size) > 0, "encoded")
      local bytes = ffi.string(out[0], size)
      local dir = tempDir()
      write(fs.join(dir, "card.webp"), bytes)
      local decoded, err = imageUtils.decodeFile(fs.join(dir, "card.webp"))
      t.ok(decoded, err)
      t.eq({ decoded:getDimensions() }, { 30, 20 })
      local r, g, b = decoded:getPixel(29, 0)
      t.eq({ r, g, b }, { 0, 0, 1 })

      -- The image cache decodes on worker threads, which load libwebp on
      -- their own; run the real worker against the same file.
      local requests, results = love.thread.newChannel(), love.thread.newChannel()
      local worker = love.thread.newThread("src/data/image_worker.lua")
      worker:start(requests, results)
      requests:push({ key = "k", path = fs.join(dir, "card.webp") })
      t.eq(results:demand(10), "k")
      local payload = results:demand(10)
      requests:push("quit")
      worker:wait()
      t.isNil(worker:getError())
      t.eq(type(payload), "userdata", "worker returned " .. tostring(payload))
      t.eq({ payload:getDimensions() }, { 30, 20 })
    end)
  end)

  t.describe("avatar", function()
    t.it("resizes to 256 max and replaces previous avatar files", function()
      local dir = tempDir()
      png(600, 300, fs.join(dir, "big.png"))
      write(fs.join(dir, "av", "avatar.jpg"), "old")
      local dest = profile.saveAvatar(fs.join(dir, "big.png"), fs.join(dir, "av"))
      t.eq(dest, fs.join(dir, "av", "avatar.png"))
      t.notOk(fs.exists(fs.join(dir, "av", "avatar.jpg")))
      t.eq({ imageUtils.decodeFile(dest):getDimensions() }, { 256, 128 })
      png(100, 50, fs.join(dir, "small.png"))
      dest = profile.saveAvatar(fs.join(dir, "small.png"), fs.join(dir, "av"))
      t.eq({ imageUtils.decodeFile(dest):getDimensions() }, { 100, 50 })
      profile.deleteAvatar(fs.join(dir, "av"))
      t.notOk(fs.exists(dest))
    end)
  end)

  t.describe("hand settings", function()
    t.it("clamps, saves non-defaults only and resets", function()
      handSettings.reset()
      t.eq(handSettings.get("cardScale"), 3)
      handSettings.set("cardScale", 99)
      t.eq(handSettings.get("cardScale"), 4)
      t.eq(settings.get("hand_cardScale"), 4)
      handSettings.set("tilt", 5, true)
      t.eq(handSettings.get("tilt"), 5)
      t.eq(settings.get("hand_tilt"), nil)
      t.notOk(handSettings.isDefault())
      handSettings.reset()
      t.ok(handSettings.isDefault())
      t.eq(settings.get("hand_cardScale"), nil)
    end)
  end)

  t.describe("table settings", function()
    t.it("selection color defaults to yellow and only saves non-defaults", function()
      local saved = settings.get(settings.keys.selectionColor)
      tableSettings.resetSelectionColor()
      t.eq(tableSettings.selectionColor(), 0xFFFFEB3B)
      t.ok(tableSettings.isSelectionColorDefault())
      t.eq(settings.get(settings.keys.selectionColor), nil)
      tableSettings.setSelectionColor(0xFF2196F3)
      t.eq(tableSettings.selectionColor(), 0xFF2196F3)
      t.eq(settings.get(settings.keys.selectionColor), 0xFF2196F3)
      t.notOk(tableSettings.isSelectionColorDefault())
      tableSettings.resetSelectionColor()
      t.eq(settings.get(settings.keys.selectionColor), nil)
      if saved ~= nil then tableSettings.setSelectionColor(saved) end
    end)

    t.it("table/playmat-border color fall back to the game's own color, then the hardcoded default", function()
      local savedFelt = settings.get(settings.keys.feltColor)
      local savedBorder = settings.get(settings.keys.playmatBorderColor)
      tableSettings.resetFeltColor()
      tableSettings.resetPlaymatBorderColor()

      -- No override, no game color: hardcoded defaults.
      t.eq(tableSettings.feltColor(nil), tableSettings.defaultFeltColor)
      t.eq(tableSettings.playmatBorderColor(nil), tableSettings.defaultPlaymatBorderColor)
      t.ok(tableSettings.isFeltColorDefault())
      t.ok(tableSettings.isPlaymatBorderColorDefault())

      -- No override: the game's own color wins over the hardcoded default.
      t.eq(tableSettings.feltColor("#5D1049"), 0xFF5D1049)
      t.eq(tableSettings.playmatBorderColor("#2A0824"), 0xFF2A0824)

      -- Setting to the game's own color (what the picker already shows)
      -- is a no-op -- it must NOT pin that game's color as a personal
      -- override that would leak into a different game.
      tableSettings.setFeltColor(0xFF5D1049, "#5D1049")
      t.ok(tableSettings.isFeltColorDefault())
      t.eq(settings.get(settings.keys.feltColor), nil)

      -- An explicit, different pick DOES override, regardless of game.
      tableSettings.setFeltColor(0xFF112233, "#5D1049")
      t.notOk(tableSettings.isFeltColorDefault())
      t.eq(tableSettings.feltColor("#5D1049"), 0xFF112233)
      t.eq(tableSettings.feltColor(nil), 0xFF112233) -- carries over to a game with no color of its own

      tableSettings.resetFeltColor()
      t.ok(tableSettings.isFeltColorDefault())
      t.eq(tableSettings.feltColor("#5D1049"), 0xFF5D1049) -- reset returns to the game's color, not green

      if savedFelt ~= nil then tableSettings.setFeltColor(savedFelt) end
      if savedBorder ~= nil then tableSettings.setPlaymatBorderColor(savedBorder) end
    end)
  end)

  t.describe("recent servers", function()
    t.it("keeps the last 5 unique servers, most recent first", function()
      local saved = settings.get(settings.keys.recentServers)
      settings.remove(settings.keys.recentServers)
      t.eq(#profile.getRecentServers(), 0)
      for i = 1, 6 do profile.addRecentServer("10.0.0." .. i, 4000) end
      profile.addRecentServer("10.0.0.3", 4000)
      profile.addRecentServer("10.0.0.3", 5000)
      local list = profile.getRecentServers()
      t.eq(#list, 5)
      t.eq(list[1].host .. ":" .. list[1].port, "10.0.0.3:5000")
      t.eq(list[2].host .. ":" .. list[2].port, "10.0.0.3:4000")
      t.eq(list[3].host, "10.0.0.6")
      t.eq(list[5].host, "10.0.0.4")
      profile.removeRecentServer("10.0.0.3", 4000)
      list = profile.getRecentServers()
      t.eq(#list, 4)
      t.eq(list[1].host .. ":" .. list[1].port, "10.0.0.3:5000")
      t.eq(list[2].host, "10.0.0.6")
      if saved == nil then settings.remove(settings.keys.recentServers) else settings.set(settings.keys.recentServers, saved) end
    end)
  end)

  t.describe("controls dialog", function()
    t.it("parses CONTROLS.md headings, tables, bullets and paragraphs", function()
      local controls = require("src.ui.screens.controls_dialog")
      local b = controls.parse([[
# Title

## Sec

| Key | Effect |
|-----|--------|
| **F** | Flip `it` |

**Bold line**

- one
- two

Some
text.
]])
      local kinds = {}
      for i, x in ipairs(b) do kinds[i] = x.kind end
      t.eq(table.concat(kinds, ","), "h1,h2,table,bold,bullet,bullet,p")
      t.eq(b[3].header[2], "Effect")
      t.eq(#b[3].rows, 1)
      t.eq(b[3].rows[1][1], "F")
      t.eq(b[3].rows[1][2], "Flip it")
      t.eq(b[7].text, "Some text.")
      t.ok(love.filesystem.getInfo("CONTROLS.md") ~= nil)
    end)
  end)
end
