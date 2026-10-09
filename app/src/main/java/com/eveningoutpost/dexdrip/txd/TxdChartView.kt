package com.eveningoutpost.dexdrip.txd

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Minimal glucose line chart with a 70–180 target band (iOS status chart). */
class TxdChartView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    private var points: List<TxdBridge.Point> = emptyList()
    private var hours = 6
    private val band = Paint().apply { color = 0x1A4CD964; style = Paint.Style.FILL }
    private val grid = Paint().apply { color = 0x1FFFFFFF; strokeWidth = 1f }
    private val line = Paint().apply { color = 0xFFBF59F2.toInt(); strokeWidth = 4f; style = Paint.Style.STROKE; isAntiAlias = true }
    private val dot = Paint().apply { isAntiAlias = true }
    private val text = Paint().apply { color = 0xFF9A9A9E.toInt(); textSize = 26f; isAntiAlias = true }
    private val fmt = SimpleDateFormat("h a", Locale.getDefault())

    fun setPoints(p: List<TxdBridge.Point>, hours: Int) {
        points = p
        this.hours = hours
        invalidate()
    }

    override fun onDraw(c: Canvas) {
        super.onDraw(c)
        val left = 70f
        val bottom = height - 40f
        val top = 20f
        val now = System.currentTimeMillis()
        val lo = now - hours * 3600_000L
        val yMax = maxOf(250.0, (points.maxOfOrNull { it.mgdl } ?: 0.0) + 20)
        val yMin = 40.0
        fun x(ts: Long) = left + ((ts - lo).toFloat() / (now - lo)) * (width - left - 10f)
        fun y(v: Double) = (bottom - ((v - yMin) / (yMax - yMin)).toFloat() * (bottom - top))

        c.drawRect(left, y(180.0), width.toFloat(), y(70.0), band)
        for (g in listOf(40, 70, 100, 140, 180, 250)) {
            c.drawLine(left, y(g.toDouble()), width.toFloat(), y(g.toDouble()), grid)
            c.drawText(g.toString(), 4f, y(g.toDouble()) + 9f, text)
        }
        val labels = 6
        for (i in 0..labels) {
            val ts = lo + (now - lo) * i / labels
            val xx = x(ts)
            c.drawLine(xx, top, xx, bottom, grid)
            if (i < labels) c.drawText(fmt.format(Date(ts)), xx + 2f, height - 8f, text)
        }
        if (points.isEmpty()) {
            c.drawText("No readings in this window yet.", left + 10f, (top + bottom) / 2, text)
            return
        }
        val path = Path()
        points.forEachIndexed { i, p -> if (i == 0) path.moveTo(x(p.ts), y(p.mgdl)) else path.lineTo(x(p.ts), y(p.mgdl)) }
        c.drawPath(path, line)
        val r = if (hours <= 6) 7f else 4f
        points.forEach { p ->
            dot.color = when { p.mgdl < 70 -> Color.RED; p.mgdl > 180 -> 0xFFFF9F0A.toInt(); else -> 0xFFBF59F2.toInt() }
            c.drawCircle(x(p.ts), y(p.mgdl), r, dot)
        }
        val last = points.last()
        dot.color = Color.WHITE
        c.drawCircle(x(last.ts), y(last.mgdl), 10f, dot)
        val lbl = Paint(text).apply { color = Color.WHITE; textSize = 30f; isFakeBoldText = true }
        c.drawText(Math.round(last.mgdl).toString(), x(last.ts) - 18f, y(last.mgdl) - 16f, lbl)
    }
}
