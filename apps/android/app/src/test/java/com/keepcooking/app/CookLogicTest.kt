package com.keepcooking.app

import com.keepcooking.app.cook.CookActivityStub
import com.keepcooking.app.cook.CookSession
import com.keepcooking.app.cook.ParsedTimer
import com.keepcooking.app.cook.ScaleVoiceCommand
import com.keepcooking.app.cook.VoiceCommand
import com.keepcooking.app.cook.VoiceIngredientRef
import com.keepcooking.app.cook.applyScaleCommand
import com.keepcooking.app.cook.fractionDisplayString
import com.keepcooking.app.cook.fuzzyVoiceMatch
import com.keepcooking.app.cook.ingredientId
import com.keepcooking.app.cook.normalizeVoiceText
import com.keepcooking.app.cook.parseTimers
import com.keepcooking.app.cook.parseVoiceCommand
import com.keepcooking.app.cook.roundToQuarter
import com.keepcooking.app.cook.scaleFactor
import com.keepcooking.app.cook.scaledDisplay
import com.keepcooking.app.cook.validatedStep
import com.keepcooking.app.cook.voiceNumberValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Logic tests mirroring apps/ios/Features/Cook/CookTests.swift:
 * scaling, timer parsing, and the voice parser.
 */
class CookLogicTest {
    // MARK: - Scaling 4 -> 6 servings

    @Test
    fun scaleFactor4to6() {
        assertEquals(1.5, scaleFactor(4.0, 6.0), 0.0)
    }

    @Test
    fun scaleFactorClamped() {
        assertEquals(4.0, scaleFactor(4.0, 40.0), 0.0) // 10x -> 4x
        assertEquals(0.25, scaleFactor(4.0, 0.1), 0.0) // tiny -> 0.25x
        assertEquals(1.0, scaleFactor(0.0, 6.0), 0.0) // degenerate
    }

    @Test
    fun fractionDisplay() {
        assertEquals("1½", fractionDisplayString(1.5))
        assertEquals("6", fractionDisplayString(6.0)) // 4 cups @1.5x
        assertEquals("½", fractionDisplayString(0.5))
        assertEquals("¼", fractionDisplayString(0.25))
        assertEquals("2½", fractionDisplayString(2.5))
        assertEquals("12½", fractionDisplayString(12.5))
        assertEquals("4", fractionDisplayString(4.0))
    }

    @Test
    fun scaledDisplay4to6() {
        assertEquals("6 cups flour", scaledDisplay("flour", 4.0, "cups", 1.5))
        assertEquals("1½ cup sugar", scaledDisplay("sugar", 1.0, "cup", 1.5))
        assertEquals("Salt to taste", scaledDisplay("Salt to taste", null, "", 1.5))
    }

    // MARK: - Timer parser

    @Test
    fun timerParserRangeUsesUpperBound() {
        val timers = parseTimers("bake 12-15 min")
        assertEquals(1, timers.size)
        assertEquals(15 * 60, timers[0].seconds)
    }

    @Test
    fun timerParserMultiTimer() {
        val timers = parseTimers("bake 12-15 min, rest 1 hr")
        assertEquals(2, timers.size)
        assertEquals(15 * 60, timers[0].seconds)
        assertEquals(3600, timers[1].seconds)
    }

    @Test
    fun timerParserSeconds() {
        val timers = parseTimers("sear 30 seconds per side")
        assertEquals(1, timers.size)
        assertEquals(30, timers[0].seconds)
    }

    @Test
    fun timerParserNoTimers() {
        assertTrue(parseTimers("chop the onions finely").isEmpty())
    }

    // MARK: - Cubic fixes: scaler ties, timer fractions/compounds/labels

    @Test
    fun roundToQuarterTiesAwayFromZero() {
        // 1/8 sits exactly between 0 and 1/4: iOS .rounded() goes to 1/4.
        assertEquals(0.25, roundToQuarter(0.125), 0.0)
        assertEquals(0.5, roundToQuarter(0.375), 0.0)
        assertEquals(2.75, roundToQuarter(2.625), 0.0)
        assertEquals(1.0, roundToQuarter(1.0), 0.0)
    }

