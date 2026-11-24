// Keep Cooking — Lane 4 CookTests (XCTest)
// Covers the Lane 4 pure core — no SwiftData, no network, no UI:
//   1. Scaling 4 -> 6 servings (factor + fraction display).
//   2. Timer parser (ranges use upper bound, multi-timer, hr/min/sec).
//   3. Week aggregation (scaled merge + unmeasured passthrough).
//   4. Aisle sort + pantry helpers (expiry, low-stock).
//
// Run: these live in the KeepCookingTests target alongside SyncEngineTests
// (apps/ios/Sync/SyncEngineTests.swift). The pure-logic sources under test
// (RecipeScaler.swift, StepTimerParser.swift, CookSession.swift,
// ../Plan/PlanAggregation.swift, ../Shop/ShopHelpers.swift) compile into
// the same test target (see project.yml + Smidgen.xcodeproj) — no import
// needed, no @testable import (standalone bundle, no app host).

import XCTest

// Same-target convention (see header): no import needed.

final class CookTests: XCTestCase {
    // MARK: - Scaling 4 -> 6 servings

    func testScaleFactor4to6() {
        XCTAssertEqual(scaleFactor(baseServings: 4, targetServings: 6), 1.5)
    }

    func testScaleFactorClamped() {
        XCTAssertEqual(scaleFactor(baseServings: 4, targetServings: 40), 4) // 10x -> 4x
        XCTAssertEqual(scaleFactor(baseServings: 4, targetServings: 0.1), 0.25) // tiny -> 0.25x
        XCTAssertEqual(scaleFactor(baseServings: 0, targetServings: 6), 1) // degenerate
    }

    func testFractionDisplay() {
        XCTAssertEqual(fractionDisplayString(for: 1.5), "1½")
        XCTAssertEqual(fractionDisplayString(for: 6), "6") // 4 cups @1.5x
        XCTAssertEqual(fractionDisplayString(for: 0.5), "½")
        XCTAssertEqual(fractionDisplayString(for: 0.25), "¼")
        // Servings labels must never use %.1g (2.5 -> "2", 12.5 -> "1e+01").
        XCTAssertEqual(fractionDisplayString(for: 2.5), "2½")
        XCTAssertEqual(fractionDisplayString(for: 12.5), "12½")
        XCTAssertEqual(fractionDisplayString(for: 4), "4")
    }

    func testScaledDisplay4to6() {
        // 4 cups flour, base 4 servings -> 6 servings = 6 cups.
        XCTAssertEqual(
            scaledDisplay(name: "flour", quantity: 4, unit: "cups", factor: 1.5),
            "6 cups flour")
        // 1 cup sugar -> 1½ cups.
        XCTAssertEqual(
            scaledDisplay(name: "sugar", quantity: 1, unit: "cup", factor: 1.5),
            "1½ cup sugar")
        // Unmeasured stays bare.
        XCTAssertEqual(
            scaledDisplay(name: "Salt to taste", quantity: nil, unit: "", factor: 1.5),
            "Salt to taste")
    }

    // MARK: - Timer parser

