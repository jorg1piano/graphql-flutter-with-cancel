import 'dart:async';
import 'dart:convert';

import 'package:graphql/client.dart';
import 'package:http/http.dart' as http;

/// NB!
/// This is essentially a copy of gql_http_link-1.2.0/lib/src/link.dart
/// but instead of using Request we use AbortableRequest.
/// This in combination with [CancelToken] allows us to cancel
/// requests in-flight either manually, or when variables change.

typedef HttpResponseDecoder = FutureOr<Map<String, dynamic>?> Function(
    http.Response httpResponse);

/// A simple HttpLink implementation.
///
/// To use non-standard [Request] and [Response] shapes
/// you can override [serializeRequest], [parseResponse],
/// [parseError] and [parseLocation].
///
/// To customize the request headers you can pass a custom
/// [http.Client] to the constructor.

class HttpLinkCancellable extends Link {
  Map<String, Completer<void>> abortSignals = {};

  /// Endpoint of the GraphQL service
  final Uri uri;

  /// Default HTTP headers
  final Map<String, String> defaultHeaders;

  /// set to `true` to use the HTTP `GET` method for queries (but not for mutations)
  final bool useGETForQueries;

  /// Serializer used to serialize request
  final RequestSerializer serializer;

  /// Parser used to parse response
  final ResponseParser parser;

  /// A function that decodes the incoming http response to `Map<String, dynamic>`,
  /// the decoded map will be then passes to the `RequestSerializer`.
  /// It is recommended for performance to decode the response using `compute` function.
  /// ```
  /// httpResponseDecoder : (http.Response httpResponse) => Isolate.run(() =>
  ///             const Utf8Decoder()
  ///                 .fuse(const JsonDecoder())
  ///                 .convert(response.bodyBytes) as Map<String, dynamic>?))
  /// ```
  HttpResponseDecoder httpResponseDecoder;

  // use the hidden _JsonUtf8Decoder obtained by fusing
  // Utf8Decoder and JsonDecoder
  // see https://github.com/dart-lang/sdk/blob/5b2ea0c7a227d91c691d2ff8cbbeb5f7f86afdb9/sdk/lib/_internal/vm/lib/convert_patch.dart#L40
  static final Converter _defaultHttpResponseDecoder =
      const Utf8Decoder().fuse<Object?>(const JsonDecoder());

  static Map<String, dynamic>? _defaultHttpResponseDecode(
          http.Response httpResponse) =>
      _defaultHttpResponseDecoder.convert(httpResponse.bodyBytes)
          as Map<String, dynamic>?;

  http.Client? _httpClient;

  final bool followRedirects;

  /// Construct the Link
  ///
  /// You can pass a [httpClient] to extend to customize the network request.
  HttpLinkCancellable(
    String uri, {
    this.defaultHeaders = const {},
    this.useGETForQueries = false,
    http.Client? httpClient,
    this.serializer = const RequestSerializer(),
    this.parser = const ResponseParser(),
    this.httpResponseDecoder = _defaultHttpResponseDecode,
    this.followRedirects = false,
  }) : uri = Uri.parse(uri) {
    _httpClient = httpClient ?? http.Client();
  }

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) async* {
    final httpResponse = await _executeRequest(request);

    final response = await _parseHttpResponse(httpResponse);

    if (httpResponse.statusCode >= 300 ||
        (response.data == null && response.errors == null)) {
      throw HttpLinkServerException(
        response: httpResponse,
        parsedResponse: response,
        statusCode: httpResponse.statusCode,
      );
    }

    yield Response(
      data: response.data,
      errors: response.errors,
      response: response.response,
      context: _updateResponseContext(response, httpResponse),
    );
  }

  Context _updateResponseContext(
    Response response,
    http.Response httpResponse,
  ) {
    try {
      return response.context.withEntry(
        HttpLinkResponseContext(
          statusCode: httpResponse.statusCode,
          headers: httpResponse.headers,
        ),
      );
    } catch (e, stackTrace) {
      throw ContextWriteException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    }
  }

  Future<Response> _parseHttpResponse(http.Response httpResponse) async {
    try {
      final responseBody = await httpResponseDecoder(httpResponse);
      return parser.parseResponse(responseBody!);
    } catch (e, stackTrace) {
      throw HttpLinkParserException(
        originalException: e,
        originalStackTrace: stackTrace,
        response: httpResponse,
      );
    }
  }

  Future<http.Response> _executeRequest(Request request) async {
    final httpRequest = _prepareRequest(request);
    try {
      final response = await _httpClient!.send(httpRequest);
      return http.Response.fromStream(response);
    } catch (e, stackTrace) {
      throw ServerException(
        originalException: e,
        originalStackTrace: stackTrace,
        parsedResponse: null,
      );
    }
  }

  http.BaseRequest _prepareRequest(Request request) {
    final body = _encodeAttempter(
      request,
      serializer.serializeRequest,
    )(request);

    CancelToken? cancelToken;
    try {
      final entry = request.context.entry<CancelTokenEntry>();
      cancelToken = entry?.token;
    } catch (_) {
      // no cancel token provided
    }

    final contextHeaders = _getHttpLinkHeaders(request);
    final headers = {
      'Content-type': 'application/json',
      'Accept': '*/*',
      ...defaultHeaders,
      ...contextHeaders,
    };

    final fileMap = extractFlattenedFileMap(body);

    final useGetForThisRequest =
        fileMap.isEmpty && useGETForQueries && request.isQuery;

    if (useGetForThisRequest) {
      return http.AbortableRequest(
        'GET',
        uri.replace(
          queryParameters: _encodeAttempter(
            request,
            _encodeAsUriParams,
          )(body),
        ),
        abortTrigger: cancelToken?.future,
      )..headers.addAll(headers);
    }

    final httpBody = _encodeAttempter(
      request,
      (Map body) => json.encode(
        body,
        toEncodable: (dynamic object) =>
            (object is http.MultipartFile) ? null : object.toJson(),
      ),
    )(body);

    if (fileMap.isNotEmpty) {
      return http.MultipartRequest("POST", uri)
        ..body = httpBody
        ..addAllFiles(fileMap)
        ..headers.addAll(headers);
    }

    return http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: cancelToken?.future,
    )
      ..body = httpBody
      ..followRedirects = followRedirects
      ..headers.addAll(headers);
  }

  /// wrap an encoding transform in exception handling
  T Function(V) _encodeAttempter<T, V>(
    Request request,
    T Function(V) encoder,
  ) =>
      (V input) {
        try {
          return encoder(input);
        } catch (e, stackTrace) {
          throw RequestFormatException(
            originalException: e,
            originalStackTrace: stackTrace,
            request: request,
          );
        }
      };

  /// Closes the underlining [http.Client]
  @override
  Future<void> dispose() async {
    _httpClient?.close();
  }
}