    @Test
    fun timerParserFractionYieldsNoTimer() {
        // "1/2 hour" is a quantity, not a duration: neither the "1" (blocked
        // by what follows) nor the "2" (preceded by "/") may match.
        assertTrue(parseTimers("simmer 1/2 hour").isEmpty())
        assertTrue(parseTimers("add 3/4 cup stock").isEmpty())
    }

    @Test
    fun timerParserCompoundSums() {
        val timers = parseTimers("simmer 1 hour 30 minutes")
        assertEquals(1, timers.size)
        assertEquals(90 * 60, timers[0].seconds)
        assertEquals("simmer", timers[0].label)
    }

    @Test
    fun timerParserCompoundWithAndSums() {
        val timers = parseTimers("bake 1 hour and 30 minutes")
        assertEquals(1, timers.size)
        assertEquals(90 * 60, timers[0].seconds)
    }

    @Test
    fun timerParserSecondLabelExcludesFirstDuration() {
        val timers = parseTimers("bake 12-15 min, rest 1 hr")
        assertEquals(2, timers.size)
        assertEquals("bake", timers[0].label)
        // Must be "rest", not "min rest" (words from the first duration leak).
        assertEquals("rest", timers[1].label)
    }

    // MARK: - Session: Finish is idempotent, card toggle unmarks

    @Test
    fun markStepDoneIdempotent() {
        val session = CookSession(stepCount = 3)
        session.markStepDone("s-last")
        session.markStepDone("s-last")
        assertTrue(session.crossedOffSteps.contains("s-last"))
        session.toggleStep("s-last")
        assertFalse(session.crossedOffSteps.contains("s-last"))
    }

    // MARK: - Timer scheduling: stable unique identifiers

    @Test
    fun scheduleIdsUniqueAcrossCalls() {
        val timer = ParsedTimer(seconds = 600, label = "bake")
        val first = CookActivityStub.makeIDs(listOf(timer))
        val second = CookActivityStub.makeIDs(listOf(timer))
        assertEquals(1, first.size)
        assertEquals(1, second.size)
        assertNotEquals(first[0], second[0])
    }

    @Test
    fun scheduleIdsUniqueWithinBatch() {
        val timers = listOf(ParsedTimer(600, "bake"), ParsedTimer(600, "rest"))
        val ids = CookActivityStub.makeIDs(timers)
        assertEquals(2, ids.size)
        assertNotEquals(ids[0], ids[1])
    }

    // MARK: - Voice parser