    func testTimerParserRangeUsesUpperBound() {
        let timers = parseTimers(from: "bake 12-15 min")
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].seconds, 15 * 60)
    }

    func testTimerParserMultiTimer() {
        let timers = parseTimers(from: "bake 12-15 min, rest 1 hr")
        XCTAssertEqual(timers.count, 2)
        XCTAssertEqual(timers[0].seconds, 15 * 60)
        XCTAssertEqual(timers[1].seconds, 3600)
    }

    func testTimerParserSeconds() {
        let timers = parseTimers(from: "sear 30 seconds per side")
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].seconds, 30)
    }

    func testTimerParserNoTimers() {
        XCTAssertTrue(parseTimers(from: "chop the onions finely").isEmpty)
    }

    // MARK: - Aggregation (plan -> list, scaled)

    func testAggregationScaledMerge() {
        // Two plans, same flour: 2 cups @4 servings as-written + 2 cups @4
        // servings scaled to 6 (1.5x -> 3 cups) = 5 cups total.
        let inputs = [
            PlanGroceryInput(name: "Flour", quantity: 2, unit: "cups",
                             baseServings: 4, targetServings: 4, recipeId: "r1"),
            PlanGroceryInput(name: "flour", quantity: 2, unit: "cups",
                             baseServings: 4, targetServings: 6, recipeId: "r2"),
        ]
        let out = aggregateWeekToList(inputs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].totalQuantity ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(out[0].display, "5 cups Flour")
    }

    func testAggregationUnmeasuredPassthrough() {
        let inputs = [
            PlanGroceryInput(name: "Salt", quantity: nil, unit: "",
                             baseServings: 4, targetServings: 6),
        ]
        let out = aggregateWeekToList(inputs)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].totalQuantity)
        XCTAssertEqual(out[0].display, "Salt")
    }

    // MARK: - Shop helpers

    func testAisleSortProduceBeforeDairy() {
        let kp = aisleSortKey(aisle: "produce", name: "x")
        let kd = aisleSortKey(aisle: "dairy", name: "x")
        XCTAssertTrue(kp.0 < kd.0)
        // Unknown aisles sort after known ones.
        let ku = aisleSortKey(aisle: "zebra", name: "x")
        XCTAssertTrue(kd.0 < ku.0)
    }

    func testAisleGroupedNamesNormalizesCaseAndWhitespace() {
        // Values differing only by case/whitespace must collapse to one section.
        struct Item { let aisle: String; let name: String }
        let items = [
            Item(aisle: "Produce", name: "Apples"),
            Item(aisle: "produce ", name: "Carrots"),
            Item(aisle: "PRODUCE", name: "Bananas"),
            Item(aisle: "dairy", name: "Milk"),
            Item(aisle: "", name: "Mystery"),
            Item(aisle: "  ", name: "Other mystery"),
        ]
        let groups = aisleGroupedNames(items: items, aisleOf: { $0.aisle }, nameOf: { $0.name })
        XCTAssertEqual(groups.count, 3) // produce + dairy + unfiled, not 6
        XCTAssertEqual(
            Set(groups.map { normalizedAisleKey($0) }),
            Set(["produce", "dairy", ""]))
    }

    func testNormalizedAisleKey() {
        XCTAssertEqual(normalizedAisleKey(" Produce "), "produce")
        XCTAssertEqual(normalizedAisleKey("DAIRY"), "dairy")
        XCTAssertEqual(normalizedAisleKey(""), "")
    }

    func testExpiryStatus() {
        let now = Date()
        XCTAssertEqual(expiryStatus(expiresAt: now.addingTimeInterval(-10)), .expired)
        XCTAssertEqual(expiryStatus(expiresAt: now.addingTimeInterval(3 * 86400)), .expiringSoon)
        XCTAssertEqual(expiryStatus(expiresAt: now.addingTimeInterval(30 * 86400)), .fresh)
        XCTAssertEqual(expiryStatus(expiresAt: nil), .noDate)
    }

    func testLowStock() {
        XCTAssertTrue(isLowStock(quantity: "1", threshold: "2"))
        XCTAssertFalse(isLowStock(quantity: "3", threshold: "2"))
        XCTAssertFalse(isLowStock(quantity: "anything", threshold: "")) // no threshold
        XCTAssertTrue(isLowStock(quantity: "", threshold: "2")) // nothing left
    }

    // MARK: - Session: Finish is idempotent, card toggle unmarks

    @MainActor
    func testMarkStepDoneIdempotent() {
        let session = CookSession(stepCount: 3)
        session.markStepDone(id: "s-last")
        session.markStepDone(id: "s-last") // repeat Finish tap
        XCTAssertTrue(session.crossedOffSteps.contains("s-last"))
        // Card toggle remains the explicit unmark action.
        session.toggleStep(id: "s-last")
        XCTAssertFalse(session.crossedOffSteps.contains("s-last"))
    }

    // MARK: - Timer scheduling: stable unique identifiers

    func testScheduleIdsUniqueAcrossCalls() {
        // Per-timer starts each pass a one-element array; equal durations
        // must not reuse one notification identifier. Exercises the pure
        // ID builder: UNUserNotificationCenter is unavailable in the
        // host-less test bundle, so `schedule` itself is not called here.
        let timer = ParsedTimer(seconds: 600, label: "bake")
        let first = CookActivityStub.makeIDs(for: [timer])
        let second = CookActivityStub.makeIDs(for: [timer])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first[0], second[0])
    }

    func testScheduleIdsUniqueWithinBatch() {
        let timers = [ParsedTimer(seconds: 600, label: "bake"),
                      ParsedTimer(seconds: 600, label: "rest")]
        let ids = CookActivityStub.makeIDs(for: timers)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    // MARK: - Voice parser (Option A, Lane 10)

    func testVoiceNextPreviousRepeat() {
        XCTAssertEqual(parseVoiceCommand("next"), .next)
        // Standalone-utterance match: trim + trailing period + case.
        XCTAssertEqual(parseVoiceCommand("  Next. "), .next)
        XCTAssertEqual(parseVoiceCommand("previous step"), .previous)
        XCTAssertEqual(parseVoiceCommand("repeat that"), .repeatStep)
        // Wake-word prefix is stripped generally.
        XCTAssertEqual(parseVoiceCommand("smidgen next"), .next)
        XCTAssertEqual(parseVoiceCommand("hey smidgen, previous step"), .previous)
    }

    func testVoiceGoToStep() {
        XCTAssertEqual(parseVoiceCommand("go to step 3"), .goToStep(3))
        XCTAssertEqual(parseVoiceCommand("go to step three"), .goToStep(3))
        XCTAssertEqual(parseVoiceCommand("go to the last step"), .goToStep(VoiceCommand.lastStep))
    }

    func testVoiceStartOver() {
        XCTAssertEqual(parseVoiceCommand("start over"), .startOver)
    }

    func testVoiceTimerExtraction() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 10 minutes"),
            .startTimer(seconds: 600, label: nil))
        // Ranges use the upper bound, matching parseTimers.
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 12-15 minutes"),
            .startTimer(seconds: 900, label: nil))
        XCTAssertEqual(
            parseVoiceCommand("start a timer for ten minutes"),
            .startTimer(seconds: 600, label: nil))
        // No duration: the caller resolves the current step via parseTimers.
        XCTAssertEqual(
            parseVoiceCommand("start the timer"),
            .startTimer(seconds: nil, label: nil))
    }

    func testVoiceScaleCommands() {
        XCTAssertEqual(parseVoiceCommand("double the recipe"), .doubleScale)
        XCTAssertEqual(parseVoiceCommand("halve the recipe"), .halveScale)
        XCTAssertEqual(parseVoiceCommand("reset the scale"), .resetScale)
    }

    func testVoiceSmidgenPrefixRule() {
        // Bare ambiguous utterances stay unknown ...
        XCTAssertEqual(parseVoiceCommand("halve it"), .unknown)
        XCTAssertEqual(parseVoiceCommand("double it"), .unknown)
        XCTAssertEqual(parseVoiceCommand("come again"), .unknown)
        // ... but are honored with the "smidgen" prefix.
        XCTAssertEqual(parseVoiceCommand("smidgen halve it"), .halveScale)
        XCTAssertEqual(parseVoiceCommand("smidgen double it"), .doubleScale)
        XCTAssertEqual(parseVoiceCommand("smidgen come again"), .repeatStep)
        XCTAssertEqual(parseVoiceCommand("smidgen what was that?"), .repeatStep)
        XCTAssertEqual(parseVoiceCommand("smidgen cancel"), .stopCooking)
    }

    func testVoiceMidSentenceGuard() {
        // Parser only handles standalone utterances; embedded commands stay
        // unknown (mid-sentence gating lives with the caller).
        XCTAssertEqual(parseVoiceCommand("please tell me the next step"), .unknown)
        XCTAssertEqual(parseVoiceCommand("can you go to step 3 for me"), .unknown)
    }

    func testVoiceCrossUncrossFuzzy() {
        XCTAssertEqual(parseVoiceCommand("cross off the flour"), .crossOff(name: "flour"))
        XCTAssertEqual(parseVoiceCommand("uncross flour"), .uncross(name: "flour"))
        // Fuzzy helper: a short spoken name matches the longer label.
        XCTAssertEqual(
            fuzzyVoiceMatch("flour", candidates: ["All-purpose flour", "Sugar"]),
            "All-purpose flour")
    }

    func testVoiceAddToList() {
        XCTAssertEqual(
            parseVoiceCommand("add the ingredients to my list"),
            .addToList(listName: nil))
        XCTAssertEqual(
            parseVoiceCommand("add the ingredients to my costco list"),
            .addToList(listName: "costco"))
    }

    func testVoiceIngredientAmount() {
        XCTAssertEqual(
            parseVoiceCommand("how much flour do i need"),
            .ingredientAmount(name: "flour"))
    }

    func testVoiceStopCommands() {
        XCTAssertEqual(parseVoiceCommand("stop speaking"), .stopSpeaking)
        XCTAssertEqual(parseVoiceCommand("stop cooking"), .stopCooking)
    }

    func testVoiceScaleHelper() {
        var target = 4.0
        applyScaleCommand(.double, baseServings: 4, targetServings: &target)
        XCTAssertEqual(target, 8)
        applyScaleCommand(.halve, baseServings: 4, targetServings: &target)
        XCTAssertEqual(target, 2)
        applyScaleCommand(.reset, baseServings: 4, targetServings: &target)
        XCTAssertEqual(target, 4)
    }

    func testVoiceIngredientIdHelper() {
        let ingredients = [(id: "i1", name: "All-purpose flour"), (id: "i2", name: "Sugar")]
        XCTAssertEqual(ingredientId(matching: "flour", in: ingredients), "i1")
        XCTAssertNil(ingredientId(matching: "cinnamon", in: ingredients))
    }
}

