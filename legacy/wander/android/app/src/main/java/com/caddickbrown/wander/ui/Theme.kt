package com.caddickbrown.wander.ui

import android.content.Context
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * A theme is a palette, a set of faces and a handful of chrome switches. All
 * fourteen are defined once, in Resources/themes.json, and read from there by
 * the Apple builds, by the icon generator, by the Tauri build and — through the
 * copy in this app's assets — by this one. A theme is described in one place and
 * looks the same in four.
 */
@Immutable
data class Tone(val hex: Int, val alpha: Float = 1f) {

    constructor(string: String) : this(
        string.removePrefix("#").toIntOrNull(16) ?: 0
    )

    val r: Float get() = ((hex shr 16) and 0xFF) / 255f
    val g: Float get() = ((hex shr 8) and 0xFF) / 255f
    val b: Float get() = (hex and 0xFF) / 255f

    val color: Color get() = Color(r, g, b, alpha)

    /** The packed ARGB an Android span or paint wants. */
    val argb: Int
        get() = ((alpha * 255).toInt() and 0xFF shl 24) or (hex and 0xFFFFFF)

    fun opacity(a: Float): Tone = Tone(hex, a)

    /** Perceived lightness, 0–1. Used to decide what can be read on top. */
    val luminance: Float get() = 0.2126f * r + 0.7152f * g + 0.0722f * b

    /**
     * Whichever of two tones actually contrasts with this one. Measured, not
     * assumed: in a dark theme `ink` is near-white, so picking it as "the dark
     * one" put white text on a white block.
     */
    fun readable(first: Tone, second: Tone): Tone =
        if (abs(first.luminance - luminance) >= abs(second.luminance - luminance)) first else second

    /** Contrast ratio against another tone, on the usual 1–21 scale. */
    fun contrast(other: Tone): Float {
        val a = luminance + 0.05f
        val b = other.luminance + 0.05f
        return max(a, b) / min(a, b)
    }

    /**
     * The first candidate that can actually be read on this tone, else the one
     * that comes closest. Acid yellow is a fine fill and terrible text on white;
     * this is what tells them apart.
     */
    fun legible(candidates: List<Tone>, minimum: Float = 3.2f): Tone =
        candidates.firstOrNull { contrast(it) >= minimum }
            ?: candidates.maxByOrNull { contrast(it) }
            ?: candidates[0]
}

enum class RowStyle { RULE, PLAIN, CARD, BLOCK, INDENT }
enum class Ornament { NONE, WASH, LETTERBOX, WEDGE, GHOST, CONFETTI, RAIL }
enum class MastheadStyle { RULE, BAND, CENTRED, DOUBLE, NONE }
enum class StatsStyle { ROWS, FIGURES }
enum class SchemeHint(val label: String) {
    LIGHT("Light"), DARK("Dark"), BOTH("Light or dark")
}

/** A face a theme asks for: preferred families in order, and a shape to fall back to. */
@Immutable
data class FaceSpec(val families: List<String>, val shape: Shape) {
    enum class Shape { SERIF, SANS, MONO, ROUNDED }
}

@Immutable
data class Theme(
    val id: String,
    val name: String,
    val note: String,

    // Palette
    val paper: Tone,
    val panel: Tone,
    val surface: Tone,
    val ink: Tone,
    val prose: Tone,
    val muted: Tone,
    val rule: Tone,
    val ruleFaint: Tone,
    val accent: Tone,
    val accentDeep: Tone,
    val tint: Tone,
    val green: Tone,

    // Type
    val proseFace: FaceSpec,
    val proseWeight: FontWeight,
    val proseSize: Float,
    val displayFace: FaceSpec,
    val displayWeight: FontWeight,
    val displayScale: Float,
    val displayUppercase: Boolean,
    val displayTracking: Float,
    val labelFace: FaceSpec,
    val labelWeight: FontWeight,
    val labelSize: Float,
    val labelTracking: Float,
    val labelUppercase: Boolean,

    // Chrome
    val mastheadRule: Float,
    val mastheadStyle: MastheadStyle,
    val statsStyle: StatsStyle,
    val kicker: Boolean,
    val rowStyle: RowStyle,
    val corner: Float,
    val border: Float,
    val filledButtons: Boolean,
    val ornament: Ornament,
    val centred: Boolean,
    val measure: Float,
    val lineHeight: Float,
    val figureBlocks: Boolean,
    val pageCard: Boolean,
    val rowColours: Boolean,
    val recommended: SchemeHint,
) {
    /** The title as this theme sets it, in sp. */
    val titleSize: Float get() = 30f * displayScale

    /**
     * The accent, where it is being used as text rather than as a fill: a theme
     * whose accent is acid yellow needs something else on a pale ground.
     */
    val accentInk: Tone get() = paper.legible(listOf(accent, ink, accentDeep, tint))

    /** The accent as it must read on the ink band of a `band` masthead. */
    val accentOnBand: Tone get() = ink.legible(listOf(accent, tint, green, paper))

    /**
     * Distinct fills for the stats blocks. Several themes point two or three of
     * their colours at the same value — Brutalist's accent, ink and green are
     * all one white in the dark — so the list is deduplicated and padded with
     * the surface rather than repeating a block.
     */
    val figureFills: List<Tone>
        get() {
            val chosen = ArrayList<Tone>()
            for (tone in listOf(accent, tint, green, ink)) {
                if (chosen.none { it.hex == tone.hex }) chosen.add(tone)
            }
            while (chosen.size < 3) chosen.add(surface)
            return chosen
        }

    /** Code spans, wherever a theme doesn't already set prose in a mono face. */
    val monoFace: FaceSpec
        get() = if (proseFace.shape == FaceSpec.Shape.MONO) proseFace
        else FaceSpec(listOf("IBM Plex Mono"), FaceSpec.Shape.MONO)

    /**
     * An index row's title — the display face, at a weight that survives being
     * small in themes whose display weight is heavy.
     */
    val rowTitleWeight: FontWeight
        get() = when (displayWeight) {
            FontWeight.Black, FontWeight.Bold, FontWeight.ExtraBold -> FontWeight.SemiBold
            FontWeight.Light, FontWeight.Thin, FontWeight.ExtraLight -> FontWeight.Light
            else -> FontWeight.Normal
        }

    fun labelText(text: String): String = if (labelUppercase) text.uppercase() else text

    fun displayText(text: String): String = if (displayUppercase) text.uppercase() else text
}

