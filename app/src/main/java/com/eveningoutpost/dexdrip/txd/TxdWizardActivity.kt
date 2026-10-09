package com.eveningoutpost.dexdrip.txd

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.View
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.eveningoutpost.dexdrip.BaseAppCompatActivity
import com.eveningoutpost.dexdrip.Home
import com.eveningoutpost.dexdrip.R
import com.eveningoutpost.dexdrip.databinding.ActivityTxdWizardBinding
import com.eveningoutpost.dexdrip.utilitymodels.Pref

/**
 * TxD xDrip wizard + status front-end (Android twin of the iOS
 * `TxDSimpleRootView`). Start → Health Connect → Connect → Status.
 * "Advanced" opens the full xDrip+ Home; the engine is shared.
 */
class TxdWizardActivity : BaseAppCompatActivity() {

    private lateinit var b: ActivityTxdWizardBinding
    private val handler = Handler(Looper.getMainLooper())
    private var healthOk = false
    private var chartHours = 6
    private val ticker = object : Runnable {
        override fun run() { refresh(); handler.postDelayed(this, 5_000) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        b = ActivityTxdWizardBinding.inflate(layoutInflater)
        setContentView(b.root)
        supportActionBar?.hide()
        TxdBridge.applyDefaults()

        b.btnStart.setOnClickListener { go(TxdBridge.Step.HEALTH) }
        b.btnAllowHealth.setOnClickListener { TxdBridge.requestHealthAccess(this) }
        b.btnHealthContinue.setOnClickListener { go(TxdBridge.Step.CONNECT) }
        b.btnHealthInstall.setOnClickListener {
            runCatching {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata&url=healthconnect%3A%2F%2Fonboarding")))
            }
        }
        b.btnCompanion.setOnClickListener { TxdBridge.setupCompanion(this); refresh() }
        b.btnCompanionSettings.setOnClickListener { startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")) }
        b.btnDirect.setOnClickListener { askPairingCode() }
        b.btnConnectContinue.setOnClickListener { go(TxdBridge.Step.STATUS) }
        b.btnRefresh.setOnClickListener { refresh() }
        b.btnForget.setOnClickListener {
            AlertDialog.Builder(this).setTitle(R.string.txd_forget_title).setMessage(R.string.txd_forget_msg)
                .setPositiveButton(android.R.string.ok) { _, _ -> TxdBridge.forgetSource(); go(TxdBridge.Step.CONNECT) }
                .setNegativeButton(android.R.string.cancel, null).show()
        }
        b.btnAdvanced.setOnClickListener { startActivity(Intent(this, Home::class.java)) }
        listOf(b.h3 to 3, b.h6 to 6, b.h12 to 12, b.h24 to 24).forEach { (v, h) -> v.setOnClickListener { chartHours = h; refresh() } }

        // Resume where the user left off.
        if (TxdBridge.hasSource) TxdBridge.step = TxdBridge.Step.STATUS
        requestNotificationPermissionIfNeeded()
    }

    override fun onResume() {
        super.onResume()
        handler.post(ticker)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(ticker)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9101)
        }
    }

    private fun go(step: TxdBridge.Step) {
        TxdBridge.step = step
        refresh()
    }