// MARK: - Voice parser cubic fixes (Lane 10 P1/P2, appended only)

extension CookTests {
    // Fix 1: normalize strips ASCII + curly apostrophes.
    func testVoiceNormalizeAsciiApostrophe() {
        XCTAssertEqual(normalizeVoiceText("I'm done"), "im done")
    }

    func testVoiceNormalizeCurlyApostrophe() {
        XCTAssertEqual(normalizeVoiceText("I\u{2019}m done"), "im done")
    }

    func testVoiceNormalizeLeftSingleQuote() {
        XCTAssertEqual(normalizeVoiceText("I\u{2018}m done"), "im done")
    }

    func testVoiceNormalizeBacktickApostrophe() {
        XCTAssertEqual(normalizeVoiceText("I`m done"), "im done")
    }

    func testVoiceSmidgenImDoneCurly() {
        XCTAssertEqual(parseVoiceCommand("smidgen I\u{2019}m done"), .next)
    }

    func testVoiceSmidgenImDoneAscii() {
        XCTAssertEqual(parseVoiceCommand("smidgen I'm done"), .next)
    }

    func testVoiceBareImDoneUnknownBothQuotes() {
        XCTAssertEqual(parseVoiceCommand("I'm done"), .unknown)
        XCTAssertEqual(parseVoiceCommand("I\u{2019}m done"), .unknown)
    }

