package com.caddickbrown.wander.editor

import android.content.Context
import android.os.Build
import android.text.Editable
import android.text.InputType
import android.text.Spannable
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import androidx.appcompat.widget.AppCompatEditText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.caddickbrown.wander.ui.Fonts
import com.caddickbrown.wander.ui.Theme

/**
 * The writing surface: a platform text view holding plain markdown, styled in
 * place. There is no preview pane — a heading looks like a heading while you
 * type it, and the markers themselves recede to a hairline grey.
 *
 * macOS uses NSTextView and iOS UITextView; this is the third of the same idea,
 * on Android's EditText. Going through the platform text view rather than
 * drawing our own is what buys the things a journal on a phone lives or dies by:
 * the IME's composing region, autocorrect, the selection handles, the magnifier,
 * dictation, and a soft keyboard that knows where the caret is.
 */
class ProseEditText(context: Context) : AppCompatEditText(context) {

    /** Replaced by `update` as the theme, the type size or focus mode change. */
    var styler: MarkdownStyler? = null
    var typewriter: Boolean = false
    var dimInactive: Boolean = false
    var onProseChanged: ((String) -> Unit)? = null

    /** True while the styler is running, so nothing it does can re-enter. */
    private var styling = false

    init {
        layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        background = null
        setPadding(0, 0, 0, 0)
        gravity = Gravity.TOP or Gravity.START
        isSingleLine = false
        maxLines = Int.MAX_VALUE
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        setHorizontallyScrolling(false)
        includeFontPadding = false
        // Sentence caps, autocorrect on: the IME composes and corrects here
        // exactly as it would in any other text field, which is the point.
        inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
            InputType.TYPE_TEXT_FLAG_AUTO_CORRECT

        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                if (styling || s == null) return
                restyle(s, restyleAll = false)
                onProseChanged?.invoke(s.toString())
                if (typewriter) scrollCaretToEye()
            }
        })
    }

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        // Focus mode follows the caret, so moving it is a restyle even when
        // nothing was typed.
        if (dimInactive) text?.let { restyle(it, restyleAll = true) }
        if (typewriter) scrollCaretToEye()
    }

    /**
     * Restyle in place. This only ever sets and clears spans — never a
     * character — so the input method's composing region survives it, and a
     * keystroke does not have to be rebuilt out from under the keyboard.
     */
    fun restyle(target: Editable, restyleAll: Boolean) {
        val styler = styler ?: return
        styling = true
        styler.apply(target as Spannable, selectionStart.coerceAtLeast(0), restyleAll)
        styling = false
    }

    /**
     * Typewriter scrolling: keep the line being written at eye level rather than
     * letting it walk to the bottom of the screen, which on a phone means
     * writing into the strip left above the keyboard.
     */
    private fun scrollCaretToEye() {
        val layout = layout ?: return
        if (height == 0) return
        val line = layout.getLineForOffset(selectionStart.coerceAtLeast(0))
        val target = layout.getLineTop(line) - (height * 0.38f).toInt()
        val limit = (layout.height - height).coerceAtLeast(0)
        scrollTo(0, target.coerceIn(0, limit))
    }

    /** Wrap the selection in a marker — the ⌘B and ⌘I of the desktop builds. */
    fun wrapSelection(marker: String) {
        val editable = text ?: return
        val from = minOf(selectionStart, selectionEnd).coerceAtLeast(0)
        val to = maxOf(selectionStart, selectionEnd).coerceAtLeast(0)
        val selected = editable.subSequence(from, to).toString()
        // Wrapping an already-wrapped selection unwraps it, so the button is a
        // toggle rather than a way to end up with four asterisks.
        val already = selected.length >= marker.length * 2 &&
            selected.startsWith(marker) && selected.endsWith(marker)
        if (already) {
            val inner = selected.substring(marker.length, selected.length - marker.length)
            editable.replace(from, to, inner)
            setSelection(from, from + inner.length)
        } else {
            editable.replace(from, to, "$marker$selected$marker")
            setSelection(from + marker.length, from + marker.length + selected.length)
        }
    }
}

/** Everything the editor needs that isn't the text itself. */
data class ProseStyle(
    val theme: Theme,
    val size: Float,          // sp
    val leading: Float,
    val typewriter: Boolean,
    val dimInactive: Boolean,
)

@Composable
fun ProseEditor(
    text: String,
    style: ProseStyle,
    onTextChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    onViewReady: (ProseEditText) -> Unit = {},
) {
    val density = LocalDensity.current
    val sizePx = with(density) { style.size.sp.toPx() }
    // The styler is rebuilt when the look changes, not when the text does.
    val styler = remember(style.theme, sizePx, style.leading, style.dimInactive) {
        MarkdownStyler(style.theme, sizePx, style.leading, style.dimInactive)
    }

    AndroidView(
        modifier = modifier,
        factory = { context -> ProseEditText(context).also(onViewReady) },
        update = { view ->
            view.styler = styler
            view.typewriter = style.typewriter
            view.dimInactive = style.dimInactive
            view.onProseChanged = onTextChange

            view.setTextSize(TypedValue.COMPLEX_UNIT_SP, style.size)
            view.typeface = Fonts.typeface(style.theme.proseFace, style.theme.proseWeight)
            view.setTextColor(style.theme.prose.argb)
            view.setHintTextColor(style.theme.muted.opacity(0.5f).argb)
            view.highlightColor = style.theme.accent.opacity(0.22f).argb
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                runCatching { view.textCursorDrawable?.setTint(style.theme.accent.argb) }
            }
            // sp to px through TypedValue: `scaledDensity` is deprecated, and on a
            // device with non-linear font scaling it was never the right number.
            val extra = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP,
                style.size * style.leading,
                view.resources.displayMetrics,
            )
            view.setLineSpacing(extra, 1f)

            // Only when it actually differs: assigning the same string would
            // reset the composing region and the selection under the IME, which
            // is the classic way an Android editor eats a letter mid-word.
            if (view.text?.toString() != text) {
                view.setText(text)
                view.setSelection(view.text?.length ?: 0)
            }
            view.text?.let { view.restyle(it, restyleAll = true) }
        },
    )
}
