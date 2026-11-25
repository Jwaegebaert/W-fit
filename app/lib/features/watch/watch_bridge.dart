import 'package:flutter/services.dart';

/// Phone side of the Wearable Data Layer (`WatchBridge.kt`). Every call is best effort: without a watch, Google Play
/// services or the platform channel (tests) nothing happens.
class WatchBridge {
  const WatchBridge();

  static const _channel = MethodChannel('wfit/watch');

  Future<bool> available() async => await _call<bool>('available') ?? false;

  /// Replaces the snapshot the watch sees.
  Future<void> publish(String json) => _call<void>('publish', json);

  /// Messages from the watch that are still waiting, e.g. from while the app was closed.
  Future<List<String>> pending() async => (await _call<List<Object?>>('pending'))?.whereType<String>().toList() ?? [];

  /// Opens the watch app, when it is installed on a connected watch.
  Future<void> openOnWatch() => _call<void>('open');

  void listen(void Function(String json) onMessage) => _channel.setMethodCallHandler((call) async {
        final json = call.arguments;
        if (call.method == 'message' && json is String) onMessage(json);
      });

  Future<T?> _call<T>(String method, [Object? arg]) async {
    try {
      return await _channel.invokeMethod<T>(method, arg);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