    // Fix 2: token-boundary-aware fuzzy scoring + tie rejection.
    func testFuzzyExactEqualityWins() {
        XCTAssertEqual(
            fuzzyVoiceMatch("sea salt", candidates: ["sea salt", "sea salt flakes"]),
            "sea salt")
    }

    func testFuzzyTokenOverlapBeatsSubstring() {
        // "salt" is an exact token of "sea salt" but only a non-boundary
        // substring of "salty snacks" -> the token match must win.
        XCTAssertEqual(
            fuzzyVoiceMatch("salt", candidates: ["salty snacks", "sea salt"]),
            "sea salt")
    }

    func testFuzzyNonBoundarySubstringRejected() {
        XCTAssertNil(fuzzyVoiceMatch("our", candidates: ["flour"]))
    }

    func testFuzzyPrefixSubstringRejected() {
        XCTAssertNil(fuzzyVoiceMatch("flo", candidates: ["flour"]))
    }

    func testFuzzyMostMatchedTokensWins() {
        XCTAssertEqual(
            fuzzyVoiceMatch(
                "flour sugar salt",
                candidates: ["flour sugar", "flour sugar salt"]),
            "flour sugar salt")
    }

    func testFuzzyLongestSpanWinsOnTokenCountTie() {
        // Both overlap 1 token; "pepper" (6 chars) beats "salt" (4 chars).
        XCTAssertEqual(
            fuzzyVoiceMatch(
                "pepper salt",
                candidates: ["pepper flakes", "pepperoni salt"]),
            "pepper flakes")
    }

