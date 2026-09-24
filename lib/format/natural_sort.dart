// 自然序（natural order）比较：**数字段按数值大小**排（`META-11` ②）。
//
// 为什么不用字典序：`10.jpg` 的字典序排在 `2.jpg` 之前（`'1' < '2'`），
// 漫画页序会被打乱；自然序把连续数字段当数字比较 → `2.jpg` 在 `10.jpg` 之前。
// CBZ / CBR 的图片页排序用它（`FMT-02` 验收①「按页顺序显示」、`META-11` ②）。
//
// 纯 Dart 叶子：零 import，可进 isolate。
//
// 比较口径（确定性全序）：
//   1. 数字段按**数值**比较（先比有效位数、再逐位；前导零少者在前：`7` < `07`）；
//   2. 非数字段逐字符比较，**ASCII 大小写不敏感**（`Page.jpg` 与 `page.jpg` 稳定排序）；
//   3. 全部相等时回退原始串 `compareTo`（大小写不同时也保持全序，排序结果稳定）。
int compareNatural(String a, String b) {
  int i = 0;
  int j = 0;
  while (i < a.length && j < b.length) {
    final int ca = a.codeUnitAt(i);
    final int cb = b.codeUnitAt(j);
    final bool da = _isDigit(ca);
    final bool db = _isDigit(cb);
    if (da && db) {
      // 数字段：跳过前导 0，比较有效数位。
      int sa = i;
      int sb = j;
      while (sa < a.length && a.codeUnitAt(sa) == 0x30) {
        sa++;
      }
      while (sb < b.length && b.codeUnitAt(sb) == 0x30) {
        sb++;
      }
      int ea = sa;
      int eb = sb;
      while (ea < a.length && _isDigit(a.codeUnitAt(ea))) {
        ea++;
      }
      while (eb < b.length && _isDigit(b.codeUnitAt(eb))) {
        eb++;
      }
      final int la = ea - sa;
      final int lb = eb - sb;
      if (la != lb) return la - lb; // 有效位数多 = 数值大
      for (int k = 0; k < la; k++) {
        final int d = a.codeUnitAt(sa + k) - b.codeUnitAt(sb + k);
        if (d != 0) return d;
      }
      // 数值相等：前导零少的在前（`7` < `07`）。
      final int za = sa - i;
      final int zb = sb - j;
      if (za != zb) return za - zb;
      i = ea;
      j = eb;
    } else {
      final int x = _lowerAscii(ca);
      final int y = _lowerAscii(cb);
      if (x != y) return x - y;
      i++;
      j++;
    }
  }
  // 先耗尽的在前（`a` < `a1`）。
  final int ra = a.length - i;
  final int rb = b.length - j;
  if (ra != rb) return ra - rb;
  return a.compareTo(b); // 仅大小写差异时回退原始串，保证全序稳定
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

int _lowerAscii(int c) => (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c;
