package com.edde746.plezy

import android.content.Context
import android.util.Log
import android.graphics.Color
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * A small, isolated preview player for the TV home spotlight.
 *
 * The preview uses a dedicated SurfaceView for direct video presentation and
 * does not contend with Plezy's main player.
 */
internal class TrailerPreviewPlatformViewFactory :
  PlatformViewFactory(StandardMessageCodec.INSTANCE) {

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val params = args as? Map<*, *>
    val url = params?.get("url") as? String
    val audioEnabled = params?.get("audioEnabled") as? Boolean ?: true
    return TrailerPreviewPlatformView(context, url, audioEnabled)
  }
}

@OptIn(UnstableApi::class)
private class TrailerPreviewPlatformView(
  context: Context,
  url: String?,
  audioEnabled: Boolean
) : PlatformView {
  // Plex can answer trailer playback URLs with an HTTP 302 that changes
  // protocol (commonly HTTP -> HTTPS). ExoPlayer's default HTTP factory
  // rejects cross-protocol redirects, so explicitly allow them here.
  private val httpDataSourceFactory = DefaultHttpDataSource.Factory()
    .setAllowCrossProtocolRedirects(true)
  private val mediaSourceFactory = DefaultMediaSourceFactory(
    DefaultDataSource.Factory(context, httpDataSourceFactory)
  )
  private val player = ExoPlayer.Builder(context)
    .setMediaSourceFactory(mediaSourceFactory)
    .build()
  private val surfaceView = SurfaceView(context)
  private var playerReleased = false
  private val container = FrameLayout(context).apply {
    setBackgroundColor(Color.TRANSPARENT)
    addView(
      surfaceView,
      FrameLayout.LayoutParams(
        FrameLayout.LayoutParams.MATCH_PARENT,
        FrameLayout.LayoutParams.MATCH_PARENT,
        Gravity.CENTER
      )
    )
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    isFocusable = false
    isFocusableInTouchMode = false
  }

  init {
    Log.i("TrailerPreview", "Native preview view created; URL present=${!url.isNullOrBlank()}")
    player.addListener(object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        Log.i("TrailerPreview", "Playback state=$playbackState, playWhenReady=${player.playWhenReady}")
        if (playbackState == Player.STATE_ENDED) {
          // A SurfaceView owns a separate surface and can leave a black layer
          // above Flutter even when its container is merely INVISIBLE. Remove
          // the surface and release the player so the original artwork shows.
          Log.i("TrailerPreview", "Trailer finished; releasing preview and revealing static artwork")
          releasePlayer()
        }
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        Log.i("TrailerPreview", "Video size=${videoSize.width}x${videoSize.height}, pixelRatio=${videoSize.pixelWidthHeightRatio}")
      }

      override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
        Log.e("TrailerPreview", "Native preview playback error: ${error.errorCodeName}", error)
      }

      override fun onRenderedFirstFrame() {
        Log.i("TrailerPreview", "First trailer video frame rendered")
      }
    })
    player.addAnalyticsListener(object : AnalyticsListener {
      override fun onVideoDecoderInitialized(
        eventTime: AnalyticsListener.EventTime,
        decoderName: String,
        initializedTimestampMs: Long,
        initializationDurationMs: Long
      ) {
        Log.i("TrailerPreview", "Video decoder=$decoderName, initialization=${initializationDurationMs}ms")
      }

      override fun onDroppedVideoFrames(
        eventTime: AnalyticsListener.EventTime,
        droppedFrames: Int,
        elapsedMs: Long
      ) {
        Log.w("TrailerPreview", "Dropped video frames=$droppedFrames over ${elapsedMs}ms")
      }
    })
    player.volume = if (audioEnabled) 1f else 0f
    Log.i("TrailerPreview", "Trailer audio enabled=$audioEnabled")
    player.repeatMode = Player.REPEAT_MODE_OFF
    player.setVideoSurfaceView(surfaceView)
    if (!url.isNullOrBlank()) {
      player.setMediaItem(MediaItem.fromUri(url))
      player.prepare()
      player.playWhenReady = true
    }
  }

  override fun getView(): View = container

  private fun releasePlayer() {
    if (playerReleased) return
    playerReleased = true
    // Mute first, then detach the SurfaceView and release every decoder/audio
    // resource. This also guarantees no preview audio survives a navigation
    // transition or the start of normal playback.
    player.volume = 0f
    surfaceView.visibility = View.GONE
    container.visibility = View.GONE
    player.clearVideoSurfaceView(surfaceView)
    player.stop()
    player.release()
  }

  override fun dispose() {
    Log.i("TrailerPreview", "Disposing native preview view")
    releasePlayer()
  }
}
