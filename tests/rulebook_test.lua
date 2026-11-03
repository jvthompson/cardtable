-- Rulebook viewer: Markdown parsing/heading structure, PDF-vs-Markdown
-- format detection, PDF page layout math, loading a game's rulebook (or
-- lack of one), and per-game scroll persistence. Actual rendering
-- (controls_dialog.drawBlocks, PDFium decoding, panel chrome) needs a live
-- love.graphics context and isn't exercised here - see the manual Ctrl+R
-- spot-check instead.
local fs = require("src.data.fs")
local models = require("src.core.models")
local controls = require("src.ui.screens.controls_dialog")
local rulebookViewer = require("src.ui.screens.rulebook_viewer")
local rulebookSettings = require("src.data.rulebook_settings")

return function(t)
  local function tempDir(name)
    local dir = fs.join(love.filesystem.getSaveDirectory(), "test_tmp", "rulebook_" .. name)
    fs.removeTree(dir)
    fs.mkdirs(dir)
    return dir
  end

  t.describe("rulebook", function()
    t.it("parses headings, bullets and paragraphs with nesting", function()
      local blocks = controls.parse(
        "# Title\n\nSome intro text.\n\n## Section One\n\n- a bullet\n- another\n\n### Sub One\n")
      local kinds = {}
      for _, b in ipairs(blocks) do kinds[#kinds + 1] = b.kind end
      t.eq(kinds, { "h1", "p", "h2", "bullet", "bullet", "h3" })
      t.eq(blocks[1].text, "Title")
      t.eq(blocks[3].text, "Section One")
      t.eq(blocks[6].text, "Sub One")
    end)

    t.it("parses an image reference as its own block", function()
      local blocks = controls.parse("# Title\n\n![A diagram](diagram.png)\n\nAfter.\n")
      local kinds = {}
      for _, b in ipairs(blocks) do kinds[#kinds + 1] = b.kind end
      t.eq(kinds, { "h1", "image", "p" })
      t.eq(blocks[2].alt, "A diagram")
      t.eq(blocks[2].path, "diagram.png")
    end)

    t.it("doesn't crash loading a rulebook whose referenced image is missing", function()
      local dir = tempDir("missing_image")
      fs.writeFile(fs.join(dir, "rulebook.md"), "# Game\n\n![Missing](nope.png)\n")
      local rv = rulebookViewer.new(models.GameDefinition.new({ id = "rb_test_missing_image", name = "X", folderPath = dir }))
      rv:ensureLoaded()
      t.ok(rv.docs.rulebook.hasContent)
      t.eq(rv.docs.rulebook.blocks[2].kind, "image")
      t.notOk(rv.docs.rulebook.blocks[2].image)
    end)

    t.it("loads rulebook.md from the game's folder, and reports no content when missing", function()
      local dir = tempDir("present")
      fs.writeFile(fs.join(dir, "rulebook.md"), "# Game\n\n## Setup\n\nDo the thing.\n")
      local withFile = rulebookViewer.new(models.GameDefinition.new({ id = "rb_test_present", name = "X", folderPath = dir }))
      withFile:ensureLoaded()
      t.ok(withFile.docs.rulebook.hasContent)
      t.eq(#withFile.docs.rulebook.blocks, 3)
      t.eq(withFile.docs.rulebook.blocks[1].kind, "h1")

      local emptyDir = tempDir("missing")
      local noFile = rulebookViewer.new(models.GameDefinition.new({ id = "rb_test_missing", name = "X", folderPath = emptyDir }))
      noFile:ensureLoaded()
      t.notOk(noFile.docs.rulebook.hasContent)

      local noFolder = rulebookViewer.new(models.GameDefinition.new({ id = "rb_test_nofolder", name = "X" }))
      noFolder:ensureLoaded()
      t.notOk(noFolder.docs.rulebook.hasContent)
    end)

    t.it("persists scroll position per game id", function()
      local id = "rb_test_scroll"
      t.eq(rulebookSettings.getScroll(id), 0)
      rulebookSettings.setScroll(id, 420)
      t.eq(rulebookSettings.getScroll(id), 420)
      rulebookSettings.setScroll(id, 0) -- leave it as found
    end)

    t.it("prefers rulebook.pdf over rulebook.md when both are present", function()
      local dir = tempDir("pdf_precedence")
      fs.writeFile(fs.join(dir, "rulebook.md"), "# Game\n")
      fs.writeFile(fs.join(dir, "rulebook.pdf"), "not a real pdf, just present")
      local rv = rulebookViewer.new(models.GameDefinition.new({ id = "rb_test_pdf_precedence", name = "X", folderPath = dir }))
      rv:ensureLoaded()
      t.ok(rv.docs.rulebook.hasContent)
      t.eq(rv.docs.rulebook.kind, "pdf")
    end)

    t.it("falls back to rulebook.md when there's no PDF", function()
      local dir = tempDir("md_only")
      fs.writeFile(fs.join(dir, "rulebook.md"), "# Game\n")
      local rv = rulebookViewer.new(models.GameDefinition.new({ id = "rb_test_md_only", name = "X", folderPath = dir }))
      rv:ensureLoaded()
      t.ok(rv.docs.rulebook.hasContent)
      t.eq(rv.docs.rulebook.kind, "md")
    end)

    t.it("computes PDF page layout: every page scaled to the full column width, stacked with a gap", function()
      local layout = rulebookViewer._computePdfLayout({ { 600, 800 }, { 300, 300 } }, 400, 10)
      t.eq(#layout.pages, 2)
      t.eq(layout.pages[1].y, 0)
      t.near(layout.pages[1].h, 400 * 800 / 600)
      t.near(layout.pages[2].y, layout.pages[1].h + 10)
      t.near(layout.pages[2].h, 400 * 300 / 300)
      t.near(layout.contentHeight, layout.pages[2].y + layout.pages[2].h)
    end)

    t.it("loads a scenario's guide from _scenarios, by its own extension, under the game's folder", function()
      local dir = tempDir("guide_md")
      fs.mkdirs(fs.join(dir, "_scenarios"))
      fs.writeFile(fs.join(dir, "_scenarios", "opening.md"), "# Opening\n\nDo this first.\n")
      local game = models.GameDefinition.new({ id = "rb_test_guide_md", name = "X", folderPath = dir })
      local rv = rulebookViewer.new(game)
      local scenario = models.Scenario.new({ id = "s1", name = "Opening", guidePath = "opening.md" })
      local doc = rv:ensureGuideLoaded(scenario)
      t.ok(doc)
      t.ok(doc.hasContent)
      t.eq(doc.kind, "md")
      t.eq(doc.blocks[1].text, "Opening")
    end)

    t.it("ensureGuideLoaded returns nil (and drops docs.guide) with no scenario, no guidePath, or a missing file", function()
      local dir = tempDir("guide_missing")
      local game = models.GameDefinition.new({ id = "rb_test_guide_missing", name = "X", folderPath = dir })
      local rv = rulebookViewer.new(game)
      t.isNil(rv:ensureGuideLoaded(nil))
      t.isNil(rv:ensureGuideLoaded(models.Scenario.new({ id = "s1", name = "No Guide" })))
      t.isNil(rv:ensureGuideLoaded(models.Scenario.new({ id = "s2", name = "Bad Path", guidePath = "nope.md" })))
      t.isNil(rv.docs.guide)
    end)
  end)
end
