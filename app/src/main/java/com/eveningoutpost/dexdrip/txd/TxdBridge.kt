package com.eveningoutpost.dexdrip.txd

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import androidx.health.connect.client.HealthConnectClient
import androidx.core.app.ActivityCompat
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.BloodGlucoseRecord
import com.eveningoutpost.dexdrip.healthconnect.HealthGamut
import com.eveningoutpost.dexdrip.models.BgReading
import com.eveningoutpost.dexdrip.models.Sensor
import com.eveningoutpost.dexdrip.services.Ob1G5CollectionService
import com.eveningoutpost.dexdrip.services.UiBasedCollector
import com.eveningoutpost.dexdrip.utilitymodels.CollectionServiceStarter
import com.eveningoutpost.dexdrip.utilitymodels.Pref
import com.eveningoutpost.dexdrip.utils.DexCollectionType
import com.eveningoutpost.dexdrip.utils.LocationHelper
import kotlinx.coroutines.runBlocking

/**
 * TxD xDrip — thin bridge front-end over the xDrip+ engine (Android twin of
 * the iOS `TxDBridgeModel`).
 *
 * Drives the whole setup the way a user would otherwise do by hand:
 *   1. defaults: mg/dL, Health Connect send on
 *   2. Health Connect write permission (the only bridge to Food Health TxD)
 *   3. a glucose source: "Companion app" (reads the Stelo/G7 app's
 *      notifications, the vendor app keeps the sensor) or direct Bluetooth
 *      to the G7/ONE+/Stelo (xDrip+ owns the sensor; vendor app must go)
 *   4. status: last reading, readings in 24 h, Health Connect state
 * Everything below calls the same engine code the full UI uses; nothing in
 * the collector / database / Health Connect layers is touched.
 */
object TxdBridge {

    enum class Step { WELCOME, HEALTH, CONNECT, STATUS }
    enum class Mode { NONE, COMPANION, DIRECT }

    private const val PREF_STEP = "txd_wizard_step"
    private const val PREF_MODE = "txd_connect_mode"

    var step: Step
        get() = runCatching { Step.valueOf(Pref.getString(PREF_STEP, Step.WELCOME.name)) }.getOrDefault(Step.WELCOME)
        set(v) { Pref.setString(PREF_STEP, v.name) }

    var mode: Mode
        get() = runCatching { Mode.valueOf(Pref.getString(PREF_MODE, Mode.NONE.name)) }.getOrDefault(Mode.NONE)
        set(v) { Pref.setString(PREF_MODE, v.name) }

    /** Defaults a bridge needs: mg/dL and Health Connect sending. */
    fun applyDefaults() {
        if (Pref.getString("units", "mgdl") != "mgdl") Pref.setString("units", "mgdl")
        Pref.setBoolean("health_connect_enable", true)
        Pref.setBoolean("health_connect_send", true)
    }

    // ---- Health Connect ----

    fun healthConnectAvailable(ctx: Context): Boolean =
        HealthConnectClient.getSdkStatus(ctx) == HealthConnectClient.SDK_AVAILABLE

    private val writeGlucose = HealthPermission.getWritePermission(BloodGlucoseRecord::class)

    /** Blocking check (runs the suspend call on a worker thread); result on main thread. */
    fun checkHealthWrite(ctx: Context, cb: (Boolean) -> Unit) {
        if (!healthConnectAvailable(ctx)) { cb(false); return }
        Thread {
            val ok = runCatching {
                runBlocking { HealthConnectClient.getOrCreate(ctx).permissionController.getGrantedPermissions() }
                    .contains(writeGlucose)
            }.getOrDefault(false)
            Handler(Looper.getMainLooper()).post { cb(ok) }
        }.start()
    }

