import 'dart:async';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:graphql/src/links/cancel_token.dart';

/// A [Link] that automatically cancels previous in-flight requests from the
/// same ObservableQuery when variables change.
///
/// This is particularly useful for solving race conditions in scenarios like:
/// - Search autocomplete (cancel previous search when user types more)
/// - File/folder browsers (cancel previous request when switching folders)
/// - Paginated lists (cancel old page request when switching pages)
///
/// The link tracks requests by queryId (from ObservableQuery). When a new
/// request comes in from the same ObservableQuery, the old request is cancelled.
///
/// **Note**: This link does NOT deduplicate requests from different ObservableQueries
/// with the same query and variables. Use DedupeLink from gql_dedupe_link for that.
///
/// Example usage:
/// ```dart
/// final httpLink = HttpLink('https://api.example.com/graphql');
/// final cancellationLink = CancellationLink();
///
/// final client = GraphQLClient(
///   link: Link.from([
///     cancellationLink,  // Add before your http link
///     httpLink,
///   ]),
///   cache: GraphQLCache(),
/// );
///
/// // Now when using ObservableQuery:
/// final observable = client.watchQuery(
///   WatchQueryOptions(
///     document: gql(query),
///     variables: {'id': 1},
///     fetchPolicy: FetchPolicy.cacheAndNetwork,
///   ),
/// );
///
/// // Change variables - old request is automatically cancelled
/// observable.variables = {'id': 2};
/// observable.fetchResults();
/// ```
///
/// **Important Notes:**
/// - This link must be placed BEFORE your HTTP link in the chain
/// - The HTTP link must support cancellation (e.g., via AbortableRequest)
/// - Cancellation happens automatically when the same ObservableQuery makes a new request
/// - Multiple ObservableQueries with the same query/variables will NOT cancel each other
class CancellationLink extends Link {
  // Track by queryId for ObservableQuery requests (cancels when variables change)
  final Map<String, CancelToken> _activeQueryIds = {};

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    if (forward == null) {
      return;
    }

    // Extract queryId if present (from ObservableQuery requests)
    String? queryId;
    try {
      queryId = request.context.entry<QueryIdEntry>()?.queryId;
    } catch (_) {}

    // Cancel previous request from same ObservableQuery (when variables change)
    if (queryId != null) {
      final previousQueryToken = _activeQueryIds[queryId];
      if (previousQueryToken != null && !previousQueryToken.isCancelled) {
        previousQueryToken.cancel();
      }
    }

    // Create a new cancel token for this request
    final cancelToken = CancelToken();
    if (queryId != null) {
      _activeQueryIds[queryId] = cancelToken;
    }

    // Add the cancel token to the request context so downstream links can use it
    final updatedRequest = Request(
      operation: request.operation,
      variables: request.variables,
      context: request.context.withEntry(CancelTokenEntry(cancelToken)),
    );

    try {
      await for (final response in forward(updatedRequest)) {
        // Only yield responses if the request hasn't been cancelled
        if (!cancelToken.isCancelled) {
          yield response;
        } else {
          // Request was cancelled, stop processing
          break;
        }
      }
    } catch (error) {
      // Only rethrow if the request wasn't cancelled
      // If cancelled, silently stop (the cancellation is intentional)
      if (!cancelToken.isCancelled) {
        rethrow;
      }
    } finally {
      // Clean up: remove this token if it's still the active one
      if (queryId != null && _activeQueryIds[queryId] == cancelToken) {
        _activeQueryIds.remove(queryId);
      }
    }
  }


  /// Cancels all active requests.
  void cancelAll() {
    for (final token in _activeQueryIds.values) {
      if (!token.isCancelled) {
        token.cancel();
      }
    }
    _activeQueryIds.clear();
  }
}
