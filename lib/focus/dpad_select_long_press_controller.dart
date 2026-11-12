import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult, VoidCallback;

import 'dpad_navigator.dart';

/// Tracks the timer and physical key state for a D-pad SELECT long press.
///
/// Focus loss, context-menu dispatch, and transferred/touch gesture suppression
/// stay with the caller because their behavior differs between widgets.
class DpadSelectLongPressController {
  static const defaultDuration = Duration(milliseconds: 500);

  Timer? _timer;
  bool _isKeyDown = false;

  KeyEventResult handleKeyEvent(
    KeyEvent event, {
    Duration duration = defaultDuration,
    required bool Function() isOwnerActive,
    required VoidCallback onShortPress,
    required VoidCallback onLongPress,
  }) {
    if (!event.logicalKey.isSelectKey) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      // Some platforms report another down instead of a repeat. Only the
      // transition from up to down may start (or restart) the timer.
      if (!_isKeyDown) {
        debugPrint('[SynopsisDebug] SELECT down: long-press timer started');
        _isKeyDown = true;
        _timer?.cancel();
        _timer = Timer(duration, () {
          debugPrint('[SynopsisDebug] SELECT timer fired; ownerActive=${isOwnerActive()}, keyDown=$_isKeyDown');
          if (!isOwnerActive() || !_isKeyDown) return;
          SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
          debugPrint('[SynopsisDebug] invoking long-press callback');
          onLongPress();
        });
      }
      return KeyEventResult.handled;
    }

    if (event is KeyRepeatEvent) return KeyEventResult.handled;

    if (event is KeyUpEvent) {
      debugPrint('[SynopsisDebug] SELECT up; timerActive=${_timer?.isActive}, keyDown=$_isKeyDown');
      final timerWasActive = _timer?.isActive ?? false;
      _timer?.cancel();
      if (timerWasActive && _isKeyDown) onShortPress();
      _isKeyDown = false;
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void reset() {
    _timer?.cancel();
    _isKeyDown = false;
  }

  void dispose() => reset();
}
