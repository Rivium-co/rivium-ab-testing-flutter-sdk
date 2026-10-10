import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivium_ab_testing/src/platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

String tokenFor(String sub, {int expiresIn = 3600}) {
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': sub, 'exp': exp})))
      .replaceAll('=', '');
  return 'header.$payload.signature';
}

String? subOf(String? token) {
  if (token == null) return null;
  final payload = token.split('.')[1];
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))))[
      'sub'] as String?;
}

http.Response json(Object body, [int status = 200, Map<String, String>? headers]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...?headers});

http.Response tokenError(String code) =>
    json({'statusCode': 401, 'error': 'Unauthorized', 'code': code}, 401);

Map<String, dynamic> assignment(String key, String variant,
        {bool? inExperiment}) =>
    {
      'data': {
        'experimentId': 'id-$key',
        'experimentKey': key,
        'variantId': 'vid-$variant',
        'variantKey': variant,
        'variantName': variant,
        'config': {'colour': variant},
        'isControl': false,
        if (inExperiment != null) 'inExperiment': inExperiment,
      }
    };

/// A stand-in for the service. Records every request; [onPost] may answer a
/// POST, otherwise the defaults below apply.
class FakeService {
  final List<http.Request> requests = [];
  http.Response? Function(http.Request request)? onPost;
  List<Map<String, dynamic>> experiments = [];
  List<Map<String, dynamic>> flags = [];
  int assignStatus = 200;

  List<http.Request> posts([String? path]) => requests
      .where((r) => r.method == 'POST' && (path == null || r.url.path == path))
      .toList();

  http.Client client() => MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (request.method == 'GET') {
          if (path == '/public/experiments') return json({'data': experiments});
          if (path == '/public/flags') return json({'flags': flags});
          return json({'experiments': [], 'serverTime': 'now'});
        }
        final custom = onPost?.call(request);
        if (custom != null) return custom;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (path == '/public/assign') {
          return json(
              assignment(body['experimentKey'] as String, 'B'), assignStatus);
        }
        if (path == '/public/sync') {
          return json({
            'success': true,
            'synced': (body['events'] as List).length,
            'failed': 0,
          });
        }
        return json({'enabled': true, 'value': true});
      });

  /// Use this service for everything the SDK does, on a device that is online
  /// and has empty storage.
  void install() {
    SharedPreferences.setMockInitialValues({});
    RiviumPlatform.httpClient = client;
    RiviumPlatform.isOnline = () async => true;
    RiviumPlatform.onlineChanges = () => const Stream<bool>.empty();
  }
}

List<Map<String, dynamic>> eventsOf(http.Request request) =>
    ((jsonDecode(request.body) as Map<String, dynamic>)['events'] as List)
        .cast<Map<String, dynamic>>();

/// Let the SDK's background work (storage, requests) finish.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
