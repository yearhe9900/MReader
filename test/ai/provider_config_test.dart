// `M3-T01`：AiProviderConfig 序列化 / 校验 / 端点派生测试（`AI-01`、`DATA-02` ①）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mreader/ai/provider_config.dart';

AiProviderConfig _valid({
  String id = 'c1',
  String name = '测试配置',
  String baseUrl = 'https://api.deepseek.com/v1',
  String model = 'deepseek-chat',
  Map<String, String> headers = const <String, String>{},
  int timeout = 60,
  int? maxTokens,
  double? temperature,
  Set<AiUseCase> useFor = const <AiUseCase>{},
}) {
  return AiProviderConfig(
    id: id,
    name: name,
    baseUrl: baseUrl,
    model: model,
    customHeaders: headers,
    timeoutSeconds: timeout,
    maxTokens: maxTokens,
    temperature: temperature,
    useFor: useFor,
  );
}

void main() {
  group('序列化（`DATA-02` ①：apiKey 结构性不落盘）', () {
    test('toJson 不含 apiKey 字段', () {
      final Map<String, Object?> json = _valid().toJson();
      expect(json.keys, isNot(contains('apiKey')));
      expect(json.containsKey('key'), isFalse);
    });

    test('roundtrip：toJson → fromJson 字段保真', () {
      final AiProviderConfig src = _valid(
        headers: const <String, String>{'X-Org': 'acme'},
        timeout: 30,
        maxTokens: 1024,
        temperature: 0.7,
        useFor: const <AiUseCase>{AiUseCase.chat, AiUseCase.translate},
      );
      final AiProviderConfig? back = AiProviderConfig.fromJson(src.toJson());
      expect(back, isNotNull);
      expect(back!.id, 'c1');
      expect(back.name, '测试配置');
      expect(back.baseUrl, 'https://api.deepseek.com/v1');
      expect(back.model, 'deepseek-chat');
      expect(back.customHeaders, <String, String>{'X-Org': 'acme'});
      expect(back.timeoutSeconds, 30);
      expect(back.maxTokens, 1024);
      expect(back.temperature, 0.7);
      expect(back.useFor, <AiUseCase>{AiUseCase.chat, AiUseCase.translate});
    });

    test('fromJson 容错：非 Map / 缺关键字段 → null；缺省字段回退默认', () {
      expect(AiProviderConfig.fromJson('not a map'), isNull);
      expect(AiProviderConfig.fromJson(<String, Object?>{'id': 'x'}), isNull);
      final AiProviderConfig? minimal = AiProviderConfig.fromJson(
        <String, Object?>{'id': 'a', 'name': 'n', 'baseUrl': 'u', 'model': 'm'},
      );
      expect(minimal, isNotNull);
      expect(minimal!.timeoutSeconds, AiProviderConfig.defaultTimeoutSeconds);
      expect(minimal.maxTokens, isNull);
      expect(minimal.temperature, isNull);
      expect(minimal.useFor, isEmpty);
    });

    test('坏 timeout 回退默认；未知 useFor 名被跳过', () {
      final AiProviderConfig? c = AiProviderConfig.fromJson(<String, Object?>{
        'id': 'a',
        'name': 'n',
        'baseUrl': 'u',
        'model': 'm',
        'timeoutSeconds': -5,
        'useFor': <String>['chat', 'bogus'],
      });
      expect(c!.timeoutSeconds, AiProviderConfig.defaultTimeoutSeconds);
      expect(c.useFor, <AiUseCase>{AiUseCase.chat});
    });
  });

  group('validate（`AI-01` ② 可读中文错误）', () {
    test('合法配置 → null', () {
      expect(_valid().validate(), isNull);
    });

    test('空配置名 → 报错', () {
      expect(_valid(name: '   ').validate(), '请填写配置名称');
    });

    test('非 http(s) Base URL → 报错', () {
      expect(_valid(baseUrl: 'ftp://x').validate(), isNotNull);
      expect(_valid(baseUrl: '不完整地址').validate(), isNotNull);
      expect(_valid(baseUrl: '').validate(), isNotNull);
    });

    test('空模型名 / 非正超时 / 非正 maxTokens / 越界温度 → 各自报错', () {
      expect(_valid(model: '').validate(), '请填写模型名');
      expect(_valid(timeout: 0).validate(), '超时需为正整数秒');
      expect(_valid(maxTokens: 0).validate(), 'max_tokens 需为正整数');
      expect(_valid(temperature: 2.5).validate(), 'temperature 取值范围为 0 ~ 2');
      expect(_valid(temperature: -0.1).validate(), isNotNull);
    });
  });

  group('端点派生', () {
    test('chatCompletionsUri：去尾斜杠 + /chat/completions', () {
      expect(
        _valid(baseUrl: 'https://api.deepseek.com/v1/').chatCompletionsUri.toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(
        _valid(baseUrl: 'http://127.0.0.1:8080/v1').chatCompletionsUri.toString(),
        'http://127.0.0.1:8080/v1/chat/completions',
      );
    });
  });

  group('AiUseCase.tryParse', () {
    test('已知名 → 枚举；未知 / null → null', () {
      expect(AiUseCase.tryParse('chat'), AiUseCase.chat);
      expect(AiUseCase.tryParse('translate'), AiUseCase.translate);
      expect(AiUseCase.tryParse('bogus'), isNull);
      expect(AiUseCase.tryParse(null), isNull);
    });

    test('label 中文展示名', () {
      expect(AiUseCase.chat.label, '对话');
      expect(AiUseCase.summarize.label, '摘要');
    });
  });
}
