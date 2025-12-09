# Request Cancellation Guide

This guide explains how to cancel in-flight GraphQL requests to prevent race conditions and improve app performance.

## The Problem: Race Conditions

When using `ObservableQuery` with `FetchPolicy.cacheAndNetwork` and frequently changing variables (e.g., in a search box or file browser), you may encounter race conditions where older network responses arrive after newer ones:

```dart
observable.variables = {"id": 1}
observable.fetchResults(fetchPolicy: FetchPolicy.cacheAndNetwork);
// Cached result for id 1 returns immediately
// Network request for id 1 starts...

observable.variables = {"id": 2}
observable.fetchResults(fetchPolicy: FetchPolicy.cacheAndNetwork);
// Cached result for id 2 returns immediately
// Network request for id 2 starts...
// ❌ Network result for id 1 returns (OLD DATA!)
// ✅ Network result for id 2 returns
```

## The Solution: CancellationLink

The `CancellationLink` automatically cancels previous in-flight requests when a new request with the same query is made.

### Basic Setup

```dart
import 'package:graphql/client.dart';

final httpLink = HttpLink('https://api.example.com/graphql');

final client = GraphQLClient(
  link: Link.from([
    CancellationLink(),  // Add this before your HTTP link
    httpLink,
  ]),
  cache: GraphQLCache(),
);
```

That's it! Now race conditions are automatically prevented.

### How It Works

1. **Automatic Cancellation**: When you change `observable.variables` and call `fetchResults()`, the previous network request is automatically cancelled.

2. **Query Key Matching**: Requests are matched based on their operation and variables. Same query + same variables = deduplicated. Different variables = old request cancelled.

3. **Context Propagation**: The `CancellationLink` adds a `CancelToken` to the request context, which can be used by downstream links that support cancellation.

### Example: File Browser

```dart
// File browser that changes folder frequently
final observable = client.watchQuery(
  WatchQueryOptions(
    document: gql(r'''
      query GetFiles($folderId: ID!) {
        folder(id: $folderId) {
          files { id name }
        }
      }
    '''),
    variables: {'folderId': 'folder-1'},
    fetchPolicy: FetchPolicy.cacheAndNetwork,
  ),
);

// User navigates quickly through folders
observable.variables = {'folderId': 'folder-2'};  // Request for folder-1 cancelled
observable.fetchResults();

observable.variables = {'folderId': 'folder-3'};  // Request for folder-2 cancelled
observable.fetchResults();

// Only folder-3 results will be shown ✅
```

### Example: Search Autocomplete

```dart
void onSearchChanged(String query) {
  observable.variables = {'query': query};
  observable.fetchResults();
  // Previous search automatically cancelled
}
```

## Using CancelToken Directly

For more control, you can use `CancelToken` directly without `CancellationLink`:

```dart
final cancelToken = CancelToken();

final queryFuture = client.query(
  QueryOptions(
    document: gql(query),
    variables: {'id': 1},
    context: Context.fromList([
      CancelTokenEntry(cancelToken),
    ]),
  ),
);

// Later, to cancel:
cancelToken.cancel();

// Handle the cancellation
queryFuture.catchError((error) {
  print('Query cancelled or failed: $error');
});
```

### Custom HTTP Link with Cancellation Support

If you're building a custom HTTP link, read the `CancelToken` from context:

```dart
class MyHttpLink extends Link {
  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    // Extract cancel token from context
    CancelToken? cancelToken;
    try {
      final entry = request.context.entry<CancelTokenEntry>();
      cancelToken = entry?.token;
    } catch (_) {}

    // Use it with your HTTP client
    final httpRequest = http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: cancelToken?.future,
    );

    // ... send request and yield response
  }
}
```

## When to Use Cancellation

✅ **Good use cases:**
- Search autocomplete
- File/folder browsers
- Rapidly changing filter/sort options
- User clicking "cancel" button
- Component unmounting with in-flight requests

❌ **Not needed for:**
- Simple one-off queries
- Mutations (usually shouldn't be cancelled)
- Queries that complete quickly
- When you need all results regardless of order

## Performance Benefits

- **Reduced network traffic**: Cancelled requests stop downloading data
- **Lower memory usage**: Old responses don't get processed
- **Better UX**: Users see only relevant, up-to-date results
- **Prevents bugs**: Eliminates race condition bugs

## Compatibility

- ✅ Works with `ObservableQuery`
- ✅ Works with `client.query()`
- ✅ Works with `client.mutate()`
- ✅ Works with `client.subscribe()`
- ✅ Compatible with all existing links
- ⚠️ Requires HTTP client that supports cancellation (e.g., `http.AbortableRequest`)

## Troubleshooting

### Cancellation not working?

1. **Check link order**: `CancellationLink` must come BEFORE your HTTP link
   ```dart
   Link.from([
     CancellationLink(),  // ✅ First
     httpLink,            // ✅ Second
   ])
   ```

2. **Check HTTP client support**: Your HTTP link must support cancellation via `AbortableRequest` or similar.

3. **Check for errors**: Enable logging to see if cancellation errors are being thrown.

### How to debug?

```dart
class DebugCancellationLink extends Link {
  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    print('Request started: ${request.operation.operationName}');

    try {
      await for (final response in forward!(request)) {
        print('Response received: ${request.operation.operationName}');
        yield response;
      }
    } catch (e) {
      print('Request failed or cancelled: ${request.operation.operationName}');
      rethrow;
    }
  }
}

final client = GraphQLClient(
  link: Link.from([
    DebugCancellationLink(),
    CancellationLink(),
    httpLink,
  ]),
  cache: GraphQLCache(),
);
```
