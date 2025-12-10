import 'dart:async';
import 'package:gql_exec/gql_exec.dart';

/// A token that can be used to cancel an in-flight GraphQL request.
///
/// When [cancel] is called, any HTTP request associated with this token
/// will be aborted (if the Link implementation supports cancellation).
///
/// Example usage:
/// ```dart
/// final cancelToken = CancelToken();
///
/// final result = client.query(
///   QueryOptions(
///     document: gql(query),
///     variables: {'id': 1},
///     context: Context.fromList([
///       CancelTokenEntry(cancelToken),
///     ]),
///   ),
/// );
///
/// // Later, to cancel the request:
/// cancelToken.cancel();
/// ```
class CancelToken {
  final Completer<void> _completer = Completer<void>();
  bool _isCancelled = false;

  /// Returns a [Future] that completes when [cancel] is called.
  Future<void> get future => _completer.future;

  /// Returns true if this token has been cancelled.
  bool get isCancelled => _isCancelled;

  /// Cancels the request associated with this token.
  ///
  /// This method is idempotent - calling it multiple times has the same
  /// effect as calling it once.
  void cancel() {
    if (!_isCancelled && !_completer.isCompleted) {
      _isCancelled = true;
      _completer.complete();
    }
  }
}

/// A [ContextEntry] that carries a [CancelToken] through the Link chain.
///
/// This allows Links to check if a request should be cancelled and to
/// set up cancellation listeners.
///
/// Example:
/// ```dart
/// final cancelToken = CancelToken();
/// final context = Context.fromList([
///   CancelTokenEntry(cancelToken),
/// ]);
/// ```
class CancelTokenEntry extends ContextEntry {
  /// The cancel token for this request.
  final CancelToken token;

  /// Creates a new [CancelTokenEntry] with the given [token].
  CancelTokenEntry(this.token);

  @override
  List<Object?> get fieldsForEquality => [token];
}

/// A [ContextEntry] that carries a query ID through the Link chain.
///
/// This is used by [CancellationLink] to track and cancel previous requests
/// from the same [ObservableQuery] when variables change.
///
/// For example, when using an ObservableQuery with changing variables:
/// ```dart
/// observable.variables = {'id': 1};
/// observable.fetchResults(); // Request 1 starts
///
/// observable.variables = {'id': 2};
/// observable.fetchResults(); // Request 1 is cancelled, Request 2 starts
/// ```
///
/// The queryId allows [CancellationLink] to identify that both requests
/// came from the same ObservableQuery and cancel the first one.
class QueryIdEntry extends ContextEntry {
  /// The query ID for this request.
  final String queryId;

  /// Creates a new [QueryIdEntry] with the given [queryId].
  QueryIdEntry(this.queryId);

  @override
  List<Object?> get fieldsForEquality => [queryId];
}