Map<String, String> _getHttpLinkHeaders(Request request) {
  try {
    final HttpLinkHeaders? linkHeaders = request.context.entry();

    return {
      if (linkHeaders != null) ...linkHeaders.headers,
    };
  } catch (e, stackTrace) {
    throw ContextReadException(
      originalException: e,
      originalStackTrace: stackTrace,
    );
  }
}

Map<String, String> _encodeAsUriParams(Map<String, dynamic> serialized) =>
    serialized.map<String, String>(
      (k, dynamic v) => MapEntry(k, v is String ? v : json.encode(v)),
    );

// Copied from gql_http_link-1.2.0/lib/src/link.dart
Map<String, http.MultipartFile> extractFlattenedFileMap(
  dynamic body, {
  Map<String, http.MultipartFile>? currentMap,
  List<String> currentPath = const <String>[],
}) {
  currentMap ??= <String, http.MultipartFile>{};
  if (body is Map<String, dynamic>) {
    final Iterable<MapEntry<String, dynamic>> entries = body.entries;
    for (final MapEntry<String, dynamic> element in entries) {
      currentMap.addAll(
        extractFlattenedFileMap(
          element.value,
          currentMap: currentMap,
          currentPath: List<String>.from(currentPath)..add(element.key),
        ),
      );
    }
    return currentMap;
  }
  if (body is List<dynamic>) {
    for (int i = 0; i < body.length; i++) {
      currentMap.addAll(
        extractFlattenedFileMap(
          body[i],
          currentMap: currentMap,
          currentPath: List<String>.from(currentPath)..add(i.toString()),
        ),
      );
    }
    return currentMap;
  }

  if (body is http.MultipartFile) {
    return currentMap
      ..addAll({
        currentPath.join('.'): body,
      });
  }

  return currentMap;
}

extension AddAllFiles on http.MultipartRequest {
  void addAllFiles(Map<String, http.MultipartFile> fileMap) {
    final Map<String, List<String>> fileMapping = <String, List<String>>{};
    final List<http.MultipartFile> fileList = <http.MultipartFile>[];

    final List<MapEntry<String, http.MultipartFile>> fileMapEntries =
        fileMap.entries.toList(growable: false);

    for (int i = 0; i < fileMapEntries.length; i++) {
      final MapEntry<String, http.MultipartFile> entry = fileMapEntries[i];
      final String indexString = i.toString();
      fileMapping.addAll(<String, List<String>>{
        indexString: <String>[entry.key],
      });
      final http.MultipartFile f = entry.value;
      fileList.add(http.MultipartFile(
        indexString,
        f.finalize(),
        f.length,
        contentType: f.contentType,
        filename: f.filename,
      ));
    }

    fields["map"] = json.encode(fileMapping);

    files.addAll(fileList);
  }

  set body(String body) => fields["operations"] = body;
}
