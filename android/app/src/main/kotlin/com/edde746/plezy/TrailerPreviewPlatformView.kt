package com.edde746.plezy

import android.content.Context
import android.graphics.Color
import android.util.Log
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** One Media3 player shared by Discover and details corner surfaces. */
@OptIn(UnstableApi::class)
internal object TrailerPreviewPlayerManager {
  private const val TAG = "TrailerPreview"
  private val surfaces = LinkedHashMap<Int, SurfaceView>()
  private var player: ExoPlayer? = null
  private var currentUrl: String? = null
  private var completedUrl: String? = null
  private var activeViewId: Int? = null
  private var eventChannel: MethodChannel? = null
  private var awaitingFirstFrame = false

  @Synchronized
  fun setEventChannel(channel: MethodChannel) {
    eventChannel = channel
  }

  private fun notifySurfaceWaiting() {
    awaitingFirstFrame = true
    eventChannel?.invokeMethod("surfaceWaiting", null)
  }

  private fun notifySurfaceReady() {
    if (!awaitingFirstFrame) return
    awaitingFirstFrame = false
    eventChannel?.invokeMethod("surfaceReady", null)
  }

  @Synchronized
  fun attach(viewId: Int, context: Context, surface: SurfaceView, url: String?, audioEnabled: Boolean) {
    surfaces[viewId] = surface
    if (url.isNullOrBlank()) return
    if (completedUrl == url) {
      surface.visibility = View.GONE
      return
    }
    if (currentUrl != url || player == null) {
      releasePlayer()
      currentUrl = url
      completedUrl = null
      createPlayer(context.applicationContext, url, audioEnabled)
    }
    player?.volume = if (audioEnabled) 1f else 0f
    surfaces.values.forEach { it.visibility = View.GONE }
    surface.visibility = View.VISIBLE
    activeViewId = viewId
    notifySurfaceWaiting()
    player?.setVideoSurfaceView(surface)
    player?.playWhenReady = true
    Log.i(TAG, "Attached view=" + viewId + " to shared trailer session")
  }

  @Synchronized
  fun detach(viewId: Int) {
    surfaces.remove(viewId)
    if (activeViewId != viewId) return
    val fallback = surfaces.entries.lastOrNull()
    if (fallback != null && currentUrl != null && completedUrl != currentUrl) {
      surfaces.values.forEach { it.visibility = View.GONE }
      fallback.value.visibility = View.VISIBLE
      activeViewId = fallback.key
      notifySurfaceWaiting()
      player?.setVideoSurfaceView(fallback.value)
      player?.playWhenReady = true
      Log.i(TAG, "Transferred shared trailer surface to view=" + fallback.key)
    } else {
      player?.clearVideoSurface()
      player?.playWhenReady = false
      activeViewId = null
      Log.i(TAG, "No preview surface; retaining paused trailer session")
    }
  }

  @Synchronized
  fun stop() {
    Log.i(TAG, "Stopping shared trailer session on normal playback")
    releasePlayer()
    currentUrl = null
    completedUrl = null
    notifySurfaceReady()
    surfaces.values.forEach { it.visibility = View.GONE }
    activeViewId = null
  }

  private fun createPlayer(context: Context, url: String, audioEnabled: Boolean) {
    val httpFactory = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
    val mediaSourceFactory = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, httpFactory))
    val created = ExoPlayer.Builder(context).setMediaSourceFactory(mediaSourceFactory).build()
    player = created
    created.addListener(object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        if (player !== created) return
        Log.i(TAG, "Playback state=" + playbackState + ", playWhenReady=" + created.playWhenReady)
        if (playbackState == Player.STATE_ENDED) {
          synchronized(this@TrailerPreviewPlayerManager) {
            completedUrl = currentUrl
            Log.i(TAG, "Trailer finished; releasing decoder and revealing static artwork")
            notifySurfaceReady()
            releasePlayer()
            surfaces.values.forEach { it.visibility = View.GONE }
            activeViewId = null
          }
        }
      }
      override fun onVideoSizeChanged(videoSize: VideoSize) {
        Log.i(TAG, "Video size=" + videoSize.width + "x" + videoSize.height)
      }
      override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
        Log.e(TAG, "Native preview playback error: " + error.errorCodeName, error)
        synchronized(this@TrailerPreviewPlayerManager) {
          notifySurfaceReady()
        }
      }
      override fun onRenderedFirstFrame() {
        synchronized(this@TrailerPreviewPlayerManager) {
          notifySurfaceReady()
        }
        Log.i(TAG, "First trailer frame rendered")
      }
    })
    created.addAnalyticsListener(object : AnalyticsListener {
      override fun onVideoDecoderInitialized(
        eventTime: AnalyticsListener.EventTime,
        decoderName: String,
        initializedTimestampMs: Long,
        initializationDurationMs: Long
      ) {
        Log.i(TAG, "Video decoder=" + decoderName + ", initMs=" + initializationDurationMs)
      }
      override fun onDroppedVideoFrames(
        eventTime: AnalyticsListener.EventTime,
        droppedFrames: Int,
        elapsedMs: Long
      ) {
        Log.w(TAG, "Dropped video frames=" + droppedFrames + " in " + elapsedMs + "ms")
      }
    })
    created.volume = if (audioEnabled) 1f else 0f
    created.repeatMode = Player.REPEAT_MODE_OFF
    created.setMediaItem(MediaItem.fromUri(url))
    created.prepare()
    Log.i(TAG, "Created shared trailer player; audio enabled=" + audioEnabled)
  }

  private fun releasePlayer() {
    val old = player ?: return
    old.volume = 0f
    old.clearVideoSurface()
    old.stop()
    old.release()
    player = null
  }
}

internal class TrailerPreviewPlatformViewFactory :
  PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val params = args as? Map<*, *>
    val url = params?.get("url") as? String
    val audioEnabled = params?.get("audioEnabled") as? Boolean ?: true
    return TrailerPreviewPlatformView(context, viewId, url, audioEnabled)
  }
}

private class TrailerPreviewPlatformView(
  context: Context,
  private val viewId: Int,
  url: String?,
  audioEnabled: Boolean
) : PlatformView {
  private val surfaceView = SurfaceView(context)
  private val container = FrameLayout(context).apply {
    setBackgroundColor(Color.TRANSPARENT)
    addView(surfaceView, FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
      Gravity.CENTER
    ))
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
  }
  init {
    Log.i("TrailerPreview", "Native preview surface created; view=" + viewId + ", URL present=" + !url.isNullOrBlank())
    TrailerPreviewPlayerManager.attach(viewId, context, surfaceView, url, audioEnabled)
  }
  override fun getView(): View = container
  override fun dispose() {
    Log.i("TrailerPreview", "Disposing preview surface view=" + viewId)
    TrailerPreviewPlayerManager.detach(viewId)
  }
}