    func testFuzzyTieReturnsNil() {
        XCTAssertNil(
            fuzzyVoiceMatch("flour", candidates: ["white flour", "wheat flour"]))
    }

    func testFuzzyExactDuplicateTieReturnsNil() {
        XCTAssertNil(fuzzyVoiceMatch("flour", candidates: ["Flour", "flour"]))
    }

    func testFuzzyNoMatchReturnsNil() {
        XCTAssertNil(fuzzyVoiceMatch("cinnamon", candidates: ["flour", "sugar"]))
    }

    func testFuzzyEmptyQueryReturnsNil() {
        XCTAssertNil(fuzzyVoiceMatch("  ", candidates: ["flour"]))
    }

    func testFuzzyEmptyCandidatesReturnsNil() {
        XCTAssertNil(fuzzyVoiceMatch("flour", candidates: []))
    }

    func testFuzzyHyphenBoundaryMatches() {
        XCTAssertEqual(
            fuzzyVoiceMatch("purpose", candidates: ["all-purpose flour", "sugar"]),
            "all-purpose flour")
    }

    func testVoiceIngredientIdAmbiguousReturnsNil() {
        let ingredients = [(id: "i1", name: "white flour"), (id: "i2", name: "wheat flour")]
        XCTAssertNil(ingredientId(matching: "flour", in: ingredients))
    }

    // Fix 3: bounded timer durations (1...43200s), finite guard.
    func testVoiceTimerZeroMinutesUnknown() {
        XCTAssertEqual(parseVoiceCommand("start a timer for 0 minutes"), .unknown)
    }

    func testVoiceTimerHugeHoursUnknown() {
        XCTAssertEqual(parseVoiceCommand("start a timer for 100 hours"), .unknown)
    }