    private fun askPairingCode() {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            hint = "4-digit pairing code"
            setText(Pref.getString("dex_txid", ""))
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.txd_direct_title)
            .setMessage(R.string.txd_direct_msg)
            .setView(input)
            .setPositiveButton(R.string.txd_connect) { _, _ ->
                val code = input.text.toString().trim()
                if (code.length == 4) { TxdBridge.setupDirect(this, code); refresh() }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ---- Rendering ----

    private fun refresh() {
        val step = TxdBridge.step
        val dots = listOf(b.dot1, b.dot2, b.dot3, b.dot4)
        dots.forEachIndexed { i, v -> v.alpha = if (i <= step.ordinal) 1f else 0.25f }
        b.stepWelcome.visibility = if (step == TxdBridge.Step.WELCOME) View.VISIBLE else View.GONE
        b.stepHealth.visibility = if (step == TxdBridge.Step.HEALTH) View.VISIBLE else View.GONE
        b.stepConnect.visibility = if (step == TxdBridge.Step.CONNECT) View.VISIBLE else View.GONE
        b.stepStatus.visibility = if (step == TxdBridge.Step.STATUS) View.VISIBLE else View.GONE

        val hcAvailable = TxdBridge.healthConnectAvailable(this)
        TxdBridge.checkHealthWrite(this) { ok ->
            healthOk = ok
            renderHealth(hcAvailable, ok)
            if (TxdBridge.step == TxdBridge.Step.STATUS) renderStatus()
        }
        if (step == TxdBridge.Step.CONNECT) renderConnect()
        if (step == TxdBridge.Step.STATUS) renderStatus()
    }

    private fun renderHealth(available: Boolean, ok: Boolean) {
        b.btnHealthInstall.visibility = if (available) View.GONE else View.VISIBLE
        b.btnAllowHealth.visibility = if (available && !ok) View.VISIBLE else View.GONE
        b.btnHealthContinue.visibility = if (ok) View.VISIBLE else View.GONE
        b.txtHealthState.text = when {
            !available -> getString(R.string.txd_hc_missing)
            ok -> getString(R.string.txd_hc_ok)
            else -> getString(R.string.txd_hc_need)
        }
        b.txtHealthState.setTextColor(if (ok) 0xFF4CD964.toInt() else 0xFFFFB84D.toInt())
    }

    private fun renderConnect() {
        val mode = TxdBridge.mode
        val listener = TxdBridge.notificationListenerEnabled(this)
        when {
            mode == TxdBridge.Mode.COMPANION && !listener -> {
                b.txtConnectState.text = getString(R.string.txd_companion_need_access)
                b.btnCompanionSettings.visibility = View.VISIBLE
                b.btnConnectContinue.visibility = View.GONE
            }
            mode == TxdBridge.Mode.COMPANION -> {
                b.txtConnectState.text = getString(R.string.txd_companion_ready)
                b.btnCompanionSettings.visibility = View.GONE
                b.btnConnectContinue.visibility = View.VISIBLE
            }
            mode == TxdBridge.Mode.DIRECT -> {
                b.txtConnectState.text = getString(R.string.txd_direct_ready, Pref.getString("dex_txid", ""))
                b.btnCompanionSettings.visibility = View.GONE
                b.btnConnectContinue.visibility = View.VISIBLE
            }
            else -> {
                b.txtConnectState.text = ""
                b.btnCompanionSettings.visibility = View.GONE
                b.btnConnectContinue.visibility = View.GONE
            }
        }
    }

    private fun renderStatus() {
        val s = TxdBridge.status()
        b.rowSource.text = s.sourceName
        val listening = when (s.mode) {
            TxdBridge.Mode.COMPANION -> TxdBridge.notificationListenerEnabled(this)
            TxdBridge.Mode.DIRECT -> true
            else -> false
        }
        val fresh = s.lastTs != null && System.currentTimeMillis() - s.lastTs < 20 * 60_000L
        b.rowConnection.text = when {
            !listening -> getString(R.string.txd_state_not_listening)
            fresh -> getString(R.string.txd_state_connected)
            else -> getString(R.string.txd_state_waiting)
        }
        b.rowConnection.setTextColor(if (fresh) 0xFF4CD964.toInt() else if (listening) 0xFFFFD60A.toInt() else 0xFFFF9F0A.toInt())
        b.rowLast.text = if (s.lastMgdl != null && s.lastTs != null) "${s.lastMgdl} mg/dL · ${rel(s.lastTs)}" else getString(R.string.txd_none_yet)
        b.rowCount.text = s.count24h.toString()
        b.rowHealth.text = if (healthOk) getString(R.string.txd_hc_row_ok) else getString(R.string.txd_hc_row_bad)
        b.rowHealth.setTextColor(if (healthOk) 0xFF4CD964.toInt() else 0xFFFF9F0A.toInt())
        val cutoff = System.currentTimeMillis() - chartHours * 3600_000L
        b.chart.setPoints(s.points.filter { it.ts >= cutoff }, chartHours)
        listOf(b.h3 to 3, b.h6 to 6, b.h12 to 12, b.h24 to 24).forEach { (v, h) -> v.alpha = if (h == chartHours) 1f else 0.5f }
    }

    private fun rel(ts: Long): String {
        val s = (System.currentTimeMillis() - ts) / 1000
        return when {
            s < 90 -> "just now"
            s < 3600 -> "${s / 60} min ago"
            else -> "${s / 3600} h ago"
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        refresh()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }
}