/**
 * The catalogue, read once from assets/themes.json — the same file the other
 * three builds read, copied in by the build rather than rewritten by hand.
 */
object Themes {

    private var catalogue: List<ThemeEntry> = emptyList()

    /** The light and dark halves of one theme, as the file has them. */
    class ThemeEntry(val id: String, val name: String, val note: String,
                     val light: Theme, val dark: Theme) {
        fun resolve(dark: Boolean): Theme = if (dark) this.dark else this.light
        val hint: SchemeHint get() = light.recommended
    }

    val all: List<ThemeEntry> get() = catalogue

    fun load(context: Context) {
        if (catalogue.isNotEmpty()) return
        val text = runCatching {
            context.assets.open("themes.json").use { it.readBytes().toString(Charsets.UTF_8) }
        }.getOrNull() ?: return
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return
        val array = root.optJSONArray("themes") ?: return
        val out = ArrayList<ThemeEntry>(array.length())
        for (i in 0 until array.length()) {
            val entry = array.optJSONObject(i) ?: continue
            runCatching { parse(entry) }.getOrNull()?.let(out::add)
        }
        catalogue = out
    }

    fun named(id: String): ThemeEntry? = catalogue.firstOrNull { it.id == id }

    fun resolve(id: String, dark: Boolean): Theme =
        (named(id) ?: catalogue.firstOrNull())?.resolve(dark) ?: fallback