    func testVoiceTimerTwelveHoursOk() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 12 hours"),
            .startTimer(seconds: 43200, label: nil))
    }

    func testVoiceTimerThirteenHoursUnknown() {
        XCTAssertEqual(parseVoiceCommand("start a timer for 13 hours"), .unknown)
    }

    func testVoiceTimerHugeSecondsUnknown() {
        XCTAssertEqual(parseVoiceCommand("start a timer for 50000 seconds"), .unknown)
    }

    func testVoiceTimerFractionalMinuteOk() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 0.5 minutes"),
            .startTimer(seconds: 30, label: nil))
    }

    func testVoiceTimerAstronomicalHoursUnknown() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 99999999999999999999 hours"), .unknown)
    }

    // Fix 4: hundreds/thousands words, no partial-number fallback.
    func testVoiceTimerOneHundredMinutes() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for one hundred minutes"),
            .startTimer(seconds: 6000, label: nil))
    }

    func testVoiceTimerOneHundredTwentyFiveMinutes() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for one hundred twenty five minutes"),
            .startTimer(seconds: 7500, label: nil))
    }

    func testVoiceTimerTwoHundredFiftyMinutesNoTruncation() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for two hundred fifty minutes"),
            .startTimer(seconds: 15000, label: nil))
    }

    func testVoiceTimerAHundredSeconds() {
        XCTAssertEqual(
            parseVoiceCommand("set a timer for a hundred seconds"),
            .startTimer(seconds: 100, label: nil))
    }

    func testVoiceTimerOneHundredAndFiveSeconds() {
        XCTAssertEqual(
            parseVoiceCommand("set a timer for one hundred and five seconds"),
            .startTimer(seconds: 105, label: nil))
    }

    func testVoiceTimerOneThousandSeconds() {
        XCTAssertEqual(
            parseVoiceCommand("set a timer for one thousand seconds"),
            .startTimer(seconds: 1000, label: nil))
    }

    func testVoiceTimerBareHundredUnknown() {
        XCTAssertEqual(parseVoiceCommand("start a timer for hundred minutes"), .unknown)
    }

    // Fix 5: step validation helper; parse stays pure.
    func testVoiceGoToStepParseCarriesAsIs() {
        XCTAssertEqual(parseVoiceCommand("go to step 99"), .goToStep(99))
    }

    func testValidatedStepInRange() {
        XCTAssertEqual(validatedStep(requested: 3, stepCount: 5), 3)
    }

    func testValidatedStepFirstAndLast() {
        XCTAssertEqual(validatedStep(requested: 1, stepCount: 5), 1)
        XCTAssertEqual(validatedStep(requested: 5, stepCount: 5), 5)
    }

    func testValidatedStepOutOfRange() {
        XCTAssertNil(validatedStep(requested: 9, stepCount: 5))
    }

    func testValidatedStepZeroNil() {
        XCTAssertNil(validatedStep(requested: 0, stepCount: 5))
    }

    func testValidatedStepLastMapsToCount() {
        XCTAssertEqual(
            validatedStep(requested: VoiceCommand.lastStep, stepCount: 5), 5)
    }

    func testValidatedStepEmptyRecipeNil() {
        XCTAssertNil(validatedStep(requested: 1, stepCount: 0))
        XCTAssertNil(validatedStep(requested: VoiceCommand.lastStep, stepCount: 0))
    }

    // Fix 6: explicit ambiguity signal (fuzzy nil is ambiguous OR no-match).
    func testAmbiguousTieTrue() {
        XCTAssertTrue(
            isFuzzyVoiceMatchAmbiguous("flour", candidates: ["white flour", "wheat flour"]))
    }

    func testAmbiguousExactDuplicateTrue() {
        XCTAssertTrue(
            isFuzzyVoiceMatchAmbiguous("flour", candidates: ["Flour", "flour"]))
    }

    func testAmbiguousSingleMatchFalse() {
        XCTAssertFalse(
            isFuzzyVoiceMatchAmbiguous("flour", candidates: ["All-purpose flour", "Sugar"]))
    }

    func testAmbiguousNoMatchFalse() {
        XCTAssertFalse(
            isFuzzyVoiceMatchAmbiguous("cinnamon", candidates: ["flour", "sugar"]))
    }

    func testAmbiguousEmptyQueryFalse() {
        XCTAssertFalse(isFuzzyVoiceMatchAmbiguous("  ", candidates: ["flour"]))
    }

    // Fix 7: compound durations sum instead of truncating.
    func testVoiceTimerCompoundHourAndMinutes() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 1 hour 30 minutes"),
            .startTimer(seconds: 5400, label: nil))
    }

    func testVoiceTimerCompoundWords() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for one hour thirty minutes"),
            .startTimer(seconds: 5400, label: nil))
    }

    func testVoiceTimerCompoundMixedDigitAndWords() {
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 1 hour thirty minutes"),
            .startTimer(seconds: 5400, label: nil))
    }

    func testVoiceTimerCompoundTooLargeUnknown() {
        // 11h + 2h = 13h exceeds the 12h bound.
        XCTAssertEqual(
            parseVoiceCommand("start a timer for 11 hours 2 hours"), .unknown)
    }
}
