package com.edde746.plezy

import android.content.Context
import android.graphics.Color
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * A small, isolated preview player for the TV home spotlight.
 *
 * Unlike Plezy's primary playback surface, this uses Media3's TextureView
 * output. It can therefore live inside a Flutter layout box and cannot take
 * ownership of the app-wide MPV SurfaceView used by normal playback.
 */
internal class TrailerPreviewPlatformViewFactory :
  PlatformViewFactory(StandardMessageCodec.INSTANCE) {

  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val url = (args as? Map<*, *>)?.get("url") as? String
    return TrailerPreviewPlatformView(context, url)
  }
}

private class TrailerPreviewPlatformView(
  context: Context,
  url: String?
) : PlatformView {
  private val player = ExoPlayer.Builder(context).build()
  private val playerView = PlayerView(context).apply {
    useController = false
    setUseTextureView(true)
    setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_ZOOM)
    setShutterBackgroundColor(Color.TRANSPARENT)
    setKeepContentOnPlayerReset(true)
    setBackgroundColor(Color.TRANSPARENT)
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    isFocusable = false
    isFocusableInTouchMode = false
    player = this@TrailerPreviewPlatformView.player
  }

  init {
    player.volume = 0f
    player.repeatMode = Player.REPEAT_MODE_ONE
    if (!url.isNullOrBlank()) {
      player.setMediaItem(MediaItem.fromUri(url))
      player.prepare()
      player.playWhenReady = true
    }
  }

  override fun getView(): View = playerView

  override fun dispose() {
    playerView.player = null
    player.release()
  }
}
