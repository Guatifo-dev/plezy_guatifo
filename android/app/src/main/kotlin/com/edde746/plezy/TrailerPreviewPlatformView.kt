package com.edde746.plezy

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * A small, isolated preview player for the TV home spotlight.
 *
 * The preview renders directly into a TextureView so it stays within the
 * Flutter platform-view bounds and does not contend with Plezy's main player.
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
  private val textureView = TextureView(context)
  private val container = FrameLayout(context).apply {
    setBackgroundColor(Color.TRANSPARENT)
    addView(
      textureView,
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
    player.volume = 0f
    player.repeatMode = Player.REPEAT_MODE_ONE
    player.setVideoTextureView(textureView)
    if (!url.isNullOrBlank()) {
      player.setMediaItem(MediaItem.fromUri(url))
      player.prepare()
      player.playWhenReady = true
    }
  }

  override fun getView(): View = container

  override fun dispose() {
    player.clearVideoTextureView(textureView)
    player.release()
  }
}
