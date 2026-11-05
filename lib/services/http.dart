import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Identifies the app to OSM-based services, as their usage policies require.
const String userAgent = 'VeloSM/1.0 (bicycle touring app; Flutter)';

class ServiceException implements Exception {
  final String message;

  const ServiceException(this.message);

  @override
  String toString() => message;
}

/// Thin HTTP helper with a user agent, timeouts and readable errors.
class Http {
  final http.Client client;

  Http([http.Client? client]) : client = client ?? http.Client();

  Map<String, String> get _headers => {'User-Agent': userAgent};

  Future<String> get(Uri uri, {Duration timeout = const Duration(seconds: 60)}) async {
    final res = await _guard(() => client.get(uri, headers: _headers), timeout, uri);
    return _body(res, uri);
  }

  Future<String> postForm(Uri uri, Map<String, String> form,
      {Duration timeout = const Duration(seconds: 120)}) async {
    final res = await _guard(
        () => client.post(uri, headers: _headers, body: form), timeout, uri);
    return _body(res, uri);
  }

  Future<dynamic> getJson(Uri uri, {Duration timeout = const Duration(seconds: 60)}) async =>
      jsonDecode(await get(uri, timeout: timeout));

  Future<http.Response> _guard(
      Future<http.Response> Function() f, Duration timeout, Uri uri) async {
    try {
      return await f().timeout(timeout);
    } on TimeoutException {
      throw ServiceException('${uri.host} did not answer in time.');
    } on http.ClientException catch (e) {
      throw ServiceException('Network error (${uri.host}): ${e.message}');
    } catch (e) {
      if (e is ServiceException) rethrow;
      throw ServiceException('Network error (${uri.host}): $e');
    }
  }

  String _body(http.Response res, Uri uri) {
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode == 200) return body;
    final text = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    throw HttpStatusException(res.statusCode, '${uri.host}: HTTP ${res.statusCode} ${text.trim()}');
  }
}

class HttpStatusException extends ServiceException {
  final int status;

  const HttpStatusException(this.status, super.message);
}
