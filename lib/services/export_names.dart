/// An export file name: [base] with characters that are illegal in
/// Windows/macOS/Android filenames replaced (auto session names contain `:`
/// — e.g. `2026-07-29 14:05:32`), leading dots stripped (they would hide the
/// file on macOS/Linux), trailing dots/spaces trimmed (illegal on Windows),
/// and a Windows reserved device name disambiguated with an underscore —
/// Windows refuses CON, NUL, COM1–COM9, LPT1–LPT9 and friends regardless of
/// extension, so the save dialog would reject the suggested name outright.
/// An empty (or scrubbed-away) base becomes [fallback].
library;

String exportFileNameFor(
  String base,
  String extension, {
  String fallback = 'export',
}) {
  var name = (base.isEmpty ? fallback : base)
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
      .replaceAll(RegExp(r'^\.+'), '')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = fallback;
  // Reserved when followed by the end of the name or an extension dot
  // ("con.txt" is as refused as "con"); keep the name recognizable by
  // marking it right after the reserved word ("con_.txt").
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?=\.|$)',
    caseSensitive: false,
  ).firstMatch(name);
  if (reserved != null) {
    name = '${reserved[0]}_${name.substring(reserved.end)}';
  }
  return '$name.$extension';
}
