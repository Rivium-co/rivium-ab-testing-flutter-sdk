import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

/// The device services the SDK uses, in one place so tests can replace them.
class RiviumPlatform {
  RiviumPlatform._();

  static http.Client Function() httpClient = _defaultHttpClient;
  static Future<bool> Function() isOnline = _defaultIsOnline;
  static Stream<bool> Function() onlineChanges = _defaultOnlineChanges;

  static void restoreDefaults() {
    httpClient = _defaultHttpClient;
    isOnline = _defaultIsOnline;
    onlineChanges = _defaultOnlineChanges;
  }

  static http.Client _defaultHttpClient() => http.Client();

  static Future<bool> _defaultIsOnline() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  static Stream<bool> _defaultOnlineChanges() => Connectivity()
      .onConnectivityChanged
      .map((results) => !results.contains(ConnectivityResult.none));
}