    private fun parse(entry: JSONObject): ThemeEntry {
        val id = entry.getString("id")
        val name = entry.optString("name", id)
        val note = entry.optString("note", "")
        val type = entry.getJSONObject("type")
        val chrome = entry.getJSONObject("chrome")
        val hint = when (entry.optString("scheme", "both")) {
            "light" -> SchemeHint.LIGHT
            "dark" -> SchemeHint.DARK
            else -> SchemeHint.BOTH
        }

        fun face(key: String): FaceSpec {
            val spec = type.getJSONObject(key)
            val families = spec.optJSONArray("families")
            val list = ArrayList<String>()
            if (families != null) for (i in 0 until families.length()) list.add(families.getString(i))
            return FaceSpec(list, shape(spec.optString("shape", "sans")))
        }

        fun weight(key: String): FontWeight =
            weightOf(type.getJSONObject(key).optString("weight", "regular"))

        fun palette(key: String): JSONObject = entry.getJSONObject(key)

        fun build(scheme: String): Theme {
            val p = palette(scheme)
            fun tone(name: String, fallbackHex: String) = Tone(p.optString(name, fallbackHex))
            return Theme(
                id = id, name = name, note = note,
                paper = tone("paper", "#FFFFFF"),
                panel = tone("panel", "#F4F4F4"),
                surface = tone("surface", "#FFFFFF"),
                ink = tone("ink", "#111111"),
                prose = tone("prose", "#333333"),
                muted = tone("muted", "#888888"),
                rule = tone("rule", "#DDDDDD"),
                ruleFaint = tone("ruleFaint", "#EEEEEE"),
                accent = tone("accent", "#9C3220"),
                accentDeep = tone("accentDeep", "#7A2416"),
                tint = tone("tint", "#6B8CA8"),
                green = tone("green", "#2F5D4A"),
                proseFace = face("prose"),
                proseWeight = weight("prose"),
                proseSize = type.getJSONObject("prose").optDouble("size", 17.5).toFloat(),
                displayFace = face("display"),
                displayWeight = weight("display"),
                displayScale = type.getJSONObject("display").optDouble("scale", 1.0).toFloat(),
                displayUppercase = type.getJSONObject("display").optBoolean("uppercase", false),
                displayTracking = type.getJSONObject("display").optDouble("tracking", 0.0).toFloat(),
                labelFace = face("label"),
                labelWeight = weight("label"),
                labelSize = type.getJSONObject("label").optDouble("size", 10.5).toFloat(),
                labelTracking = type.getJSONObject("label").optDouble("tracking", 1.1).toFloat(),
                labelUppercase = type.getJSONObject("label").optBoolean("uppercase", true),
                mastheadRule = chrome.optDouble("mastheadRule", 2.0).toFloat(),
                mastheadStyle = when (chrome.optString("mastheadStyle", "rule")) {
                    "band" -> MastheadStyle.BAND
                    "centred" -> MastheadStyle.CENTRED
                    "double" -> MastheadStyle.DOUBLE
                    "none" -> MastheadStyle.NONE
                    else -> MastheadStyle.RULE
                },
                statsStyle = if (chrome.optString("statsStyle", "rows") == "figures")
                    StatsStyle.FIGURES else StatsStyle.ROWS,
                kicker = chrome.optBoolean("kicker", false),
                rowStyle = when (chrome.optString("rowStyle", "rule")) {
                    "plain" -> RowStyle.PLAIN
                    "card" -> RowStyle.CARD
                    "block" -> RowStyle.BLOCK
                    "indent" -> RowStyle.INDENT
                    else -> RowStyle.RULE
                },
                corner = chrome.optDouble("corner", 0.0).toFloat(),
                border = chrome.optDouble("border", 1.0).toFloat(),
                filledButtons = chrome.optBoolean("filledButtons", true),
                ornament = when (chrome.optString("ornament", "none")) {
                    "wash" -> Ornament.WASH
                    "letterbox" -> Ornament.LETTERBOX
                    "wedge" -> Ornament.WEDGE
                    "ghost" -> Ornament.GHOST
                    "confetti" -> Ornament.CONFETTI
                    "rail" -> Ornament.RAIL
                    else -> Ornament.NONE
                },
                centred = chrome.optBoolean("centred", false),
                measure = chrome.optDouble("measure", 760.0).toFloat(),
                lineHeight = chrome.optDouble("lineHeight", 1.42).toFloat(),
                figureBlocks = chrome.optBoolean("figureBlocks", false),
                pageCard = chrome.optBoolean("pageCard", false),
                rowColours = chrome.optBoolean("rowColours", false),
                recommended = hint,
            )
        }

        return ThemeEntry(id, name, note, build("light"), build("dark"))
    }

    private fun shape(name: String): FaceSpec.Shape = when (name) {
        "serif" -> FaceSpec.Shape.SERIF
        "mono" -> FaceSpec.Shape.MONO
        "rounded" -> FaceSpec.Shape.ROUNDED
        else -> FaceSpec.Shape.SANS
    }

    private fun weightOf(name: String): FontWeight = when (name) {
        "thin" -> FontWeight.Thin
        "ultraLight", "extralight" -> FontWeight.ExtraLight
        "light" -> FontWeight.Light
        "medium" -> FontWeight.Medium
        "semibold" -> FontWeight.SemiBold
        "bold" -> FontWeight.Bold
        "heavy", "extrabold" -> FontWeight.ExtraBold
        "black" -> FontWeight.Black
        else -> FontWeight.Normal
    }

    /**
     * Used only if the theme file is missing from the assets — the app should
     * still open, in something legible.
     */
    val fallback = Theme(
        id = "almanac", name = "Almanac", note = "",
        paper = Tone("#F6F2EA"), panel = Tone("#F1ECE1"), surface = Tone("#FBF8F2"),
        ink = Tone("#171310"), prose = Tone("#453D33"), muted = Tone("#8A7F6D"),
        rule = Tone("#DDD5C7"), ruleFaint = Tone("#E6DED0"),
        accent = Tone("#9C3220"), accentDeep = Tone("#7A2416"),
        tint = Tone("#6B8CA8"), green = Tone("#2F5D4A"),
        proseFace = FaceSpec(listOf("Newsreader"), FaceSpec.Shape.SERIF),
        proseWeight = FontWeight.Normal, proseSize = 17.5f,
        displayFace = FaceSpec(listOf("Newsreader"), FaceSpec.Shape.SERIF),
        displayWeight = FontWeight.SemiBold, displayScale = 1f,
        displayUppercase = false, displayTracking = 0f,
        labelFace = FaceSpec(listOf("IBM Plex Sans"), FaceSpec.Shape.SANS),
        labelWeight = FontWeight.SemiBold, labelSize = 10.5f,
        labelTracking = 1.15f, labelUppercase = true,
        mastheadRule = 2f, mastheadStyle = MastheadStyle.RULE, statsStyle = StatsStyle.ROWS,
        kicker = false, rowStyle = RowStyle.RULE, corner = 0f, border = 1f,
        filledButtons = true, ornament = Ornament.NONE, centred = false,
        measure = 760f, lineHeight = 1.42f, figureBlocks = false, pageCard = false,
        rowColours = false, recommended = SchemeHint.BOTH,
    )
}
