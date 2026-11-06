package com.caddickbrown.wander.ui

import android.content.Context
import android.content.res.AssetManager
import android.graphics.Typeface
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import org.json.JSONObject
import kotlin.math.abs

/**
 * The themes are largely made of type, so the faces they need ship with the app
 * rather than being hoped for.
 *
 * The Apple builds register the whole Fonts folder with CoreText and then ask
 * for a family by name; Android has no such registry — a typeface is a file.
 * So the build writes assets/fonts/fonts.json, a manifest of every face with the
 * family, weight and slant read out of its `name` table, and this resolves a
 * theme's request against it, choosing the nearest weight when the exact one was
 * never drawn.
 */
object Fonts {

    private data class Face(
        val family: String,
        val weight: Int,
        val italic: Boolean,
        val file: String,
    )

    private var faces: List<Face> = emptyList()
    private val typefaces = HashMap<String, Typeface>()
    private val families = HashMap<String, FontFamily>()
    private lateinit var assets: AssetManager

    fun load(context: Context) {
        if (faces.isNotEmpty()) return
        assets = context.applicationContext.assets
        val text = runCatching {
            assets.open("fonts/fonts.json").use { it.readBytes().toString(Charsets.UTF_8) }
        }.getOrNull() ?: return
        val array = runCatching { JSONObject(text).optJSONArray("faces") }.getOrNull() ?: return
        val out = ArrayList<Face>(array.length())
        for (i in 0 until array.length()) {
            val face = array.optJSONObject(i) ?: continue
            out.add(
                Face(
                    family = face.optString("family"),
                    weight = face.optInt("weight", 400),
                    italic = face.optBoolean("italic", false),
                    file = face.optString("file"),
                )
            )
        }
        faces = out
    }

    /**
     * The file that best answers a request: the right family, the right slant if
     * one was drawn, and the nearest weight to the one asked for.
     *
     * A theme naming "Spectral Light" and a theme naming "Spectral" want
     * different files, and both are in the manifest under those names, because
     * that is how the families are actually named in the font binaries.
     */
    private fun file(families: List<String>, weight: Int, italic: Boolean): String? {
        for (family in families) {
            val candidates = faces.filter { it.family == family }
            if (candidates.isEmpty()) continue
            val slanted = candidates.filter { it.italic == italic }
            val pool = slanted.ifEmpty { candidates }
            return pool.minByOrNull { abs(it.weight - weight) }?.file
        }
        return null
    }

    private fun weightOf(weight: FontWeight): Int = weight.weight

    /** A Typeface for the prose editor, which is a platform text view. */
    fun typeface(spec: FaceSpec, weight: FontWeight, italic: Boolean = false): Typeface {
        val file = file(spec.families, weightOf(weight), italic) ?: return systemFace(spec, weight, italic)
        return typefaces.getOrPut("$file|${weightOf(weight)}|$italic") {
            runCatching { Typeface.createFromAsset(assets, "fonts/$file") }
                .getOrDefault(systemFace(spec, weight, italic))
        }
    }

    /**
     * A synthesised face, for the one case the manifest can't answer: a family
     * that somehow isn't in the assets. The shape is kept — a serif theme falls
     * back to a serif, not to whatever the system hands out.
     */
    private fun systemFace(spec: FaceSpec, weight: FontWeight, italic: Boolean): Typeface {
        val base = when (spec.shape) {
            FaceSpec.Shape.SERIF -> Typeface.SERIF
            FaceSpec.Shape.MONO -> Typeface.MONOSPACE
            else -> Typeface.SANS_SERIF
        }
        var style = Typeface.NORMAL
        if (weight.weight >= 600) style = style or Typeface.BOLD
        if (italic) style = style or Typeface.ITALIC
        return Typeface.create(base, style)
    }

    /**
     * A Compose family for a face, carrying every weight and slant the manifest
     * has for it, so `FontWeight` and `FontStyle` resolve the way they would for
     * a system family rather than needing a file picked per call site.
     */
    fun family(spec: FaceSpec): FontFamily {
        val key = spec.families.joinToString("|") + "/" + spec.shape
        families[key]?.let { return it }
        val family = spec.families.firstOrNull { name -> faces.any { it.family == name } }
        val built = if (family == null) {
            when (spec.shape) {
                FaceSpec.Shape.SERIF -> FontFamily.Serif
                FaceSpec.Shape.MONO -> FontFamily.Monospace
                else -> FontFamily.SansSerif
            }
        } else {
            FontFamily(
                faces.filter { it.family == family }.map { face ->
                    Font(
                        path = "fonts/${face.file}",
                        assetManager = assets,
                        weight = FontWeight(face.weight),
                        style = if (face.italic) FontStyle.Italic else FontStyle.Normal,
                    )
                }
            )
        }
        families[key] = built
        return built
    }
}