    @Test
    fun voiceNextPreviousRepeat() {
        assertEquals(VoiceCommand.Next, parseVoiceCommand("next"))
        assertEquals(VoiceCommand.Next, parseVoiceCommand("  Next. "))
        assertEquals(VoiceCommand.Previous, parseVoiceCommand("previous step"))
        assertEquals(VoiceCommand.RepeatStep, parseVoiceCommand("repeat that"))
        assertEquals(VoiceCommand.Next, parseVoiceCommand("keep cooking next"))
        assertEquals(VoiceCommand.Previous, parseVoiceCommand("hey keep cooking, previous step"))
        // Retired wake word is rejected.
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("smidgen next"))
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("hey smidgen, previous step"))
    }

    @Test
    fun voiceGoToStep() {
        assertEquals(VoiceCommand.GoToStep(3), parseVoiceCommand("go to step 3"))
        assertEquals(VoiceCommand.GoToStep(3), parseVoiceCommand("go to step three"))
        assertEquals(VoiceCommand.GoToStep(VoiceCommand.LAST_STEP), parseVoiceCommand("go to the last step"))
    }

    @Test
    fun voiceStartOver() {
        assertEquals(VoiceCommand.StartOver, parseVoiceCommand("start over"))
    }

    @Test
    fun voiceTimerExtraction() {
        assertEquals(VoiceCommand.StartTimer(600, null), parseVoiceCommand("start a timer for 10 minutes"))
        assertEquals(VoiceCommand.StartTimer(900, null), parseVoiceCommand("start a timer for 12-15 minutes"))
        assertEquals(VoiceCommand.StartTimer(600, null), parseVoiceCommand("start a timer for ten minutes"))
        assertEquals(VoiceCommand.StartTimer(null, null), parseVoiceCommand("start the timer"))
        // Paprika parity: duration before "timer", no "for".
        assertEquals(VoiceCommand.StartTimer(600, null), parseVoiceCommand("set a 10 minute timer"))
        assertEquals(VoiceCommand.StartTimer(300, null), parseVoiceCommand("start a 5 minute timer"))
        // Articles doubling as the quantity ("a" = 1) still parse.
        assertEquals(VoiceCommand.StartTimer(60, null), parseVoiceCommand("set a minute timer"))
        assertEquals(VoiceCommand.StartTimer(3600, null), parseVoiceCommand("set an hour timer"))
        assertEquals(VoiceCommand.StartTimer(6000, null), parseVoiceCommand("set a hundred minute timer"))
        // Bare verbs and bare plurals stay unknown.
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("set"))
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("start timers"))
    }

    @Test
    fun voiceTimerCompoundSums() {
        assertEquals(VoiceCommand.StartTimer(5400, null), parseVoiceCommand("set a timer for 1 hour 30 minutes"))
        assertEquals(VoiceCommand.StartTimer(5400, null), parseVoiceCommand("set a timer for one hour and thirty minutes"))
        assertEquals(VoiceCommand.StartTimer(5400, null), parseVoiceCommand("set a timer for 1 hour thirty minutes"))
    }

    @Test
    fun voiceScaleCommands() {
        assertEquals(VoiceCommand.DoubleScale, parseVoiceCommand("double the recipe"))
        assertEquals(VoiceCommand.HalveScale, parseVoiceCommand("halve the recipe"))
        assertEquals(VoiceCommand.ResetScale, parseVoiceCommand("reset the scale"))
    }

    @Test
    fun voiceWakeWordPrefixRule() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("halve it"))
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("double it"))
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("come again"))
        assertEquals(VoiceCommand.HalveScale, parseVoiceCommand("keep cooking halve it"))
        assertEquals(VoiceCommand.DoubleScale, parseVoiceCommand("keep cooking double it"))
        assertEquals(VoiceCommand.RepeatStep, parseVoiceCommand("keep cooking come again"))
        assertEquals(VoiceCommand.RepeatStep, parseVoiceCommand("keep cooking what was that?"))
        assertEquals(VoiceCommand.StopCooking, parseVoiceCommand("keep cooking cancel"))
    }

    @Test
    fun voiceMidSentenceGuard() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("please tell me the next step"))
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("can you go to step 3 for me"))
    }

    @Test
    fun voiceCrossUncrossFuzzy() {
        assertEquals(VoiceCommand.CrossOff("flour"), parseVoiceCommand("cross off the flour"))
        assertEquals(VoiceCommand.Uncross("flour"), parseVoiceCommand("uncross flour"))
        assertEquals("All-purpose flour", fuzzyVoiceMatch("flour", listOf("All-purpose flour", "Sugar")))
    }

    @Test
    fun voiceAddToList() {
        assertEquals(VoiceCommand.AddToList(null), parseVoiceCommand("add the ingredients to my list"))
        assertEquals(VoiceCommand.AddToList("costco"), parseVoiceCommand("add the ingredients to my costco list"))
    }

    @Test
    fun voiceIngredientAmount() {
        assertEquals(VoiceCommand.IngredientAmount("flour"), parseVoiceCommand("how much flour do i need"))
        // Lenient auxiliary ("How much flour I need?" without "do").
        assertEquals(VoiceCommand.IngredientAmount("flour"), parseVoiceCommand("how much flour i need"))
    }

    @Test
    fun voiceStopCommands() {
        assertEquals(VoiceCommand.StopSpeaking, parseVoiceCommand("stop speaking"))
        assertEquals(VoiceCommand.StopCooking, parseVoiceCommand("stop cooking"))
    }

    @Test
    fun voiceScaleHelper() {
        assertEquals(8.0, applyScaleCommand(ScaleVoiceCommand.DOUBLE, 4.0, 4.0), 0.0)
        assertEquals(2.0, applyScaleCommand(ScaleVoiceCommand.HALVE, 4.0, 4.0), 0.0)
        assertEquals(4.0, applyScaleCommand(ScaleVoiceCommand.RESET, 4.0, 9.0), 0.0)
    }

    @Test
    fun voiceIngredientIdHelper() {
        val ingredients = listOf(VoiceIngredientRef("i1", "All-purpose flour"), VoiceIngredientRef("i2", "Sugar"))
        assertEquals("i1", ingredientId("flour", ingredients))
        assertNull(ingredientId("cinnamon", ingredients))
    }

    // MARK: - Voice parser hardening (Lane 10 P1/P2)

    @Test
    fun voiceNormalizeAsciiApostrophe() {
        assertEquals("im done", normalizeVoiceText("I'm done"))
    }

    @Test
    fun voiceNormalizeCurlyApostrophe() {
        assertEquals("im done", normalizeVoiceText("I’m done"))
    }

    @Test
    fun voiceWakeWordImDone() {
        assertEquals(VoiceCommand.Next, parseVoiceCommand("keep cooking I’m done"))
        assertEquals(VoiceCommand.Next, parseVoiceCommand("keep cooking I'm done"))
    }

    @Test
    fun voiceBareImDoneUnknown() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("I'm done"))
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("I’m done"))
    }

    @Test
    fun fuzzyExactEqualityWins() {
        assertEquals("sea salt", fuzzyVoiceMatch("sea salt", listOf("sea salt", "sea salt flakes")))
    }

    @Test
    fun fuzzyTokenOverlapBeatsSubstring() {
        assertEquals("sea salt", fuzzyVoiceMatch("salt", listOf("salty snacks", "sea salt")))
    }

    @Test
    fun fuzzyNonBoundarySubstringRejected() {
        assertNull(fuzzyVoiceMatch("our", listOf("flour")))
    }

    @Test
    fun fuzzyPrefixSubstringRejected() {
        assertNull(fuzzyVoiceMatch("flo", listOf("flour")))
    }

    @Test
    fun fuzzyMostMatchedTokensWins() {
        assertEquals(
            "flour sugar salt",
            fuzzyVoiceMatch("flour sugar salt", listOf("flour sugar", "flour sugar salt")),
        )
    }

    @Test
    fun fuzzyLongestSpanWinsOnTokenCountTie() {
        assertEquals(
            "pepper flakes",
            fuzzyVoiceMatch("pepper salt", listOf("pepper flakes", "pepperoni salt")),
        )
    }

    @Test
    fun fuzzyTieReturnsNull() {
        assertNull(fuzzyVoiceMatch("flour", listOf("white flour", "wheat flour")))
    }

    @Test
    fun fuzzyExactDuplicateTieReturnsNull() {
        assertNull(fuzzyVoiceMatch("flour", listOf("Flour", "flour")))
    }

    @Test
    fun fuzzyNoMatchReturnsNull() {
        assertNull(fuzzyVoiceMatch("cinnamon", listOf("flour", "sugar")))
    }

    @Test
    fun fuzzyEmptyQueryReturnsNull() {
        assertNull(fuzzyVoiceMatch("  ", listOf("flour")))
    }

    @Test
    fun fuzzyEmptyCandidatesReturnsNull() {
        assertNull(fuzzyVoiceMatch("flour", emptyList()))
    }

    @Test
    fun fuzzyHyphenBoundaryMatches() {
        assertEquals("all-purpose flour", fuzzyVoiceMatch("purpose", listOf("all-purpose flour", "sugar")))
    }

    @Test
    fun voiceIngredientIdAmbiguousReturnsNull() {
        val ingredients = listOf(VoiceIngredientRef("i1", "white flour"), VoiceIngredientRef("i2", "wheat flour"))
        assertNull(ingredientId("flour", ingredients))
    }

    @Test
    fun voiceTimerZeroMinutesUnknown() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("start a timer for 0 minutes"))
    }

    @Test
    fun voiceTimerHugeHoursUnknown() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("start a timer for 100 hours"))
    }

    @Test
    fun voiceTimerTwelveHoursOk() {
        assertEquals(VoiceCommand.StartTimer(43200, null), parseVoiceCommand("start a timer for 12 hours"))
    }

    @Test
    fun voiceTimerThirteenHoursUnknown() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("start a timer for 13 hours"))
    }

    @Test
    fun voiceTimerHugeSecondsUnknown() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("start a timer for 50000 seconds"))
    }

    @Test
    fun voiceTimerFractionalMinuteOk() {
        assertEquals(VoiceCommand.StartTimer(30, null), parseVoiceCommand("start a timer for 0.5 minutes"))
    }

    @Test
    fun voiceTimerOneHundredMinutes() {
        assertEquals(VoiceCommand.StartTimer(6000, null), parseVoiceCommand("start a timer for one hundred minutes"))
    }

    @Test
    fun voiceTimerOneHundredTwentyFiveMinutes() {
        assertEquals(
            VoiceCommand.StartTimer(7500, null),
            parseVoiceCommand("start a timer for one hundred twenty five minutes"),
        )
    }

    @Test
    fun voiceTimerTwoHundredFiftyMinutesNoTruncation() {
        assertEquals(
            VoiceCommand.StartTimer(15000, null),
            parseVoiceCommand("start a timer for two hundred fifty minutes"),
        )
    }

    @Test
    fun voiceTimerAHundredSeconds() {
        assertEquals(VoiceCommand.StartTimer(100, null), parseVoiceCommand("set a timer for a hundred seconds"))
    }

    @Test
    fun voiceTimerOneHundredAndFiveSeconds() {
        assertEquals(
            VoiceCommand.StartTimer(105, null),
            parseVoiceCommand("set a timer for one hundred and five seconds"),
        )
    }

    @Test
    fun voiceTimerOneThousandSeconds() {
        assertEquals(VoiceCommand.StartTimer(1000, null), parseVoiceCommand("set a timer for one thousand seconds"))
    }

    @Test
    fun voiceTimerBareHundredUnknown() {
        assertEquals(VoiceCommand.Unknown, parseVoiceCommand("start a timer for hundred minutes"))
    }

    @Test
    fun voiceGoToStepParseCarriesAsIs() {
        assertEquals(VoiceCommand.GoToStep(99), parseVoiceCommand("go to step 99"))
    }

    @Test
    fun validatedStepInRange() {
        assertEquals(3, validatedStep(3, 5))
    }

    @Test
    fun validatedStepFirstAndLast() {
        assertEquals(1, validatedStep(1, 5))
        assertEquals(5, validatedStep(5, 5))
    }

    @Test
    fun validatedStepOutOfRange() {
        assertNull(validatedStep(9, 5))
    }

    @Test
    fun validatedStepZeroNull() {
        assertNull(validatedStep(0, 5))
    }

    @Test
    fun validatedStepLastMapsToCount() {
        assertEquals(5, validatedStep(VoiceCommand.LAST_STEP, 5))
    }

    @Test
    fun validatedStepEmptyRecipeNull() {
        assertNull(validatedStep(1, 0))
        assertNull(validatedStep(VoiceCommand.LAST_STEP, 0))
    }

    @Test
    fun voiceNumberValueBasics() {
        assertEquals(3, voiceNumberValue("three"))
        assertEquals(25, voiceNumberValue("twenty five"))
        assertNull(voiceNumberValue("hundred"))
    }
}
