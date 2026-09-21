// XML / 文本小工具（从 `epub_parser.dart` 提出，供 `epub_toc.dart` 复用）。
//
// 纯 Dart：不 import Flutter、不 import dart:io。
import 'package:xml/xml.dart';

/// 尝试解析 XML；失败返回 `null`（由上层转成可读的中文错误）。
XmlDocument? tryParseXml(String text) {
  try {
    return XmlDocument.parse(text);
  } catch (_) {
    return null;
  }
}

/// 按 localName **递归**收集后代元素，忽略命名空间前缀差异。
///
/// 注意：本函数只取**后代**（不含 `root` 自身），且**不带层级信息**——
/// 需要嵌套深度（如目录层级）时必须改用逐层 `childElements` 递归。
Iterable<XmlElement> findAllByLocalName(XmlNode root, String localName) sync* {
  for (final XmlElement element in root.childElements) {
    if (element.name.local == localName) yield element;
    yield* findAllByLocalName(element, localName);
  }
}

/// 递归拼接节点内的全部文本（只取 [XmlText]，天然跳过注释）。
void collectXmlText(XmlNode node, StringBuffer buffer) {
  for (final XmlNode child in node.children) {
    if (child is XmlText) {
      buffer.write(child.value);
    } else if (child is XmlElement) {
      collectXmlText(child, buffer);
    }
  }
}

/// 折叠空白：连续空白（含换行）压成单个空格并 trim。
String collapseWhitespace(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 节点（含自身）内的全部文本，已折叠空白。
String collapsedText(XmlNode node) {
  final StringBuffer buffer = StringBuffer();
  collectXmlText(node, buffer);
  return collapseWhitespace(buffer.toString());
}

/// 取某个 localName 下第一段非空文本（递归，忽略命名空间前缀）。
String firstLocalizedText(XmlNode root, String localName) {
  for (final XmlElement element in findAllByLocalName(root, localName)) {
    final String text = collapsedText(element);
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 在 [element]（含自身）的子树上找第一个 localName 匹配的元素。
XmlElement? firstElementIn(XmlNode element, String localName) {
  if (element is XmlElement && element.name.local == localName) return element;
  for (final XmlElement child in element.childElements) {
    final XmlElement? found = firstElementIn(child, localName);
    if (found != null) return found;
  }
  return null;
}

/// 在 [element]（含自身）的子树上找第一个 localName 匹配元素的指定属性值。
String? firstAttributeIn(
  XmlElement element,
  String localName,
  String attributeName,
) {
  final XmlElement? found = firstElementIn(element, localName);
  return found?.getAttribute(attributeName);
}
