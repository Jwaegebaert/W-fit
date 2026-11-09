import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.status});

  final String code;
  final String message;
  final int? status;

  bool get isLimit => status == 429;
  bool get isOffline => code == 'offline';

  @override
  String toString() => message;
}

class ApiConfig {
  const ApiConfig({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  bool get isConfigured => baseUrl.isNotEmpty && apiKey.isNotEmpty;

  static const empty = ApiConfig(baseUrl: '', apiKey: '');
}

/// Persists the backend URL and API key in Android encrypted storage.
class ApiConfigStore {
  ApiConfigStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _urlKey = 'api_base_url';
  static const _keyKey = 'api_key';
  static const _defaultUrl = String.fromEnvironment('WFIT_API_URL');

  Future<ApiConfig> load() async {
    try {
      final url = await _storage.read(key: _urlKey) ?? _defaultUrl;
      final key = await _storage.read(key: _keyKey) ?? '';
      return ApiConfig(baseUrl: url, apiKey: key);
    } catch (_) {
      return const ApiConfig(baseUrl: _defaultUrl, apiKey: '');
    }
  }

  Future<void> save(ApiConfig config) async {
    await _storage.write(key: _urlKey, value: config.baseUrl.trim());
    await _storage.write(key: _keyKey, value: config.apiKey.trim());
  }
}

class ApiClient {
  ApiClient(this.config, {http.Client? client}) : _http = client ?? http.Client();

  final ApiConfig config;
  final http.Client _http;

  Uri _uri(String path) {
    var base = config.baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (!base.endsWith('/api')) base = '$base/api';
    return Uri.parse('$base/$path');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-Api-Key': config.apiKey,
      };

  Future<Map<String, dynamic>> get(String path, {Duration timeout = const Duration(seconds: 30)}) =>
      _send(() => _http.get(_uri(path), headers: _headers), timeout);

  Future<Map<String, dynamic>> post(String path, Object body, {Duration timeout = const Duration(seconds: 60)}) =>
      _send(() => _http.post(_uri(path), headers: _headers, body: jsonEncode(body)), timeout);

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call, Duration timeout) async {
    if (!config.isConfigured) {
      throw ApiException('not_configured', 'Connect the app to your W-fit backend in Settings.');
    }
    http.Response res;
    try {
      res = await call().timeout(timeout);
    } on TimeoutException {
      throw ApiException('offline', 'The server took too long to respond.');
    } catch (_) {
      throw ApiException('offline', 'No connection to the W-fit server.');
    }
    Map<String, dynamic> body = const {};
    if (res.body.isNotEmpty) {
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {}
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    throw ApiException(
      body['error'] as String? ?? 'http_${res.statusCode}',
      body['message'] as String? ?? _defaultMessage(res.statusCode),
      status: res.statusCode,
    );
  }

  static String _defaultMessage(int status) => switch (status) {
        401 => 'The API key was rejected.',
        429 => 'AI usage limit reached for now.',
        503 => 'The AI coach is unavailable right now.',
        _ => 'Server error ($status).',
      };

  Future<Map<String, dynamic>> health() => get('health', timeout: const Duration(seconds: 20));

  // Serverless SQL can take ~60 s to resume from auto-pause.
  Future<Map<String, dynamic>> sync(Map<String, dynamic> request) =>
      post('sync', request, timeout: const Duration(seconds: 120));

  // AI endpoints are stateless (the coach brief travels in the request); the server allows a fallback attempt.
  static const aiTimeout = Duration(seconds: 130);

  Future<Map<String, dynamic>> generateWorkout(Map<String, dynamic> request) =>
      post('ai/workout', request, timeout: aiTimeout);

  Future<Map<String, dynamic>> adjust(Map<String, dynamic> request) => post('ai/adjust', request, timeout: aiTimeout);

  Future<Map<String, dynamic>> swap(Map<String, dynamic> request) =>
      post('ai/swap', request, timeout: const Duration(seconds: 90));

  Future<Map<String, dynamic>> insights(Map<String, dynamic> brief) =>
      post('ai/insights', {'brief': brief}, timeout: aiTimeout);

  Future<Map<String, dynamic>> usage() => get('ai/usage', timeout: const Duration(seconds: 90));
}