    /** Ask only for glucose read/write (the engine's full list is for its own Health Connect import features). */
    fun requestHealthAccess(activity: Activity) {
        applyDefaults()
        val perms = setOf(HealthPermission.getReadPermission(BloodGlucoseRecord::class), writeGlucose)
        val intent = PermissionController.createRequestPermissionResultContract().createIntent(activity, perms)
        runCatching {
            if (Build.VERSION.SDK_INT >= 34) {
                val names = intent.getStringArrayExtra("androidx.activity.result.contract.extra.PERMISSIONS") ?: perms.toTypedArray()
                ActivityCompat.requestPermissions(activity, names, 9102)
            } else {
                activity.startActivityForResult(intent, 9102)
            }
        }.onFailure { HealthGamut.init(activity) }
    }

    // ---- Sources ----

    /** "Companion app": read the Stelo / G7 app's notifications. The vendor app keeps the sensor. */
    fun setupCompanion(activity: Activity) {
        mode = Mode.COMPANION
        Pref.setBoolean("bluetails_enabled", true)
        UiBasedCollector.switchToAndEnable(activity)
        CollectionServiceStarter.restartCollectionServiceBackground()
    }

    /** Direct Bluetooth to a G7 / ONE+ / Stelo using the 4-digit pairing code from the applicator. */
    fun setupDirect(activity: Activity, pairingCode: String) {
        mode = Mode.DIRECT
        val code = pairingCode.trim().uppercase()
        Ob1G5CollectionService.setG6Defaults()
        DexCollectionType.setDexCollectionType(DexCollectionType.DexcomG5)
        Pref.setString("dex_txid", code)
        Ob1G5CollectionService.clearDataWhenTransmitterIdEntered(code)
        Sensor.createDefaultIfMissing()
        CollectionServiceStarter.restartCollectionServiceBackground()
        LocationHelper.requestLocationForBluetooth(activity)
    }

    fun forgetSource() {
        mode = Mode.NONE
        DexCollectionType.setDexCollectionType(DexCollectionType.None)
        Pref.setString("dex_txid", "")
        CollectionServiceStarter.restartCollectionServiceBackground()
        step = Step.CONNECT
    }

    val hasSource: Boolean
        get() = when (DexCollectionType.getDexCollectionType()) {
            DexCollectionType.UiBased -> true
            DexCollectionType.DexcomG5 -> Pref.getString("dex_txid", "").isNotBlank()
            else -> false
        }

    /** Mirrors the engine's private `isNotificationServiceEnabled`. */
    fun notificationListenerEnabled(ctx: Context): Boolean {
        val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners")
        if (TextUtils.isEmpty(flat)) return false
        return flat.split(":").any { ComponentName.unflattenFromString(it)?.packageName == ctx.packageName }
    }

    // ---- Status ----

    data class Point(val ts: Long, val mgdl: Double)
    data class Status(
        val mode: Mode,
        val sourceName: String,
        val lastMgdl: Int?,
        val lastTs: Long?,
        val count24h: Int,
        val points: List<Point>,
    )

    fun status(): Status {
        val last = runCatching { BgReading.last() }.getOrNull()
        val dayAgo = System.currentTimeMillis() - 24L * 3600 * 1000
        val day = runCatching { BgReading.latestForGraph(4000, dayAgo) }.getOrDefault(emptyList())
        val pts = day.filter { it.calculated_value > 20 }.map { Point(it.timestamp, it.calculated_value) }.sortedBy { it.ts }
        val name = when (DexCollectionType.getDexCollectionType()) {
            DexCollectionType.UiBased -> "Stelo app (companion)"
            DexCollectionType.DexcomG5 -> "Dexcom " + (Pref.getString("dex_txid", "").ifBlank { "G7/Stelo" })
            else -> "not set"
        }
        return Status(
            mode = mode,
            sourceName = name,
            lastMgdl = last?.calculated_value?.let { if (it > 20) Math.round(it).toInt() else null },
            lastTs = last?.timestamp,
            count24h = day.size,
            points = pts,
        )
    }
}
