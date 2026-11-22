import 'dart:convert';

import '../sync/api_client.dart';

/// A short, plain message that can be shown to the shopkeeper as it is.
class AiError implements Exception {
  AiError(this.message);
  final String message;
  @override
  String toString() => message;
}

class AiSuggestion {
  const AiSuggestion(this.name, this.brand);
  final String name;
  final String brand;
}

/// The online-only assistant. Every call goes to the shop's server, which holds the key; nothing here works without a connection,
/// and nothing in the till depends on it.
class AiService {
  AiService(this.api);
  final ApiTransport api;

  Future<Map<String, dynamic>> _call(String method, String path, [Object? body]) async {
    final ApiResponse res;
    try {
      res = await api.send(method, path, body: body);
    } on NetworkException {
      throw AiError('You need internet for this. Try again when you are online.');
    }
    if (res.status == 200) return res.json;
    switch (res.errorCode) {
      case 'ai_unavailable':
        throw AiError('The assistant is not switched on yet. Ask your supplier.');
      case 'ai_not_included':
        throw AiError('The assistant is not part of your plan. Ask your supplier to add it.');
      case 'ai_limit_reached':
        throw AiError('This month\'s assistant limit is used up. It starts again next month.');
      case 'ai_failed':
        throw AiError('The assistant could not answer right now. Try again in a moment.');
    }
    throw AiError(res.errorMessage.isEmpty ? 'The assistant could not be reached (error ${res.status}).' : res.errorMessage);
  }

  /// Is the assistant on for this shop? Null when we could not find out (offline).
  Future<bool?> isIncluded() async {
    try {
      final j = await _call('GET', '/v1/ai/status');
      return j['available'] == true && j['included'] == true;
    } on AiError {
      return null;
    }
  }

  /// Looks at a product photo and suggests a name and brand. Returns empty strings when it cannot tell.
  Future<AiSuggestion> suggestProduct(List<int> jpeg) async {
    final j = await _call('POST', '/v1/ai/suggest-product', {'data': base64Encode(jpeg)});
    return AiSuggestion((j['name'] as String?) ?? '', (j['brand'] as String?) ?? '');
  }

  /// Asks about the shop. Sales figures are only sent for when the signed-in person may see reports.
  Future<String> ask(String question, {required bool includeSales}) async {
    final j = await _call('POST', '/v1/ai/ask', {
      'question': question,
      'include_sales': includeSales,
      'offset_min': DateTime.now().timeZoneOffset.inMinutes,
    });
    return (j['answer'] as String?) ?? '';
  }
}
